// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "src/NavBNBv2.sol";

contract ForceSend {
    constructor() payable {}

    function force(address to) external {
        selfdestruct(payable(to));
    }
}

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

contract NavBNBv2Test is NoLogBound {
    NavBNBv2 internal nav;
    address internal guardian = address(0xBEEF);
    address internal recovery = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        nav = new NavBNBv2(guardian, recovery);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(guardian, 1_000 ether);
        vm.deal(recovery, 1_000 ether);
    }

    function testDepositSlippage() public {
        uint256 amount = 1 ether;
        uint256 fee = (amount * nav.MINT_FEE_BPS()) / nav.BPS();
        uint256 valueAfterFee = amount - fee;
        uint256 minSharesOut = valueAfterFee + 1;

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.Slippage.selector);
        nav.deposit{value: amount}(minSharesOut);
    }

    function testRedeemSlippage() public {
        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 bnbAfterFee = bnbOwed - fee;

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.Slippage.selector);
        nav.redeem(tokenAmount, bnbAfterFee + 1);
    }

    function testForcedBnbDoesNotChangeNav() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        uint256 navBefore = nav.nav();
        uint256 trackedBefore = nav.trackedAssetsBNB();

        ForceSend sender = new ForceSend{value: 1 ether}();
        sender.force(address(nav));

        assertEq(nav.trackedAssetsBNB(), trackedBefore);
        assertEq(nav.nav(), navBefore);
        assertGt(nav.untrackedSurplusBNB(), 0);

        uint256 amount = 1 ether;
        uint256 fee = (amount * nav.MINT_FEE_BPS()) / nav.BPS();
        uint256 valueAfterFee = amount - fee;
        uint256 expectedMint = (valueAfterFee * 1e18) / navBefore;

        vm.prank(bob);
        nav.deposit{value: amount}(expectedMint);
        assertEq(nav.balanceOf(bob), expectedMint);

        uint256 surplus = nav.untrackedSurplusBNB();
        uint256 recoveryBalanceBefore = recovery.balance;
        uint256 navBalanceBefore = address(nav).balance;
        vm.prank(recovery);
        nav.recoverSurplus(recovery);

        assertEq(nav.trackedAssetsBNB(), trackedBefore + amount);
        assertEq(address(nav).balance, navBalanceBefore - surplus);
        assertEq(recovery.balance - recoveryBalanceBefore, surplus);
    }

    function testClaimFairnessFifo() public {
        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 attackers = 100;
        address[] memory attackAddresses = new address[](attackers);
        uint256 transferAmount = nav.balanceOf(alice) / (attackers * 10);
        for (uint256 i = 0; i < attackers; i++) {
            address attacker = address(uint160(0x1000 + i));
            attackAddresses[i] = attacker;
            vm.prank(alice);
            nav.transfer(attacker, transferAmount);
        }

        uint256 desiredBnb = 2 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        for (uint256 i = 0; i < attackers; i++) {
            address attacker = attackAddresses[i];
            uint256 balance = nav.balanceOf(attacker);
            vm.prank(attacker);
            nav.redeem(balance, 0);
        }

        for (uint256 day = 0; day < 7; day++) {
            uint256 totalLiabilitiesBefore = nav.totalLiabilitiesBNB();
            if (totalLiabilitiesBefore == 0) {
                break;
            }
            uint256 head = nav.queueHead();
            (address currentHeadUser, uint256 currentHeadRemaining) = nav.getQueueEntry(head);
            vm.warp(block.timestamp + 1 days);
            uint256 currentDay = block.timestamp / 1 days;
            uint256 cap = nav.capForDay(currentDay);
            uint256 spent = nav.spentToday(currentDay);
            uint256 capRemaining = cap > spent ? cap - spent : 0;
            uint256 reserve = nav.reserveBNB();
            uint256 available = capRemaining < reserve ? capRemaining : reserve;
            uint256 headBalanceBefore = currentHeadUser.balance;
            uint256 othersBalanceBefore = alice.balance;
            for (uint256 i = 0; i < attackers; i++) {
                othersBalanceBefore += attackAddresses[i].balance;
            }
            if (currentHeadUser == alice) {
                othersBalanceBefore -= alice.balance;
            } else {
                othersBalanceBefore -= currentHeadUser.balance;
            }
            vm.prank(alice);
            nav.claim();
            uint256 headBalanceAfter = currentHeadUser.balance;
            uint256 othersBalanceAfter = alice.balance;
            for (uint256 i = 0; i < attackers; i++) {
                othersBalanceAfter += attackAddresses[i].balance;
            }
            if (currentHeadUser == alice) {
                othersBalanceAfter -= alice.balance;
            } else {
                othersBalanceAfter -= currentHeadUser.balance;
            }
            uint256 paidHead = headBalanceAfter - headBalanceBefore;
            uint256 paidOthers = othersBalanceAfter - othersBalanceBefore;
            uint256 expectedHeadPaid = available < currentHeadRemaining ? available : currentHeadRemaining;
            assertEq(paidHead, expectedHeadPaid);
            uint256 expectedOthersPaid;
            if (currentHeadRemaining < available) {
                uint256 remaining = available - currentHeadRemaining;
                uint256 tailLiabilities = totalLiabilitiesBefore - currentHeadRemaining;
                expectedOthersPaid = remaining < tailLiabilities ? remaining : tailLiabilities;
            }
            assertEq(paidOthers, expectedOthersPaid);
        }

        assertEq(nav.totalLiabilitiesBNB(), 0);
    }

    function testCapBehaviorAndNextDayClaim() public {
        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 desiredBnb = 2 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        assertGt(liabilities, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.claim();
        uint256 balanceAfter = alice.balance;
        assertEq(balanceAfter - balanceBefore, 0);

        vm.warp(block.timestamp + 1 days);
        balanceBefore = alice.balance;
        vm.prank(alice);
        nav.claim();
        balanceAfter = alice.balance;

        assertGt(balanceAfter - balanceBefore, 0);
    }

    function testClaimCapExhaustedNoStateChange() public {
        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 desiredBnb = 2 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        uint256 spent = nav.spentToday(block.timestamp / 1 days);
        assertGt(liabilities, 0);
        uint256 head = nav.queueHead();
        (, uint256 headRemaining) = nav.getQueueEntry(head);

        vm.prank(alice);
        nav.claim();

        assertEq(nav.totalLiabilitiesBNB(), liabilities);
        assertEq(nav.spentToday(block.timestamp / 1 days), spent);
        (, uint256 headRemainingAfter) = nav.getQueueEntry(head);
        assertEq(headRemainingAfter, headRemaining);
    }

    function testEmergencyRedeemWithoutQueue() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.EMERGENCY_FEE_BPS()) / nav.BPS();
        uint256 expected = bnbOwed - fee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);
    }

    function testEmergencyRedeemDoesNotTouchQueue() public {
        vm.prank(alice);
        nav.deposit{value: 20 ether}(0);

        uint256 desiredBnb = 5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        uint256 head = nav.queueHead();
        (, uint256 headRemainingBefore) = nav.getQueueEntry(head);
        assertGt(liabilitiesBefore, 0);

        vm.prank(alice);
        nav.emergencyRedeem(nav.balanceOf(alice) / 4, 0);

        assertEq(nav.totalLiabilitiesBNB(), liabilitiesBefore);
        (, uint256 headRemainingAfter) = nav.getQueueEntry(head);
        assertEq(headRemainingAfter, headRemainingBefore);
    }

    function testEmergencyRedeemRejectsDustQueueClear() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 desiredBnb = 5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        uint256 head = nav.queueHead();
        (, uint256 headRemainingBefore) = nav.getQueueEntry(head);

        vm.prank(alice);
        nav.emergencyRedeem(1, 0);

        assertEq(nav.totalLiabilitiesBNB(), liabilitiesBefore);
        (, uint256 headRemainingAfter) = nav.getQueueEntry(head);
        assertEq(headRemainingAfter, headRemainingBefore);
    }

    function testPauseBlocksDepositAndRedeem() public {
        vm.prank(guardian);
        nav.pause();

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.PausedError.selector);
        nav.deposit{value: 1 ether}(0);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.PausedError.selector);
        nav.redeem(1, 0);
    }

    function testRecoverSurplusOnlyRecovery() public {
        ForceSend sender = new ForceSend{value: 1 ether}();
        sender.force(address(nav));
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NotRecovery.selector);
        nav.recoverSurplus(alice);
    }
}

