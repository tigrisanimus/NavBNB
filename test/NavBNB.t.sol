// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "src/NavBNB.sol";

abstract contract NoLogBound is Test {
    function bound(uint256 x, uint256 min, uint256 max) internal pure override returns (uint256 result) {
        return _bound(x, min, max);
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure virtual override returns (uint256 result) {
        require(min <= max, "StdUtils bound(uint256,uint256,uint256): Max is less than min.");
        if (x >= min && x <= max) return x;

        uint256 size = max - min + 1;

        if (x <= 3 && size > x) return min + x;
        if (x >= UINT256_MAX - 3 && size > UINT256_MAX - x) return max - (UINT256_MAX - x);

        if (x > max) {
            uint256 diff = x - max;
            uint256 rem = diff % size;
            if (rem == 0) return max;
            result = min + rem - 1;
        } else if (x < min) {
            uint256 diff = min - x;
            uint256 rem = diff % size;
            if (rem == 0) return min;
            result = max - rem + 1;
        }
    }
}

contract NavBNBTest is NoLogBound {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MINT_FEE_BPS = 25;
    uint256 internal constant REDEEM_FEE_BPS = 25;
    uint256 internal constant CAP_BPS = 100;
    uint256 internal constant EMERGENCY_FEE_BPS = 1_000;

    NavBNB internal nav;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA11);

    function setUp() public {
        nav = new NavBNB();
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    function testDepositMintsWithFee() public {
        uint256 amount = 10 ether;
        uint256 expectedMint = (amount * (BPS - MINT_FEE_BPS)) / BPS;

        vm.prank(alice);
        nav.deposit{value: amount}();

        assertEq(nav.totalSupply(), expectedMint);
        assertEq(nav.balanceOf(alice), expectedMint);
        assertGt(nav.nav(), 1e18);
    }

    function testDepositAfterOrphanedReserveSweeps() public {
        _createOrphanedReserve();
        uint256 depositAmount = 0.001 ether;

        vm.prank(bob);
        nav.deposit{value: depositAmount}();

        assertEq(address(nav).balance, depositAmount);
        uint256 expectedMint = (depositAmount * (BPS - MINT_FEE_BPS)) / BPS;
        uint256 expectedNav = (depositAmount * 1e18) / expectedMint;
        assertApproxEqAbs(nav.nav(), expectedNav, 5);
    }

    function testSweepOrphanedReserveZerosBalance() public {
        _createOrphanedReserve();
        assertEq(nav.totalSupply(), 0);
        assertEq(nav.queuedTotalOwedBNB(), 0);
        assertGt(address(nav).balance, 0);

        nav.sweepOrphanedReserve();

        assertEq(address(nav).balance, 0);
    }

    function testMetadata() public view {
        assertEq(nav.name(), "NavBNB");
        assertEq(nav.symbol(), "nBNB");
        assertEq(nav.decimals(), 18);
    }

    function testRedeemWithinCapPaysImmediately() public {
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 desiredBnb = 0.5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        uint256 expectedPayout = (desiredBnb * (BPS - REDEEM_FEE_BPS)) / BPS;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(tokenAmount);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expectedPayout, 2);
        assertEq(nav.userOwedBNB(alice), 0);
        assertGt(nav.spentToday(block.timestamp / 1 days), 0);
    }

    function testRedeemOverCapQueuesRemainder() public {
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 desiredBnb = 2 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        uint256 expectedAfterFee = (desiredBnb * (BPS - REDEEM_FEE_BPS)) / BPS;
        uint256 expectedCap = (nav.reserveBNB() * CAP_BPS) / BPS;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(tokenAmount);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expectedCap, 2);
        assertApproxEqAbs(nav.userOwedBNB(alice), expectedAfterFee - expectedCap, 2);
        assertApproxEqAbs(nav.queuedTotalOwedBNB(), expectedAfterFee - expectedCap, 2);
    }

    function testRedeemQueuesWhenQueueExistsDoesNotConsumeCap() public {
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        vm.startPrank(alice);
        nav.transfer(bob, nav.balanceOf(alice) / 4);
        vm.stopPrank();

        uint256 desiredBnb = 2 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount);

        vm.warp(block.timestamp + 1 days);
        uint256 day = block.timestamp / 1 days;
        uint256 spentBefore = nav.spentToday(day);

        uint256 bobTokens = nav.balanceOf(bob);
        uint256 bobBnbOwed = (bobTokens * nav.nav()) / 1e18;
        uint256 expectedAfterFee = (bobBnbOwed * (BPS - REDEEM_FEE_BPS)) / BPS;

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        nav.redeem(bobTokens);
        uint256 bobBalanceAfter = bob.balance;

        assertGt(bobBalanceAfter, bobBalanceBefore);
        assertLe(bobBalanceAfter - bobBalanceBefore, expectedAfterFee);
        assertApproxEqAbs(
            nav.userOwedBNB(bob),
            expectedAfterFee - (bobBalanceAfter - bobBalanceBefore),
            2
        );
        assertApproxEqAbs(nav.queuedTotalOwedBNB(), nav.userOwedBNB(alice) + nav.userOwedBNB(bob), 2);
        assertGt(nav.spentToday(day), spentBefore);
    }

    function testCapUsesTotalAssetsNotReserve() public {
        uint256 depositAmount = 0.01 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 desiredBnb = 0.009 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount);

        assertGt(nav.queuedTotalOwedBNB(), 0);

        vm.warp(block.timestamp + 1 days);
        uint256 day = block.timestamp / 1 days;

        uint256 totalAssetsCap = (address(nav).balance * CAP_BPS) / BPS;
        uint256 reserveCap = (nav.reserveBNB() * CAP_BPS) / BPS;
        uint256 cap = nav.capForDay(day);

        assertApproxEqAbs(cap, totalAssetsCap, 2);
        assertGt(cap, reserveCap);
    }

    function testEmergencyRedeemWorksWhenNoQueue() public {
        uint256 depositAmount = 10 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * EMERGENCY_FEE_BPS) / BPS;
        uint256 expectedPayout = bnbOwed - fee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expectedPayout, 2);
        assertEq(nav.balanceOf(alice), nav.totalSupply());
    }

    function testEmergencyRedeemClearsQueuedRedemption() public {
        uint256 depositAmount = 10 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 desiredBnb = 5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount);

        uint256 owedBefore = nav.userOwedBNB(alice);
        uint256 queuedBefore = nav.queuedTotalOwedBNB();
        assertGt(owedBefore, 0);

        uint256 emergencyTokens = nav.balanceOf(alice) / 4;
        vm.prank(alice);
        nav.emergencyRedeem(emergencyTokens);

        assertEq(nav.userOwedBNB(alice), 0);
        assertEq(nav.queuedTotalOwedBNB(), queuedBefore - owedBefore);
        assertEq(nav.queuedTotalOwedBNB(), nav.userOwedBNB(alice));
        assertEq(nav.reserveBNB(), address(nav).balance - nav.queuedTotalOwedBNB());
    }

    function testEmergencyRedeemRevertsOnRounding() public {
        vm.prank(alice);
        nav.deposit{value: 1 ether}();

        vm.store(address(nav), bytes32(uint256(4)), bytes32(uint256(0.9 ether)));

        vm.prank(alice);
        vm.expectRevert(bytes("ROUNDING"));
        nav.emergencyRedeem(1);
    }

    function testDepositRevertsWhenFullyQueued() public {
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        vm.store(address(nav), bytes32(uint256(4)), bytes32(address(nav).balance));
        assertEq(nav.reserveBNB(), 0);

        vm.prank(bob);
        vm.expectRevert(NavBNB.DepositsPausedNoReserve.selector);
        nav.deposit{value: 1 ether}();
    }

    function testClaimPaysProRata() public {
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 aliceTokens = nav.balanceOf(alice);
        vm.prank(alice);
        nav.transfer(bob, aliceTokens / 4);
        vm.prank(alice);
        nav.transfer(carol, aliceTokens / 4);

        uint256 desiredCapFill = 1 ether;
        uint256 fillTokens = (desiredCapFill * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(fillTokens);

        uint256 bobTokens = nav.balanceOf(bob);
        vm.prank(bob);
        nav.redeem(bobTokens);
        uint256 carolTokens = nav.balanceOf(carol);
        vm.prank(carol);
        nav.redeem(carolTokens);

        uint256 totalOwed = nav.queuedTotalOwedBNB();
        uint256 bobOwed = nav.userOwedBNB(bob);

        vm.warp(block.timestamp + 1 days);

        uint256 available = nav.capForDay(block.timestamp / 1 days);
        uint256 expectedPayout = (available * bobOwed) / totalOwed;

        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        nav.claim();
        uint256 balanceAfter = bob.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expectedPayout, 2);
        assertLe(nav.userOwedBNB(bob), bobOwed);
    }

    function testFuzzRedeemAccounting(uint128 depositAmount, uint128 redeemTokens) public {
        uint256 amount = bound(uint256(depositAmount), 1e12, 1_000 ether);
        vm.prank(alice);
        nav.deposit{value: amount}();

        uint256 balance = nav.balanceOf(alice);
        uint256 tokens = bound(uint256(redeemTokens), 1, balance);
        uint256 beforeBalance = alice.balance;
        uint256 navBefore = nav.nav();
        uint256 owedBefore = nav.userOwedBNB(alice);

        vm.prank(alice);
        nav.redeem(tokens);

        uint256 afterBalance = alice.balance;
        uint256 owedAfter = nav.userOwedBNB(alice);
        uint256 bnbOwed = (tokens * navBefore) / 1e18;
        uint256 expectedAfterFee = (bnbOwed * (BPS - REDEEM_FEE_BPS)) / BPS;
        uint256 received = afterBalance - beforeBalance;

        assertApproxEqAbs(received + (owedAfter - owedBefore), expectedAfterFee, 5);
    }

    function testFuzzClaimNeverOverpays(uint128 depositAmount) public {
        uint256 amount = bound(uint256(depositAmount), 1 ether, 500 ether);
        vm.prank(alice);
        nav.deposit{value: amount}();

        uint256 tokens = nav.balanceOf(alice) / 2;
        vm.prank(alice);
        nav.transfer(bob, tokens);

        vm.prank(bob);
        nav.redeem(tokens);

        vm.warp(block.timestamp + 1 days);

        uint256 owedBefore = nav.userOwedBNB(bob);
        if (owedBefore == 0) {
            return;
        }

        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        nav.claim();
        uint256 balanceAfter = bob.balance;

        assertLe(balanceAfter - balanceBefore, owedBefore);
    }

    function _createOrphanedReserve() internal {
        vm.prank(alice);
        nav.deposit{value: 1 ether}();

        uint256 desiredBnb = 0.5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount);

        uint256 remainingTokens = nav.balanceOf(alice);
        vm.prank(alice);
        nav.emergencyRedeem(remainingTokens);

        assertEq(nav.totalSupply(), 0);
        assertEq(nav.queuedTotalOwedBNB(), 0);
        assertGt(address(nav).balance, 0);
    }
}

