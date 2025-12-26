// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockPancakePair {
    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function setReserves(uint112 newReserve0, uint112 newReserve1) external {
        uint32 blockTimestamp = uint32(block.timestamp);
        if (blockTimestampLast != 0 && blockTimestamp > blockTimestampLast) {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (reserve0 != 0 && reserve1 != 0) {
                price0CumulativeLast += uint256(_uqdiv(_encode(reserve1), reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(_uqdiv(_encode(reserve0), reserve1)) * timeElapsed;
            }
        }
        reserve0 = newReserve0;
        reserve1 = newReserve1;
        blockTimestampLast = blockTimestamp;
    }

    function _encode(uint112 y) internal pure returns (uint224) {
        return uint224(y) << 112;
    }

    function _uqdiv(uint224 x, uint112 y) internal pure returns (uint224) {
        return x / y;
    }
}
