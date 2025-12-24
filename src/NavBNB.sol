// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract NavBNB {
    string public constant name = "NavBNB";
    string public constant symbol = "nBNB";
    uint8 public constant decimals = 18;

    uint256 public constant BPS = 10_000;
    uint256 public constant MINT_FEE_BPS = 25;
    uint256 public constant REDEEM_FEE_BPS = 25;
    uint256 public constant EMERGENCY_FEE_BPS = 1_000;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    mapping(address => uint256) public userOwedBNB;
    uint256 public queuedTotalOwedBNB;

    uint256 private locked;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed account, uint256 bnbIn, uint256 minted);
    event Redeem(address indexed account, uint256 tokenAmount, uint256 bnbPaid, uint256 bnbQueued);
    event Claim(address indexed account, uint256 bnbPaid);
    event EmergencyRedeem(address indexed account, uint256 tokenAmount, uint256 bnbPaid, uint256 fee);

    error DepositsPausedNoReserve();
    error QueueExists();
    error SupplyNotZero();
    error InsufficientLiquidity();

    modifier nonReentrant() {
        require(locked == 0, "REENTRANCY");
        locked = 1;
        _;
        locked = 0;
    }

    receive() external payable {}

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function deposit() external payable {
        require(msg.value > 0, "ZERO_DEPOSIT");
        uint256 fee = (msg.value * MINT_FEE_BPS) / BPS;
        uint256 valueAfterFee = msg.value - fee;
        uint256 preBalance = address(this).balance - msg.value;
        if (totalSupply == 0 && preBalance > 0) {
            _sweepOrphanedReserve(preBalance);
            preBalance = address(this).balance - msg.value;
        }
        uint256 preReserve = preBalance - queuedTotalOwedBNB;
        if (totalSupply > 0 && preReserve == 0) {
            revert DepositsPausedNoReserve();
        }
        uint256 navBefore = totalSupply == 0 ? 1e18 : (preReserve * 1e18) / totalSupply;
        uint256 minted = (valueAfterFee * 1e18) / navBefore;
        _mint(msg.sender, minted);
        emit Deposit(msg.sender, msg.value, minted);
    }

    function redeem(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "ZERO_REDEEM");
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = (bnbOwed * REDEEM_FEE_BPS) / BPS;
        uint256 bnbAfterFee = bnbOwed - fee;
        require(bnbAfterFee > 0, "ROUNDING");

        uint256 available = reserveBNB();

        uint256 bnbPaid;
        uint256 bnbQueued;
        if (available >= bnbAfterFee) {
            bnbPaid = bnbAfterFee;
        } else if (available > 0) {
            bnbPaid = available;
            bnbQueued = bnbAfterFee - available;
        } else {
            bnbQueued = bnbAfterFee;
        }

        _burn(msg.sender, tokenAmount);

        if (bnbQueued > 0) {
            userOwedBNB[msg.sender] += bnbQueued;
            queuedTotalOwedBNB += bnbQueued;
        }

        if (bnbPaid > 0) {
            (bool success,) = msg.sender.call{value: bnbPaid}("");
            require(success, "BNB_SEND_FAIL");
        }

        emit Redeem(msg.sender, tokenAmount, bnbPaid, bnbQueued);
    }

    function claim() external nonReentrant {
        uint256 owed = userOwedBNB[msg.sender];
        require(owed > 0, "NOTHING_OWED");
        uint256 available = address(this).balance;
        require(available > 0, "INSUFFICIENT_LIQUIDITY");

        uint256 payout;
        if (available >= queuedTotalOwedBNB) {
            payout = owed;
        } else {
            payout = (available * owed) / queuedTotalOwedBNB;
            require(payout > 0, "ROUNDING");
        }

        userOwedBNB[msg.sender] = owed - payout;
        queuedTotalOwedBNB -= payout;
        (bool success,) = msg.sender.call{value: payout}("");
        require(success, "BNB_SEND_FAIL");

        emit Claim(msg.sender, payout);
    }

    function nav() public view returns (uint256) {
        if (totalSupply == 0) {
            return 1e18;
        }
        return (reserveBNB() * 1e18) / totalSupply;
    }

    function sweepOrphanedReserve() public {
        _sweepOrphanedReserve(address(this).balance);
    }

    function _sweepOrphanedReserve(uint256 amount) internal {
        if (totalSupply != 0) {
            revert SupplyNotZero();
        }
        if (queuedTotalOwedBNB != 0) {
            revert QueueExists();
        }
        if (amount == 0) {
            return;
        }
        (bool success,) = address(0).call{value: amount}("");
        require(success, "SWEEP_FAIL");
    }

    function totalAssetsBNB() public view returns (uint256) {
        return address(this).balance;
    }

    function reserveBNB() public view returns (uint256) {
        return address(this).balance - queuedTotalOwedBNB;
    }

    function emergencyRedeem(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "ZERO_REDEEM");
        uint256 owed = userOwedBNB[msg.sender];
        if (owed > 0) {
            queuedTotalOwedBNB -= owed;
            userOwedBNB[msg.sender] = 0;
        }
        uint256 currentNav = nav();
        uint256 bnbOwed = (tokenAmount * currentNav) / 1e18;
        uint256 fee = (bnbOwed * EMERGENCY_FEE_BPS) / BPS;
        uint256 bnbOut = bnbOwed - fee;
        require(bnbOut > 0, "ROUNDING");
        if (reserveBNB() < bnbOut) {
            revert InsufficientLiquidity();
        }

        _burn(msg.sender, tokenAmount);

        (bool success,) = msg.sender.call{value: bnbOut}("");
        require(success, "BNB_SEND_FAIL");

        emit EmergencyRedeem(msg.sender, tokenAmount, bnbOut, fee);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TRANSFER_ZERO");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "BALANCE");
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "MINT_ZERO");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "BURN_BALANCE");
        balanceOf[from] = bal - amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}