contract NavBNBHandlerTest is NoLogBound {
    NavBNB internal nav;
    address[] public users;
    address[] public participants;
    uint256[] public dayList;
    mapping(address => bool) internal isParticipant;
    mapping(uint256 => bool) internal daySeen;

    bool public unexpectedOutflow;
    bool public overClaim;

    constructor(NavBNB nav_, address[] memory users_) {
        nav = nav_;
        users = users_;
    }

    function deposit(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];
        uint256 amount = bound(amountSeed, 1e12, 50 ether);
        vm.deal(user, user.balance + amount);
        uint256 beforeBalance = address(nav).balance;
        vm.prank(user);
        nav.deposit{value: amount}();
        uint256 afterBalance = address(nav).balance;
        if (afterBalance < beforeBalance) {
            unexpectedOutflow = true;
        }
        _trackParticipant(user);
    }

    function redeem(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];
        uint256 balance = nav.balanceOf(user);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 navBefore = nav.nav();
        uint256 bnbOwed = (amount * navBefore) / 1e18;
        uint256 fee = (bnbOwed * REDEEM_FEE_BPS) / BPS;
        uint256 bnbAfterFee = bnbOwed - fee;
        if (bnbAfterFee == 0) {
            return;
        }
        uint256 day = block.timestamp / 1 days;
        uint256 cap = nav.capForDay(day);
        uint256 spent = nav.spentToday(day);
        uint256 capRemaining = cap > spent ? cap - spent : 0;
        uint256 available = capRemaining;
        uint256 balanceBNB = address(nav).balance;
        if (available > balanceBNB) {
            available = balanceBNB;
        }
        if (available == 0) {
            return;
        }
        vm.prank(user);
        nav.redeem(amount);
        _trackParticipant(user);
        _trackDay();
    }

    function claim(uint256 userSeed) external {
        address user = users[userSeed % users.length];
        uint256 owed = nav.userOwedBNB(user);
        if (owed == 0) {
            return;
        }
        uint256 beforeBalance = user.balance;
        vm.prank(user);
        nav.claim();
        uint256 afterBalance = user.balance;
        if (afterBalance - beforeBalance > owed) {
            overClaim = true;
        }
        _trackParticipant(user);
        _trackDay();
    }

    function _trackParticipant(address user) internal {
        if (!isParticipant[user]) {
            isParticipant[user] = true;
            participants.push(user);
        }
    }

    function participantCount() external view returns (uint256) {
        return participants.length;
    }

    function dayCount() external view returns (uint256) {
        return dayList.length;
    }

    function _trackDay() internal {
        uint256 day = block.timestamp / 1 days;
        if (!daySeen[day]) {
            daySeen[day] = true;
            dayList.push(day);
        }
    }
}

