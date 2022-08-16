pragma solidity 0.6.11;

// Interface for performing a swap within the sYETI contract 
// Takes in YUSD and swaps for YETI

interface IsSTbRouter {
    // Must require that the swap went through successfully with at least min yeti out amounts out. 
    function swap(uint256 _SUSDAmount, uint256 _minSTBOut, address _to) external returns (uint256[] memory amounts);
}