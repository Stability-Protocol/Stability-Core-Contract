// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.11;

// Import this file to use console.log
//import "hardhat/console.sol";
import "../Interfaces/IActivePool.sol"; ///Users/phaxsam/Stability HardHat/Interfaces/IActivePool.sol
import "../Interfaces/IWhitelist.sol";
import "../Interfaces/IERC20.sol";
import "../Interfaces/IWAsset.sol";
import "../Interfaces/IDefaultPool.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/PoolBase2.sol";
import "../Dependencies/SafeERC20.sol";

import "../Interfaces/IDefaultPool.sol";


contract ActivePool is Ownable, CheckContract, IActivePool, PoolBase2 {
      using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 constant public NAME = "ActivePool";

    address internal borrowerOperationsAddress;
    address internal troveManagerAddress;
    address internal stabilityPoolAddress;
    address internal defaultPoolAddress;
     address internal troveManagerLiquidationsAddress;
    address internal troveManagerRedemptionsAddress;
    address internal collSurplusPoolAddress;

    
    // deposited collateral tracker. Colls is always the whitelist list of all collateral tokens. Amounts 
    newColls internal poolColl;

    // YUSD Debt tracker. Tracker of all debt in the system. 
    uint256 internal SUSDDebt;



     // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolSUSDDebtUpdated(uint _SUSDDebt);
    event ActivePoolBalanceUpdated(address _collateral, uint _amount);



    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress,
        address _whitelistAddress,
       // address _troveManagerLiquidationsAddress,
       // address _troveManagerRedemptionsAddress,
        address _collSurplusPoolAddress
    )
        external
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_whitelistAddress);
       // checkContract(_troveManagerLiquidationsAddress);
       // checkContract(_troveManagerRedemptionsAddress);
        checkContract(_collSurplusPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;
        whitelist = IWhitelist(_whitelistAddress);
       // troveManagerLiquidationsAddress = _troveManagerLiquidationsAddress;
      //  troveManagerRedemptionsAddress = _troveManagerRedemptionsAddress;
        collSurplusPoolAddress = _collSurplusPoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit WhitelistAddressChanged(_whitelistAddress);

        _renounceOwnership();
    }

     // --- Internal Functions ---

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the amount of a given collateral in state. Not necessarily the contract's actual balance.
    */
    function getCollateral(address _collateral) public view override returns (uint) {
        return poolColl.amounts[whitelist.getIndex(_collateral)];
    }

      // Debt that this pool holds. 
    function getSUSDDebt() external view override returns (uint) {
        return SUSDDebt;
    }


      // --- Pool functionality ---

    // Internal function to send collateral to a different pool. 
    function _sendCollateral(address _to, address _collateral, uint _amount) internal {
        uint index = whitelist.getIndex(_collateral);
        poolColl.amounts[index] = poolColl.amounts[index].sub(_amount);
        IERC20(_collateral).safeTransfer(_to, _amount);

        emit ActivePoolBalanceUpdated(_collateral, _amount);
        emit CollateralSent(_collateral, _to, _amount);
    }

    // Function sends collaterals from active pool.
    // Must be called by borrower operations, trove manager, or stability pool.
    function sendCollaterals(address _to, address[] calldata _tokens, uint[] calldata _amounts) external override {
        _requireCallerIsBOorTroveMorTMLorSP();
        uint256 len = _tokens.length;
        require(len == _amounts.length, "AP:Lengths");
        for (uint256 i; i < len; ++i) {
            uint256 thisAmount = _amounts[i];
            if (thisAmount != 0) {
                _sendCollateral(_to, _tokens[i], thisAmount); // reverts if send fails
            }
        }

        if (_needsUpdateCollateral(_to)) {
            ICollateralReceiver(_to).receiveCollateral(_tokens, _amounts);
        }

        emit CollateralSent(_tokens, _amounts, _to);
    }

      // Function for sending single collateral. Currently only used by borrower operations unlever up functionality
    function sendSingleCollateral(address _to, address _token, uint256 _amount) external override {
        _requireCallerIsBorrowerOperations();
        _sendCollateral(_to, _token, _amount); // reverts if send fails
    }

    // View function that returns if the contract transferring to needs to have its balances updated. 
    function _needsUpdateCollateral(address _contractAddress) internal view returns (bool) {
        return ((_contractAddress == defaultPoolAddress) || (_contractAddress == stabilityPoolAddress) || (_contractAddress == collSurplusPoolAddress));
    }

        // Increases the YUSD Debt of this pool. 
    function increaseSUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        SUSDDebt  = SUSDDebt.add(_amount);
        emit ActivePoolSUSDDebtUpdated(SUSDDebt);
    }

    // Decreases the YUSD Debt of this pool. 
    function decreaseSUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        SUSDDebt = SUSDDebt.sub(_amount);
        emit ActivePoolSUSDDebtUpdated(SUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBOorTroveMorTMLorSP() internal view {
        if (
            msg.sender != borrowerOperationsAddress &&
            msg.sender != troveManagerAddress &&
            msg.sender != stabilityPoolAddress &&
            msg.sender != troveManagerLiquidationsAddress &&
            msg.sender != troveManagerRedemptionsAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        if (msg.sender != borrowerOperationsAddress &&
            msg.sender != defaultPoolAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBorrowerOperations() internal view {
        if (msg.sender != borrowerOperationsAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        if (msg.sender != borrowerOperationsAddress &&
            msg.sender != troveManagerAddress &&
            msg.sender != stabilityPoolAddress &&
            msg.sender != troveManagerRedemptionsAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBOorTroveM() internal view {
        if (msg.sender != borrowerOperationsAddress &&
            msg.sender != troveManagerAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsWhitelist() internal view {
        if (msg.sender != address(whitelist)) {
            _revertWrongFuncCaller();
        }
    }

    function _revertWrongFuncCaller() internal pure {
        revert("AP: External caller not allowed");
    }

    // should be called by BorrowerOperations or DefaultPool
    // __after__ collateral is transferred to this contract.
    function receiveCollateral(address[] calldata _tokens, uint[] calldata _amounts) external override {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        poolColl.amounts = _leftSumColls(poolColl, _tokens, _amounts);
        emit ActivePoolBalanceUpdated(_tokens, _amounts);
    }

    // Adds collateral type from whitelist. 
    function addCollateralType(address _collateral) external override {
        _requireCallerIsWhitelist();
        poolColl.tokens.push(_collateral);
        poolColl.amounts.push(0);
    }
}
