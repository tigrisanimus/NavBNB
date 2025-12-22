// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

contract MockRouter {
    MockERC20 public immutable ankrBNB;
    MockERC20 public immutable wbnb;
    uint256 public rate;
    uint256 public liquidityOut;

    constructor(address ankrBNB_, address wbnb_) {
        ankrBNB = MockERC20(ankrBNB_);
        wbnb = MockERC20(wbnb_);
        rate = 1e18;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function setLiquidityOut(uint256 newLiquidityOut) external {
        liquidityOut = newLiquidityOut;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "PATH");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * rate) / 1e18;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "PATH");
        uint256 expectedOut = (amountIn * rate) / 1e18;
        uint256 available = wbnb.balanceOf(address(this));
        if (liquidityOut != 0 && liquidityOut < available) {
            available = liquidityOut;
        }
        uint256 amountOut = expectedOut <= available ? expectedOut : available;
        require(amountOut >= amountOutMin, "SLIPPAGE");

        bool pulled = ankrBNB.transferFrom(msg.sender, address(this), amountIn);
        require(pulled, "TRANSFER_IN");
        bool sent = wbnb.transfer(to, amountOut);
        require(sent, "TRANSFER_OUT");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
