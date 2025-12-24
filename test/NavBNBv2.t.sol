// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/StdStorage.sol";
import "src/NavBNBv2.sol";
import "test/mocks/MockBNBYieldStrategy.sol";

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

    function _setSpentToday(uint256 day, uint256 value) internal {
        stdstore.target(address(nav)).sig("spentToday(uint256)").with_key(day).checked_write(value);
    }

    function _activateStrategy(address newStrategy) internal {
        vm.prank(guardian);
        nav.proposeStrategy(newStrategy);
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        nav.activateStrategy();
    }

    function _setExitFeeConfig(uint256 minSeconds, uint256 fullSeconds, uint256 maxFeeBps) internal {
        vm.prank(guardian);
        nav.setExitFeeConfig(minSeconds, fullSeconds, maxFeeBps);
    }

    function _emergencyFee(uint256 bnbOwed) internal view returns (uint256) {
        uint256 quotient = bnbOwed / nav.BPS();
        uint256 remainder = bnbOwed % nav.BPS();
        uint256 fee = quotient * nav.EMERGENCY_FEE_BPS();
        uint256 remainderFee = remainder * nav.EMERGENCY_FEE_BPS();
        if (remainderFee != 0) {
            fee += (remainderFee + nav.BPS() - 1) / nav.BPS();
        }
        if (fee > bnbOwed) {
            fee = bnbOwed;
        }
        return fee;
    }

    function _setTotalClaimable(uint256 amount) internal {
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(amount);
    }

    function _setQueueLength(uint256 length) internal {
        vm.store(address(nav), bytes32(uint256(19)), bytes32(length));
    }

    function _setQueueHead(uint256 head) internal {
        stdstore.target(address(nav)).sig("queueHead()").checked_write(head);
    }

    function _setQueueEntry(uint256 index, address user, uint256 amount) internal {
        bytes32 base = keccak256(abi.encode(uint256(19)));
        uint256 offset = index * 2;
        vm.store(address(nav), bytes32(uint256(base) + offset), bytes32(uint256(uint160(user))));
        vm.store(address(nav), bytes32(uint256(base) + offset + 1), bytes32(amount));
    }

    function _seedQueue(address firstUser, uint256 entries, uint256 amount) internal {
        _setQueueLength(entries);
        for (uint256 i = 0; i < entries; i++) {
            address user = i == 0 ? firstUser : address(uint160(0x1000 + i));
            _setQueueEntry(i, user, amount);
        }
        _setQueueHead(0);
        stdstore.target(address(nav)).sig("totalLiabilitiesBNB()").checked_write(entries * amount);
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

    function testForcedBnbUpdatesNav() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        uint256 navBefore = nav.nav();

        vm.deal(address(nav), address(nav).balance + 1 ether);

        assertGt(nav.nav(), navBefore);
        assertGt(nav.totalAssets(), 10 ether);

        uint256 amount = 1 ether;
        uint256 fee = (amount * nav.MINT_FEE_BPS()) / nav.BPS();
        uint256 valueAfterFee = amount - fee;
        uint256 expectedMint = (valueAfterFee * 1e18) / nav.nav();

        vm.prank(bob);
        nav.deposit{value: amount}(expectedMint);
        assertEq(nav.balanceOf(bob), expectedMint);

        uint256 surplus = nav.untrackedSurplusBNB();
        uint256 recoveryBalanceBefore = recovery.balance;
        uint256 navBalanceBefore = address(nav).balance;
        vm.prank(recovery);
        nav.recoverSurplus(recovery);

        assertEq(nav.totalAssets(), navBalanceBefore - surplus);
        assertEq(address(nav).balance, navBalanceBefore - surplus);
        assertEq(recovery.balance - recoveryBalanceBefore, surplus);
    }

    function testTotalAssetsIncludesStrategy() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        assertEq(nav.totalAssets(), 10 ether);
        assertEq(address(nav).balance + mock.totalAssets(), 10 ether);
        assertGt(mock.totalAssets(), 0);
    }

    function testStrategyWithdrawFailureSignalsAccurately() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        _setTotalClaimable(1);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        mock.setForceZeroWithdraw(true);
        vm.deal(address(nav), 0);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.StrategyWithdrawFailed.selector);
        nav.claim();
    }

    function testSetStrategyRevertsWhenCurrentStrategyNotEmpty() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));

        mock.setAssets(1 ether);
        vm.prank(guardian);
        nav.proposeStrategy(address(0));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testSetStrategyRevertsWhenNewStrategyNotEmpty() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        mock.setAssets(1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(mock));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testSetStrategySucceedsWhenStrategiesEmpty() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        MockBNBYieldStrategy mockNext = new MockBNBYieldStrategy();

        _activateStrategy(address(mock));
        assertEq(address(nav.strategy()), address(mock));

        _activateStrategy(address(mockNext));
        assertEq(address(nav.strategy()), address(mockNext));

        _activateStrategy(address(0));
        assertEq(address(nav.strategy()), address(0));
    }

    function testSetStrategyRevertsWhenTimelockEnabled() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyTimelockEnabled.selector);
        nav.setStrategy(address(mock));
    }

    function testStrategyTimelockActivation() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();

        vm.prank(guardian);
        nav.proposeStrategy(address(mock));

        assertEq(nav.pendingStrategy(), address(mock));
        uint256 activationTime = nav.strategyActivationTime();

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyTimelockNotExpired.selector);
        nav.activateStrategy();

        vm.warp(activationTime);
        vm.prank(guardian);
        nav.activateStrategy();

        assertEq(address(nav.strategy()), address(mock));
        assertEq(nav.pendingStrategy(), address(0));
    }

    function testActivateStrategyRevertsWhenPendingNotContract() public {
        address notContract = address(0x1234);

        vm.prank(guardian);
        nav.proposeStrategy(notContract);
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotContract.selector);
        nav.activateStrategy();
    }

    function testActivateStrategyRevertsWhenCurrentNotEmpty() public {
        MockBNBYieldStrategy current = new MockBNBYieldStrategy();
        MockBNBYieldStrategy next = new MockBNBYieldStrategy();

        _activateStrategy(address(current));

        current.setAssets(1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(next));
        vm.warp(nav.strategyActivationTime());

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testActivateStrategyRevertsWhenNewNotEmpty() public {
        MockBNBYieldStrategy next = new MockBNBYieldStrategy();
        next.setAssets(1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(next));
        vm.warp(nav.strategyActivationTime());

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testDepositInvestsExcessAboveBuffer() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(100);

        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 bufferTarget = (nav.totalAssets() * nav.liquidityBufferBPS()) / nav.BPS();
        assertApproxEqAbs(address(nav).balance, bufferTarget, 1);
        assertEq(mock.totalAssets(), 100 ether - address(nav).balance);
    }

    function testRedeemQueuesWhenLiquidityLow() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 100 ether}(0);

        uint256 balanceBefore = alice.balance;
        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        _setTotalClaimable(1);
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 bnbAfterFee = bnbOwed - fee;
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);
        uint256 payout = alice.balance - balanceBefore;

        assertGt(payout, 0);
        assertLt(payout, bnbAfterFee);
        assertGt(nav.totalLiabilitiesBNB(), 0);
    }

    function testClaimUsesStrategyToMeetQueuedRedemption() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 50 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 bnbAfterFee = bnbOwed - fee;
        _setTotalClaimable(bnbAfterFee - 1 ether);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 strategyBefore = mock.totalAssets();
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.claim();
        uint256 balanceAfter = alice.balance;

        assertGt(balanceAfter - balanceBefore, 0);
        assertLe(mock.totalAssets(), strategyBefore);
    }

    function testNavUsesNetAssetsNotGross() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 desiredAfterFee = 1 ether;
        uint256 bnbOwed = (desiredAfterFee * nav.BPS()) / (nav.BPS() - nav.REDEEM_FEE_BPS());
        uint256 tokenAmount = (bnbOwed * 1e18) / nav.nav();
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 obligations = nav.totalLiabilitiesBNB() + nav.totalClaimableBNB();
        uint256 expected = ((nav.totalAssets() - obligations) * 1e18) / nav.totalSupply();
        assertEq(nav.nav(), expected);
    }

    function testZeroSupplyDoesNotAllowFreeCapture() public {
        vm.deal(address(nav), 5 ether);

        uint256 amount = 1 ether;
        uint256 fee = (amount * nav.MINT_FEE_BPS()) / nav.BPS();
        uint256 valueAfterFee = amount - fee;

        vm.prank(alice);
        nav.deposit{value: amount}(0);

        assertEq(nav.balanceOf(recovery), 5 ether);
        assertEq(nav.balanceOf(alice), valueAfterFee);

        uint256 aliceValue = (nav.balanceOf(alice) * nav.nav()) / 1e18;
        assertApproxEqAbs(aliceValue, valueAfterFee, 1e15);
    }

    function testNavNonZeroAtParity() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 desiredBnb = 1 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 bnbAfterFee = bnbOwed - fee;
        _setTotalClaimable(bnbAfterFee - 1);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        assertGt(liabilities, 0);

        vm.deal(address(nav), liabilities);
        mock.setAssets(0);
        vm.deal(address(mock), 0);

        uint256 navAfter = nav.nav();
        assertEq(navAfter, 0);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.Insolvent.selector);
        nav.redeem(1, 0);

        vm.prank(bob);
        vm.expectRevert(NavBNBv2.Insolvent.selector);
        nav.deposit{value: 1 ether}(0);
    }

    function testClaimFairnessFifo() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

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
        _setTotalClaimable(1);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        for (uint256 i = 0; i < attackers; i++) {
            address attacker = attackAddresses[i];
            uint256 balance = nav.balanceOf(attacker);
            vm.prank(attacker);
            nav.redeem(balance, 0);
        }

        uint256 totalLiabilitiesBefore = nav.totalLiabilitiesBNB();
        if (totalLiabilitiesBefore == 0) {
            return;
        }
        uint256 head = nav.queueHead();
        uint256 queueLen = nav.queueLength();
        uint256[] memory remainingBefore = new uint256[](queueLen);
        for (uint256 i = 0; i < queueLen; i++) {
            (, uint256 amount) = nav.getQueueEntry(i);
            remainingBefore[i] = amount;
        }

        vm.prank(alice);
        nav.claim();

        uint256 liabilitiesAfter = nav.totalLiabilitiesBNB();
        assertLt(liabilitiesAfter, totalLiabilitiesBefore);

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

    function testMatureExitFeeIsZero() public {
        _setExitFeeConfig(1 days, 3 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        vm.warp(block.timestamp + 3 days);
        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 expected = bnbOwed - fee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);
    }

    function testEarlyExitRequiresEmergency() public {
        _setExitFeeConfig(1 days, 3 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.TooEarlyForFreeExit.selector);
        nav.redeem(tokenAmount, 0);

        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount, 0);
    }

    function testLinearExitFeeDecay() public {
        _setExitFeeConfig(1 days, 5 days, 500);

        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        uint256 depositedAt = nav.lastDepositTime(alice);
        vm.warp(depositedAt + 1 days);
        assertEq(nav.exitFeeBps(alice), 500);

        vm.warp(depositedAt + 3 days);
        assertApproxEqAbs(nav.exitFeeBps(alice), 250, 1);

        vm.warp(depositedAt + 5 days);
        assertEq(nav.exitFeeBps(alice), 0);
    }

    function testNoGlobalHostageStates() public {
        _setExitFeeConfig(0, 1 days, 0);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        vm.prank(bob);
        nav.deposit{value: 10 ether}(0);

        uint256 day = block.timestamp / 1 days;
        _setSpentToday(day, type(uint256).max);

        uint256 tokenAmount = nav.balanceOf(bob) / 2;
        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        nav.redeem(tokenAmount, 0);
        assertGt(bob.balance, balanceBefore);
    }

    function testRedeemRejectsZeroPayout() public {
        _setExitFeeConfig(0, 1 days, nav.BPS());

        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NoProgress.selector);
        nav.redeem(tokenAmount, 0);
    }

    function testEmergencyRedeemWithoutQueue() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = _emergencyFee(bnbOwed);
        uint256 expected = bnbOwed - fee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);
    }

    function testEmergencyRedeemMinimumFeeForDust() public {
        vm.prank(alice);
        nav.deposit{value: 10}(0);

        uint256 tokenAmount = 2;
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1);
    }

    function testEmergencyRedeemDoesNotTouchQueue() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 20 ether}(0);

        vm.prank(bob);
        nav.deposit{value: 5 ether}(0);

        uint256 desiredBnb = 5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        _setTotalClaimable(1);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        assertGt(nav.reserveBNB(), 0);

        vm.prank(alice);
        nav.deposit{value: 5 ether}(0);

        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        uint256 head = nav.queueHead();
        (, uint256 headRemainingBefore) = nav.getQueueEntry(head);
        assertGt(liabilitiesBefore, 0);

        mock.setMaxWithdraw(100 ether);
        uint256 emergencyShares = nav.balanceOf(bob) / 2;
        uint256 bnbOwed = (emergencyShares * nav.nav()) / 1e18;
        uint256 fee = _emergencyFee(bnbOwed);
        uint256 expected = bnbOwed - fee;

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        nav.emergencyRedeem(emergencyShares, 0);
        uint256 bobBalanceAfter = bob.balance;

        assertApproxEqAbs(bobBalanceAfter - bobBalanceBefore, expected, 2);

        assertEq(nav.totalLiabilitiesBNB(), liabilitiesBefore);
        (, uint256 headRemainingAfter) = nav.getQueueEntry(head);
        assertEq(headRemainingAfter, headRemainingBefore);
        assertGe(nav.totalAssets(), nav.totalObligations());
    }

    function testEmergencyRedeemCannotDrainReserve() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        vm.prank(bob);
        nav.deposit{value: 1 ether}(0);

        uint256 desiredBnb = 5 ether;
        uint256 tokenAmount = (desiredBnb * 1e18) / nav.nav();
        _setTotalClaimable(1);
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);

        uint256 assets = nav.totalAssets();
        uint256 liabilities = nav.totalLiabilitiesBNB();
        uint256 claimableTarget = assets - liabilities;
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(claimableTarget);
        assertEq(nav.reserveBNB(), 0);
        assertGt(nav.totalLiabilitiesBNB(), 0);

        uint256 emergencyShares = nav.balanceOf(bob) / 2;
        vm.prank(bob);
        vm.expectRevert(NavBNBv2.NoProgress.selector);
        nav.emergencyRedeem(emergencyShares, 0);
    }

    function testEmergencyRedeemRejectsNoProgress() public {
        vm.prank(alice);
        nav.deposit{value: 10}(0);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NoProgress.selector);
        nav.emergencyRedeem(1, 0);
    }

    function testRedeemPaysQueueBeforeNewRedemption() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        _seedQueue(alice, 33, 1);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        uint256 bobRedeem = nav.balanceOf(alice) / 10;
        vm.prank(alice);
        nav.transfer(bob, bobRedeem);
        vm.prank(bob);
        nav.redeem(bobRedeem, 0);

        assertGt(alice.balance - aliceBalanceBefore, 0);
        assertEq(bob.balance - bobBalanceBefore, 0);
    }

    function testClaimBoundedSteps() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 400 ether}(0);

        _setTotalClaimable(1);
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

        uint256 liabilities = nav.totalLiabilitiesBNB();
        if (liabilities == 0) {
            return;
        }
        mock.setMaxWithdraw(100 ether);
        uint256 headBefore = nav.queueHead();
        vm.prank(alice);
        nav.claim();
        uint256 headAfter = nav.queueHead();

        uint256 remaining = nav.queueLength() - headBefore;
        uint256 expected = remaining > nav.DEFAULT_MAX_STEPS() ? nav.DEFAULT_MAX_STEPS() : remaining;
        assertEq(headAfter - headBefore, expected);
    }

    function testClaimBoundedStepsProgresses() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 400 ether}(0);

        _setTotalClaimable(1);
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

        mock.setMaxWithdraw(100 ether);
        uint256 headBefore = nav.queueHead();
        vm.prank(alice);
        nav.claim();
        uint256 headAfter = nav.queueHead();

        vm.prank(alice);
        nav.claim();
        uint256 headAfterSecond = nav.queueHead();

        uint256 remaining = nav.queueLength() - headBefore;
        uint256 expected = remaining > nav.DEFAULT_MAX_STEPS() ? nav.DEFAULT_MAX_STEPS() : remaining;
        assertEq(headAfter - headBefore, expected);
        if (nav.totalLiabilitiesBNB() > 0) {
            assertGt(headAfterSecond, headAfter);
        }
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

    function testWithdrawClaimableRevertsWhenStrategyPartial() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setAssets(2 ether);
        mock.setMaxWithdraw(1 ether);
        vm.deal(address(mock), 2 ether);

        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(2 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(2 ether);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.InsufficientLiquidityAfterWithdraw.selector);
        nav.withdrawClaimable(0);

        assertEq(nav.claimableBNB(alice), 2 ether);
        assertEq(nav.totalClaimableBNB(), 2 ether);
    }

    function testQueueHeadRevertEscrowsAndMovesOn() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 50 ether}(0);

        ToggleReceiver bad = new ToggleReceiver(nav);
        bad.setRevert(true);
        vm.deal(address(bad), 10 ether);
        bad.deposit{value: 5 ether}(0);

        mock.setAssets(2 ether);
        vm.deal(address(mock), 2 ether);
        _setQueueLength(2);
        _setQueueEntry(0, alice, 1 ether);
        _setQueueEntry(1, address(bad), 1 ether);
        _setQueueHead(0);
        stdstore.target(address(nav)).sig("totalLiabilitiesBNB()").checked_write(2 ether);

        mock.setMaxWithdraw(100 ether);
        bad.setRevert(false);
        vm.prank(alice);
        nav.claim(1);

        bad.setRevert(true);
        uint256 headBefore = nav.queueHead();
        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        uint256 totalClaimableBefore = nav.totalClaimableBNB();
        uint256 claimableBefore = nav.claimableBNB(address(bad));
        vm.prank(alice);
        nav.claim(1);

        _assertEscrowAfterClaim(bad, headBefore, liabilitiesBefore, totalClaimableBefore, claimableBefore);

        _withdrawClaimableAndAssert(bad);
    }

    function _assertEscrowAfterClaim(
        ToggleReceiver bad,
        uint256 headBefore,
        uint256 liabilitiesBefore,
        uint256 totalClaimableBefore,
        uint256 claimableBefore
    ) internal view {
        uint256 claimableAfter = nav.claimableBNB(address(bad));
        assertGt(claimableAfter, claimableBefore);
        uint256 escrowed = claimableAfter - claimableBefore;
        assertGt(nav.queueHead(), headBefore);
        uint256 paidFromQueue =
            liabilitiesBefore - nav.totalLiabilitiesBNB() - (nav.totalClaimableBNB() - totalClaimableBefore);
        assertEq(nav.totalClaimableBNB() - totalClaimableBefore, escrowed);
        assertEq(
            nav.totalLiabilitiesBNB() + nav.totalClaimableBNB(),
            liabilitiesBefore + totalClaimableBefore - paidFromQueue
        );
    }

    function _withdrawClaimableAndAssert(ToggleReceiver bad) internal {
        bad.setRevert(false);
        uint256 totalClaimableBeforeWithdraw = nav.totalClaimableBNB();
        uint256 claimableBefore = nav.claimableBNB(address(bad));
        uint256 balanceBefore = address(bad).balance;
        bad.withdrawClaimable(0);
        uint256 balanceAfter = address(bad).balance;
        uint256 payout = balanceAfter - balanceBefore;

        assertEq(payout, claimableBefore);
        assertEq(nav.totalClaimableBNB(), totalClaimableBeforeWithdraw - payout);
        assertEq(nav.claimableBNB(address(bad)), claimableBefore - payout);

        uint256 receiverBalanceBefore = address(bad).balance;
        vm.prank(alice);
        nav.claim(1);
        assertEq(address(bad).balance, receiverBalanceBefore);
    }

    function testQueueHeadFailureDoesNotLimitLaterPayments() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 20 ether}(0);

        ToggleReceiver bad = new ToggleReceiver(nav);
        bad.setRevert(false);
        vm.deal(address(bad), 2 ether);
        bad.deposit{value: 1 ether}(0);

        _setTotalClaimable(1);
        uint256 badTokens = nav.balanceOf(address(bad));
        bad.redeem(badTokens, 0);
        bad.setRevert(true);

        uint256 aliceRedeem = nav.balanceOf(alice) / 20;
        vm.prank(alice);
        nav.redeem(aliceRedeem, 0);

        (, uint256 badQueued) = nav.getQueueEntry(0);
        (, uint256 aliceQueued) = nav.getQueueEntry(1);

        mock.setMaxWithdraw(100 ether);
        uint256 aliceBalanceBefore = alice.balance;
        uint256 claimableBefore = nav.claimableBNB(address(bad));

        vm.prank(alice);
        nav.claim(2);

        uint256 claimableAfter = nav.claimableBNB(address(bad));
        uint256 alicePaid = alice.balance - aliceBalanceBefore;

        assertEq(claimableAfter - claimableBefore, badQueued);
        assertEq(alicePaid, aliceQueued);
        assertEq(nav.queueHead(), 2);
    }

    function testWithdrawClaimablePaysOut() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        ToggleReceiver receiver = new ToggleReceiver(nav);
        receiver.setRevert(false);
        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(address(receiver)).checked_write(1 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(1 ether);
        vm.deal(address(nav), 1 ether);

        uint256 claimable = nav.claimableBNB(address(receiver));
        assertEq(claimable, 1 ether);

        uint256 balanceBefore = address(receiver).balance;
        receiver.withdrawClaimable(0);
        uint256 balanceAfter = address(receiver).balance;

        assertEq(balanceAfter - balanceBefore, claimable);
        assertEq(nav.claimableBNB(address(receiver)), 0);
    }

    function testQueueAppendsEntriesPerEnqueue() public {
        NavBNBv2Harness harness = new NavBNBv2Harness(guardian, recovery);
        harness.enqueue(alice, 1 ether);
        harness.enqueue(alice, 1 ether);

        uint256 len = harness.queueLength();
        uint256 head = harness.queueHead();
        assertEq(len - head, 2);
    }

    function testWithdrawClaimableCallsStrategyOnce() public {
        MockBNBYieldStrategy mock = new MockBNBYieldStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);

        vm.prank(alice);
        nav.deposit{value: 2 ether}(0);

        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(1 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(1 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.withdrawClaimable(0);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1 ether);
        assertEq(nav.claimableBNB(alice), 0);
        assertEq(nav.totalClaimableBNB(), 0);
        assertEq(mock.withdrawCallCount(), 1);
    }

    function testWithdrawClaimableRejectsZeroPayout() public {
        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(1);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(uint256(0));

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NoProgress.selector);
        nav.withdrawClaimable(0);

        assertEq(nav.claimableBNB(alice), 1);
    }

    function testEmergencyRedeemRoundsUpFee() public {
        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        uint256 tokenAmount = 11;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = _emergencyFee(bnbOwed);
        uint256 expected = bnbOwed - fee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, expected);
    }

    function testRecoverSurplusOnlyRecovery() public {
        vm.deal(address(nav), address(nav).balance + 1 ether);
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NotRecovery.selector);
        nav.recoverSurplus(alice);
    }

    function testRecoverSurplusRejectsInvalidRecipient() public {
        vm.deal(address(nav), address(nav).balance + 1 ether);
        vm.prank(recovery);
        vm.expectRevert(NavBNBv2.InvalidRecipient.selector);
        nav.recoverSurplus(address(0));
    }

    function testDepositBootstrapsRecoveryWhenSupplyZero() public {
        vm.deal(address(nav), 5 ether);

        uint256 amount = 1 ether;
        uint256 fee = (amount * nav.MINT_FEE_BPS()) / nav.BPS();
        uint256 valueAfterFee = amount - fee;

        vm.prank(alice);
        nav.deposit{value: amount}(0);

        assertEq(nav.balanceOf(recovery), 5 ether);
        assertEq(nav.balanceOf(alice), valueAfterFee);
    }

    function testCompactQueueRebuildsFromHead() public {
        _setQueueLength(3);
        _setQueueEntry(0, alice, 1 ether);
        _setQueueEntry(1, bob, 2 ether);
        _setQueueEntry(2, recovery, 3 ether);
        _setQueueHead(1);

        uint256 remaining = nav.queueLength() - nav.queueHead();
        (address expectedUser,) = nav.getQueueEntry(nav.queueHead());

        nav.compactQueue(remaining);

        assertEq(nav.queueHead(), 0);
        assertEq(nav.queueLength(), remaining);
        (address compactedUser,) = nav.getQueueEntry(0);
        assertEq(compactedUser, expectedUser);
    }
}

