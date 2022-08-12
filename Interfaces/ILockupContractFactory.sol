// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;
    
interface ILockupContractFactory {
    
    // --- Events ---

    event STBTokenAddressSet(address _stbTokenAddress);
    event LockupContractDeployedThroughFactory(address _lockupContractAddress, address _beneficiary, uint _unlockTime, address _deployer);

    // --- Functions ---

    function setSTBTokenAddress(address _stbTokenAddress) external;

    function deployLockupContract(address _beneficiary, uint _unlockTime) external;

    function isRegisteredLockup(address _addr) external view returns (bool);
}