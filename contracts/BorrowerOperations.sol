// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "../Interfaces/IBorrowerOperations.sol";
import "../Interfaces/ITroveManager.sol";
import "../Interfaces/ISUSDToken.sol";
import "../Interfaces/ICollSurplusPool.sol";
import "../Interfaces/ISortedTroves.sol";
import "../Interfaces/IWhitelist.sol";
import "../Interfaces/IStabRouter.sol";
import "../Interfaces/IERC20.sol";
import "../Interfaces/IWAsset.sol";
import "../Interfaces/ISTBStaking.sol";
import "../Dependencies/LiquityBase.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/ReentrancyGuard.sol";
import "../Dependencies/SafeERC20.sol";


/**
 * BorrowerOperations is the contract that handles most of external facing trove activities that 
 * a user would make with their own trove, like opening, closing, adjusting, increasing leverage, etc.
 */

 /**
   A summary of Lever Up:
   Takes in a collateral token A, and simulates borrowing of YUSD at a certain collateral ratio and
   buying more token A, putting back into protocol, buying more A, etc. at a certain leverage amount.
   So if at 3x leverage and 1000$ token A, it will mint 1000 * 3x * 2/3 = $2000 YUSD, then swap for
   token A by using some router strategy, returning a little under $2000 token A to put back in the
   trove. The number here is 2/3 because the math works out to be that collateral ratio is 150% if
   we have a 3x leverage. They now have a trove with $3000 of token A and a collateral ratio of 150%.
  */