contract NavBNBInvariantTest is StdInvariant, Test {
    NavBNB internal nav;
    NavBNBHandlerTest internal handler;

    function setUp() public {
        nav = new NavBNB();
        address[] memory users = new address[](4);
        users[0] = address(0xA11CE);
        users[1] = address(0xB0B);
        users[2] = address(0xCAFE);
        users[3] = address(0xD00D);
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
        }
        handler = new NavBNBHandlerTest(nav, users);
        targetContract(address(handler));
    }

    function invariantQueuedTotalMatchesSum() public view {
        uint256 sum;
        uint256 count = handler.participantCount();
        for (uint256 i = 0; i < count; i++) {
            address user = handler.participants(i);
            sum += nav.userOwedBNB(user);
        }
        assertEq(nav.queuedTotalOwedBNB(), sum);
    }

    function invariantNoUserOverClaims() public view {
        assertFalse(handler.overClaim());
    }

    function invariantSpentWithinCap() public view {
        uint256 day = block.timestamp / 1 days;
        uint256 cap = nav.capForDay(day);
        if (cap == 0) {
            return;
        }
        assertLe(nav.spentToday(day), cap);
    }

    function invariantNoUnexpectedOutflow() public view {
        assertFalse(handler.unexpectedOutflow());
    }
}
