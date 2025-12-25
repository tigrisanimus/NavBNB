// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";

contract MockOpaqueStrategy is IBNBYieldStrategy {
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
}
