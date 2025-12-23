// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IBNBYieldStrategy {
    function deposit() external payable;
    // withdraw up to `bnbAmount`, returns actual BNB received by caller (may be <= requested)
    function withdraw(uint256 bnbAmount) external returns (uint256 received);
    // unwind all assets to the vault and return actual BNB sent
    function withdrawAllToVault() external returns (uint256 received);
    // total BNB-equivalent value controlled by the strategy for this vault
    function totalAssets() external view returns (uint256);
}
