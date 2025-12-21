// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract NavBNBv2 {
    string public constant name = "NavBNBv2";
    string public constant symbol = "nBNBv2";
    uint8 public constant decimals = 18;

    uint256 public constant BPS = 10_000;
    uint256 public constant MINT_FEE_BPS = 25;
    uint256 public constant REDEEM_FEE_BPS = 25;
    uint256 public constant CAP_BPS = 100;
    uint256 public constant EMERGENCY_FEE_BPS = 1_000;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalLiabilitiesBNB;
    mapping(uint256 => uint256) public spentToday;

    uint256 public trackedAssetsBNB;

    address public immutable guardian;
    address public immutable recovery;

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

    function deposit(uint256 minSharesOut) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) {
            revert ZeroDeposit();
        }
        if (totalSupply > 0 && reserveBNB() == 0) {
            revert Insolvent();
        }
        uint256 fee = (msg.value * MINT_FEE_BPS) / BPS;
        uint256 valueAfterFee = msg.value - fee;
        uint256 navBefore = nav();
        uint256 minted = (valueAfterFee * 1e18) / navBefore;
        if (minted < minSharesOut) {
            revert Slippage();
        }
        trackedAssetsBNB += msg.value;
        _mint(msg.sender, minted);
        emit Deposit(msg.sender, msg.value, minted);
    }

    function redeem(uint256 tokenAmount, uint256 minBnbOut) external nonReentrant whenNotPaused {
        if (tokenAmount == 0) {
            revert ZeroRedeem();
        }
        if (totalSupply > 0 && reserveBNB() == 0) {
            revert Insolvent();
        }
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = (bnbOwed * REDEEM_FEE_BPS) / BPS;
        uint256 bnbAfterFee = bnbOwed - fee;
        if (bnbAfterFee == 0) {
            revert Slippage();
        }
        if (bnbAfterFee < minBnbOut) {
            revert Slippage();
        }

        _burn(msg.sender, tokenAmount);

        uint256 bnbPaid;
        uint256 bnbQueued;
        uint256 day = _currentDay();

        if (totalLiabilitiesBNB > 0) {
            bnbQueued = bnbAfterFee;
        } else {
            uint256 available = _availableForDay(day);
            if (available >= bnbAfterFee) {
                bnbPaid = bnbAfterFee;
            } else {
                bnbPaid = available;
                bnbQueued = bnbAfterFee - available;
            }
        }

        if (bnbQueued > 0) {
            _enqueue(msg.sender, bnbQueued);
        }

        if (bnbPaid > 0) {
            spentToday[day] += bnbPaid;
            trackedAssetsBNB -= bnbPaid;
            (bool success,) = msg.sender.call{value: bnbPaid}("");
            if (!success) {
                revert BnbSendFail();
            }
        }

        emit Redeem(msg.sender, tokenAmount, bnbPaid, bnbQueued);
    }

    function claim() external nonReentrant {
        _claim(type(uint256).max);
    }

    function claim(uint256 maxSteps) external nonReentrant {
        _claim(maxSteps);
    }

    function _claim(uint256 maxSteps) internal {
        if (totalLiabilitiesBNB == 0) {
            return;
        }
        if (reserveBNB() == 0) {
            revert Insolvent();
        }
        uint256 day = _currentDay();
        uint256 available = _availableForDay(day);
        if (available == 0) {
            emit CapExhausted(day, spentToday[day], _dayCap(day));
            return;
        }
        uint256 head = queueHead;
        uint256 totalPaid;
        uint256 steps;
        while (available > 0 && head < queue.length && steps < maxSteps) {
            QueueEntry storage entry = queue[head];
            uint256 pay = entry.amount <= available ? entry.amount : available;
            entry.amount -= pay;
            available -= pay;
            totalPaid += pay;
            totalLiabilitiesBNB -= pay;
            trackedAssetsBNB -= pay;
            (bool success,) = entry.user.call{value: pay}("");
            if (!success) {
                revert BnbSendFail();
            }
            if (entry.amount == 0) {
                head++;
                steps++;
            } else {
                break;
            }
        }
        queueHead = head;
        if (totalPaid > 0) {
            spentToday[day] += totalPaid;
            emit Claim(msg.sender, totalPaid);
        }
    }

    function emergencyRedeem(uint256 tokenAmount, uint256 minBnbOut) external nonReentrant {
        if (tokenAmount == 0) {
            revert ZeroRedeem();
        }
        if (reserveBNB() == 0) {
            revert Insolvent();
        }
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = (bnbOwed * EMERGENCY_FEE_BPS) / BPS;
        uint256 bnbOut = bnbOwed - fee;
        if (bnbOut == 0) {
            revert Slippage();
        }
        if (bnbOut < minBnbOut) {
            revert Slippage();
        }
        if (bnbOut > reserveBNB()) {
            revert Insolvent();
        }

        _burn(msg.sender, tokenAmount);

        trackedAssetsBNB -= bnbOut;
        (bool success,) = msg.sender.call{value: bnbOut}("");
        if (!success) {
            revert BnbSendFail();
        }

        emit EmergencyRedeem(msg.sender, tokenAmount, bnbOut, fee);
    }

    function recoverSurplus(address to) external nonReentrant {
        if (msg.sender != recovery) {
            revert NotRecovery();
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
        if (totalSupply == 0) {
            return 1e18;
        }
        uint256 reserve = reserveBNB();
        if (reserve == 0) {
            return 0;
        }
        return (reserve * 1e18) / totalSupply;
    }

    function reserveBNB() public view returns (uint256) {
        if (trackedAssetsBNB <= totalLiabilitiesBNB) {
            return 0;
        }
        return trackedAssetsBNB - totalLiabilitiesBNB;
    }

    function untrackedSurplusBNB() public view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance <= trackedAssetsBNB) {
            return 0;
        }
        return balance - trackedAssetsBNB;
    }

    function capForDay(uint256 day) external view returns (uint256) {
        return _dayCap(day);
    }

    function _dayCap(uint256 day) internal view returns (uint256) {
        uint256 assetsForCap = trackedAssetsBNB + spentToday[day];
        return (assetsForCap * CAP_BPS) / BPS;
    }

    function _capRemaining(uint256 day) internal view returns (uint256) {
        uint256 cap = _dayCap(day);
        uint256 spent = spentToday[day];
        return cap > spent ? cap - spent : 0;
    }

    function _availableForDay(uint256 day) internal view returns (uint256) {
        uint256 capRemaining = _capRemaining(day);
        uint256 reserve = reserveBNB();
        return capRemaining < reserve ? capRemaining : reserve;
    }

    function _currentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _enqueue(address user, uint256 amount) internal {
        queue.push(QueueEntry({user: user, amount: amount}));
        totalLiabilitiesBNB += amount;
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    function getQueueEntry(uint256 index) external view returns (address user, uint256 amount) {
        QueueEntry storage entry = queue[index];
        return (entry.user, entry.amount);
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