contract NavBNBv2Harness is NavBNBv2 {
    constructor(address guardian_, address recovery_) NavBNBv2(guardian_, recovery_) {}

    function enqueue(address user, uint256 amount) external {
        _enqueue(user, amount);
    }
}

contract NavBNBv2HandlerTest is NoLogBound {
    NavBNBv2 internal nav;
    address[] public users;
    address[] public participants;
    mapping(address => bool) internal isParticipant;

    bool public overClaim;
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
        if (nav.totalAssets() <= nav.totalLiabilitiesBNB()) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(user);
        nav.redeem(amount, 0);
        _trackParticipant(user);
        if (nav.totalAssets() < nav.totalLiabilitiesBNB()) {
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
        if (nav.totalAssets() < liabilitiesBefore) {
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
        vm.prank(address(0xBEEF));
        nav.setExitFeeConfig(0, 1 days, 0);
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

    function invariantQueueHeadMonotonic() public view {
        assertFalse(handler.headDecreased());
        assertLe(nav.queueHead(), nav.queueLength());
    }

    function invariantRedeemSolvent() public view {
        assertFalse(handler.redeemBrokeSolvency());
    }

    function invariantTrackedAssetsBelowBalance() public view {
        assertLe(nav.trackedAssetsBNB(), nav.totalAssets());
    }
}
