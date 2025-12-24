// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";

contract MockBNBYieldStrategy is IBNBYieldStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 internal stored;
    bool internal forceZeroWithdraw;
    uint256 internal maxWithdraw;
    uint256 internal withdrawCalls;
    uint256 internal withdrawRatioBps;

    function deposit() external payable {
        stored += msg.value;
    }

    function withdraw(uint256 bnbAmount) external returns (uint256 received) {
        withdrawCalls += 1;
        if (forceZeroWithdraw && bnbAmount > 0) {
            return 0;
        }
        uint256 amount = bnbAmount > stored ? stored : bnbAmount;
        if (maxWithdraw != 0 && amount > maxWithdraw) {
            amount = maxWithdraw;
        }
        if (withdrawRatioBps != 0) {
            amount = (amount * withdrawRatioBps) / BPS;
        }
        stored -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "SEND_FAIL");
        return amount;
    }

    function withdrawAllToVault() external returns (uint256 received) {
        if (forceZeroWithdraw && stored > 0) {
            return 0;
        }
        uint256 amount = stored;
        stored = 0;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "SEND_FAIL");
        return amount;
    }

    function totalAssets() external view returns (uint256) {
        return stored;
    }

    function withdrawCallCount() external view returns (uint256) {
        return withdrawCalls;
    }

    function setAssets(uint256 amount) external {
        stored = amount;
    }

    function setForceZeroWithdraw(bool value) external {
        forceZeroWithdraw = value;
    }

    function setMaxWithdraw(uint256 amount) external {
        maxWithdraw = amount;
    }

    function setWithdrawRatioBps(uint256 bps) external {
        withdrawRatioBps = bps;
    }
}
