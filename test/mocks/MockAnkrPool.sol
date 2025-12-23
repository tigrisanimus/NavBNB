// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

contract MockAnkrPool {
    MockERC20 public immutable ankrBNB;
    uint256 public exchangeRatio;

    constructor(address ankrBNB_, uint256 exchangeRatio_) {
        ankrBNB = MockERC20(ankrBNB_);
        exchangeRatio = exchangeRatio_;
    }

    function setExchangeRatio(uint256 newRatio) external {
        exchangeRatio = newRatio;
    }

    function stakeCerts() external payable {
        require(msg.value > 0, "ZERO_STAKE");
        uint256 mintAmount = (msg.value * 1e18) / exchangeRatio;
        ankrBNB.mint(msg.sender, mintAmount);
    }
}