contract NavBNBv2HandlerTest is NoLogBound {
    NavBNBv2 internal nav;
    address[] public users;
    address[] public participants;
    mapping(address => bool) internal isParticipant;

    bool public overClaim;

    constructor(NavBNBv2 nav_, address[] memory users_) {
        nav = nav_;
        users = users_;
    }

    function deposit(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];
        uint256 amount = bound(amountSeed, 1e12, 50 ether);
        vm.deal(user, user.balance + amount);
        vm.prank(user);
        nav.deposit{value: amount}(0);
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
        nav.redeem(amount, 0);
        _trackParticipant(user);
    }

    function claim(uint256 userSeed) external {
        address user = users[userSeed % users.length];
        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        if (liabilitiesBefore == 0) {
            return;
        }
        uint256 beforeBalance = user.balance;
        vm.prank(user);
        nav.claim(1);
        uint256 afterBalance = user.balance;
        if (afterBalance - beforeBalance > liabilitiesBefore) {
            overClaim = true;
        }
        _trackParticipant(user);
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
}

contract NavBNBv2InvariantTest is StdInvariant, Test {
    NavBNBv2 internal nav;
    NavBNBv2HandlerTest internal handler;

    function setUp() public {
        nav = new NavBNBv2(address(0xBEEF), address(0xCAFE));
        address[] memory users = new address[](4);
        users[0] = address(0xA11CE);
        users[1] = address(0xB0B);
        users[2] = address(0xCAFE);
        users[3] = address(0xD00D);
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
        }
        handler = new NavBNBv2HandlerTest(nav, users);
        targetContract(address(handler));
    }

    function invariantQueuedTotalMatchesSum() public view {
        uint256 sum;
        uint256 head = nav.queueHead();
        uint256 len = nav.queueLength();
        for (uint256 i = head; i < len; i++) {
            (, uint256 amount) = nav.getQueueEntry(i);
            sum += amount;
        }
        assertEq(nav.totalLiabilitiesBNB(), sum);
    }

    function invariantNoUserOverClaims() public view {
        assertFalse(handler.overClaim());
    }

    function invariantTrackedAssetsBelowBalance() public view {
        assertLe(nav.trackedAssetsBNB(), address(nav).balance);
    }
}
