// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "..../Dependencies/SafeMath.sol";
import "..../Interfaces/ISTBToken.sol";

/*
* The lockup contract architecture utilizes a single LockupContract, with an unlockTime. The unlockTime is passed as an argument 
* to the LockupContract's constructor. The contract's balance can be withdrawn by the beneficiary when block.timestamp > unlockTime. 
* At construction, the contract checks that unlockTime is at least one year later than the Liquity system's deployment time. 
*/
contract LockupContract {
    using SafeMath for uint;

    // --- Data ---
    bytes32 constant public NAME = "LockupContract";

    uint constant public SECONDS_IN_ONE_YEAR = 31536000;

    address public immutable beneficiary;

    IYETIToken public immutable stbToken;

    // Unlock time is the Unix point in time at which the beneficiary can withdraw.
    uint public unlockTime;

    // --- Events ---

    event LockupContractCreated(address _beneficiary, uint _unlockTime);
    event LockupContractEmptied(uint _STBwithdrawal);

    // --- Functions ---

    constructor 
    (
        address _stbTokenAddress,
        address _beneficiary, 
        uint _unlockTime
    )
        public 
    {
        ISTBToken cachedStbToken = ISTBToken(_stbTokenAddress);
        stbToken = cachedStbToken;

        /*
        * Set the unlock time to a chosen instant in the future, as long as it is at least 1 year after
        * the system was deployed 
        */
        _requireUnlockTimeIsAtLeastOneYearAfterSystemDeployment(_unlockTime, cachedStbToken);
        unlockTime = _unlockTime;
        
        beneficiary =  _beneficiary;
        emit LockupContractCreated(_beneficiary, _unlockTime);
    }

    function withdrawSTB() external {
        _requireCallerIsBeneficiary();
        _requireLockupDurationHasPassed();

        ISTBToken stbTokenCached = stbToken;
        uint STBBalance = stbTokenCached.balanceOf(address(this));
        stbTokenCached.transfer(beneficiary, STBBalance);
        emit LockupContractEmptied(STBBalance);
    }

    // --- 'require' functions ---

    function _requireCallerIsBeneficiary() internal view {
        require(msg.sender == beneficiary, "LockupContract: caller is not the beneficiary");
    }

    function _requireLockupDurationHasPassed() internal view {
        require(block.timestamp >= unlockTime, "LockupContract: The lockup duration must have passed");
    }

    function _requireUnlockTimeIsAtLeastOneYearAfterSystemDeployment(uint _unlockTime, ISTBToken _stbToken) internal view {
        uint systemDeploymentTime = _stbToken.getDeploymentStartTime();
        require(_unlockTime >= systemDeploymentTime.add(SECONDS_IN_ONE_YEAR), "LockupContract: unlock time must be at least one year after system deployment");
    }
}