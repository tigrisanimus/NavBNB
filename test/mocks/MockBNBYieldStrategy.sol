// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";

contract MockBNBYieldStrategy is IBNBYieldStrategy {
    uint256 internal stored;

    function deposit() external payable {
        stored += msg.value;
    }

    function withdraw(uint256 bnbAmount) external returns (uint256 received) {
        uint256 amount = bnbAmount > stored ? stored : bnbAmount;
        stored -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "SEND_FAIL");
        return amount;
    }

    function totalAssets() external view returns (uint256) {
        return stored;
    }

    function setAssets(uint256 amount) external {
        stored = amount;
    }
}
