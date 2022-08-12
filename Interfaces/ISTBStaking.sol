// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

interface ISSTB {

    // --- Events --
    
    event YETITokenAddressSet(address _stbTokenAddress);
    event YUSDTokenAddressSet(address _susdTokenAddress);
    event TroveManagerAddressSet(address _troveManager);
    event TroveManagerRedemptionsAddressSet(address _troveManagerRedemptions);
    event BorrowerOperationsAddressSet(address _borrowerOperationsAddress);
    event ActivePoolAddressSet(address _activePoolAddress);

    event StakeChanged(address indexed staker, uint newStake);
    event StakingGainsWithdrawn(address indexed staker, uint SUSDGain);
    event F_SUSDUpdated(uint _F_SUSD);
    event TotalSTBStakedUpdated(uint _totalYETIStaked);
    event StakerSnapshotsUpdated(address _staker, uint _F_SUSD);

    // --- Functions ---

    function setAddresses
    (
        address _stbTokenAddress,
        address _susdTokenAddress,
        address _troveManagerAddress, 
        address _troveManagerRedemptionsAddress,
        address _borrowerOperationsAddress,
        address _activePoolAddress
    )  external;

    function stake(uint _STBamount) external;

    function unstake(uint _STBamount) external;

    function increaseF_SUSD(uint _STBFee) external;

    function getPendingSUSDGain(address _user) external view returns (uint);
}