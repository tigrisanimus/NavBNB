// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "src/NavBNB.sol";

contract NavBNBTest is Test {
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
        uint256 expectedMint = (amount * (NavBNB.BPS() - NavBNB.MINT_FEE_BPS())) / NavBNB.BPS();

        vm.prank(alice);
        nav.deposit{value: amount}();

        assertEq(nav.totalSupply(), expectedMint);
        assertEq(nav.balanceOf(alice), expectedMint);
        assertGt(nav.nav(), 1e18);
    }

    function testRedeemWithinCapPaysImmediately() public {
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        nav.deposit{value: depositAmount}();

        uint256 desiredBnb = 0.5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        uint256 expectedPayout = (desiredBnb * (NavBNB.BPS() - NavBNB.REDEEM_FEE_BPS())) / NavBNB.BPS();

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
        uint256 expectedAfterFee = (desiredBnb * (NavBNB.BPS() - NavBNB.REDEEM_FEE_BPS())) / NavBNB.BPS();
        uint256 expectedCap = (nav.reserveBNB() * NavBNB.CAP_BPS()) / NavBNB.BPS();

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(tokenAmount);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expectedCap, 2);
        assertApproxEqAbs(nav.userOwedBNB(alice), expectedAfterFee - expectedCap, 2);
        assertApproxEqAbs(nav.queuedTotalOwedBNB(), expectedAfterFee - expectedCap, 2);
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
        uint256 expectedAfterFee = (bnbOwed * (NavBNB.BPS() - NavBNB.REDEEM_FEE_BPS())) / NavBNB.BPS();
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
}

contract NavBNBHandlerTest is Test {
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

    function invariantQueuedTotalMatchesSum() public {
        uint256 sum;
        uint256 count = handler.participantCount();
        for (uint256 i = 0; i < count; i++) {
            address user = handler.participants(i);
            sum += nav.userOwedBNB(user);
        }
        assertEq(nav.queuedTotalOwedBNB(), sum);
    }

    function invariantNoUserOverClaims() public {
        assertFalse(handler.overClaim());
    }

    function invariantSpentWithinCap() public {
        uint256 count = handler.dayCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 day = handler.dayList(i);
            uint256 cap = nav.capForDay(day);
            if (cap == 0) {
                continue;
            }
            assertLe(nav.spentToday(day), cap);
        }
    }

    function invariantNoUnexpectedOutflow() public {
        assertFalse(handler.unexpectedOutflow());
    }
}
