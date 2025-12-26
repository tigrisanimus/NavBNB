// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "../IBNBYieldStrategy.sol";

interface IAnkrBNBStakingPool {
    function stakeCerts() external payable;
    function exchangeRatio() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IWBNB is IERC20 {
    function withdraw(uint256 amount) external;
}

interface IRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract AnkrBNBYieldStrategy is IBNBYieldStrategy {
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint16 public constant MAX_VALUATION_HAIRCUT_BPS = 500;
    uint16 public constant MAX_DEVIATION_BPS = 1_000;
    uint32 public constant MAX_DEADLINE_SECONDS = 1 days;
    uint32 public constant MIN_TWAP_ELAPSED = 5 minutes;
    uint256 private constant Q112 = 2 ** 112;
    uint256 private constant ONE = 1e18;

    address public immutable vault;
    address public immutable guardian;
    IAnkrBNBStakingPool public immutable stakingPool;
    IERC20 public immutable ankrBNB;
    IRouter public immutable router;
    IWBNB public immutable wbnb;
    IUniswapV2Pair public immutable twapPair;
    bool public immutable isAnkrToken0;

    uint16 public maxSlippageBps;
    uint16 public valuationHaircutBps;
    uint32 public deadlineSeconds;
    uint256 public maxChunkAnkr;
    uint256 public minRatio;
    uint256 public maxRatio;
    uint256 public maxRatioChangeBps;
    uint256 public lastRatio;
    uint16 public maxDeviationBps;
    uint256 public lastCumulativePrice;
    uint32 public lastTimestamp;
    uint256 public lastTwapPrice;
    bool public paused;
    address public recoveryAddress;
    uint256 private locked;

    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);
    event ValuationHaircutBpsSet(uint256 oldBps, uint256 newBps);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Recovered(address indexed token, uint256 amount, address indexed to);
    event RecoveryAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event WithdrawAllToVault(uint256 withdrawnBNB, uint256 lstSold);
    event RatioFallback(
        uint256 observedRatio, uint256 appliedRatio, uint256 lastRatio, bool outOfBounds, bool deltaExceeded
    );
    event MaxDeviationBpsSet(uint256 oldBps, uint256 newBps);
    event TwapUpdated(uint256 price, uint32 timestamp);

    error NotVault();
    error NotGuardian();
    error PausedError();
    error NotPaused();
    error SlippageTooHigh();
    error ValuationHaircutTooHigh();
    error ZeroAmount();
    error BnbSendFail();
    error ApprovalFailed();
    error TransferFailed();
    error ZeroAddress();
    error InvalidRecoveryToken();
    error InvalidRecipient();
    error InputNotConsumed();
    error InvalidDeadline();
    error InvalidPair();
    error TwapNotReady();
    error TwapUpdateTooSoon(uint256 elapsed, uint256 minElapsed);
    error TwapDeviation(uint256 spotOut, uint256 twapOut);
    error DeviationTooHigh();

