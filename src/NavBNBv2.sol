// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "./IBNBYieldStrategy.sol";

interface IBNBYieldStrategyWithAll is IBNBYieldStrategy {
    function withdrawAllToVault() external returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IAnkrStrategyTokens {
    function ankrBNB() external view returns (address);
    function wbnb() external view returns (address);
}

contract NavBNBv2 {
    string public constant name = "NavBNBv2";
    string public constant symbol = "nBNBv2";
    uint8 public constant decimals = 18;

    uint256 public constant BPS = 10_000;
    uint256 public constant MINT_FEE_BPS = 25;
    uint256 public constant REDEEM_FEE_BPS = 25;
    uint256 public constant EMERGENCY_FEE_BPS = 1_000;
    uint256 public constant DEFAULT_MAX_STEPS = 32;
    uint256 public constant MIN_PAYOUT_WEI_LOWER = 1;
    uint256 public constant MIN_PAYOUT_WEI_UPPER = 1e18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalLiabilitiesBNB;
    uint256 public totalClaimableBNB;
    uint256 public trackedAssetsBNB;
    mapping(address => uint256) public claimableBNB;
    uint256 public minPayoutWei;

    IBNBYieldStrategy public strategy;
    uint256 public liquidityBufferBPS = 1_000;
    uint256 public minExitSeconds;
    uint256 public fullExitSeconds;
    uint256 public maxExitFeeBps;
    mapping(address => uint64) public lastDepositTime;

    address public immutable guardian;
    address public immutable recovery;

    uint32 public constant MAX_STRATEGY_TIMELOCK_SECONDS = 7 days;
    address public pendingStrategy;
    uint64 public strategyActivationTime;
    uint32 public strategyTimelockSeconds;

    bool public paused;
    uint256 private locked;

    struct QueueEntry {
        address user;
        uint256 amount;
    }

    QueueEntry[] internal queue;
    uint256 public queueHead;
    uint256 internal queueCompactionIndex;
    uint256 internal queueCompactionPopped;
    uint256 internal queueCompactionHead;
    uint256 internal queueCompactionLength;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed account, uint256 bnbIn, uint256 minted);
    event Redeem(address indexed account, uint256 tokenAmount, uint256 bnbPaid, uint256 bnbQueued);
    event Claim(address indexed account, uint256 bnbPaid);
    event EmergencyRedeem(address indexed account, uint256 tokenAmount, uint256 bnbPaid, uint256 fee);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event RecoverSurplus(address indexed to, uint256 amount);
    event ClaimableCredited(address indexed user, uint256 amount);
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event StrategyProposed(address indexed newStrategy, uint256 activationTime);
    event StrategyActivated(address indexed newStrategy);
    event StrategyProposalCancelled();
    event StrategyTimelockUpdated(uint256 newSeconds);
    event LiquidityBufferUpdated(uint256 bps);
    event ExitFeeConfigUpdated(uint256 minSeconds, uint256 fullSeconds, uint256 maxFeeBps);
    event ExitFeeCharged(address indexed account, uint256 feeBps, uint256 feeAmount);
    event MinPayoutWeiUpdated(uint256 minPayoutWei);
    event ClaimableWithdrawn(address indexed account, uint256 amount);

    error ZeroDeposit();
    error ZeroRedeem();
    error Slippage();
    error PausedError();
    error Insolvent();
    error NotGuardian();
    error NotRecovery();
    error TransferZero();
    error Allowance();
    error Balance();
    error BurnBalance();
    error MintZero();
    error BnbSendFail();
    error QueueActive();
    error InvalidRecipient();
    error NoEquity();
    error StrategyNotEmpty();
    error StrategyNotContract();
    error StrategyWithdrawFailed();
    error InsufficientLiquidityAfterWithdraw();
    error NoProgress();
    error QueueEmpty();
    error NoLiquidity();
    error PayoutTooSmall(uint256 payout, uint256 minPayoutWei);
    error MaxStepsNoProgress();
    error StrategyProposalMissing();
    error StrategyTimelockNotExpired();
    error StrategyTimelockTooLong();
    error StrategyTimelockEnabled();
    error TooEarlyForFreeExit();
    error ExitFeeConfigInvalid();
    error MinPayoutOutOfRange();

