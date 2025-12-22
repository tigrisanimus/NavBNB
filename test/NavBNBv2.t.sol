// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/StdStorage.sol";
import "src/NavBNBv2.sol";

contract ForceSend {
    constructor() payable {}

    function force(address to) external {
        selfdestruct(payable(to));
    }
}

contract ToggleReceiver {
    NavBNBv2 internal nav;
    bool public shouldRevert;

    constructor(NavBNBv2 nav_) {
        nav = nav_;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function deposit(uint256 minSharesOut) external payable {
        nav.deposit{value: msg.value}(minSharesOut);
    }

    function redeem(uint256 tokenAmount, uint256 minBnbOut) external {
        nav.redeem(tokenAmount, minBnbOut);
    }

    function withdrawClaimable(uint256 minOut) external {
        nav.withdrawClaimable(minOut);
    }

    receive() external payable {
        if (shouldRevert) {
            revert("NO_RECEIVE");
        }
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
    using stdStorage for StdStorage;
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

    function testNavNonZeroAtParity() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 capToday = nav.capRemainingToday();
        uint256 desiredBnb = capToday + 1 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        assertGt(liabilities, 0);

        stdstore.target(address(nav)).sig("trackedAssetsBNB()").checked_write(liabilities);
        uint256 day = block.timestamp / 1 days;
        uint256 capForDay = nav.capForDay(day);
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(capForDay);

        uint256 navAfter = nav.nav();
        assertGt(navAfter, 0);

        vm.prank(bob);
        vm.expectRevert(NavBNBv2.Insolvent.selector);
        nav.redeem(1, 0);

        vm.prank(bob);
        nav.deposit{value: 1 ether}(0);

        uint256 bobTokenAmount = nav.balanceOf(bob) / 2;
        uint256 navAfterDeposit = nav.nav();
        uint256 expectedBnbOwed = (bobTokenAmount * navAfterDeposit) / 1e18;
        uint256 fee = (expectedBnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 expectedAfterFee = expectedBnbOwed - fee;

        vm.prank(bob);
        nav.redeem(bobTokenAmount, 0);

        uint256 lastIndex = nav.queueLength() - 1;
        (, uint256 queuedAmount) = nav.getQueueEntry(lastIndex);
        assertEq(queuedAmount, expectedAfterFee);
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

        uint256 maxDays = 90;
        for (uint256 day = 0; day < maxDays; day++) {
            if (nav.totalLiabilitiesBNB() == 0) {
                break;
            }
            vm.warp(block.timestamp + 1 days);
            uint256 totalLiabilitiesBefore = nav.totalLiabilitiesBNB();
            uint256 head = nav.queueHead();
            uint256 queueLen = nav.queueLength();
            uint256 capRemaining = nav.capRemainingToday();
            uint256 available = capRemaining;
            if (available > totalLiabilitiesBefore) {
                available = totalLiabilitiesBefore;
            }
            uint256 contractBalanceBefore = address(nav).balance;
            uint256[] memory remainingBefore = new uint256[](queueLen);
            for (uint256 i = 0; i < queueLen; i++) {
                (, uint256 amount) = nav.getQueueEntry(i);
                remainingBefore[i] = amount;
            }
            vm.prank(alice);
            nav.claim();
            uint256 contractBalanceAfter = address(nav).balance;
            uint256 paidTotal = contractBalanceBefore - contractBalanceAfter;
            assertLe(paidTotal, available);
            assertLe(paidTotal, totalLiabilitiesBefore);

            uint256 lastPaidIndex = head;
            bool sawDecrease;
            bool sawNoDecreaseAfter;
            for (uint256 i = head; i < queueLen; i++) {
                (, uint256 amountAfter) = nav.getQueueEntry(i);
                if (amountAfter < remainingBefore[i]) {
                    if (sawNoDecreaseAfter) {
                        assertEq(amountAfter, remainingBefore[i]);
                    }
                    sawDecrease = true;
                    lastPaidIndex = i;
                } else if (sawDecrease) {
                    sawNoDecreaseAfter = true;
                }
            }
            if (sawNoDecreaseAfter && lastPaidIndex + 1 < queueLen) {
                for (uint256 i = lastPaidIndex + 1; i < queueLen; i++) {
                    (, uint256 amountAfter) = nav.getQueueEntry(i);
                    assertEq(amountAfter, remainingBefore[i]);
                }
            }
        }

        uint256 remainingLiabilities = nav.totalLiabilitiesBNB();
        if (remainingLiabilities > 0) {
            fail(string(abi.encodePacked("remaining liabilities: ", vm.toString(remainingLiabilities))));
        }
    }

    function testCapIgnoresLiabilities() public {
        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 day = block.timestamp / 1 days;
        uint256 capBefore = nav.capForDay(day);
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(type(uint256).max);

        uint256 desiredBnb = 5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        assertGt(nav.totalLiabilitiesBNB(), 0);
        uint256 capAfter = nav.capForDay(day);
        assertEq(capAfter, capBefore);
    }

    function testCapBehaviorAndNextDayClaim() public {
        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 capToday = nav.capForDay(block.timestamp / 1 days);
        uint256 desiredBnb = capToday + 1 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        assertGt(liabilities, 0);
        assertEq(nav.capRemainingToday(), 0);

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

        uint256 capToday = nav.capForDay(block.timestamp / 1 days);
        uint256 desiredBnb = capToday + 1 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        uint256 spent = nav.spentToday(block.timestamp / 1 days);
        assertGt(liabilities, 0);
        assertEq(nav.capRemainingToday(), 0);
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

        vm.prank(alice);
        nav.deposit{value: 5 ether}(0);

        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        uint256 head = nav.queueHead();
        (, uint256 headRemainingBefore) = nav.getQueueEntry(head);
        assertGt(liabilitiesBefore, 0);

        uint256 emergencyShares = nav.balanceOf(alice) / 4;
        assertGe(nav.balanceOf(alice), emergencyShares);
        assertGt(emergencyShares, 0);
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.QueueActive.selector);
        nav.emergencyRedeem(emergencyShares, 0);

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
        vm.expectRevert(NavBNBv2.QueueActive.selector);
        nav.emergencyRedeem(1, 0);

        assertEq(nav.totalLiabilitiesBNB(), liabilitiesBefore);
        (, uint256 headRemainingAfter) = nav.getQueueEntry(head);
        assertEq(headRemainingAfter, headRemainingBefore);
    }

    function testRedeemUsesCapToPayQueueHead() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 capToday = nav.capRemainingToday();
        uint256 desiredBnb = capToday + 1 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        assertGt(nav.totalLiabilitiesBNB(), 0);
        vm.warp(block.timestamp + 1 days);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        uint256 bobRedeem = nav.balanceOf(alice) / 10;
        vm.prank(alice);
        nav.transfer(bob, bobRedeem);
        vm.prank(bob);
        nav.redeem(bobRedeem, 0);

        assertGt(alice.balance - aliceBalanceBefore, 0);
        assertEq(bob.balance - bobBalanceBefore, 0);

        uint256 lastIndex = nav.queueLength() - 1;
        (, uint256 queuedAmount) = nav.getQueueEntry(lastIndex);
        assertGt(queuedAmount, 0);
    }

    function testClaimBoundedSteps() public {
        vm.prank(alice);
        nav.deposit{value: 400 ether}(0);

        uint256 day = block.timestamp / 1 days;
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(type(uint256).max);

        for (uint256 i = 0; i < 40; i++) {
            uint256 desiredAfterFee = 1 ether;
            uint256 bnbOwed = (desiredAfterFee * nav.BPS()) / (nav.BPS() - nav.REDEEM_FEE_BPS());
            uint256 tokenAmount = (bnbOwed * 1e18) / nav.nav();
            address user = address(uint160(0x1000 + i));
            vm.prank(alice);
            nav.transfer(user, tokenAmount);
            vm.prank(user);
            nav.redeem(tokenAmount, 0);
        }

        assertGt(nav.totalLiabilitiesBNB(), 0);
        vm.warp(block.timestamp + 1 days);

        uint256 headBefore = nav.queueHead();
        vm.prank(alice);
        nav.claim();
        uint256 headAfter = nav.queueHead();

        assertEq(headAfter - headBefore, nav.DEFAULT_MAX_STEPS());
        assertGt(nav.totalLiabilitiesBNB(), 0);
    }

    function testClaimBoundedStepsProgresses() public {
        vm.prank(alice);
        nav.deposit{value: 400 ether}(0);

        uint256 day = block.timestamp / 1 days;
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(type(uint256).max);

        for (uint256 i = 0; i < 40; i++) {
            uint256 desiredAfterFee = 1 ether;
            uint256 bnbOwed = (desiredAfterFee * nav.BPS()) / (nav.BPS() - nav.REDEEM_FEE_BPS());
            uint256 tokenAmount = (bnbOwed * 1e18) / nav.nav();
            address user = address(uint160(0x1000 + i));
            vm.prank(alice);
            nav.transfer(user, tokenAmount);
            vm.prank(user);
            nav.redeem(tokenAmount, 0);
        }

        vm.warp(block.timestamp + 1 days);
        uint256 headBefore = nav.queueHead();
        vm.prank(alice);
        nav.claim();
        uint256 headAfter = nav.queueHead();

        vm.prank(alice);
        nav.claim();
        uint256 headAfterSecond = nav.queueHead();

        assertEq(headAfter - headBefore, nav.DEFAULT_MAX_STEPS());
        assertGt(headAfterSecond, headAfter);
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

    function testEmergencyRedeemPausedReverts() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        vm.prank(guardian);
        nav.pause();

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.PausedError.selector);
        nav.emergencyRedeem(1, 0);
    }

    function testCapAccountingFromClaim() public {
        vm.prank(alice);
        nav.deposit{value: 20 ether}(0);

        uint256 day = block.timestamp / 1 days;
        uint256 desiredBnb = nav.capRemainingToday() + 1 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        vm.warp(block.timestamp + 1 days);
        uint256 capBefore = nav.capRemainingToday();
        uint256 spentBefore = nav.spentToday(day + 1);

        vm.prank(alice);
        nav.claim();

        uint256 spentAfter = nav.spentToday(day + 1);
        uint256 capAfter = nav.capRemainingToday();
        uint256 paid = spentAfter - spentBefore;

        assertLe(paid, capBefore);
        assertEq(capBefore - capAfter, paid);
    }

    function testQueueHeadRevertEscrowsAndMovesOn() public {
        vm.prank(alice);
        nav.deposit{value: 50 ether}(0);

        ToggleReceiver bad = new ToggleReceiver(nav);
        bad.setRevert(true);
        vm.deal(address(bad), 10 ether);
        bad.deposit{value: 5 ether}(0);

        uint256 day = block.timestamp / 1 days;
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(type(uint256).max);

        uint256 badTokens;
        badTokens = nav.balanceOf(address(bad));
        bad.redeem(badTokens, 0);

        vm.prank(alice);
        nav.redeem(nav.balanceOf(alice) / 10, 0);

        vm.warp(block.timestamp + 1 days);
        uint256 claimableBefore = nav.claimableBNB(address(bad));
        vm.prank(alice);
        nav.claim();

        uint256 claimableAfter = nav.claimableBNB(address(bad));
        assertGt(claimableAfter, claimableBefore);

        uint256 head = nav.queueHead();
        assertGt(head, 0);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        nav.claim();
        assertGt(alice.balance - aliceBalanceBefore, 0);
    }

    function testWithdrawClaimablePaysOut() public {
        vm.prank(alice);
        nav.deposit{value: 20 ether}(0);

        ToggleReceiver receiver = new ToggleReceiver(nav);
        receiver.setRevert(true);
        vm.deal(address(receiver), 5 ether);
        receiver.deposit{value: 1 ether}(0);

        uint256 day = block.timestamp / 1 days;
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(type(uint256).max);

        receiver.redeem(nav.balanceOf(address(receiver)), 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        nav.claim();

        uint256 claimable = nav.claimableBNB(address(receiver));
        assertGt(claimable, 0);

        receiver.setRevert(false);
        uint256 balanceBefore = address(receiver).balance;
        receiver.withdrawClaimable(0);
        uint256 balanceAfter = address(receiver).balance;

        assertEq(balanceAfter - balanceBefore, claimable);
        assertEq(nav.claimableBNB(address(receiver)), 0);
    }

    function testCoalesceQueueEntries() public {
        vm.prank(alice);
        nav.deposit{value: 20 ether}(0);

        uint256 day = block.timestamp / 1 days;
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(type(uint256).max);

        uint256 desiredAfterFee = 1 ether;
        uint256 bnbOwed = (desiredAfterFee * nav.BPS()) / (nav.BPS() - nav.REDEEM_FEE_BPS());
        uint256 tokenAmount = (bnbOwed * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 len = nav.queueLength();
        uint256 head = nav.queueHead();
        assertEq(len - head, 1);
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
    bool public overCap;
    bool public headDecreased;
    bool public redeemBrokeSolvency;
    uint256 public lastQueueHead;

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
        _trackQueueHead();
    }

    function redeem(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];
        uint256 balance = nav.balanceOf(user);
        if (balance == 0) {
            return;
        }
        if (nav.trackedAssetsBNB() <= nav.totalLiabilitiesBNB()) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(user);
        nav.redeem(amount, 0);
        _trackParticipant(user);
        if (nav.trackedAssetsBNB() < nav.totalLiabilitiesBNB()) {
            redeemBrokeSolvency = true;
        }
        _trackQueueHead();
    }

    function claim(uint256 userSeed) external {
        address user = users[userSeed % users.length];
        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        if (liabilitiesBefore == 0) {
            return;
        }
        if (nav.trackedAssetsBNB() < liabilitiesBefore) {
            return;
        }
        uint256 capRemaining = nav.capRemainingToday();
        uint256 beforeBalance = user.balance;
        vm.prank(user);
        nav.claim(1);
        uint256 afterBalance = user.balance;
        if (afterBalance - beforeBalance > liabilitiesBefore) {
            overClaim = true;
        }
        uint256 liabilitiesAfter = nav.totalLiabilitiesBNB();
        uint256 paid = liabilitiesBefore - liabilitiesAfter;
        if (paid > capRemaining) {
            overCap = true;
        }
        _trackParticipant(user);
        _trackQueueHead();
    }

    function _trackParticipant(address user) internal {
        if (!isParticipant[user]) {
            isParticipant[user] = true;
            participants.push(user);
        }
    }

    function _trackQueueHead() internal {
        uint256 head = nav.queueHead();
        if (head < lastQueueHead) {
            headDecreased = true;
        }
        lastQueueHead = head;
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
        uint256 claimableSum;
        uint256 participants = handler.participantCount();
        for (uint256 i = 0; i < participants; i++) {
            address participant = handler.participants(i);
            claimableSum += nav.claimableBNB(participant);
        }
        assertEq(nav.totalLiabilitiesBNB(), sum + claimableSum);
    }

    function invariantNoUserOverClaims() public view {
        assertFalse(handler.overClaim());
    }

    function invariantClaimWithinCap() public view {
        assertFalse(handler.overCap());
    }

    function invariantQueueHeadMonotonic() public view {
        assertFalse(handler.headDecreased());
        assertLe(nav.queueHead(), nav.queueLength());
    }

    function invariantRedeemSolvent() public view {
        assertFalse(handler.redeemBrokeSolvency());
    }

    function invariantTrackedAssetsBelowBalance() public view {
        assertLe(nav.trackedAssetsBNB(), address(nav).balance);
    }
}