    modifier onlyVault() {
        if (msg.sender != vault) {
            revert NotVault();
        }
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PausedError();
        }
        _;
    }

    modifier nonReentrant() {
        require(locked == 0, "REENTRANCY");
        locked = 1;
        _;
        locked = 0;
    }

    constructor(
        address vault_,
        address guardian_,
        address bnbStakingPool_,
        address ankrBNB_,
        address router_,
        address wbnb_,
        address recovery_,
        address twapPair_
    ) {
        if (vault_ == address(0) || recovery_ == address(0)) {
            revert ZeroAddress();
        }
        guardian = guardian_;
        stakingPool = IAnkrBNBStakingPool(bnbStakingPool_);
        ankrBNB = IERC20(ankrBNB_);
        router = IRouter(router_);
        wbnb = IWBNB(wbnb_);
        vault = vault_;
        if (twapPair_ == address(0)) {
            revert ZeroAddress();
        }
        IUniswapV2Pair pair = IUniswapV2Pair(twapPair_);
        address token0 = pair.token0();
        address token1 = pair.token1();
        if (!((token0 == ankrBNB_ && token1 == wbnb_) || (token0 == wbnb_ && token1 == ankrBNB_))) {
            revert InvalidPair();
        }
        twapPair = pair;
        isAnkrToken0 = token0 == ankrBNB_;
        maxSlippageBps = 100;
        valuationHaircutBps = 100;
        maxDeviationBps = 200;
        deadlineSeconds = 300;
        maxChunkAnkr = 500 ether;
        minRatio = 1e18;
        maxRatio = 2e18;
        maxRatioChangeBps = 100;
        recoveryAddress = recovery_;
    }

    receive() external payable {}

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGuardian {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setMaxSlippageBps(uint16 newBps) external onlyGuardian {
        if (newBps > MAX_SLIPPAGE_BPS) {
            revert SlippageTooHigh();
        }
        _updateLastGoodRatio(_readRatio());
        uint256 oldBps = maxSlippageBps;
        maxSlippageBps = newBps;
        emit MaxSlippageBpsSet(oldBps, newBps);
    }

    function setMaxDeviationBps(uint16 newBps) external onlyGuardian {
        if (newBps > MAX_DEVIATION_BPS) {
            revert DeviationTooHigh();
        }
        uint256 oldBps = maxDeviationBps;
        maxDeviationBps = newBps;
        emit MaxDeviationBpsSet(oldBps, newBps);
    }

    function setValuationHaircutBps(uint16 newBps) external onlyGuardian {
        if (newBps > MAX_VALUATION_HAIRCUT_BPS) {
            revert ValuationHaircutTooHigh();
        }
        _updateLastGoodRatio(_readRatio());
        uint256 oldBps = valuationHaircutBps;
        valuationHaircutBps = newBps;
        emit ValuationHaircutBpsSet(oldBps, newBps);
    }

    function setDeadlineSeconds(uint32 newSeconds) external onlyGuardian {
        if (newSeconds == 0 || newSeconds > MAX_DEADLINE_SECONDS) {
            revert InvalidDeadline();
        }
        deadlineSeconds = newSeconds;
    }

    function setMaxChunkAnkr(uint256 newMaxChunk) external onlyGuardian {
        maxChunkAnkr = newMaxChunk;
    }

    function setRecoveryAddress(address newRecovery) external onlyGuardian {
        if (newRecovery == address(0)) {
            revert ZeroAddress();
        }
        address oldRecovery = recoveryAddress;
        recoveryAddress = newRecovery;
        emit RecoveryAddressUpdated(oldRecovery, newRecovery);
    }

    function recoverToken(address token, address to, uint256 amount) external onlyGuardian {
        if (!paused) {
            revert NotPaused();
        }
        if (token == address(0) || token == address(ankrBNB) || token == address(wbnb)) {
            revert InvalidRecoveryToken();
        }
        if (to != vault && to != recoveryAddress) {
            revert InvalidRecipient();
        }
        if (!IERC20(token).transfer(to, amount)) {
            revert TransferFailed();
        }
        emit Recovered(token, amount, to);
    }

    function deposit() external payable onlyVault whenNotPaused {
        if (msg.value == 0) {
            revert ZeroAmount();
        }
        _updateLastGoodRatio(_readRatio());
        stakingPool.stakeCerts{value: msg.value}();
    }

    function withdraw(uint256 bnbAmount) external onlyVault whenNotPaused returns (uint256 received) {
        uint256 ratio = _resolveRatio(_readRatio());
        if (bnbAmount == 0) {
            return 0;
        }

        if (ratio == 0) {
            return 0;
        }

        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 ankrNeeded = _mulDivUp(bnbAmount, ONE, ratio);
        uint256 ankrToSwap = ankrNeeded > ankrBalance ? ankrBalance : ankrNeeded;
        _swapAnkrForBnb(ankrToSwap, ratio);
        uint256 bnbOut = _sendAllBnbToVault();
        return bnbOut;
    }

    function withdrawAllToVault() external onlyVault returns (uint256 received) {
        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 ratio = _resolveRatio(_readRatio());
        if (ankrBalance > 0) {
            _swapAnkrForBnb(ankrBalance, ratio);
        }
        uint256 totalBnb = _sendAllBnbToVault();
        if (ankrBalance > 0) {
            emit WithdrawAllToVault(totalBnb, ankrBalance);
        }
        return totalBnb;
    }

    function totalAssets() external view returns (uint256) {
        uint256 ratio = _readRatio();
        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 bnbValue = ratio == 0 ? 0 : (ankrBalance * ratio) / ONE;
        uint256 adjusted = (bnbValue * (BPS - valuationHaircutBps)) / BPS;
        return address(this).balance + adjusted;
    }

    function updateTwap() public returns (uint256 price) {
        (uint256 priceCumulative, uint32 blockTimestamp) = _currentCumulativePrice();
        uint32 lastTs = lastTimestamp;
        if (lastTs == 0) {
            lastTimestamp = blockTimestamp;
            lastCumulativePrice = priceCumulative;
            return 0;
        }
        uint32 elapsed = blockTimestamp - lastTs;
        if (elapsed < MIN_TWAP_ELAPSED) {
            revert TwapUpdateTooSoon(elapsed, MIN_TWAP_ELAPSED);
        }
        uint256 averagePrice = (priceCumulative - lastCumulativePrice) / elapsed;
        lastCumulativePrice = priceCumulative;
        lastTimestamp = blockTimestamp;
        lastTwapPrice = averagePrice;
        emit TwapUpdated(averagePrice, blockTimestamp);
        return averagePrice;
    }

    function consultTwap(uint256 amountIn) public view returns (uint256 amountOut) {
        uint256 price = lastTwapPrice;
        if (price == 0 || lastTimestamp == 0) {
            return 0;
        }
        return (amountIn * price) / Q112;
    }

    function twapReady() external view returns (bool) {
        return lastTimestamp != 0 && lastTwapPrice != 0;
    }

    function transferHoldingsTo(address to, uint256 ankrAmount, uint256 wbnbAmount, uint256 bnbAmount)
        external
        onlyVault
        nonReentrant
    {
        if (to == address(0)) {
            revert InvalidRecipient();
        }
        if (ankrAmount > 0) {
            if (!ankrBNB.transfer(to, ankrAmount)) {
                revert TransferFailed();
            }
        }
        if (wbnbAmount > 0) {
            if (!wbnb.transfer(to, wbnbAmount)) {
                revert TransferFailed();
            }
        }
        if (bnbAmount > 0) {
            (bool success,) = to.call{value: bnbAmount}("");
            if (!success) {
                revert BnbSendFail();
            }
        }
    }

    function _readRatio() internal view returns (uint256) {
        return stakingPool.exchangeRatio();
    }

    function _updateLastGoodRatio(uint256 ratio) internal {
        if (!_isRatioGood(ratio)) {
            return;
        }
        lastRatio = ratio;
    }

    function _resolveRatio(uint256 ratio) internal returns (uint256) {
        uint256 clamped = _clampRatio(ratio);
        if (_isRatioGood(clamped)) {
            lastRatio = clamped;
            return clamped;
        }
        uint256 applied = clamped;
        uint256 previous = lastRatio;
        if (previous != 0) {
            uint256 maxDelta = (previous * maxRatioChangeBps) / BPS;
            if (clamped > previous) {
                applied = previous + maxDelta;
            } else if (previous > maxDelta) {
                applied = previous - maxDelta;
            } else {
                applied = 0;
            }
            applied = _clampRatio(applied);
        }
        emit RatioFallback(
            ratio,
            applied,
            previous,
            ratio < minRatio || ratio > maxRatio,
            previous != 0 && _deltaExceeded(clamped, previous)
        );
        return applied;
    }

    function _isRatioGood(uint256 ratio) internal view returns (bool) {
        if (ratio < minRatio || ratio > maxRatio) {
            return false;
        }
        uint256 previous = lastRatio;
        if (previous == 0) {
            return true;
        }
        return !_deltaExceeded(ratio, previous);
    }

    function _deltaExceeded(uint256 ratio, uint256 previous) internal view returns (bool) {
        uint256 delta = ratio > previous ? ratio - previous : previous - ratio;
        uint256 maxDelta = (previous * maxRatioChangeBps) / BPS;
        return delta > maxDelta;
    }

    function _clampRatio(uint256 ratio) internal view returns (uint256) {
        if (ratio < minRatio) {
            return minRatio;
        }
        if (ratio > maxRatio) {
            return maxRatio;
        }
        return ratio;
    }

    function _minOutFromRatio(uint256 ankrIn, uint256 ratio) internal view returns (uint256) {
        if (ankrIn == 0 || ratio == 0) {
            return 0;
        }
        uint256 expectedOut = (ankrIn * ratio) / ONE;
        uint256 afterHaircut = (expectedOut * (BPS - valuationHaircutBps)) / BPS;
        return (afterHaircut * (BPS - maxSlippageBps)) / BPS;
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }
        uint256 quotient = a / denominator;
        uint256 remainder = a % denominator;
        uint256 result = quotient * b;
        if (remainder == 0) {
            return result;
        }
        uint256 remainderProduct = remainder * b;
        uint256 extra = remainderProduct / denominator;
        if (remainderProduct % denominator != 0) {
            extra += 1;
        }
        return result + extra;
    }

    function _swapAnkrForBnb(uint256 ankrToSwap, uint256 ratio) internal {
        if (ankrToSwap == 0 || ratio == 0) {
            return;
        }
        address[] memory path = new address[](2);
        path[0] = address(ankrBNB);
        path[1] = address(wbnb);

        _ensureAllowance(ankrToSwap);
        if (deadlineSeconds == 0 || deadlineSeconds > MAX_DEADLINE_SECONDS) {
            revert InvalidDeadline();
        }
        uint256 remaining = ankrToSwap;
        uint256 chunkSize = maxChunkAnkr == 0 ? remaining : maxChunkAnkr;
        while (remaining > 0) {
            uint256 chunk = remaining > chunkSize ? chunkSize : remaining;
            uint256 spotQuoteOut = router.getAmountsOut(chunk, path)[1];
            uint256 twapOut = consultTwap(chunk);
            if (twapOut == 0) {
                revert TwapNotReady();
            }
            uint256 minSpotAllowed = (twapOut * (BPS - maxDeviationBps)) / BPS;
            if (spotQuoteOut < minSpotAllowed) {
                revert TwapDeviation(spotQuoteOut, twapOut);
            }
            uint256 ratioMinOut = _minOutFromRatio(chunk, ratio);
            uint256 twapMinOut = (twapOut * (BPS - maxSlippageBps)) / BPS;
            uint256 spotMinOut = (spotQuoteOut * (BPS - maxSlippageBps)) / BPS;
            uint256 amountOutMin = ratioMinOut;
            if (twapMinOut < amountOutMin) {
                amountOutMin = twapMinOut;
            }
            if (spotMinOut < amountOutMin) {
                amountOutMin = spotMinOut;
            }
            uint256 ankrBefore = ankrBNB.balanceOf(address(this));

            router.swapExactTokensForTokens(chunk, amountOutMin, path, address(this), block.timestamp + deadlineSeconds);

            uint256 ankrAfter = ankrBNB.balanceOf(address(this));
            if (ankrBefore - ankrAfter != chunk) {
                revert InputNotConsumed();
            }
            _unwrapWbnbBalance();
            remaining -= chunk;
        }
        _unwrapWbnbBalance();
    }

    function _sendAllBnbToVault() internal returns (uint256 bnbOut) {
        _unwrapWbnbBalance();
        bnbOut = address(this).balance;
        if (bnbOut > 0) {
            (bool success,) = vault.call{value: bnbOut}("");
            if (!success) {
                revert BnbSendFail();
            }
        }
    }

    function _approve(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.approve.selector, spender, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert ApprovalFailed();
        }
    }

    function _ensureAllowance(uint256 amount) internal {
        uint256 current = ankrBNB.allowance(address(this), address(router));
        if (current >= amount) {
            return;
        }
        if (current != 0) {
            _approve(ankrBNB, address(router), 0);
        }
        _approve(ankrBNB, address(router), type(uint256).max);
    }

    function _unwrapWbnbBalance() internal {
        uint256 wbnbBalance = wbnb.balanceOf(address(this));
        if (wbnbBalance > 0) {
            wbnb.withdraw(wbnbBalance);
        }
    }

    function _currentCumulativePrice() internal view returns (uint256 priceCumulative, uint32 blockTimestamp) {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 currentTimestamp) = _currentCumulativePrices();
        blockTimestamp = currentTimestamp;
        priceCumulative = isAnkrToken0 ? price0Cumulative : price1Cumulative;
    }

    function _currentCumulativePrices()
        internal
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        price0Cumulative = twapPair.price0CumulativeLast();
        price1Cumulative = twapPair.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = twapPair.getReserves();
        blockTimestamp = uint32(block.timestamp);
        if (blockTimestampLast != blockTimestamp) {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (reserve0 != 0 && reserve1 != 0) {
                price0Cumulative += (uint256(_uqdiv(_encode(reserve1), reserve0)) * timeElapsed);
                price1Cumulative += (uint256(_uqdiv(_encode(reserve0), reserve1)) * timeElapsed);
            }
        }
    }

    function _encode(uint112 y) internal pure returns (uint224) {
        return uint224(y) << 112;
    }

    function _uqdiv(uint224 x, uint112 y) internal pure returns (uint224) {
        return x / y;
    }
}
