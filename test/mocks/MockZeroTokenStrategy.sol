// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";

contract MockZeroTokenStrategy is IBNBYieldStrategy {
    function deposit() external payable {}

    function withdraw(uint256) external returns (uint256 received) {
        return 0;
    }

    function withdrawAllToVault() external returns (uint256 received) {
        return 0;
    }

    function totalAssets() external view returns (uint256) {
        return 0;
    }

    function ankrBNB() external pure returns (address) {
        return address(0);
    }

    function wbnb() external pure returns (address) {
        return address(0);
    }

    function stakingPool() external pure returns (address) {
        return address(0);
    }

    function valuationHaircutBps() external pure returns (uint16) {
        return 0;
    }

    function consultTwap(uint256) external pure returns (uint256) {
        return 0;
    }

    function transferHoldingsTo(address, uint256, uint256, uint256) external pure {}
}
