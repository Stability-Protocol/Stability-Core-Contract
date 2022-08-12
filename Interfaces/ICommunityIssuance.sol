// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

interface ICommunityIssuance { 
    
    // --- Events ---
    
    event STBTokenAddressSet(address _stbTokenAddress);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TotalSTBIssuedUpdated(uint _totalSTBIssued);

    // --- Functions ---

    function setAddresses(address _stbTokenAddress, address _stabilityPoolAddress) external;

    function issueSTB() external returns (uint);

    function sendSTB(address _account, uint _STBamount) external;
}