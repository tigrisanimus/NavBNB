// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "./IBNBYieldStrategy.sol";

contract NavBNBv2 {
    string public constant name = "NavBNBv2";
    string public constant symbol = "nBNBv2";
    uint8 public constant decimals = 18;

    uint256 public constant BPS = 10_000;
    uint256 public constant MINT_FEE_BPS = 25;
    uint256 public constant REDEEM_FEE_BPS = 25;
    uint256 public constant CAP_BPS = 1_000;
    uint256 public constant EMERGENCY_FEE_BPS = 1_000;
    uint256 public constant DEFAULT_MAX_STEPS = 32;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalLiabilitiesBNB;
    uint256 public totalClaimableBNB;
    mapping(uint256 => uint256) public spentToday;
    mapping(uint256 => uint256) internal capBaseBNB;
    mapping(uint256 => bool) internal capBaseSet;

    uint256 public trackedAssetsBNB;
    mapping(address => uint256) public claimableBNB;

    IBNBYieldStrategy public strategy;
    uint256 public liquidityBufferBPS = 1_000;

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

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed account, uint256 bnbIn, uint256 minted);
    event Redeem(address indexed account, uint256 tokenAmount, uint256 bnbPaid, uint256 bnbQueued);
    event Claim(address indexed account, uint256 bnbPaid);
    event EmergencyRedeem(address indexed account, uint256 tokenAmount, uint256 bnbPaid, uint256 fee);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event RecoverSurplus(address indexed to, uint256 amount);
    event CapExhausted(uint256 indexed day, uint256 spent, uint256 cap);
    event ClaimableCredited(address indexed user, uint256 amount);
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event StrategyProposed(address indexed newStrategy, uint256 activationTime);
    event StrategyActivated(address indexed newStrategy);
    event StrategyProposalCancelled();
    event StrategyTimelockUpdated(uint256 newSeconds);
    event LiquidityBufferUpdated(uint256 bps);

    error ZeroDeposit();
    error ZeroRedeem();
    error Slippage();
    error PausedError();
    error CapReached();
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
    error InsufficientReserve();
    error NoProgress();
    error StrategyProposalMissing();
    error StrategyTimelockNotExpired();
    error StrategyTimelockTooLong();
    error StrategyTimelockEnabled();

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
        trackedAssetsBNB = totalAssets();
        _investExcess();
        emit Deposit(msg.sender, msg.value, minted);
    }

    function redeem(uint256 tokenAmount, uint256 minBnbOut) external nonReentrant whenNotPaused {
        if (tokenAmount == 0) {
            revert ZeroRedeem();
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
        uint256 bnbAfterFee = bnbOwed - fee;
        if (bnbAfterFee == 0) {
            revert Slippage();
        }
        if (bnbAfterFee < minBnbOut) {
            revert Slippage();
        }

        uint256 bnbPaid;
        uint256 bnbQueued;
        uint256 day = _currentDay();
        _initCapBase(day);
        uint256 capRemaining = _capRemaining(day);

        if (totalLiabilitiesBNB > 0) {
            uint256 paidFromQueue = _payQueueHead(day, capRemaining, DEFAULT_MAX_STEPS);
            capRemaining -= paidFromQueue;
            if (totalLiabilitiesBNB == 0 && capRemaining > 0) {
                if (capRemaining >= bnbAfterFee) {
                    bnbPaid = bnbAfterFee;
                } else {
                    bnbPaid = capRemaining;
                    bnbQueued = bnbAfterFee - capRemaining;
                }
            } else {
                bnbQueued = bnbAfterFee;
            }
        } else {
            if (capRemaining >= bnbAfterFee) {
                bnbPaid = bnbAfterFee;
            } else {
                bnbPaid = capRemaining;
                bnbQueued = bnbAfterFee - capRemaining;
            }
        }

        if (bnbQueued > 0) {
            _enqueue(msg.sender, bnbQueued);
        }

        if (bnbPaid > 0) {
            spentToday[day] += bnbPaid;
            _ensureLiquidity(bnbPaid);
            (bool success,) = msg.sender.call{value: bnbPaid}("");
            if (!success) {
                revert BnbSendFail();
            }
            trackedAssetsBNB = totalAssets();
        }

        _burn(msg.sender, tokenAmount);
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
        uint256 day = _currentDay();
        _initCapBase(day);
        uint256 capRemaining = _capRemaining(day);
        if (capRemaining == 0) {
            return;
        }
        uint256 totalPaid = _payQueueHead(day, capRemaining, maxSteps);
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
        _initCapBase(_currentDay());
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = (bnbOwed * EMERGENCY_FEE_BPS + (BPS - 1)) / BPS;
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

    function untrackedSurplusBNB() public view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reserved = trackedAssetsBNB + totalClaimableBNB;
        if (balance <= reserved) {
            return 0;
        }
        return balance - reserved;
    }

    function capForDay(uint256 day) external view returns (uint256) {
        return _dayCap(day);
    }

    function _dayCap(uint256 day) internal view returns (uint256) {
        uint256 base = capBaseSet[day] ? capBaseBNB[day] : totalAssets();
        return (base * CAP_BPS) / BPS;
    }

    function _initCapBase(uint256 day) internal {
        if (!capBaseSet[day]) {
            capBaseSet[day] = true;
            capBaseBNB[day] = totalAssets();
        }
    }

    function _capRemaining(uint256 day) internal view returns (uint256) {
        uint256 cap = _dayCap(day);
        uint256 spent = spentToday[day];
        return cap > spent ? cap - spent : 0;
    }

    function capRemainingForDay(uint256 day) external view returns (uint256) {
        return _capRemaining(day);
    }

    function capRemainingToday() external view returns (uint256) {
        return _capRemaining(_currentDay());
    }

    function _availableForDay(uint256 day) internal view returns (uint256) {
        uint256 capRemaining = _capRemaining(day);
        uint256 available = capRemaining < totalLiabilitiesBNB ? capRemaining : totalLiabilitiesBNB;
        uint256 assets = totalAssets();
        return available < assets ? available : assets;
    }

    function _currentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _totalObligations() internal view returns (uint256) {
        return totalLiabilitiesBNB + totalClaimableBNB;
    }

    function _enqueue(address user, uint256 amount) internal {
        if (queue.length > queueHead) {
            QueueEntry storage lastEntry = queue[queue.length - 1];
            if (lastEntry.user == user) {
                lastEntry.amount += amount;
                totalLiabilitiesBNB += amount;
                return;
            }
        }
        queue.push(QueueEntry({user: user, amount: amount}));
        totalLiabilitiesBNB += amount;
    }

    function _payQueueHead(uint256 day, uint256 maxAmount, uint256 maxSteps) internal returns (uint256 paid) {
        if (maxAmount == 0 || totalLiabilitiesBNB == 0) {
            return 0;
        }
        uint256 liquid = totalAssets() > totalClaimableBNB ? totalAssets() - totalClaimableBNB : 0;
        uint256 remainingCap = maxAmount;
        if (remainingCap > totalLiabilitiesBNB) {
            remainingCap = totalLiabilitiesBNB;
        }
        uint256 remainingLiquid = liquid;
        if (remainingLiquid > totalLiabilitiesBNB) {
            remainingLiquid = totalLiabilitiesBNB;
        }
        uint256 payBudget = remainingCap;
        if (payBudget > remainingLiquid) {
            payBudget = remainingLiquid;
        }
        _ensureLiquidity(payBudget);
        remainingLiquid = address(this).balance;
        if (remainingLiquid > payBudget) {
            remainingLiquid = payBudget;
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
                spentToday[day] += pay;
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
        if (maxMoves < remaining) {
            return;
        }
        QueueEntry[] memory entries = new QueueEntry[](remaining);
        for (uint256 i = 0; i < remaining; i++) {
            entries[i] = queue[head + i];
        }
        delete queue;
        for (uint256 i = 0; i < remaining; i++) {
            queue.push(entries[i]);
        }
        queueHead = 0;
    }

    function withdrawClaimable(uint256 minOut) external nonReentrant whenNotPaused {
        uint256 claimable = claimableBNB[msg.sender];
        if (claimable == 0) {
            return;
        }
        if (totalAssets() < _totalObligations()) {
            revert Insolvent();
        }
        uint256 day = _currentDay();
        _initCapBase(day);
        uint256 capRemaining = _capRemaining(day);
        uint256 payout = claimable <= capRemaining ? claimable : capRemaining;
        uint256 assets = totalAssets();
        if (payout > assets) {
            payout = assets;
        }
        if (payout < minOut) {
            revert Slippage();
        }
        if (payout == 0) {
            return;
        }
        claimableBNB[msg.sender] = claimable - payout;
        totalClaimableBNB -= payout;
        spentToday[day] += payout;
        _ensureLiquidity(payout);
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
        uint256 received = strategy.withdraw(shortfall);
        if (available > 0 && received == 0) {
            revert StrategyWithdrawFailed();
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
            if (strategy.totalAssets() != 0) {
                revert StrategyNotEmpty();
            }
        }
        if (newStrategy != address(0)) {
            if (newStrategy.code.length == 0) {
                revert StrategyNotContract();
            }
            if (IBNBYieldStrategy(newStrategy).totalAssets() != 0) {
                revert StrategyNotEmpty();
            }
        }
        strategy = IBNBYieldStrategy(newStrategy);
        emit StrategyUpdated(oldStrategy, newStrategy);
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