contract BorrowerOperations is LiquityBase, Ownable, IBorrowerOperations, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    string public constant NAME = "BorrowerOperations";

    // --- Connected contract declarations ---

    ITroveManager internal troveManager;

    address internal stabilityPoolAddress;

    address internal gasPoolAddress;

    ICollSurplusPool internal collSurplusPool;

    ISSTB internal stbStaking;
    address internal stbStakingAddress;

    address internal sSTBAddress;

    ISUSDToken internal susdToken;

    uint internal constant BOOTSTRAP_PERIOD = 14 days;
    uint deploymentTime;

    // A doubly linked list of Troves, sorted by their recovery collateral ratios
    ISortedTroves internal sortedTroves;


    //bool leverUpEnabled; // if false, then leverup functions cannot be called.


    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct DepositFeeCalc {
        uint256 collateralSUSDFee;
        uint256 systemCollateralVC;
        uint256 collateralInputVC;
        uint256 systemTotalVC;
        address token;
        uint256 activePoolVCPost;
    }

    struct AdjustTrove_Params {
        address[] _collsIn;
        uint256[] _amountsIn;
        address[] _collsOut;
        uint256[] _amountsOut;
        uint256[] _maxSlippages;
        uint256 _SUSDChange;
//      uint256 _totalSUSDDebtFromLever;
        bool _isDebtIncrease;
       // bool _isUnlever;
        address _upperHint;
        address _lowerHint;
        uint256 _maxFeePercentage;
    }

    struct LocalVariables_adjustTrove {
        uint256 netDebtChange;
        bool isCollIncrease;
        bool isRecoveryMode;
        uint256 collChange;
        uint256 currVC;
        uint256 newVC;
        uint256 debt;
        address[] currAssets;
        uint256[] currAmounts;
        address[] newAssets;
        uint256[] newAmounts;
        uint256 oldICR;
        uint256 newICR;
        uint256 newRICR;
        uint256 newTCR;
        uint256 SUSDFee;
        uint256 variableSUSDFee;
        uint256 newDebt;
        uint256 VCin;
        uint256 VCout;
        uint256 maxFeePercentageFactor;
        uint256 entireSystemColl;
        uint256 entireSystemDebt;
    }

    struct OpenTrove_Params {
        uint256 _maxFeePercentage;
        uint256 _SUSDAmount;
        uint256 _totalSUSDDebtFromLever;
        address _upperHint;
        address _lowerHint;
    }

    struct LocalVariables_openTrove {
        uint256 SUSDFee;
        uint256 netDebt;
        uint256 compositeDebt;
        uint256 RICR;
        uint256 ICR;
        uint256 arrayIndex;
        uint256 VC;
        uint256 newTCR;
        uint256 entireSystemColl;
        uint256 entireSystemDebt;
        bool isRecoveryMode;
    }

    struct CloseTrove_Params {
        address[] _collsOut;
        uint256[] _amountsOut;
        uint256[] _maxSlippages;
        //bool _isUnlever;
    }

    struct ContractsCache {
        ITroveManager troveManager;
        IActivePool activePool;
        ISUSDToken susdToken;
        IWhitelist whitelist;
    }

    enum BorrowerOperation {
        openTrove,
        closeTrove,
        adjustTrove
    }

    event TroveCreated(address indexed _borrower, uint256 arrayIndex);
    event TroveUpdated(
        address indexed _borrower,
        uint256 _debt,
        address[] _tokens,
        uint256[] _amounts,
        BorrowerOperation operation
    );
    event SUSDBorrowingFeePaid(address indexed _borrower, uint256 _SUSDFee);



    // --- Dependency setters ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _sortedTrovesAddress,
        address _susdTokenAddress,
        address _sSTBAddress,
        address _whitelistAddress
    ) external override onlyOwner {
        // This makes impossible to open a trove with zero withdrawn YUSD
        require(MIN_NET_DEBT != 0, "BO:MIN_NET_DEBT==0");

        deploymentTime = block.timestamp;

        troveManager = ITroveManager(_troveManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        whitelist = IWhitelist(_whitelistAddress);
        stabilityPoolAddress = _stabilityPoolAddress;
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        susdToken = ISUSDToken(_susdTokenAddress);
        sSTBAddress = _sSTBAddress;

        _renounceOwnership();
    }

    // --- Borrower Trove Operations ---

        function openTrove(
        uint256 _maxFeePercentage,
        uint256 _SUSDAmount,
        address _upperHint,
        address _lowerHint,
        address[] calldata _colls,
        uint256[] calldata _amounts
    ) external override nonReentrant {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);
        _requireLengthNonzero(_amounts.length);
        _requireValidDepositCollateral(_colls, _amounts, contractsCache.whitelist);

        // transfer collateral into ActivePool
        _transferCollateralsIntoActivePool(_colls, _amounts);

        OpenTrove_Params memory params = OpenTrove_Params(
            _maxFeePercentage,
            _SUSDAmount,
            0,
            _upperHint,
            _lowerHint
        );
        _openTroveInternal(params, _colls, _amounts, contractsCache);
    }


    // amounts should be a uint array giving the amount of each collateral
    // to be transferred in in order of the current whitelist
    // Should be called *after* collateral has been already sent to the active pool
    // Should confirm _colls, is valid collateral prior to calling this
    function _openTroveInternal(
        OpenTrove_Params memory params,
        address[] memory _colls,
        uint256[] memory _amounts,
        ContractsCache memory contractsCache
    ) internal {
        LocalVariables_openTrove memory vars;

        (vars.isRecoveryMode, vars.entireSystemColl, vars.entireSystemDebt) = _checkRecoveryModeAndSystem();

        _requireValidMaxFeePercentage(params._maxFeePercentage, vars.isRecoveryMode);
        _requireTroveisNotActive(contractsCache.troveManager, msg.sender);

        vars.netDebt = params._SUSDAmount;

        // For every collateral type in, calculate the VC and get the variable fee
        vars.VC = contractsCache.whitelist.getValuesVC(_colls, _amounts);

        if (!vars.isRecoveryMode) {
            // when not in recovery mode, add in the 0.5% fee
            vars.SUSDFee = _triggerBorrowingFee(
                contractsCache.troveManager,
                contractsCache.susdToken,
                params._SUSDAmount,
                vars.VC, // here it is just VC in, which is always larger than YUSD amount
                params._maxFeePercentage
            );
            params._maxFeePercentage = params._maxFeePercentage.sub(vars.SUSDFee.mul(DECIMAL_PRECISION).div(vars.VC));
        }

        // Add in variable fee. Always present, even in recovery mode.
        vars.SUSDFee = vars.SUSDFee.add(
            _getTotalVariableDepositFee(_colls, _amounts, vars.entireSystemColl, vars.VC, 0, vars.VC, params._maxFeePercentage, contractsCache)
        );
        
        // Adds total fees to netDebt
        vars.netDebt = vars.netDebt.add(vars.SUSDFee); // The raw debt change includes the fee

        _requireAtLeastMinNetDebt(vars.netDebt);
        // ICR is based on the composite debt, i.e. the requested YUSD amount + YUSD borrowing fee + YUSD gas comp.
        // _getCompositeDebt returns  vars.netDebt + YUSD gas comp.
        vars.compositeDebt = _getCompositeDebt(vars.netDebt);

        vars.ICR = LiquityMath._computeCR(vars.VC, vars.compositeDebt);
        if (vars.isRecoveryMode) {
            _requireICRisAboveCCR(vars.ICR);
        } else {
            _requireICRisAboveMCR(vars.ICR);
            vars.newTCR = _getNewTCRFromTroveChange(vars.entireSystemColl, vars.entireSystemDebt, vars.VC, true, vars.compositeDebt, true); // bools: coll increase, debt increase
            _requireNewTCRisAboveCCR(vars.newTCR);
        }

        // Set the trove struct's properties
        contractsCache.troveManager.setTroveStatus(msg.sender, 1);

        contractsCache.troveManager.updateTroveColl(msg.sender, _colls, _amounts);
        contractsCache.troveManager.increaseTroveDebt(msg.sender, vars.compositeDebt);

        contractsCache.troveManager.updateTroveRewardSnapshots(msg.sender);

        contractsCache.troveManager.updateStakeAndTotalStakes(msg.sender);

        vars.RICR = LiquityMath._computeCR(_getRVC(_colls, _amounts), vars.compositeDebt);

        sortedTroves.insert(msg.sender, vars.RICR, params._upperHint, params._lowerHint);
        vars.arrayIndex = contractsCache.troveManager.addTroveOwnerToArray(msg.sender);
        emit TroveCreated(msg.sender, vars.arrayIndex);

        contractsCache.activePool.receiveCollateral(_colls, _amounts);

        _withdrawSUSD(
            contractsCache.activePool,
            contractsCache.susdToken,
            msg.sender,
            params._SUSDAmount.sub(params._totalSUSDDebtFromLever),
            vars.netDebt
        );

        // Move the YUSD gas compensation to the Gas Pool
        _withdrawSUSD(
            contractsCache.activePool,
            contractsCache.susdToken,
            gasPoolAddress,
            SUSD_GAS_COMPENSATION,
            SUSD_GAS_COMPENSATION
        );

        emit TroveUpdated(
            msg.sender,
            vars.compositeDebt,
            _colls,
            _amounts,
            BorrowerOperation.openTrove
        );
        emit SUSDBorrowingFeePaid(msg.sender, vars.SUSDFee);
    }


    // add collateral to trove. Calls _adjustTrove with correct params. 
    function addColl(
        address[] calldata _collsIn,
        uint256[] calldata _amountsIn,
        address _upperHint,
        address _lowerHint, 
        uint256 _maxFeePercentage
    ) external override nonReentrant {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);
        AdjustTrove_Params memory params;
        params._collsIn = _collsIn;
        params._amountsIn = _amountsIn;
        params._upperHint = _upperHint;
        params._lowerHint = _lowerHint;
        params._maxFeePercentage = _maxFeePercentage;

        // check that all _collsIn collateral types are in the whitelist
        _requireValidDepositCollateral(_collsIn, _amountsIn, contractsCache.whitelist);

        // pull in deposit collateral
        _transferCollateralsIntoActivePool(_collsIn, _amountsIn);
        _adjustTrove(params, contractsCache);
    }



    // Withdraw collateral from a trove. Calls _adjustTrove with correct params. 
    function withdrawColl(
        address[] calldata _collsOut,
        uint256[] calldata _amountsOut,
        address _upperHint,
        address _lowerHint
    ) external override nonReentrant {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);
        AdjustTrove_Params memory params;
        params._collsOut = _collsOut;
        params._amountsOut = _amountsOut;
        params._upperHint = _upperHint;
        params._lowerHint = _lowerHint;

        // check that all _collsOut collateral types are in the whitelist
        _requireValidDepositCollateral(_collsOut, _amountsOut, contractsCache.whitelist);

        _adjustTrove(params, contractsCache);
    }

    // Withdraw YUSD tokens from a trove: mint new YUSD tokens to the owner, and increase the trove's debt accordingly. 
    // Calls _adjustTrove with correct params. 
    function withdrawSUSD(
        uint256 _maxFeePercentage,
        uint256 _SUSDAmount,
        address _upperHint,
        address _lowerHint
    ) external override nonReentrant {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);
        AdjustTrove_Params memory params;
        params._SUSDChange = _SUSDAmount;
        params._maxFeePercentage = _maxFeePercentage;
        params._upperHint = _upperHint;
        params._lowerHint = _lowerHint;
        params._isDebtIncrease = true;
        _adjustTrove(params, contractsCache);
    }

    // Repay YUSD tokens to a Trove: Burn the repaid YUSD tokens, and reduce the trove's debt accordingly. 
    // Calls _adjustTrove with correct params. 
    function repaySUSD(
        uint256 _SUSDAmount,
        address _upperHint,
        address _lowerHint
    ) external override nonReentrant {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);
        AdjustTrove_Params memory params;
        params._SUSDChange = _SUSDAmount;
        params._upperHint = _upperHint;
        params._lowerHint = _lowerHint;
        params._isDebtIncrease = false;
        _adjustTrove(params, contractsCache);
    }

    // Adjusts trove with multiple colls in / out. Calls _adjustTrove with correct params.
    function adjustTrove(
        address[] calldata _collsIn,
        uint256[] memory _amountsIn,
        address[] calldata _collsOut,
        uint256[] calldata _amountsOut,
        uint256 _SUSDChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint,
        uint256 _maxFeePercentage
    ) external override nonReentrant {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);
        // check that all _collsIn collateral types are in the whitelist
        _requireValidDepositCollateral(_collsIn, _amountsIn, contractsCache.whitelist);
        _requireValidDepositCollateral(_collsOut, _amountsOut, contractsCache.whitelist);
        _requireNoOverlapColls(_collsIn, _collsOut); // check that there are no overlap between _collsIn and _collsOut

        // pull in deposit collateral
        _transferCollateralsIntoActivePool(_collsIn, _amountsIn);

        AdjustTrove_Params memory params = AdjustTrove_Params(
            _collsIn,
            _amountsIn,
            _collsOut,
            _amountsOut,
            new uint256[](0), // max leverages is a 0 array in this case.
            _SUSDChange,
            0,
            _isDebtIncrease,
            false,
            _upperHint,
            _lowerHint,
            _maxFeePercentage
        );

        _adjustTrove(params, contractsCache);
    }

    /*
     * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
     * the ith element of _amountsIn and _amountsOut corresponds to the ith element of the addresses _collsIn and _collsOut passed in
     *
     * Should be called after the collsIn has been sent to ActivePool
     */
    function _adjustTrove(AdjustTrove_Params memory params, ContractsCache memory contractsCache) internal {

        LocalVariables_adjustTrove memory vars;

        (vars.isRecoveryMode, vars.entireSystemColl, vars.entireSystemDebt) = _checkRecoveryModeAndSystem();

        if (params._isDebtIncrease) {
            _requireValidMaxFeePercentage(params._maxFeePercentage, vars.isRecoveryMode);
            _requireNonZeroDebtChange(params._SUSDChange);
        }

        // Checks that at least one array is non-empty, and also that at least one value is 1. 
        _requireNonZeroAdjustment(params._amountsIn, params._amountsOut, params._SUSDChange);
        _requireTroveisActive(contractsCache.troveManager, msg.sender);

        contractsCache.troveManager.applyPendingRewards(msg.sender);
        vars.netDebtChange = params._SUSDChange;

        vars.VCin = contractsCache.whitelist.getValuesVC(params._collsIn, params._amountsIn);
        vars.VCout = contractsCache.whitelist.getValuesVC(params._collsOut, params._amountsOut);

        if (params._isDebtIncrease) {
            vars.maxFeePercentageFactor = LiquityMath._max(vars.VCin, params._SUSDChange);
        } else {
            vars.maxFeePercentageFactor = vars.VCin;
        }
        
        // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
        if (params._isDebtIncrease && !vars.isRecoveryMode) {
            vars.SUSDFee = _triggerBorrowingFee(
                contractsCache.troveManager,
                contractsCache.susdToken,
                params._SUSDChange,
                vars.maxFeePercentageFactor, // max of VC in and YUSD change here to see what the max borrowing fee is triggered on.
                params._maxFeePercentage
            );
            // passed in max fee minus actual fee percent applied so far
            params._maxFeePercentage = params._maxFeePercentage.sub(vars.SUSDFee.mul(DECIMAL_PRECISION).div(vars.maxFeePercentageFactor)); 
            vars.netDebtChange = vars.netDebtChange.add(vars.SUSDFee); // The raw debt change includes the fee
        }

        // get current portfolio in trove
        (vars.currAssets, vars.currAmounts) = contractsCache.troveManager.getTroveColls(msg.sender);
        // current VC based on current portfolio and latest prices
        vars.currVC = contractsCache.whitelist.getValuesVC(vars.currAssets, vars.currAmounts);

        // get new portfolio in trove after changes. Will error if invalid changes:
        (vars.newAssets, vars.newAmounts) = _getNewPortfolio(
            vars.currAssets,
            vars.currAmounts,
            params._collsIn,
            params._amountsIn,
            params._collsOut,
            params._amountsOut
        );
        // new VC based on new portfolio and latest prices
        vars.newVC = vars.currVC.add(vars.VCin).sub(vars.VCout);

        vars.isCollIncrease = vars.newVC > vars.currVC;
        vars.collChange = 0;
        if (vars.isCollIncrease) {
            vars.collChange = (vars.newVC).sub(vars.currVC);
        } else {
            vars.collChange = (vars.currVC).sub(vars.newVC);
        }

        vars.debt = contractsCache.troveManager.getTroveDebt(msg.sender);

        if (params._collsIn.length != 0) {
            vars.variableSUSDFee = _getTotalVariableDepositFee(
                    params._collsIn,
                    params._amountsIn,
                    vars.entireSystemColl,
                    vars.VCin,
                    vars.VCout,
                    vars.maxFeePercentageFactor,
                    params._maxFeePercentage,
                    contractsCache
            );
        }

        // Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
        vars.oldICR = LiquityMath._computeCR(vars.currVC, vars.debt);

        vars.debt = vars.debt.add(vars.variableSUSDFee); 

        vars.newICR = _getNewICRFromTroveChange(vars.newVC,
            vars.debt, // with variableYUSDFee already added. 
            vars.netDebtChange,
            params._isDebtIncrease 
        );

        // Check the adjustment satisfies all conditions for the current system mode
        _requireValidAdjustmentInCurrentMode(
            params._amountsOut,
            params._isDebtIncrease,
            vars
        );

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough YUSD
        if (!params._isUnlever && !params._isDebtIncrease && params._SUSDChange != 0) {
            _requireAtLeastMinNetDebt(_getNetDebt(vars.debt).sub(vars.netDebtChange));
            _requireValidSUSDRepayment(vars.debt, vars.netDebtChange);
            _requireSufficientSUSDBalance(contractsCache.susdToken, msg.sender, vars.netDebtChange);
        }

        if (params._collsIn.length != 0) {
            contractsCache.activePool.receiveCollateral(params._collsIn, params._amountsIn);
        }

        vars.newDebt = _updateTroveFromAdjustment(
            contractsCache.troveManager,
            msg.sender,
            vars.newAssets,
            vars.newAmounts,
            vars.netDebtChange,
            params._isDebtIncrease, 
            vars.variableSUSDFee
        );

        contractsCache.troveManager.updateStakeAndTotalStakes(msg.sender);

        vars.newRICR = LiquityMath._computeCR(_getRVC(vars.newAssets, vars.newAmounts), vars.newDebt);
        // Re-insert trove in to the sorted list
        sortedTroves.reInsert(msg.sender, vars.newRICR, params._upperHint, params._lowerHint);

        emit TroveUpdated(
            msg.sender,
            vars.newDebt,
            vars.newAssets,
            vars.newAmounts,
            BorrowerOperation.adjustTrove
        );
        emit SUSDBorrowingFeePaid(msg.sender, vars.SUSDFee);

            // Use the unmodified _YUSDChange here, as we don't send the fee to the user
            _moveSUSD(
                contractsCache.activePool,
                contractsCache.susdToken,
                msg.sender,
                params._SUSDChange, 
                params._isDebtIncrease,
                vars.netDebtChange
            );

            // Additionally move the variable deposit fee to the active pool manually, as it is always an increase in debt
            _withdrawSUSD(
                contractsCache.activePool,
                contractsCache.susdToken,
                msg.sender,
                0,
                vars.variableSUSDFee
            );

            // transfer withdrawn collateral to msg.sender from ActivePool
            activePool.sendCollateralsUnwrap(msg.sender, msg.sender, params._collsOut, params._amountsOut);
        }


       function closeTrove() external override nonReentrant{
        CloseTrove_Params memory params; // default false
        _closeTrove(params);
      }

    /** 
     * Closes trove by applying pending rewards, making sure that the YUSD Balance is sufficient, and transferring the 
     * collateral to the owner, and repaying the debt.
     * if it is a unlever, then it will transfer the collaterals / sell before. Otherwise it will just do it last. 
     */
    function _closeTrove(
        CloseTrove_Params memory params
        ) internal {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, susdToken, whitelist);

        _requireTroveisActive(contractsCache.troveManager, msg.sender);
        (bool isRecoveryMode, uint256 entireSystemColl, uint256 entireSystemDebt) = _checkRecoveryModeAndSystem();
        require(!isRecoveryMode, "BO:NoCloseInRecMode");

        contractsCache.troveManager.applyPendingRewards(msg.sender);

        uint256 troveVC = contractsCache.troveManager.getTroveVC(msg.sender); // should get the latest VC
        (address[] memory colls, uint256[] memory amounts) = contractsCache.troveManager.getTroveColls(
            msg.sender
        );
        uint256 debt = contractsCache.troveManager.getTroveDebt(msg.sender);

        {
        // do check after unlever (if applies)
        _requireSufficientSUSDBalance(contractsCache.susdToken, msg.sender, debt.sub(SUSD_GAS_COMPENSATION));
        uint256 newTCR = _getNewTCRFromTroveChange(entireSystemColl, entireSystemDebt, troveVC, false, debt, false);
        _requireNewTCRisAboveCCR(newTCR);

        contractsCache.troveManager.removeStake(msg.sender);
        contractsCache.troveManager.closeTrove(msg.sender);


        // Burn the repaid YUSD from the user's balance and the gas compensation from the Gas Pool
        _repaySUSD(contractsCache.activePool, contractsCache.susdToken, msg.sender, debt.sub(SUSD_GAS_COMPENSATION));
        _repaySUSD(contractsCache.activePool, contractsCache.susdToken, gasPoolAddress, SUSD_GAS_COMPENSATION);

        // Send the collateral back to the user
        // Also sends the rewards
            contractsCache.activePool.sendCollateralsUnwrap(msg.sender, msg.sender, colls, amounts);
    

        emit TroveUpdated(msg.sender, 0, new address[](0), new uint256[](0), BorrowerOperation.closeTrove);
    }
        }
    /**
     * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
     * to do all necessary interactions. TODO: Can delete if this is the only way to reduce size.
     */
    function claimCollateral() external override {
        // send collateral from CollSurplus Pool to owner
        collSurplusPool.claim(msg.sender);
    }

    // --- Helper functions ---

    /** 
     * Gets the variable deposit fee from the whitelist calculation. Multiplies the 
     * fee by the vc of the collateral.
     */
    function _getTotalVariableDepositFee(
        address[] memory _tokensIn,
        uint256[] memory _amountsIn,
        uint256 _entireSystemColl,
        uint256 _VCin,
        uint256 _VCout,
        uint256 _maxFeePercentageFactor, 
        uint256 _maxFeePercentage,
        ContractsCache memory _contractsCache
    ) internal returns (uint256 SUSDFee) {
        if (_VCin == 0) {
            return 0;
        }
        DepositFeeCalc memory vars;
        // active pool total VC at current state is passed in as _entireSystemColl
        // active pool total VC post adding and removing all collaterals
        vars.activePoolVCPost = _entireSystemColl.add(_VCin).sub(_VCout);
        uint256 tokensLen = _tokensIn.length;
        for (uint256 i; i < tokensLen; ++i) {
            vars.token = _tokensIn[i];
            // VC value of collateral of this type inputted
            vars.collateralInputVC = _contractsCache.whitelist.getValueVC(vars.token, _amountsIn[i]);

            // total value in VC of this collateral in active pool (before adding input)
            vars.systemCollateralVC = _contractsCache.activePool.getCollateralVC(vars.token).add(
                defaultPool.getCollateralVC(vars.token)
            );

            // (collateral VC In) * (Collateral's Fee Given Yeti Protocol Backed by Given Collateral)
            uint256 whitelistFee = 
                    _contractsCache.whitelist.getFeeAndUpdate(
                        vars.token,
                        vars.collateralInputVC,
                        vars.systemCollateralVC,
                        _entireSystemColl,
                        vars.activePoolVCPost
                    );
            if (_isBeforeFeeBootstrapPeriod()) {
                whitelistFee = LiquityMath._min(whitelistFee, 1e16); // cap at 1%
            } 
            vars.collateralSUSDFee = vars.collateralInputVC
                .mul(whitelistFee).div(1e18);

            SUSDFee = SUSDFee.add(vars.collateralSUSDFee);
        }
        _requireUserAcceptsFee(SUSDFee, _maxFeePercentageFactor, _maxFeePercentage);
        _triggerDepositFee(_contractsCache.susdToken, SUSDFee);
    }

    // Transfer in collateral and send to ActivePool
    // (where collateral is held)
    function _transferCollateralsIntoActivePool(
        address[] memory _colls,
        uint256[] memory _amounts
    ) internal {
        uint256 amountsLen = _amounts.length;
        for (uint256 i; i < amountsLen; ++i) {
            address collAddress = _colls[i];
            uint256 amount = _amounts[i];
            _singleTransferCollateralIntoActivePool(
                collAddress,
                amount
            );
        }
    }

    // does one transfer of collateral into active pool. Checks that it transferred to the active pool correctly.
    function _singleTransferCollateralIntoActivePool(
        address _coll,
        uint256 _amount
    ) internal {
        if (whitelist.isWrapped(_coll)) {
            // If wrapped asset then it wraps it and sends the wrapped version to the active pool, 
            // and updates reward balance to the new owner. 
            IWAsset(_coll).wrap(_amount, msg.sender, address(activePool), msg.sender);
        } else {
            IERC20(_coll).safeTransferFrom(msg.sender, address(activePool), _amount);
        }
    }

    /**
     * Triggers normal borrowing fee, calculated from base rate and on YUSD amount.
     */
    function _triggerBorrowingFee(
        ITroveManager _troveManager,
        ISUSDToken _susdToken,
        uint256 _SUSDAmount,
        uint256 _maxFeePercentageFactor,
        uint256 _maxFeePercentage
    ) internal returns (uint256) {
        _troveManager.decayBaseRateFromBorrowing(); // decay the baseRate state variable
        uint256 SUSDFee = _troveManager.getBorrowingFee(_SUSDAmount);

        _requireUserAcceptsFee(SUSDFee, _maxFeePercentageFactor, _maxFeePercentage);

        // Send fee to sSTB contract
       // stbStaking.increaseF_SUSD(SUSDFee);
        _susdToken.mint(sSTBAddress, SUSDFee); // todo 
        return SUSDFee;
    }

    function _triggerDepositFee(ISUSDToken _susdToken, uint256 _SUSDFee) internal {
        // Send fee to sSTB contract
         //stbStaking.increaseF_SUSD(SUSDFee);
        _susdToken.mint(sSTBAddress, _SUSDFee); // todo 
    }

    // Update trove's coll and debt based on whether they increase or decrease
    function _updateTroveFromAdjustment( 
        ITroveManager _troveManager,
        address _borrower,
        address[] memory _finalColls,
        uint256[] memory _finalAmounts,
        uint256 _debtChange,
        bool _isDebtIncrease, 
        uint256 _variableSUSDFee
    ) internal returns (uint256) {
        uint256 newDebt;
        _troveManager.updateTroveColl(_borrower, _finalColls, _finalAmounts);
        if (_isDebtIncrease) { // if debt increase, increase by both amounts
           newDebt = _troveManager.increaseTroveDebt(_borrower, _debtChange.add(_variableSUSDFee));
        } else {
            if (_debtChange > _variableSUSDFee) { // if debt decrease, and greater than variable fee, decrease 
                newDebt = _troveManager.decreaseTroveDebt(_borrower, _debtChange - _variableSUSDFee); // already checked no safemath needed
            } else { // otherwise increase by opposite subtraction
                newDebt = _troveManager.increaseTroveDebt(_borrower, _variableSUSDFee - _debtChange); // already checked no safemath needed
            }
        }

        return newDebt;
    }

    // gets the finalColls and finalAmounts after all deposits and withdrawals have been made
    // this function will error if trying to deposit a collateral that is not in the whitelist
    // or trying to withdraw more collateral of any type that is not in the trove
    function _getNewPortfolio(
        address[] memory _initialTokens,
        uint256[] memory _initialAmounts,
        address[] memory _tokensIn,
        uint256[] memory _amountsIn,
        address[] memory _tokensOut,
        uint256[] memory _amountsOut
    ) internal view returns (address[] memory, uint256[] memory) {

        // Initial Colls + Input Colls
        newColls memory cumulativeIn = _sumColls(
            newColls(_initialTokens, _initialAmounts),
            newColls(_tokensIn,_amountsIn)
        );

        newColls memory newPortfolio = _subColls(cumulativeIn, _tokensOut, _amountsOut);
        return (newPortfolio.tokens, newPortfolio.amounts);
    }

    // Moves the YUSD around based on whether it is an increase or decrease in debt.
    function _moveSUSD(
        IActivePool _activePool,
        ISUSDToken _susdToken,
        address _borrower,
        uint256 _SUSDChange,
        bool _isDebtIncrease,
        uint256 _netDebtChange
    ) internal {
        if (_isDebtIncrease) {
            _withdrawSUSD(_activePool, _susdToken, _borrower, _SUSDChange, _netDebtChange);
        } else {
            _repaySUSD(_activePool, _susdToken, _borrower, _SUSDChange);
        }
    }

    // Issue the specified amount of YUSD to _account and increases the total active debt (_netDebtIncrease potentially includes a YUSDFee)
    function _withdrawSUSD(
        IActivePool _activePool,
        ISUSDToken _susdToken,
        address _account,
        uint256 _SUSDAmount,
        uint256 _netDebtIncrease
    ) internal {
        _activePool.increaseSUSDDebt(_netDebtIncrease);
        _susdToken.mint(_account, _SUSDAmount);
    }

    // Burn the specified amount of YUSD from _account and decreases the total active debt
    function _repaySUSD(
        IActivePool _activePool,
        ISUSDToken _susdToken,
        address _account,
        uint256 _SUSD
    ) internal {
        _activePool.decreaseSUSDDebt(_SUSD);
        _susdToken.burn(_account, _SUSD);
    }

    // Returns _coll1 minus _tokens and _amounts
    // will error if _tokens include a token not in _coll1.tokens
    function _subColls(newColls memory _coll1, address[] memory _tokens, uint[] memory _amounts)
    internal
    view
    returns (newColls memory finalColls)
    {
        uint256 tokensLen = _tokens.length;
        if (tokensLen == 0) {
            return _coll1;
        }
        uint256 coll1Len = _coll1.tokens.length;

        newColls memory coll3;
        coll3.tokens = whitelist.getValidCollateral();
        uint256 coll3Len = coll3.tokens.length;
        coll3.amounts = new uint256[](coll3Len);
        uint256 n = 0;
        for (uint256 i; i < coll1Len; ++i) {
            if (_coll1.amounts[i] != 0) {
                uint256 tokenIndex = whitelist.getIndex(_coll1.tokens[i]);
                coll3.amounts[tokenIndex] = _coll1.amounts[i];
                n++;
            }
        }
        for (uint256 i; i < tokensLen; ++i) {
            uint256 tokenIndex = whitelist.getIndex(_tokens[i]);
            coll3.amounts[tokenIndex] = coll3.amounts[tokenIndex].sub(_amounts[i]);
            if (coll3.amounts[tokenIndex] == 0) {
                n--;
            }
        }

        address[] memory diffTokens = new address[](n);
        uint256[] memory diffAmounts = new uint256[](n);

        if (n != 0) {
            uint j;
            for (uint i; i < coll3Len; ++i) {
                if (coll3.amounts[i] != 0) {
                    diffTokens[j] = coll3.tokens[i];
                    diffAmounts[j] = coll3.amounts[i];
                    ++j;
                }
            }
        }
        finalColls.tokens = diffTokens;
        finalColls.amounts = diffAmounts;
    }

    // --- 'Require' wrapper functions ---

    // Checks that amounts are nonzero, that the the length of colls and amounts are the same, that the coll is active,
    // and that there is no overlab collateral in the list.
    function _requireValidDepositCollateral(address[] memory _colls, uint256[] memory _amounts, IWhitelist whitelist) internal view {
        uint256 collsLen = _colls.length;
        _requireLengthsEqual(collsLen, _amounts.length);
        for (uint256 i; i < collsLen; ++i) {
            require(whitelist.getIsActive(_colls[i]), "BO:BadColl");
            require(_amounts[i] != 0, "BO:NoAmounts");
            for (uint256 j = i.add(1); j < collsLen; j++) {
                require(_colls[i] != _colls[j], "BO:OverlapColls");
            }
        }
    }

    function _requireNoOverlapColls(address[] calldata _colls1, address[] calldata _colls2)
        internal
        pure
    {
        uint256 colls1Len = _colls1.length;
        uint256 colls2Len = _colls2.length;
        for (uint256 i; i < colls1Len; ++i) {
            for (uint256 j; j < colls2Len; j++) {
                require(_colls1[i] != _colls2[j], "BO:OverlapColls");
            }
        }
    }

    // Condition of whether amountsIn is 0 amounts, or amountsOut is 0 amounts, is checked in previous call
    // to _requireValidDepositCollateral.
    function _requireNonZeroAdjustment(
        uint256[] memory _amountsIn,
        uint256[] memory _amountsOut,
        uint256 _SUSDChange
    ) internal pure {
        if (_SUSDChange == 0) {
            require(_amountsIn.length != 0 || _amountsOut.length != 0, "BO:0Adjust");
        }
    }

    function _isBeforeFeeBootstrapPeriod() internal view returns (bool) {
        return block.timestamp < deploymentTime + BOOTSTRAP_PERIOD; // won't overflow
    }


    function _requireTroveisActive(ITroveManager _troveManager, address _borrower) internal view {
        require(_troveManager.isTroveActive(_borrower), "BO:TroveInactive");
    }

    function _requireTroveisNotActive(ITroveManager _troveManager, address _borrower) internal view {
        require(!_troveManager.isTroveActive(_borrower), "BO:TroveActive");
    }

    function _requireNonZeroDebtChange(uint256 _SUSDChange) internal pure {
        require(_SUSDChange != 0, "BO:NoDebtChange");
    }

    function _requireNoCollWithdrawal(uint256[] memory _amountOut) internal pure {
        uint256 arrLen = _amountOut.length;
        for (uint256 i; i < arrLen; ++i) {
            if (_amountOut[i] != 0) {
                revert("BO:NoCollWithdrawRecMode");
            }
        }
    }

    // Function require length nonzero, used to save contract size on revert strings. 
    function _requireLengthNonzero(uint256 length) internal pure {
        require(length != 0, "BOps:Len0");
    }

    // Function require length equal, used to save contract size on revert strings.
    function _requireLengthsEqual(uint256 length1, uint256 length2) internal pure {
        require(length1 == length2, "BO:LenMismatch");
    }

    function _requireValidAdjustmentInCurrentMode(
        uint256[] memory _collWithdrawal,
        bool _isDebtIncrease,
        LocalVariables_adjustTrove memory _vars
    ) internal pure {
        /*
         *In Recovery Mode, only allow:
         *
         * - Pure collateral top-up
         * - Pure debt repayment
         * - Collateral top-up with debt repayment
         * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
         *
         * In Normal Mode, ensure:
         *
         * - The new ICR is above MCR
         * - The adjustment won't pull the TCR below CCR
         */
        if (_vars.isRecoveryMode) {
            _requireNoCollWithdrawal(_collWithdrawal);
            if (_isDebtIncrease) {
                _requireICRisAboveCCR(_vars.newICR);
                _requireNewICRisAboveOldICR(_vars.newICR, _vars.oldICR);
            }
        } else {
            // if Normal Mode
            _requireICRisAboveMCR(_vars.newICR);
            _vars.newTCR = _getNewTCRFromTroveChange(
                _vars.entireSystemColl,
                _vars.entireSystemDebt,
                _vars.collChange,
                _vars.isCollIncrease,
                _vars.netDebtChange,
                _isDebtIncrease
            );
            _requireNewTCRisAboveCCR(_vars.newTCR);
        }
    }

    function _requireICRisAboveMCR(uint256 _newICR) internal pure {
        require(
            _newICR >= MCR,
            "BO:ReqICR>MCR"
        );
    }

    function _requireICRisAboveCCR(uint256 _newICR) internal pure {
        require(_newICR >= CCR, "BO:ReqICR>CCR");
    }

    function _requireNewICRisAboveOldICR(uint256 _newICR, uint256 _oldICR) internal pure {
        require(
            _newICR >= _oldICR,
            "BO:RecMode:ICR<oldICR"
        );
    }

    function _requireNewTCRisAboveCCR(uint256 _newTCR) internal pure {
        require(
            _newTCR >= CCR,
            "BO:ReqTCR>CCR"
        );
    }

    function _requireAtLeastMinNetDebt(uint256 _netDebt) internal pure {
        require(
            _netDebt >= MIN_NET_DEBT,
            "BO:netDebt<2000"
        );
    }

    function _requireValidSUSDRepayment(uint256 _currentDebt, uint256 _debtRepayment) internal pure {
        require(
            _debtRepayment <= _currentDebt.sub(SUSD_GAS_COMPENSATION),
            "BO:InvalidSUSDRepay"
        );
    }

    function _requireSufficientSUSDBalance(
        ISUSDToken _susdToken,
        address _borrower,
        uint256 _debtRepayment
    ) internal view {
        require(
            _susdToken.balanceOf(_borrower) >= _debtRepayment,
            "BO:InsuffSUSDBal"
        );
    }

    function _requireValidMaxFeePercentage(uint256 _maxFeePercentage, bool _isRecoveryMode)
        internal
        pure
    {
        // Alwawys require max fee to be less than 100%, and if not in recovery mode then max fee must be greater than 0.5%
        if (_maxFeePercentage > DECIMAL_PRECISION || (!_isRecoveryMode && _maxFeePercentage < BORROWING_FEE_FLOOR)) {
            revert("BO:InvalidMaxFee");
        }
    }

    /* team can turn lever up functionality off and on.
     * leverUpEnabled will initially be false.
     * Plan is to turn on functionality once YUSD has sufficient liquidity
     * The only reason it would be turned off is under
     * unforeseen extreme circumstances
    *
    function setLeverUp(bool _enabled) external override {
        require(whitelist.isValidCaller(msg.sender), "BO: UnapprovedCaller");
        leverUpEnabled = _enabled;
    }*/


    // --- ICR and TCR getters ---

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromTroveChange(
        uint256 _newVC,
        uint256 _debt,
        uint256 _debtChange,
        bool _isDebtIncrease
    ) internal pure returns (uint256) {
        uint256 newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

        uint256 newICR = LiquityMath._computeCR(_newVC, newDebt);
        return newICR;
    }

    function _getNewTCRFromTroveChange(
        uint256 _entireSystemColl,
        uint256 _entireSystemDebt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    ) internal pure returns (uint256) {

        _entireSystemColl = _isCollIncrease ? _entireSystemColl.add(_collChange) : _entireSystemColl.sub(_collChange);
        _entireSystemDebt = _isDebtIncrease ? _entireSystemDebt.add(_debtChange) : _entireSystemDebt.sub(_debtChange);

        uint256 newTCR = LiquityMath._computeCR(_entireSystemColl, _entireSystemDebt);
        return newTCR;
    }

    function getCompositeDebt(uint256 _debt) external pure override returns (uint256) {
        return _getCompositeDebt(_debt);
    }
}