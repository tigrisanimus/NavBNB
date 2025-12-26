// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "src/IBNBYieldStrategy.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockBNBYieldStrategy is IBNBYieldStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 internal stored;
    bool internal forceZeroWithdraw;
    uint256 internal maxWithdraw;
    uint256 internal withdrawCalls;
    uint256 internal withdrawRatioBps;
    address internal immutable ankrToken;
    address internal immutable wbnbToken;
    address internal immutable stakingPoolAddress;
    uint16 internal valuationHaircutBpsValue;
    uint256 internal twapRate;
    bool internal twapReadyValue;

    constructor(address ankrToken_, address wbnbToken_, address stakingPool_) {
        ankrToken = ankrToken_;
        wbnbToken = wbnbToken_;
        stakingPoolAddress = stakingPool_;
        valuationHaircutBpsValue = 100;
        twapRate = 1e18;
        twapReadyValue = true;
    }

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

    function ankrBNB() external view returns (address) {
        return ankrToken;
    }

    function wbnb() external view returns (address) {
        return wbnbToken;
    }

    function stakingPool() external view returns (address) {
        return stakingPoolAddress;
    }

    function valuationHaircutBps() external view returns (uint16) {
        return valuationHaircutBpsValue;
    }

    function consultTwap(uint256 amountIn) external view returns (uint256) {
        if (!twapReadyValue) {
            return 0;
        }
        return (amountIn * twapRate) / 1e18;
    }

    function twapReady() external view returns (bool) {
        return twapReadyValue;
    }

    function transferHoldingsTo(address to, uint256 ankrAmount, uint256 wbnbAmount, uint256 bnbAmount) external {
        if (ankrAmount > 0) {
            require(MockERC20(ankrToken).transfer(to, ankrAmount), "ANKR_TRANSFER");
        }
        if (wbnbAmount > 0) {
            require(MockERC20(wbnbToken).transfer(to, wbnbAmount), "WBNB_TRANSFER");
        }
        if (bnbAmount > 0) {
            (bool success,) = to.call{value: bnbAmount}("");
            require(success, "BNB_TRANSFER");
        }
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

    function setValuationHaircutBps(uint16 bps) external {
        valuationHaircutBpsValue = bps;
    }

    function setTwapRate(uint256 rate) external {
        twapRate = rate;
    }

    function setTwapReady(bool value) external {
        twapReadyValue = value;
    }
}