    enum ClaimBlockReason {
        None,
        QueueEmpty,
        NoLiquidity,
        PayoutTooSmall,
        MaxStepsNoProgress
    }

    modifier nonReentrant() {
        require(locked == 0, "REENTRANCY");
        locked = 1;
        _;
        locked = 0;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PausedError();
        }
        _;
    }

    constructor(address guardian_, address recovery_) {
        if (guardian_ == address(0) || recovery_ == address(0)) {
            revert TransferZero();
        }
        guardian = guardian_;
        recovery = recovery_;
        strategyTimelockSeconds = 1 days;
        fullExitSeconds = 30 days;
        maxExitFeeBps = 500;
        minPayoutWei = 1e14;
    }

    receive() external payable {}

    function approve(address spender, uint256 amount) external nonReentrant returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) {
                revert Allowance();
            }
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function pause() external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setStrategy(address newStrategy) external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        if (strategyTimelockSeconds != 0) {
            revert StrategyTimelockEnabled();
        }
        _setStrategy(newStrategy);
        _clearPendingStrategy();
    }

    function proposeStrategy(address newStrategy) external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        pendingStrategy = newStrategy;
        strategyActivationTime = uint64(block.timestamp + strategyTimelockSeconds);
        emit StrategyProposed(newStrategy, strategyActivationTime);
    }

    function activateStrategy() external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        if (strategyActivationTime == 0) {
            revert StrategyProposalMissing();
        }
        if (block.timestamp < strategyActivationTime) {
            revert StrategyTimelockNotExpired();
        }
        address newStrategy = pendingStrategy;
        if (newStrategy != address(0) && newStrategy.code.length == 0) {
            revert StrategyNotContract();
        }
        _setStrategy(newStrategy);
        _clearPendingStrategy();
        emit StrategyActivated(newStrategy);
    }

    function cancelStrategyProposal() external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        _clearPendingStrategy();
        emit StrategyProposalCancelled();
    }

    function setStrategyTimelockSeconds(uint32 newSeconds) external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        if (newSeconds > MAX_STRATEGY_TIMELOCK_SECONDS) {
            revert StrategyTimelockTooLong();
        }
        strategyTimelockSeconds = newSeconds;
        emit StrategyTimelockUpdated(newSeconds);
    }

    function setLiquidityBufferBPS(uint256 newBps) external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        if (newBps > BPS) {
            revert Slippage();
        }
        liquidityBufferBPS = newBps;
        emit LiquidityBufferUpdated(newBps);
    }

    function setExitFeeConfig(uint256 minSeconds, uint256 fullSeconds, uint256 maxFeeBps) external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        if (fullSeconds < minSeconds) {
            revert ExitFeeConfigInvalid();
        }
        if (maxFeeBps > BPS) {
            revert ExitFeeConfigInvalid();
        }
        if (fullSeconds == minSeconds && maxFeeBps != 0) {
            revert ExitFeeConfigInvalid();
        }
        minExitSeconds = minSeconds;
        fullExitSeconds = fullSeconds;
        maxExitFeeBps = maxFeeBps;
        emit ExitFeeConfigUpdated(minSeconds, fullSeconds, maxFeeBps);
    }

    function setMinPayoutWei(uint256 newMinPayoutWei) external nonReentrant {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        if (newMinPayoutWei < MIN_PAYOUT_WEI_LOWER || newMinPayoutWei > MIN_PAYOUT_WEI_UPPER) {
            revert MinPayoutOutOfRange();
        }
        minPayoutWei = newMinPayoutWei;
        emit MinPayoutWeiUpdated(newMinPayoutWei);
    }

    function deposit(uint256 minSharesOut) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) {
            revert ZeroDeposit();
        }
        uint256 assetsBefore = totalAssets() - msg.value;
        if (totalSupply > 0 && assetsBefore <= _totalObligations()) {
            revert Insolvent();
        }
        bool wasZeroSupply = totalSupply == 0;
        if (wasZeroSupply) {
            if (_totalObligations() > 0) {
                revert NoEquity();
            }
            if (assetsBefore > 0) {
                // Protect against free capture of pre-existing assets on first deposit.
                _mint(recovery, assetsBefore);
            }
        }
        if (!wasZeroSupply && assetsBefore > trackedAssetsBNB) {
            uint256 surplus = assetsBefore - trackedAssetsBNB;
            uint256 navAtTracked = _navWithAssets(trackedAssetsBNB);
            if (navAtTracked == 0) {
                navAtTracked = _navWithAssets(assetsBefore);
            }
            uint256 surplusShares = (surplus * 1e18) / navAtTracked;
            if (surplusShares > 0) {
                _mint(recovery, surplusShares);
            }
        }
        uint256 navBefore = _navWithAssets(assetsBefore);
        uint256 fee = (msg.value * MINT_FEE_BPS) / BPS;
        uint256 valueAfterFee = msg.value - fee;
        uint256 minted = (valueAfterFee * 1e18) / navBefore;
        if (minted < minSharesOut) {
            revert Slippage();
        }
        _mint(msg.sender, minted);
        lastDepositTime[msg.sender] = uint64(block.timestamp);
        trackedAssetsBNB = totalAssets();
        _investExcess();
        emit Deposit(msg.sender, msg.value, minted);
    }

    function redeem(uint256 tokenAmount, uint256 minBnbOut) external nonReentrant whenNotPaused {
        if (tokenAmount == 0) {
            revert ZeroRedeem();
        }
        uint64 lastDeposit = lastDepositTime[msg.sender];
        if (lastDeposit != 0 && minExitSeconds != 0 && block.timestamp < uint256(lastDeposit) + minExitSeconds) {
            revert TooEarlyForFreeExit();
        }
        uint256 obligations = _totalObligations();
        if (totalAssets() <= obligations) {
            revert Insolvent();
        }
        uint256 currentNav = nav();
        if (currentNav == 0) {
            revert Insolvent();
        }
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = (bnbOwed * REDEEM_FEE_BPS) / BPS;
        uint256 timeFeeBps = exitFeeBps(msg.sender);
        uint256 timeFee = ((bnbOwed - fee) * timeFeeBps) / BPS;
        uint256 bnbAfterFee = bnbOwed - fee - timeFee;
        if (bnbAfterFee == 0) {
            revert NoProgress();
        }
        if (bnbAfterFee < minBnbOut) {
            revert Slippage();
        }

        uint256 bnbPaid;
        uint256 bnbQueued;
        if (totalLiabilitiesBNB > 0) {
            _payQueueHead(totalLiabilitiesBNB, DEFAULT_MAX_STEPS);
        }
        if (totalLiabilitiesBNB > 0) {
            bnbQueued = bnbAfterFee;
        } else {
            _ensureLiquidityBestEffort(bnbAfterFee);
            uint256 liquidAvailable = _queueRedeemableBalance();
            if (liquidAvailable >= bnbAfterFee) {
                bnbPaid = bnbAfterFee;
            } else {
                bnbPaid = liquidAvailable;
                bnbQueued = bnbAfterFee - liquidAvailable;
            }
        }

        if (bnbQueued > 0) {
            _enqueue(msg.sender, bnbQueued);
        }

        if (bnbPaid > 0) {
            _ensureLiquidityBestEffort(bnbPaid);
            (bool success,) = msg.sender.call{value: bnbPaid}("");
            if (!success) {
                revert BnbSendFail();
            }
            trackedAssetsBNB = totalAssets();
        }

        _burn(msg.sender, tokenAmount);
        if (timeFee > 0) {
            emit ExitFeeCharged(msg.sender, timeFeeBps, timeFee);
        }
        emit Redeem(msg.sender, tokenAmount, bnbPaid, bnbQueued);
    }

    function claim() external nonReentrant {
        _claim(DEFAULT_MAX_STEPS, false);
    }

    function claim(uint256 maxSteps) external nonReentrant {
        _claim(maxSteps, false);
    }

    function claim(uint256 maxSteps, bool acceptDust) external nonReentrant {
        _claim(maxSteps, acceptDust);
    }

    function _claim(uint256 maxSteps, bool acceptDust) internal {
        if (totalLiabilitiesBNB == 0) {
            revert QueueEmpty();
        }
        if (maxSteps == 0) {
            revert MaxStepsNoProgress();
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        (uint256 totalPaid, uint256 totalCredited) = _payQueueHead(totalLiabilitiesBNB, maxSteps);
        uint256 totalProgress = totalPaid + totalCredited;
        if (totalProgress == 0) {
            revert NoLiquidity();
        }
        _validatePayout(totalProgress, acceptDust);
        if (totalPaid > 0) {
            emit Claim(msg.sender, totalPaid);
        }
    }

    function emergencyRedeem(uint256 tokenAmount, uint256 minBnbOut) external nonReentrant whenNotPaused {
        _emergencyRedeem(tokenAmount, minBnbOut, false);
    }

    function emergencyRedeem(uint256 tokenAmount, uint256 minBnbOut, bool acceptDust)
        external
        nonReentrant
        whenNotPaused
    {
        _emergencyRedeem(tokenAmount, minBnbOut, acceptDust);
    }

    function _emergencyRedeem(uint256 tokenAmount, uint256 minBnbOut, bool acceptDust) internal {
        if (tokenAmount == 0) {
            revert ZeroRedeem();
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = _emergencyFee(bnbOwed);
        uint256 bnbOut = bnbOwed - fee;
        if (bnbOut == 0) {
            revert NoProgress();
        }
        _ensureLiquidityBestEffort(bnbOut);
        uint256 payableOut = _queueRedeemableBalance();
        if (payableOut > bnbOut) {
            payableOut = bnbOut;
        }
        if (payableOut == 0) {
            revert NoLiquidity();
        }
        _validatePayout(payableOut, acceptDust);
        if (payableOut < minBnbOut) {
            revert Slippage();
        }
        uint256 burnAmount = (tokenAmount * payableOut + bnbOut - 1) / bnbOut;
        if (burnAmount == 0) {
            revert NoProgress();
        }
        (bool success,) = msg.sender.call{value: payableOut}("");
        if (!success) {
            revert BnbSendFail();
        }
        trackedAssetsBNB = totalAssets();

        _burn(msg.sender, burnAmount);
        emit EmergencyRedeem(msg.sender, burnAmount, payableOut, fee);
    }

    function _emergencyFee(uint256 bnbOwed) internal pure returns (uint256) {
        uint256 quotient = bnbOwed / BPS;
        uint256 remainder = bnbOwed % BPS;
        uint256 fee = quotient * EMERGENCY_FEE_BPS;
        uint256 remainderFee = remainder * EMERGENCY_FEE_BPS;
        if (remainderFee != 0) {
            fee += (remainderFee + BPS - 1) / BPS;
        }
        if (fee > bnbOwed) {
            fee = bnbOwed;
        }
        if (bnbOwed > 0 && fee >= bnbOwed) {
            fee = bnbOwed - 1;
        }
        return fee;
    }

    function recoverSurplus(address to) external nonReentrant {
        if (msg.sender != recovery) {
            revert NotRecovery();
        }
        if (to == address(0) || to == address(this)) {
            revert InvalidRecipient();
        }
        uint256 surplus = untrackedSurplusBNB();
        if (surplus == 0) {
            return;
        }
        (bool success,) = to.call{value: surplus}("");
        if (!success) {
            revert BnbSendFail();
        }
        emit RecoverSurplus(to, surplus);
    }

    function nav() public view returns (uint256) {
        return _navWithAssets(totalAssets());
    }

    function navPerShare() external view returns (uint256) {
        return nav();
    }

    function previewRedeem(address user, uint256 shares)
        external
        view
        returns (uint256 bnbOut, uint256 exitFee, uint256 redeemFee)
    {
        uint256 currentNav = nav();
        uint256 bnbOwed = (shares * currentNav) / 1e18;
        redeemFee = (bnbOwed * REDEEM_FEE_BPS) / BPS;
        uint256 feeBps = exitFeeBps(user);
        exitFee = ((bnbOwed - redeemFee) * feeBps) / BPS;
        bnbOut = bnbOwed - redeemFee - exitFee;
    }

    function previewEmergencyRedeem(uint256 shares) external view returns (uint256 bnbOut, uint256 fee) {
        uint256 currentNav = nav();
        uint256 bnbOwed = (shares * currentNav) / 1e18;
        fee = _emergencyFee(bnbOwed);
        bnbOut = bnbOwed - fee;
    }

    function exitFeeBpsNow(address user) external view returns (uint256) {
        return exitFeeBps(user);
    }

    function timeUntilZeroExitFee(address user) external view returns (uint256 secondsRemaining) {
        uint64 lastDeposit = lastDepositTime[user];
        if (lastDeposit == 0) {
            return 0;
        }
        uint256 fullSeconds = fullExitSeconds;
        if (fullSeconds == 0) {
            return 0;
        }
        uint256 maturity = uint256(lastDeposit) + fullSeconds;
        if (block.timestamp >= maturity) {
            return 0;
        }
        return maturity - block.timestamp;
    }

    function maturityTimestamp(address user) public view returns (uint64) {
        uint64 lastDeposit = lastDepositTime[user];
        if (lastDeposit == 0 || fullExitSeconds == 0) {
            return 0;
        }
        uint256 maturity = uint256(lastDeposit) + fullExitSeconds;
        if (maturity > type(uint64).max) {
            return type(uint64).max;
        }
        return uint64(maturity);
    }

    function totalObligations() public view returns (uint256) {
        return _totalObligations();
    }

    function redeemableBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function reserveBNB() public view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 obligations = _totalObligations();
        if (assets <= obligations) {
            return 0;
        }
        return assets - obligations;
    }

    function totalAssets() public view returns (uint256) {
        uint256 strategyAssets = address(strategy) == address(0) ? 0 : strategy.totalAssets();
        return address(this).balance + strategyAssets;
    }

    function exitFeeBps(address user) public view returns (uint256) {
        if (maxExitFeeBps == 0) {
            return 0;
        }
        uint64 lastDeposit = lastDepositTime[user];
        if (lastDeposit == 0) {
            return 0;
        }
        uint256 fullSeconds = fullExitSeconds;
        if (fullSeconds == 0) {
            return 0;
        }
        uint256 elapsed = block.timestamp - uint256(lastDeposit);
        if (elapsed >= fullSeconds) {
            return 0;
        }
        uint256 remaining = fullSeconds - elapsed;
        uint256 numerator = maxExitFeeBps * remaining;
        uint256 fee = numerator / fullSeconds;
        if (numerator % fullSeconds != 0) {
            fee += 1;
        }
        if (fee > maxExitFeeBps) {
            fee = maxExitFeeBps;
        }
        return fee;
    }

    function untrackedSurplusBNB() public view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reserved = trackedAssetsBNB + totalClaimableBNB;
        if (balance <= reserved) {
            return 0;
        }
        return balance - reserved;
    }

    function _queueRedeemableBalance() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reserved = totalClaimableBNB;
        return balance > reserved ? balance - reserved : 0;
    }

    function queueState() external view returns (uint256 head, uint256 len, address headUser, uint256 headAmount) {
        head = queueHead;
        len = queue.length;
        if (head < len) {
            QueueEntry storage entry = queue[head];
            headUser = entry.user;
            headAmount = entry.amount;
        }
    }

    function claimStatus(uint256 maxSteps)
        external
        view
        returns (bool canPay, ClaimBlockReason reason, uint256 expectedPaid, uint256 redeemable, uint256 headAmount)
    {
        redeemable = _queueRedeemableBalance();
        if (totalLiabilitiesBNB == 0 || queueHead >= queue.length) {
            return (false, ClaimBlockReason.QueueEmpty, 0, redeemable, 0);
        }
        if (maxSteps == 0) {
            QueueEntry storage entry = queue[queueHead];
            return (false, ClaimBlockReason.MaxStepsNoProgress, 0, redeemable, entry.amount);
        }
        uint256 len = queue.length;
        uint256 head = queueHead;
        uint256 steps = 0;
        uint256 remaining = 0;
        while (head < len && steps < maxSteps) {
            remaining += queue[head].amount;
            head++;
            steps++;
        }
        if (remaining > redeemable) {
            expectedPaid = redeemable;
        } else {
            expectedPaid = remaining;
        }
        QueueEntry storage headEntry = queue[queueHead];
        headAmount = headEntry.amount;
        if (expectedPaid == 0) {
            return (false, ClaimBlockReason.NoLiquidity, 0, redeemable, headAmount);
        }
        if (expectedPaid < minPayoutWei) {
            return (false, ClaimBlockReason.PayoutTooSmall, expectedPaid, redeemable, headAmount);
        }
        return (true, ClaimBlockReason.None, expectedPaid, redeemable, headAmount);
    }

    function userExitStatus(address user, uint256 shares)
        external
        view
        returns (uint256 navValue, uint256 owed, uint256 exitFeeBpsValue, uint256 maturityTs, uint256 minPayoutWei_)
    {
        navValue = nav();
        owed = (shares * navValue) / 1e18;
        exitFeeBpsValue = exitFeeBps(user);
        maturityTs = maturityTimestamp(user);
        minPayoutWei_ = minPayoutWei;
    }

    function _totalObligations() internal view returns (uint256) {
        return totalLiabilitiesBNB + totalClaimableBNB;
    }

    function _enqueue(address user, uint256 amount) internal {
        queue.push(QueueEntry({user: user, amount: amount}));
        totalLiabilitiesBNB += amount;
    }

    function _payQueueHead(uint256 maxAmount, uint256 maxSteps) internal returns (uint256 paid, uint256 credited) {
        if (maxAmount == 0 || totalLiabilitiesBNB == 0) {
            return (0, 0);
        }
        uint256 remainingCap = maxAmount;
        if (remainingCap > totalLiabilitiesBNB) {
            remainingCap = totalLiabilitiesBNB;
        }
        uint256 payBudget = remainingCap;
        _ensureLiquidityBestEffort(payBudget);
        uint256 remainingLiquid = _queueRedeemableBalance();
        if (remainingLiquid > remainingCap) {
            remainingLiquid = remainingCap;
        }
        uint256 head = queueHead;
        uint256 steps;
        while (remainingCap > 0 && remainingLiquid > 0 && head < queue.length && steps < maxSteps) {
            QueueEntry storage entry = queue[head];
            uint256 pay = entry.amount;
            if (pay > remainingCap) {
                pay = remainingCap;
            }
            if (pay > remainingLiquid) {
                pay = remainingLiquid;
            }
            entry.amount -= pay;
            totalLiabilitiesBNB -= pay;
            (bool success,) = entry.user.call{value: pay}("");
            if (!success) {
                uint256 creditedAmount = pay + entry.amount;
                entry.amount = 0;
                totalLiabilitiesBNB -= creditedAmount - pay;
                claimableBNB[entry.user] += creditedAmount;
                totalClaimableBNB += creditedAmount;
                emit ClaimableCredited(entry.user, creditedAmount);
                credited += creditedAmount;
                if (creditedAmount >= remainingLiquid) {
                    remainingLiquid = 0;
                } else {
                    remainingLiquid -= creditedAmount;
                }
                head++;
                steps++;
                continue;
            } else {
                paid += pay;
                remainingCap -= pay;
                remainingLiquid -= pay;
            }
            if (entry.amount == 0) {
                head++;
                steps++;
            } else {
                break;
            }
        }
        queueHead = head;
        if (paid > 0) {
            trackedAssetsBNB = totalAssets();
        }
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    function getQueueEntry(uint256 index) external view returns (address user, uint256 amount) {
        QueueEntry storage entry = queue[index];
        return (entry.user, entry.amount);
    }

    function compactQueue(uint256 maxMoves) external nonReentrant {
        uint256 head = queueHead;
        if (head == 0 || maxMoves == 0) {
            return;
        }
        uint256 len = queue.length;
        uint256 remaining = len - head;
        if (queueCompactionHead != head || queueCompactionLength != len) {
            queueCompactionHead = head;
            queueCompactionLength = len;
            queueCompactionIndex = 0;
            queueCompactionPopped = 0;
        }
        uint256 movesLeft = maxMoves;
        if (queueCompactionIndex < remaining) {
            uint256 shiftRemaining = remaining - queueCompactionIndex;
            uint256 shiftMoves = shiftRemaining > movesLeft ? movesLeft : shiftRemaining;
            for (uint256 i = 0; i < shiftMoves; i++) {
                queue[queueCompactionIndex + i] = queue[head + queueCompactionIndex + i];
            }
            queueCompactionIndex += shiftMoves;
            movesLeft -= shiftMoves;
        }
        if (queueCompactionIndex < remaining || movesLeft == 0) {
            return;
        }
        uint256 popRemaining = head - queueCompactionPopped;
        uint256 popMoves = popRemaining > movesLeft ? movesLeft : popRemaining;
        for (uint256 i = 0; i < popMoves; i++) {
            queue.pop();
        }
        queueCompactionPopped += popMoves;
        if (popMoves > 0) {
            queueCompactionLength = len - popMoves;
        }
        if (queueCompactionPopped < head) {
            return;
        }
        queueHead = 0;
        queueCompactionIndex = 0;
        queueCompactionPopped = 0;
        queueCompactionHead = 0;
        queueCompactionLength = 0;
    }

    function withdrawClaimable(uint256 minOut) external nonReentrant whenNotPaused {
        _withdrawClaimable(minOut, false);
    }

    function withdrawClaimable(uint256 minOut, bool acceptDust) external nonReentrant whenNotPaused {
        _withdrawClaimable(minOut, acceptDust);
    }

    function _withdrawClaimable(uint256 minOut, bool acceptDust) internal {
        uint256 claimable = claimableBNB[msg.sender];
        if (claimable == 0) {
            revert NoProgress();
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        _ensureLiquidityBestEffort(claimable);
        uint256 payout = claimable;
        uint256 liquidAvailable = redeemableBalance();
        if (payout > liquidAvailable) {
            payout = liquidAvailable;
        }
        if (payout == 0) {
            revert NoLiquidity();
        }
        _validatePayout(payout, acceptDust);
        if (payout < minOut) {
            revert Slippage();
        }
        claimableBNB[msg.sender] = claimable - payout;
        totalClaimableBNB -= payout;
        (bool success,) = msg.sender.call{value: payout}("");
        if (!success) {
            revert BnbSendFail();
        }
        trackedAssetsBNB = totalAssets();
        emit ClaimableWithdrawn(msg.sender, payout);
    }

    function _navWithAssets(uint256 assets) internal view returns (uint256) {
        if (totalSupply == 0) {
            return 1e18;
        }
        uint256 obligations = _totalObligations();
        if (assets <= obligations) {
            return 0;
        }
        uint256 netAssets = assets - obligations;
        return (netAssets * 1e18) / totalSupply;
    }

    function _investExcess() internal {
        if (address(strategy) == address(0)) {
            return;
        }
        uint256 assets = totalAssets();
        uint256 bufferTarget = (assets * liquidityBufferBPS) / BPS;
        uint256 balance = address(this).balance;
        if (balance > bufferTarget) {
            uint256 excess = balance - bufferTarget;
            strategy.deposit{value: excess}();
        }
    }

    function _ensureLiquidityExact(uint256 needed) internal {
        if (needed == 0 || address(strategy) == address(0)) {
            return;
        }
        uint256 balance = address(this).balance;
        if (balance >= needed) {
            return;
        }
        uint256 shortfall = needed - balance;
        uint256 available = strategy.totalAssets();
        uint256 withdrawAmount = shortfall > available ? available : shortfall;
        if (withdrawAmount == 0) {
            revert InsufficientLiquidityAfterWithdraw();
        }
        uint256 received = strategy.withdraw(withdrawAmount);
        if (available > 0 && received == 0) {
            revert StrategyWithdrawFailed();
        }
        if (address(this).balance < needed) {
            revert InsufficientLiquidityAfterWithdraw();
        }
    }

    function _ensureLiquidityBestEffort(uint256 target) internal {
        if (target == 0 || address(strategy) == address(0)) {
            return;
        }
        uint256 balance = address(this).balance;
        if (balance >= target) {
            return;
        }
        uint256 shortfall = target - balance;
        uint256 available = strategy.totalAssets();
        uint256 withdrawAmount = shortfall > available ? available : shortfall;
        if (withdrawAmount == 0) {
            return;
        }
        uint256 received = strategy.withdraw(withdrawAmount);
        if (available > 0 && received == 0) {
            revert StrategyWithdrawFailed();
        }
    }

    function _validatePayout(uint256 payout, bool acceptDust) internal view {
        if (acceptDust) {
            if (payout == 0) {
                revert NoLiquidity();
            }
            return;
        }
        if (payout < minPayoutWei) {
            revert PayoutTooSmall(payout, minPayoutWei);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) {
            revert TransferZero();
        }
        uint256 bal = balanceOf[from];
        if (bal < amount) {
            revert Balance();
        }
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        if (amount > 0) {
            uint64 fromLastDeposit = lastDepositTime[from];
            uint64 toLastDeposit = lastDepositTime[to];
            if (fromLastDeposit > toLastDeposit) {
                lastDepositTime[to] = fromLastDeposit;
            }
        }
        emit Transfer(from, to, amount);
    }

    function _setStrategy(address newStrategy) internal {
        address oldStrategy = address(strategy);
        if (oldStrategy != address(0)) {
            IBNBYieldStrategyWithAll(oldStrategy).withdrawAllToVault();
            _requireStrategyEmpty(oldStrategy);
        }
        if (newStrategy != address(0)) {
            if (newStrategy.code.length == 0) {
                revert StrategyNotContract();
            }
            _requireStrategyEmpty(newStrategy);
        }
        strategy = IBNBYieldStrategy(newStrategy);
        trackedAssetsBNB = totalAssets();
        emit StrategyUpdated(oldStrategy, newStrategy);
    }

    function _requireStrategyEmpty(address strategyAddress) internal view {
        if (IBNBYieldStrategy(strategyAddress).totalAssets() != 0) {
            revert StrategyNotEmpty();
        }
        if (strategyAddress.balance != 0) {
            revert StrategyNotEmpty();
        }
        _requireTokenBalanceEmpty(strategyAddress, IAnkrStrategyTokens.ankrBNB.selector);
        _requireTokenBalanceEmpty(strategyAddress, IAnkrStrategyTokens.wbnb.selector);
    }

    function _requireTokenBalanceEmpty(address strategyAddress, bytes4 selector) internal view {
        (bool success, bytes memory data) = strategyAddress.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length != 32) {
            return;
        }
        address token = abi.decode(data, (address));
        if (token == address(0)) {
            return;
        }
        if (IERC20(token).balanceOf(strategyAddress) != 0) {
            revert StrategyNotEmpty();
        }
    }

    function _clearPendingStrategy() internal {
        pendingStrategy = address(0);
        strategyActivationTime = 0;
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) {
            revert MintZero();
        }
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        if (bal < amount) {
            revert BurnBalance();
        }
        balanceOf[from] = bal - amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}
