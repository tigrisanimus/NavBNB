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

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalLiabilitiesBNB;
    uint256 public totalClaimableBNB;
    uint256 public trackedAssetsBNB;
    mapping(address => uint256) public claimableBNB;

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
    error InsufficientReserve();
    error NoProgress();
    error StrategyProposalMissing();
    error StrategyTimelockNotExpired();
    error StrategyTimelockTooLong();
    error StrategyTimelockEnabled();
    error TooEarlyForFreeExit();
    error ExitFeeConfigInvalid();

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

    function deposit(uint256 minSharesOut) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) {
            revert ZeroDeposit();
        }
        uint256 assetsBefore = totalAssets() - msg.value;
        if (totalSupply > 0 && assetsBefore <= _totalObligations()) {
            revert Insolvent();
        }
        if (totalSupply == 0) {
            if (_totalObligations() > 0) {
                revert NoEquity();
            }
            if (assetsBefore > 0) {
                // Protect against free capture of pre-existing assets on first deposit.
                _mint(recovery, assetsBefore);
            }
        }
        uint256 fee = (msg.value * MINT_FEE_BPS) / BPS;
        uint256 valueAfterFee = msg.value - fee;
        uint256 navBefore = _navWithAssets(assetsBefore);
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
            _ensureLiquidity(bnbAfterFee);
            uint256 liquidAvailable = _redeemableBalance();
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
            _ensureLiquidity(bnbPaid);
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
        _claim(DEFAULT_MAX_STEPS);
    }

    function claim(uint256 maxSteps) external nonReentrant {
        _claim(maxSteps);
    }

    function _claim(uint256 maxSteps) internal {
        if (totalLiabilitiesBNB == 0) {
            return;
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        uint256 totalPaid = _payQueueHead(totalLiabilitiesBNB, maxSteps);
        if (totalPaid > 0) {
            emit Claim(msg.sender, totalPaid);
        }
    }

    function emergencyRedeem(uint256 tokenAmount, uint256 minBnbOut) external nonReentrant whenNotPaused {
        if (tokenAmount == 0) {
            revert ZeroRedeem();
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
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
        uint256 bnbOut = bnbOwed - fee;
        if (bnbOut == 0) {
            revert NoProgress();
        }
        if (bnbOut < minBnbOut) {
            revert Slippage();
        }
        if (bnbOut > reserveBNB()) {
            revert InsufficientReserve();
        }
        _ensureLiquidity(bnbOut);
        (bool success,) = msg.sender.call{value: bnbOut}("");
        if (!success) {
            revert BnbSendFail();
        }
        trackedAssetsBNB = totalAssets();

        _burn(msg.sender, tokenAmount);
        emit EmergencyRedeem(msg.sender, tokenAmount, bnbOut, fee);
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

    function totalObligations() public view returns (uint256) {
        return _totalObligations();
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
        uint256 minSeconds = minExitSeconds;
        uint256 fullSeconds = fullExitSeconds;
        if (fullSeconds <= minSeconds) {
            return 0;
        }
        uint256 start = uint256(lastDeposit) + minSeconds;
        if (block.timestamp < start) {
            return maxExitFeeBps;
        }
        uint256 end = uint256(lastDeposit) + fullSeconds;
        if (block.timestamp >= end) {
            return 0;
        }
        uint256 remaining = end - block.timestamp;
        uint256 duration = fullSeconds - minSeconds;
        return (maxExitFeeBps * remaining) / duration;
    }

    function untrackedSurplusBNB() public view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reserved = trackedAssetsBNB + totalClaimableBNB;
        if (balance <= reserved) {
            return 0;
        }
        return balance - reserved;
    }

    function _redeemableBalance() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reserved = totalClaimableBNB;
        return balance > reserved ? balance - reserved : 0;
    }

    function _totalObligations() internal view returns (uint256) {
        return totalLiabilitiesBNB + totalClaimableBNB;
    }

    function _enqueue(address user, uint256 amount) internal {
        queue.push(QueueEntry({user: user, amount: amount}));
        totalLiabilitiesBNB += amount;
    }

    function _payQueueHead(uint256 maxAmount, uint256 maxSteps) internal returns (uint256 paid) {
        if (maxAmount == 0 || totalLiabilitiesBNB == 0) {
            return 0;
        }
        uint256 remainingCap = maxAmount;
        if (remainingCap > totalLiabilitiesBNB) {
            remainingCap = totalLiabilitiesBNB;
        }
        uint256 payBudget = remainingCap;
        _ensureLiquidity(payBudget);
        uint256 remainingLiquid = _redeemableBalance();
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
                uint256 credited = pay + entry.amount;
                entry.amount = 0;
                totalLiabilitiesBNB -= credited - pay;
                claimableBNB[entry.user] += credited;
                totalClaimableBNB += credited;
                emit ClaimableCredited(entry.user, credited);
                if (credited >= remainingLiquid) {
                    remainingLiquid = 0;
                } else {
                    remainingLiquid -= credited;
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
        uint256 claimable = claimableBNB[msg.sender];
        if (claimable == 0) {
            return;
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        uint256 assets = totalAssets();
        uint256 payout = claimable > assets ? assets : claimable;
        if (payout == 0) {
            revert NoProgress();
        }
        _ensureLiquidity(payout);
        uint256 liquidAvailable = address(this).balance;
        if (payout > liquidAvailable) {
            payout = liquidAvailable;
        }
        if (payout == 0) {
            revert NoProgress();
        }
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

    function _ensureLiquidity(uint256 needed) internal {
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
