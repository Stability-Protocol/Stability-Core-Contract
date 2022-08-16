// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "../Interfaces/ISUSDToken.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/CheckContract.sol";

/*
*
* Based upon OpenZeppelin's ERC20 contract:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
*  
* and their EIP2612 (ERC20Permit / ERC712) functionality:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/53516bc555a454862470e7860a9b5254db4d00f5/contracts/token/ERC20/ERC20Permit.sol
* 
*
* --- Functionality added specific to the YUSDToken ---
* 
* 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Yeti contracts) in external 
* transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending YUSD directly to a Yeti 
* core contract, when they should rather call the right function. 
*
* 2) sendToPool() and returnFromPool(): functions callable only Yeti core contracts, which move YUSD tokens between Yeti <-> user.
*/

contract SUSDToken is CheckContract, ISUSDToken {
    using SafeMath for uint256;
    
    uint256 private _totalSupply;
    string constant internal _NAME = "SUSD Stablecoin";
    string constant internal _SYMBOL = "SUSD";
    string constant internal _VERSION = "1";
    uint8 constant internal _DECIMALS = 18;
    
    // --- Data for EIP2612 ---
    
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    
    mapping (address => uint256) private _nonces;
    
    // User data for YUSD token
    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;  
    
    // --- Addresses ---
    address internal immutable troveManagerAddress;
    address internal immutable troveManagerLiquidationsAddress;
    address internal immutable troveManagerRedemptionsAddress;
    address internal immutable stabilityPoolAddress;
    address internal immutable borrowerOperationsAddress;
    address internal immutable timelockAddress;
    mapping(address => bool) validMinters;
    
    // --- Events ---
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event TroveManagerLiquidatorAddressChanged(address _troveManagerLiquidatorAddress);
    event TroveManagerRedemptionsAddressChanged(address _troveManagerRedemptionsAddress);
    event StabilityPoolAddressChanged(address _newStabilityPoolAddress);
    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);

    constructor
    (
        address _troveManagerAddress,
        address _troveManagerLiquidationsAddress,
        address _troveManagerRedemptionsAddress,
        address _stabilityPoolAddress,
        address _borrowerOperationsAddress,
        address _timelockAddress
    )
        public 
    {
        checkContract(_troveManagerAddress);
        checkContract(_troveManagerLiquidationsAddress);
        checkContract(_troveManagerRedemptionsAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_borrowerOperationsAddress);

        troveManagerAddress = _troveManagerAddress;
        emit TroveManagerAddressChanged(_troveManagerAddress);

        troveManagerLiquidationsAddress = _troveManagerLiquidationsAddress;
        emit TroveManagerLiquidatorAddressChanged(_troveManagerLiquidationsAddress);

        troveManagerRedemptionsAddress = _troveManagerRedemptionsAddress;
        emit TroveManagerRedemptionsAddressChanged(_troveManagerRedemptionsAddress);

        stabilityPoolAddress = _stabilityPoolAddress;
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        validMinters[_borrowerOperationsAddress] = true;
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);

        timelockAddress = _timelockAddress;
        
        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));
        
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);
    }

    // --- Functions for intra-Yeti calls ---

    function mint(address _account, uint256 _amount) external override {
        _requireValidMinter();
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        _burn(_account, _amount);
    }

    function sendToPool(address _sender,  address _poolAddress, uint256 _amount) external override {
        _requireCallerIsStabilityPool();
        _transfer(_sender, _poolAddress, _amount);
    }

    function returnFromPool(address _poolAddress, address _receiver, uint256 _amount) external override {
        _requireCallerIsTMLorSP();
        _transfer(_poolAddress, _receiver, _amount);
    }

    // --- External functions ---

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    // --- EIP 2612 Functionality ---

    function domainSeparator() public view override returns (bytes32) {    
        if (_chainID() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit
    (
        address owner, 
        address spender, 
        uint amount, 
        uint deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) 
        external 
        override 
    {            
        require(deadline >= block.timestamp, 'SUSD: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01', 
                         domainSeparator(), keccak256(abi.encode(
                         _PERMIT_TYPEHASH, owner, spender, amount, 
                         _nonces[owner]++, deadline))));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress == owner || recoveredAddress != address(0) , 'SUSD: invalid signature');
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view override returns (uint256) { // FOR EIP 2612
        return _nonces[owner];
    }

    // --- Internal operations ---

    function _chainID() private pure returns (uint256 chainID) {
        assembly {
            chainID := chainid()
        }
    }
    
    function _buildDomainSeparator(bytes32 typeHash, bytes32 name, bytes32 version) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, name, version, _chainID(), address(this)));
    }

    // --- Internal operations ---
    // Warning: sanity checks (for sender and recipient) should have been done before calling these internal functions

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "_transfer: sender is address(0)");
        require(recipient != address(0), "_transfer: recipient is 0address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount > balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "_mint: account is address(0)");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account] + amount; 
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "_burn: account is address(0)");
        
        _balances[account] = _balances[account].sub(amount, "ERC20: burn amount > balance");
        _totalSupply = _totalSupply - amount; // can't underflow since indiv balance didn't
        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "_approve: owner is address(0)");
        require(spender != address(0), "_approve: spender is address(0)");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function addValidMinter(address _newMinter) external {
        require(msg.sender == timelockAddress, "SUSD: NotTimelock");
        validMinters[_newMinter] = true;
    }

    // --- 'require' functions ---

    // TODO: update this when we've finalized where YUSD can/can't be sent.
    // May want to make it possible to send to adddress(0) for burns or something
    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) && 
            _recipient != address(this),
            "SUSD: Cannot transfer tokens directly to the YUSD token contract or the zero address"
        );
        // require(
        //     _recipient != stabilityPoolAddress && 
        //     _recipient != troveManagerAddress &&
        //     _recipient != troveManagerLiquidationsAddress && 
        //     _recipient != troveManagerRedemptionsAddress, //&& 
        //     // _recipient != borrowerOperationsAddress, //
        //     "YUSD: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps"
        // );
    }

    function _requireValidMinter() internal view {
        require(validMinters[msg.sender], "SUSDToken: Caller is not Valid Minter");
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress ||
            msg.sender == stabilityPoolAddress ||
            msg.sender == troveManagerRedemptionsAddress,
            "SUSD: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"
        );
    }

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "SUSD: Caller is not the StabilityPool");
    }

    function _requireCallerIsTMLorSP() internal view {
        require(
            msg.sender == stabilityPoolAddress || msg.sender == troveManagerLiquidationsAddress,
            "SUSD: Caller is neither TroveManagerLiquidator nor StabilityPool");
    }

    // --- Optional functions ---

    function name() external view override returns (string memory) {
        return _NAME;
    }

    function symbol() external view override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }

    function version() external view override returns (string memory) {
        return _VERSION;
    }

    function permitTypeHash() external view override returns (bytes32) {
        return _PERMIT_TYPEHASH;
    }
}