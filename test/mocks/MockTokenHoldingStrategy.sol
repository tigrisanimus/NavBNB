// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockTokenHoldingStrategy is IBNBYieldStrategy {
    MockERC20 public immutable ankrBNB;
    MockERC20 public immutable wbnb;
    uint256 internal stored;
    bool internal forceZeroWithdraw;

    constructor(address ankrBNB_, address wbnb_) {
        ankrBNB = MockERC20(ankrBNB_);
        wbnb = MockERC20(wbnb_);
    }

    function deposit() external payable {
        stored += msg.value;
    }

    function withdraw(uint256) external returns (uint256 received) {
        return 0;
    }

    function withdrawAllToVault() external returns (uint256 received) {
        if (forceZeroWithdraw && stored > 0) {
            return 0;
        }
        uint256 amount = stored;
        stored = 0;
        if (amount > 0) {
            (bool success,) = msg.sender.call{value: amount}("");
            require(success, "SEND_FAIL");
        }
        return amount;
    }

    function totalAssets() external view returns (uint256) {
        return stored;
    }

    function setAssets(uint256 amount) external {
        stored = amount;
    }

    function setForceZeroWithdraw(bool value) external {
        forceZeroWithdraw = value;
    }
}
