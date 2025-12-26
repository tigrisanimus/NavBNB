// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockTokenHoldingStrategy is IBNBYieldStrategy {
    MockERC20 public immutable ankrBNB;
    MockERC20 public immutable wbnb;
    address public immutable stakingPool;
    uint16 public valuationHaircutBps = 100;
    uint256 public twapRate = 1e18;
    bool public twapReady = true;
    uint256 internal stored;
    bool internal forceZeroWithdraw;

    constructor(address ankrBNB_, address wbnb_, address stakingPool_) {
        ankrBNB = MockERC20(ankrBNB_);
        wbnb = MockERC20(wbnb_);
        stakingPool = stakingPool_;
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

    function consultTwap(uint256 amountIn) external view returns (uint256) {
        if (!twapReady) {
            return 0;
        }
        return (amountIn * twapRate) / 1e18;
    }

    function transferHoldingsTo(address to, uint256 ankrAmount, uint256 wbnbAmount, uint256 bnbAmount) external {
        if (ankrAmount > 0) {
            require(ankrBNB.transfer(to, ankrAmount), "ANKR_TRANSFER");
        }
        if (wbnbAmount > 0) {
            require(wbnb.transfer(to, wbnbAmount), "WBNB_TRANSFER");
        }
        if (bnbAmount > 0) {
            (bool success,) = to.call{value: bnbAmount}("");
            require(success, "BNB_TRANSFER");
        }
    }

    function setAssets(uint256 amount) external {
        stored = amount;
    }

    function setForceZeroWithdraw(bool value) external {
        forceZeroWithdraw = value;
    }

    function setValuationHaircutBps(uint16 bps) external {
        valuationHaircutBps = bps;
    }

    function setTwapRate(uint256 rate) external {
        twapRate = rate;
    }

    function setTwapReady(bool value) external {
        twapReady = value;
    }
}
