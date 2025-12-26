// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/StdStorage.sol";
import "src/NavBNBv2.sol";
import "test/mocks/MockBNBYieldStrategy.sol";
import "test/mocks/MockTokenHoldingStrategy.sol";
import "test/mocks/MockOpaqueStrategy.sol";
import "test/mocks/MockZeroTokenStrategy.sol";
import "test/mocks/MockERC20.sol";
import {MockAnkrPool} from "test/mocks/MockAnkrPool.sol";

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

    function withdrawClaimable(uint256 minOut, bool acceptDust) external {
        nav.withdrawClaimable(minOut, acceptDust);
    }

    receive() external payable {
        if (shouldRevert) {
            revert("NO_RECEIVE");
        }
    }
}

contract GasBurnerReceiver {
    uint256 public burnLoops;

    function setBurnLoops(uint256 loops) external {
        burnLoops = loops;
    }

    receive() external payable {
        uint256 loops = burnLoops;
        for (uint256 i = 0; i < loops; i++) {
            assembly {
                pop(0)
            }
        }
    }
}

contract ForceSend {
    constructor() payable {}

    function boom(address payable target) external {
        selfdestruct(target);
    }
}

contract DirectSender {
    function send(address payable target) external payable {
        (bool success, bytes memory data) = target.call{value: msg.value}("");
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
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
    MockERC20 internal ankr;
    MockERC20 internal wbnb;
    MockAnkrPool internal pool;
    address internal guardian = address(0xBEEF);
    address internal recovery = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        nav = new NavBNBv2(guardian, recovery);
        ankr = new MockERC20("ankrBNB", "ankrBNB");
        wbnb = new MockERC20("WBNB", "WBNB");
        pool = new MockAnkrPool(address(ankr), 1e18);
        vm.prank(guardian);
        nav.setExitFeeConfig(0, 1 days, 0);
        vm.prank(guardian);
        nav.setMinPayoutWei(1);
        vm.prank(guardian);
        nav.setMinQueueEntryWei(1);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(guardian, 1_000 ether);
        vm.deal(recovery, 1_000 ether);
    }

    function _newMockStrategy() internal returns (MockBNBYieldStrategy) {
        return new MockBNBYieldStrategy(address(ankr), address(wbnb), address(pool));
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

    function _setMinPayout(uint256 newMin) internal {
        vm.prank(guardian);
        nav.setMinPayoutWei(newMin);
    }

    function _setMinQueueEntry(uint256 newMin) internal {
        vm.prank(guardian);
        nav.setMinQueueEntryWei(newMin);
    }

    function _emergencyFee(uint256 bnbOwed) internal view returns (uint256) {
        if (bnbOwed == 0) {
            return 0;
        }
        uint256 quotient = bnbOwed / nav.BPS();
        uint256 remainder = bnbOwed % nav.BPS();
        uint256 fee = quotient * nav.EMERGENCY_FEE_BPS();
        if (remainder != 0) {
            uint256 remainderFee = remainder * nav.EMERGENCY_FEE_BPS();
            fee += (remainderFee + nav.BPS() - 1) / nav.BPS();
        }
        if (fee >= bnbOwed) {
            fee = bnbOwed - 1;
        }
        return fee;
    }

    function _emergencyShareFee(uint256 shares) internal view returns (uint256) {
        if (shares == 0) {
            return 0;
        }
        uint256 quotient = shares / nav.BPS();
        uint256 remainder = shares % nav.BPS();
        uint256 fee = quotient * nav.EMERGENCY_FEE_BPS();
        if (remainder != 0) {
            uint256 remainderFee = remainder * nav.EMERGENCY_FEE_BPS();
            fee += (remainderFee + nav.BPS() - 1) / nav.BPS();
        }
        if (fee >= shares) {
            fee = shares - 1;
        }
        return fee;
    }

    function _setTotalClaimable(uint256 amount) internal {
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(amount);
    }

    function _setQueueLength(uint256 length) internal {
        vm.store(address(nav), bytes32(uint256(22)), bytes32(length));
    }

    function _setQueueLengthFor(address target, uint256 length) internal {
        vm.store(target, bytes32(uint256(22)), bytes32(length));
    }

    function _setQueueHead(uint256 head) internal {
        stdstore.target(address(nav)).sig("queueHead()").checked_write(head);
    }

    function _setQueueHeadFor(address target, uint256 head) internal {
        stdstore.target(target).sig("queueHead()").checked_write(head);
    }

    function _setQueueEntry(uint256 index, address user, uint256 amount) internal {
        bytes32 base = keccak256(abi.encode(uint256(22)));
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

    function testRedeemRejectsQueueEntriesBelowMinimum() public {
        _setMinQueueEntry(1 ether);
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(1);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 100;
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.RedeemTooSmall.selector);
        nav.redeem(tokenAmount, 0);
    }

    function testQueueDynamicMinEntryRisesWithActiveLength() public {
        NavBNBv2Harness harness = new NavBNBv2Harness(guardian, recovery);
        uint256 baseMin = 1e14;
        vm.prank(guardian);
        harness.setMinQueueEntryWei(baseMin);
        _setQueueHeadFor(address(harness), 0);
        _setQueueLengthFor(address(harness), 64);

        uint256 expected = baseMin + (baseMin * 64) / harness.QUEUE_ENTRY_SCALE();
        assertEq(harness.effectiveMinQueueEntry(), expected);

        vm.expectRevert(NavBNBv2.RedeemTooSmall.selector);
        harness.enqueue(alice, expected - 1);

        harness.enqueue(alice, expected);
        assertEq(harness.queueLength(), 65);
    }

    function testEmergencyRedeemAcceptsDustWithOverride() public {
        _setMinPayout(1 ether);
        vm.prank(alice);
        nav.deposit{value: 0.05 ether}(0);

        uint256 shares = nav.balanceOf(alice);
        (uint256 expectedOut,) = nav.previewEmergencyRedeem(shares);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(shares, 0, true);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, expectedOut);
    }

    function testEmergencyRedeemTinyAmountPaysAtLeastOneWei() public {
        _setMinPayout(1);
        vm.prank(alice);
        nav.deposit{value: 1}(0);

        uint256 shares = nav.balanceOf(alice);
        (uint256 bnbOut, uint256 fee) = nav.previewEmergencyRedeem(shares);
        assertEq(bnbOut, 1);
        assertEq(fee, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(shares, 0, true);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1);
    }

    function testForcedBnbUpdatesNav() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        uint256 navBefore = nav.nav();

        ForceSend force = new ForceSend{value: 1 ether}();
        force.boom(payable(address(nav)));

        assertGt(nav.nav(), navBefore);
        assertGt(nav.totalAssets(), 10 ether);

        uint256 amount = 1 ether;
        uint256 fee = (amount * nav.MINT_FEE_BPS()) / nav.BPS();
        uint256 valueAfterFee = amount - fee;
        uint256 navAtTracked = (nav.trackedAssetsBNB() * 1e18) / nav.totalSupply();
        uint256 expectedMint = (valueAfterFee * 1e18) / navAtTracked;

        uint256 recoveryBefore = nav.balanceOf(recovery);
        vm.prank(bob);
        nav.deposit{value: amount}(expectedMint);
        assertEq(nav.balanceOf(bob), expectedMint);
        assertGt(nav.balanceOf(recovery), recoveryBefore);

        uint256 bobValue = (nav.balanceOf(bob) * nav.nav()) / 1e18;
        assertApproxEqAbs(bobValue, valueAfterFee, 1e15);

        assertEq(nav.untrackedSurplusBNB(), 0);
    }

    function testDirectBnbTransferReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(NavBNBv2.DirectBnbNotAccepted.selector);
        (bool success, bytes memory data) = address(nav).call{value: 1 ether}("");
        success = success;
        data = data;
    }

    function testDirectBnbTransferRevertsFromContract() public {
        DirectSender sender = new DirectSender();
        vm.deal(address(sender), 1 ether);
        vm.expectRevert(NavBNBv2.DirectBnbNotAccepted.selector);
        sender.send{value: 1 ether}(payable(address(nav)));
    }

    function testEffectiveMinQueueEntryScalesWithQueueLength() public {
        _setMinQueueEntry(1);
        _seedQueue(alice, 64, 1);

        uint256 effective = nav.effectiveMinQueueEntry();
        assertGt(effective, nav.minQueueEntryWei());
    }

    function testForcedBnbSendDoesNotMint() public {
        vm.prank(alice);
        nav.deposit{value: 2 ether}(0);

        uint256 totalSupplyBefore = nav.totalSupply();
        uint256 trackedBefore = nav.trackedAssetsBNB();
        uint256 balanceBefore = address(nav).balance;
        uint256 surplusBefore = nav.untrackedSurplusBNB();

        ForceSend force = new ForceSend{value: 1 ether}();
        force.boom(payable(address(nav)));

        assertEq(nav.totalSupply(), totalSupplyBefore);
        assertEq(nav.trackedAssetsBNB(), trackedBefore);
        assertEq(address(nav).balance, balanceBefore + 1 ether);
        assertEq(nav.untrackedSurplusBNB(), surplusBefore + 1 ether);
    }

    function testReceiveAcceptsWbnbUnwrap() public {
        MockERC20 ankr = new MockERC20("ankrBNB", "ankrBNB");
        MockWBNB wbnb = new MockWBNB();
        MockTokenHoldingStrategy strategyWithWbnb =
            new MockTokenHoldingStrategy(address(ankr), address(wbnb), address(pool));
        _activateStrategy(address(strategyWithWbnb));

        wbnb.mint(address(nav), 1 ether);
        vm.deal(address(wbnb), 1 ether);
        uint256 balanceBefore = address(nav).balance;
        vm.prank(address(nav));
        wbnb.withdraw(1 ether);

        assertEq(address(nav).balance, balanceBefore + 1 ether);
    }

    function testReceiveAcceptsStrategyReturn() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));

        vm.deal(address(mock), 1 ether);
        uint256 balanceBefore = address(nav).balance;
        vm.prank(address(mock));
        (bool success,) = address(nav).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(nav).balance, balanceBefore + 1 ether);
    }

    function testTotalAssetsIncludesStrategy() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        assertEq(nav.totalAssets(), 10 ether);
        assertEq(address(nav).balance + mock.totalAssets(), 10 ether);
        assertGt(mock.totalAssets(), 0);
    }

    function testStrategyWithdrawFailureSignalsAccurately() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));

        vm.deal(address(mock), 1 ether);
        vm.prank(guardian);
        nav.proposeStrategy(address(0));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testSetStrategyRevertsWhenNewStrategyNotEmpty() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        vm.deal(address(mock), 1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(mock));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testStrategySwitchFailsWhenOldStrategyHoldsTokens() public {
        MockERC20 ankr = new MockERC20("ankrBNB", "ankrBNB");
        MockERC20 wbnb = new MockERC20("WBNB", "WBNB");
        MockTokenHoldingStrategy strategyWithTokens =
            new MockTokenHoldingStrategy(address(ankr), address(wbnb), address(pool));

        _activateStrategy(address(strategyWithTokens));

        ankr.mint(address(strategyWithTokens), 1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(0));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testStrategyActivationFailsWhenTokenGetterMissing() public {
        MockERC20 token = new MockERC20("token", "token");
        MockOpaqueStrategy opaque = new MockOpaqueStrategy();

        token.mint(address(opaque), 1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(opaque));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavBNBv2.StrategyTokenQueryFailed.selector, address(opaque), bytes4(keccak256("ankrBNB()"))
            )
        );
        nav.activateStrategy();
    }

    function testStrategyActivationFailsWhenTokenAddressZero() public {
        MockZeroTokenStrategy zeroToken = new MockZeroTokenStrategy();

        vm.prank(guardian);
        nav.proposeStrategy(address(zeroToken));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavBNBv2.StrategyTokenAddressZero.selector, address(zeroToken), bytes4(keccak256("ankrBNB()"))
            )
        );
        nav.activateStrategy();
    }

    function testNavIgnoresStrategyTotalAssets() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(10_000);

        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        mock.setAssets(100 ether);
        assertEq(nav.totalAssets(), 1 ether);
    }

    function testActivateStrategyRevertsWhenPendingBalanceNonZero() public {
        MockBNBYieldStrategy next = _newMockStrategy();
        vm.deal(address(next), 1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(next));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testSetStrategySucceedsWhenStrategiesEmpty() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        MockBNBYieldStrategy mockNext = _newMockStrategy();

        _activateStrategy(address(mock));
        assertEq(address(nav.strategy()), address(mock));

        _activateStrategy(address(mockNext));
        assertEq(address(nav.strategy()), address(mockNext));

        _activateStrategy(address(0));
        assertEq(address(nav.strategy()), address(0));
    }

    function testStrategyMigrationUpdatesTrackedAssets() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        mock.setAssets(12 ether);
        vm.deal(address(mock), 12 ether);

        _activateStrategy(address(0));

        assertEq(nav.trackedAssetsBNB(), nav.totalAssets());
        assertEq(nav.untrackedSurplusBNB(), 0);
    }

    function testStrategyMigrationSweepsOldStrategy() public {
        MockBNBYieldStrategy oldStrategy = _newMockStrategy();
        _activateStrategy(address(oldStrategy));

        oldStrategy.setAssets(2 ether);
        vm.deal(address(oldStrategy), 2 ether);

        MockBNBYieldStrategy nextStrategy = _newMockStrategy();
        vm.prank(guardian);
        nav.proposeStrategy(address(nextStrategy));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        nav.activateStrategy();

        assertEq(oldStrategy.totalAssets(), 0);
        assertEq(address(oldStrategy).balance, 0);
        assertEq(address(nav.strategy()), address(nextStrategy));
    }

    function testSetStrategyRevertsWhenTimelockEnabled() public {
        MockBNBYieldStrategy mock = _newMockStrategy();

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyTimelockEnabled.selector);
        nav.setStrategy(address(mock));
    }

    function testStrategyTimelockActivation() public {
        MockBNBYieldStrategy mock = _newMockStrategy();

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
        MockBNBYieldStrategy current = _newMockStrategy();
        MockBNBYieldStrategy next = _newMockStrategy();

        _activateStrategy(address(current));

        vm.deal(address(current), 1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(next));
        vm.warp(nav.strategyActivationTime());

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testActivateStrategyRevertsWhenNewNotEmpty() public {
        MockBNBYieldStrategy next = _newMockStrategy();
        vm.deal(address(next), 1 ether);

        vm.prank(guardian);
        nav.proposeStrategy(address(next));
        vm.warp(nav.strategyActivationTime());

        vm.prank(guardian);
        vm.expectRevert(NavBNBv2.StrategyNotEmpty.selector);
        nav.activateStrategy();
    }

    function testDepositInvestsExcessAboveBuffer() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 50 ether}(0);

        _setTotalClaimable(1);
        _seedQueue(alice, 1, 1 ether);

        uint256 strategyBefore = mock.totalAssets();
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.claim();
        uint256 balanceAfter = alice.balance;

        assertGt(balanceAfter - balanceBefore, 0);
        assertLe(mock.totalAssets(), strategyBefore);
    }

    function testClaimBestEffortPaysPartialStrategyWithdraw() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setWithdrawRatioBps(9_000);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        _seedQueue(alice, 1, 1 ether);

        uint256 balanceBefore = alice.balance;
        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        vm.prank(alice);
        nav.claim();
        uint256 balanceAfter = alice.balance;

        assertGt(balanceAfter - balanceBefore, 0);
        assertLt(nav.totalLiabilitiesBNB(), liabilitiesBefore);
    }

    function testQueuePaymentsRespectClaimableReserve() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(3 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(3 ether);

        _setQueueLength(1);
        _setQueueEntry(0, bob, 2 ether);
        _setQueueHead(0);
        stdstore.target(address(nav)).sig("totalLiabilitiesBNB()").checked_write(2 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        nav.claim();
        assertEq(bob.balance - bobBefore, 2 ether);
        assertEq(nav.totalClaimableBNB(), 3 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        nav.withdrawClaimable(0);
        assertEq(alice.balance - aliceBefore, 3 ether);
    }

    function testNavUsesNetAssetsNotGross() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
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

    function testEarlyExitAppliesFee() public {
        _setExitFeeConfig(1 days, 3 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 timeFeeBps = nav.exitFeeBps(alice);
        uint256 timeFee = ((bnbOwed - fee) * timeFeeBps) / nav.BPS();
        uint256 expected = bnbOwed - fee - timeFee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);

        vm.prank(alice);
        nav.emergencyRedeem(tokenAmount, 0);
    }

    function testLinearExitFeeDecay() public {
        _setExitFeeConfig(0, 5 days, 500);

        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        uint256 depositedAt = nav.lastDepositTime(alice);
        assertEq(nav.exitFeeBps(alice), 500);

        vm.warp(depositedAt + 2 days + 12 hours);
        assertApproxEqAbs(nav.exitFeeBps(alice), 250, 1);

        vm.warp(depositedAt + 5 days);
        assertEq(nav.exitFeeBps(alice), 0);
    }

    function testExitFeeTransfersWithFullShares() public {
        _setExitFeeConfig(0, 1 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice);
        vm.prank(alice);
        nav.transfer(bob, tokenAmount);

        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 timeFeeBps = nav.exitFeeBps(bob);
        uint256 timeFee = ((bnbOwed - fee) * timeFeeBps) / nav.BPS();
        uint256 expected = bnbOwed - fee - timeFee;

        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        nav.redeem(tokenAmount, 0);
        uint256 balanceAfter = bob.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);
    }

    function testExitFeeTransfersOnPartialShares() public {
        _setExitFeeConfig(0, 1 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        vm.prank(alice);
        nav.transfer(bob, tokenAmount);

        assertEq(nav.exitFeeBps(bob), nav.exitFeeBps(alice));
        assertGt(nav.exitFeeBps(bob), 0);
    }

    function testExitFeeAppliesAfterTransferToFreshAddress() public {
        _setExitFeeConfig(0, 1 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice);
        uint256 aliceFeeBps = nav.exitFeeBps(alice);
        assertGt(aliceFeeBps, 0);

        vm.prank(alice);
        nav.transfer(bob, tokenAmount);
        assertEq(nav.exitFeeBps(bob), aliceFeeBps);

        uint256 bnbOwed = (tokenAmount * nav.nav()) / 1e18;
        uint256 fee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        uint256 timeFee = ((bnbOwed - fee) * aliceFeeBps) / nav.BPS();
        uint256 expected = bnbOwed - fee - timeFee;

        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        nav.redeem(tokenAmount, 0);
        uint256 balanceAfter = bob.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);
    }

    function testTransferFromOlderDoesNotReduceRecipientMaturity() public {
        _setExitFeeConfig(0, 10 days, 500);

        vm.prank(bob);
        nav.deposit{value: 1 ether}(0);
        uint64 bobDeposit = nav.lastDepositTime(bob);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);
        uint64 aliceDeposit = nav.lastDepositTime(alice);
        assertGt(aliceDeposit, bobDeposit);

        uint256 transferAmount = nav.balanceOf(bob) / 2;
        vm.prank(bob);
        nav.transfer(alice, transferAmount);

        assertEq(nav.lastDepositTime(alice), aliceDeposit);
    }

    function testDefaultExitFeeConfigDecaysToZero() public {
        NavBNBv2 localNav = new NavBNBv2(guardian, recovery);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        localNav.deposit{value: 10 ether}(0);

        uint256 depositedAt = localNav.lastDepositTime(alice);
        assertEq(localNav.exitFeeBps(alice), localNav.maxExitFeeBps());

        vm.warp(depositedAt + 15 days);
        assertApproxEqAbs(localNav.exitFeeBps(alice), localNav.maxExitFeeBps() / 2, 1);

        vm.warp(depositedAt + 30 days);
        assertEq(localNav.exitFeeBps(alice), 0);

        uint256 tokenAmount = localNav.balanceOf(alice) / 2;
        uint256 bnbOwed = (tokenAmount * localNav.nav()) / 1e18;
        uint256 fee = (bnbOwed * localNav.REDEEM_FEE_BPS()) / localNav.BPS();
        uint256 expected = bnbOwed - fee;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        localNav.redeem(tokenAmount, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, expected, 2);
    }

    function testExitFeeViewHelpers() public {
        _setExitFeeConfig(0, 10 days, 500);

        vm.prank(alice);
        nav.deposit{value: 2 ether}(0);

        uint64 depositedAt = nav.lastDepositTime(alice);
        assertEq(nav.maturityTimestamp(alice), depositedAt + 10 days);
        assertEq(nav.timeUntilZeroExitFee(alice), 10 days);
        assertEq(nav.exitFeeFreeAfterSeconds(), 10 days);
        assertEq(nav.secondsUntilFeeFree(alice), 10 days);
        assertEq(nav.exitFeeBpsNow(alice), nav.exitFeeBps(alice));

        vm.warp(depositedAt + 3 days);
        assertEq(nav.timeUntilZeroExitFee(alice), 7 days);
        assertEq(nav.secondsUntilFeeFree(alice), 7 days);
    }

    function testPreviewRedeemMatchesRedeem() public {
        _setExitFeeConfig(0, 10 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint64 depositedAt = nav.lastDepositTime(alice);
        vm.warp(depositedAt + 2 days);

        uint256 shares = nav.balanceOf(alice) / 2;
        (uint256 bnbOut, uint256 exitFee, uint256 redeemFee) = nav.previewRedeem(alice, shares);

        uint256 currentNav = nav.nav();
        uint256 bnbOwed = (shares * currentNav) / 1e18;
        assertEq(redeemFee, (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS());
        uint256 expectedExitFee = ((bnbOwed - redeemFee) * nav.exitFeeBps(alice)) / nav.BPS();
        assertEq(exitFee, expectedExitFee);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(shares, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, bnbOut, 2);
    }

    function testPreviewDepositMatchesDeposit() public {
        (uint256 sharesOut, uint256 fee, uint256 navBefore) = nav.previewDeposit(10 ether);
        uint256 expectedFee = (10 ether * nav.MINT_FEE_BPS()) / nav.BPS();
        assertEq(fee, expectedFee);
        assertEq(navBefore, 1e18);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 minted = nav.balanceOf(alice);
        assertApproxEqAbs(minted, sharesOut, 1);
    }

    function testPreviewRedeemViewMatchesRedeem() public {
        _setExitFeeConfig(0, 10 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint64 depositedAt = nav.lastDepositTime(alice);
        vm.warp(depositedAt + 2 days);

        uint256 shares = nav.balanceOf(alice) / 2;
        vm.prank(alice);
        (uint256 bnbOut, uint256 feeBps, uint256 fee, uint256 navValue) = nav.previewRedeem(shares);

        uint256 bnbOwed = (shares * navValue) / 1e18;
        uint256 redeemFee = (bnbOwed * nav.REDEEM_FEE_BPS()) / nav.BPS();
        assertEq(feeBps, nav.exitFeeBps(alice));
        assertEq(fee, ((bnbOwed - redeemFee) * feeBps) / nav.BPS());

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.redeem(shares, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, bnbOut, 2);
    }

    function testUserPositionAndLiquidityStatusViews() public {
        _setExitFeeConfig(0, 10 days, 500);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        (
            uint256 shares,
            uint256 estimatedBnbValue,
            uint64 lastDeposit,
            uint256 currentExitFeeBps,
            uint256 secondsUntilFree
        ) = nav.userPosition(alice);

        assertEq(shares, nav.balanceOf(alice));
        assertEq(estimatedBnbValue, (shares * nav.nav()) / 1e18);
        assertEq(lastDeposit, nav.lastDepositTime(alice));
        assertEq(currentExitFeeBps, nav.exitFeeBps(alice));
        assertEq(secondsUntilFree, nav.timeUntilZeroExitFee(alice));

        (uint256 liquidBNB, uint256 strategyAssets, uint256 obligations, uint256 bufferTarget, uint256 bufferBps) =
            nav.liquidityStatus();

        assertEq(liquidBNB, address(nav).balance);
        assertEq(strategyAssets, 0);
        assertEq(obligations, nav.totalLiabilitiesBNB() + nav.totalClaimableBNB());
        assertEq(bufferTarget, ((liquidBNB + strategyAssets) * nav.liquidityBufferBPS()) / nav.BPS());
        assertEq(bufferBps, nav.liquidityBufferBPS());
    }

    function testPreviewEmergencyRedeemMatchesEmergencyRedeem() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 shares = nav.balanceOf(alice) / 2;
        (uint256 bnbOut, uint256 fee) = nav.previewEmergencyRedeem(shares);

        uint256 currentNav = nav.nav();
        uint256 bnbOwed = (shares * currentNav) / 1e18;
        assertEq(fee, _emergencyFee(bnbOwed));

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(shares, 0);
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, bnbOut, 2);
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
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
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

    function testEmergencyRedeemReturnsAtLeastOneWei() public {
        vm.prank(alice);
        nav.deposit{value: 10}(0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(1, 0);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1);
    }

    function testRedeemPaysQueueBeforeNewRedemption() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 400 ether}(0);

        _setTotalClaimable(1);
        _seedQueue(alice, 40, 1 ether);

        uint256 liabilities = nav.totalLiabilitiesBNB();
        if (liabilities == 0) {
            return;
        }
        mock.setMaxWithdraw(100 ether);
        uint256 headBefore = nav.queueHead();
        uint256 queueLengthBefore = nav.queueLength();
        vm.prank(alice);
        nav.claim();
        uint256 headAfter = nav.queueHead();

        uint256 remainingBefore = queueLengthBefore - headBefore;
        uint256 expected = remainingBefore > nav.DEFAULT_MAX_STEPS() ? nav.DEFAULT_MAX_STEPS() : remainingBefore;
        if (headAfter == 0) {
            assertEq(nav.queueLength(), remainingBefore - expected);
        } else {
            assertEq(headAfter - headBefore, expected);
        }
    }

    function testClaimBoundedStepsProgresses() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 400 ether}(0);

        _setTotalClaimable(1);
        _seedQueue(alice, 40, 1 ether);

        mock.setMaxWithdraw(100 ether);
        uint256 headBefore = nav.queueHead();
        uint256 queueLengthBefore = nav.queueLength();
        vm.prank(alice);
        nav.claim();
        uint256 headAfter = nav.queueHead();

        vm.prank(alice);
        nav.claim();
        uint256 headAfterSecond = nav.queueHead();

        uint256 remainingBefore = queueLengthBefore - headBefore;
        uint256 expected = remainingBefore > nav.DEFAULT_MAX_STEPS() ? nav.DEFAULT_MAX_STEPS() : remainingBefore;
        if (headAfter == 0) {
            assertEq(nav.queueLength(), remainingBefore - expected);
        } else {
            assertEq(headAfter - headBefore, expected);
        }
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

    function testEmergencyRedeemInKindOnlyVaultBalances() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 feeShares = _emergencyShareFee(tokenAmount);
        uint256 netShares = tokenAmount - feeShares;
        uint256 expectedBnb = (address(nav).balance * netShares) / nav.totalSupply();

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeemInKind(tokenAmount);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, expectedBnb);
    }

    function testEmergencyRedeemInKindOnlyStrategyBalances() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        ankr.mint(address(mock), 4 ether);
        wbnb.mint(address(mock), 3 ether);

        uint256 tokenAmount = nav.balanceOf(alice);
        uint256 feeShares = _emergencyShareFee(tokenAmount);
        uint256 netShares = tokenAmount - feeShares;
        uint256 supply = nav.totalSupply();
        uint256 expectedBnb = (address(mock).balance * netShares) / supply;
        uint256 expectedAnkr = (ankr.balanceOf(address(mock)) * netShares) / supply;
        uint256 expectedWbnb = (wbnb.balanceOf(address(mock)) * netShares) / supply;

        uint256 bnbBefore = alice.balance;
        uint256 ankrBefore = ankr.balanceOf(alice);
        uint256 wbnbBefore = wbnb.balanceOf(alice);
        vm.prank(alice);
        nav.emergencyRedeemInKind(tokenAmount);

        assertEq(alice.balance - bnbBefore, expectedBnb);
        assertEq(ankr.balanceOf(alice) - ankrBefore, expectedAnkr);
        assertEq(wbnb.balanceOf(alice) - wbnbBefore, expectedWbnb);
    }

    function testEmergencyRedeemInKindMixedBalances() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(5_000);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        ankr.mint(address(mock), 2 ether);
        wbnb.mint(address(mock), 1 ether);
        vm.deal(address(nav), address(nav).balance + 1 ether);

        uint256 tokenAmount = nav.balanceOf(alice) / 2;
        uint256 feeShares = _emergencyShareFee(tokenAmount);
        uint256 netShares = tokenAmount - feeShares;
        uint256 supply = nav.totalSupply();
        uint256 expectedVaultBnb = (address(nav).balance * netShares) / supply;
        uint256 expectedStrategyBnb = (address(mock).balance * netShares) / supply;
        uint256 expectedAnkr = (ankr.balanceOf(address(mock)) * netShares) / supply;
        uint256 expectedWbnb = (wbnb.balanceOf(address(mock)) * netShares) / supply;

        uint256 bnbBefore = alice.balance;
        uint256 ankrBefore = ankr.balanceOf(alice);
        uint256 wbnbBefore = wbnb.balanceOf(alice);
        vm.prank(alice);
        nav.emergencyRedeemInKind(tokenAmount);

        assertEq(alice.balance - bnbBefore, expectedVaultBnb + expectedStrategyBnb);
        assertEq(ankr.balanceOf(alice) - ankrBefore, expectedAnkr);
        assertEq(wbnb.balanceOf(alice) - wbnbBefore, expectedWbnb);
    }

    function testEmergencyRedeemInKindSmallAmountPaysOut() public {
        vm.prank(alice);
        nav.deposit{value: 1}(0);

        uint256 shares = nav.balanceOf(alice);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeemInKind(shares);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1);
    }

    function testEmergencyRedeemInKindRejectsZeroPayout() public {
        stdstore.target(address(nav)).sig("totalSupply()").checked_write(1e18);
        stdstore.target(address(nav)).sig("balanceOf(address)").with_key(alice).checked_write(1e18);
        vm.deal(address(nav), 1);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NoProgress.selector);
        nav.emergencyRedeemInKind(1e18);
    }

    function testWithdrawClaimablePaysPartialWhenStrategyPartial() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setAssets(2 ether);
        mock.setMaxWithdraw(1 ether);
        vm.deal(address(mock), 2 ether);

        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(2 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(2 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.withdrawClaimable(0);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1 ether);
        assertEq(nav.claimableBNB(alice), 1 ether);
        assertEq(nav.totalClaimableBNB(), 1 ether);
    }

    function testQueuedBNBTracksEntriesAndClaim() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);

        vm.prank(alice);
        nav.redeem(nav.balanceOf(alice) / 2, 0);

        uint256 queued = nav.queuedBNB(alice);
        assertGt(queued, 0);

        vm.deal(address(nav), queued);
        vm.prank(alice);
        nav.claim(1, true);

        assertEq(nav.queuedBNB(alice), 0);
    }

    function testQueuedBNBZeroedWhenCreditClaimable() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(100 ether);

        ToggleReceiver bad = new ToggleReceiver(nav);
        bad.setRevert(true);
        vm.deal(address(bad), 10 ether);
        bad.deposit{value: 5 ether}(0);
        _seedQueue(bob, 1, 2 ether);
        mock.setMaxWithdraw(1 ether);
        vm.deal(address(nav), 0);
        bad.redeem(nav.balanceOf(address(bad)), 0);

        uint256 queuedBefore = nav.queuedBNB(address(bad));
        assertGt(queuedBefore, 0);

        vm.deal(address(nav), queuedBefore);
        bad.setRevert(false);
        vm.prank(alice);
        nav.claim(1, true);

        assertEq(nav.queuedBNB(address(bad)), 0);
    }

    function testPreviewWithdrawClaimableMatchesWithdraw() public {
        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(1 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(1 ether);
        vm.deal(address(nav), 0.4 ether);

        (uint256 previewPayout, uint256 previewClaimable) = nav.previewWithdrawClaimable(alice);
        assertEq(previewClaimable, 1 ether);
        assertEq(previewPayout, 0.4 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.withdrawClaimable(0, true);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, previewPayout);
    }

    function testQueueHeadRevertEscrowsAndMovesOn() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        vm.expectRevert(NavBNBv2.QueueEmpty.selector);
        nav.claim(1);
        assertEq(address(bad).balance, receiverBalanceBefore);
    }

    function testQueueHeadFailureDoesNotLimitLaterPayments() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        assertEq(alicePaid, aliceQueued - 1);
        assertEq(nav.queueHead(), 1);
        (, uint256 remainingAliceQueued) = nav.getQueueEntry(1);
        assertEq(remainingAliceQueued, 1);
    }

    function testQueueGasStipendCreditsClaimableAndPaysNext() public {
        GasBurnerReceiver bad = new GasBurnerReceiver();
        bad.setBurnLoops(100_000);

        address good = address(0xB0B0);
        vm.deal(address(nav), 2 ether);
        _setQueueLength(2);
        _setQueueEntry(0, address(bad), 1 ether);
        _setQueueEntry(1, good, 1 ether);
        _setQueueHead(0);
        stdstore.target(address(nav)).sig("totalLiabilitiesBNB()").checked_write(2 ether);

        uint256 badBalanceBefore = address(bad).balance;
        uint256 goodBalanceBefore = good.balance;
        vm.prank(alice);
        nav.claim(2);
        uint256 goodBalanceAfter = good.balance;

        assertEq(goodBalanceAfter - goodBalanceBefore, 1 ether);
        assertEq(address(bad).balance, badBalanceBefore);
        assertEq(nav.claimableBNB(address(bad)), 1 ether);
        assertEq(nav.totalLiabilitiesBNB(), 0);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.QueueEmpty.selector);
        nav.claim(1);
        assertEq(nav.claimableBNB(address(bad)), 1 ether);
    }

    function testWithdrawClaimablePaysOut() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        MockBNBYieldStrategy mock = _newMockStrategy();
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
        vm.expectRevert(NavBNBv2.NoLiquidity.selector);
        nav.withdrawClaimable(0);

        assertEq(nav.claimableBNB(alice), 1);
    }

    function testWithdrawClaimableBestEffortKeepsRemainder() public {
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setAssets(3 ether);
        mock.setMaxWithdraw(1 ether);
        vm.deal(address(mock), 3 ether);
        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(2 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(2 ether);
        _seedQueue(bob, 1, 1 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.withdrawClaimable(0, true);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1 ether);
        assertEq(nav.claimableBNB(alice), 1 ether);
        assertEq(nav.totalClaimableBNB(), 1 ether);
    }

    function testClaimRejectsDustWithoutAccept() public {
        _setMinPayout(1 ether);
        vm.deal(address(nav), 0.5 ether);
        _seedQueue(alice, 1, 0.5 ether);

        uint256 headBefore = nav.queueHead();
        uint256 liabilitiesBefore = nav.totalLiabilitiesBNB();
        (, uint256 amountBefore) = nav.getQueueEntry(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NavBNBv2.PayoutTooSmall.selector, 0.5 ether, 1 ether));
        nav.claim(1, false);
        assertEq(nav.queueHead(), headBefore);
        assertEq(nav.totalLiabilitiesBNB(), liabilitiesBefore);
        (, uint256 amountAfter) = nav.getQueueEntry(0);
        assertEq(amountAfter, amountBefore);
    }

    function testClaimAcceptsDustWithOverride() public {
        _setMinPayout(1 ether);
        vm.deal(address(nav), 0.5 ether);
        _seedQueue(alice, 1, 0.5 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.claim(1, true);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 0.5 ether);
    }

    function testClaimRejectsZeroPayoutEntry() public {
        _setQueueLength(1);
        _setQueueEntry(0, alice, 0);
        _setQueueHead(0);
        stdstore.target(address(nav)).sig("totalLiabilitiesBNB()").checked_write(1 ether);
        vm.deal(address(nav), 1 ether);

        vm.prank(alice);
        vm.expectRevert(NavBNBv2.NoLiquidity.selector);
        nav.claim(1);
    }

    function testEmergencyRedeemIgnoresQueueState() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        _seedQueue(bob, 1, 1 ether);

        uint256 shares = nav.balanceOf(alice) / 2;
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nav.emergencyRedeem(shares, 0);
        uint256 balanceAfter = alice.balance;

        assertGt(balanceAfter - balanceBefore, 0);
        assertGt(nav.totalLiabilitiesBNB(), 0);
    }

    function testDepositAllowedWithQueue() public {
        vm.prank(alice);
        nav.deposit{value: 10 ether}(0);
        _seedQueue(alice, 1, 1 ether);

        vm.prank(bob);
        nav.deposit{value: 1 ether}(0);
        assertGt(nav.balanceOf(bob), 0);
    }

    function testEmergencyRedeemRejectsDustPayout() public {
        _setMinPayout(1 ether);
        vm.prank(alice);
        nav.deposit{value: 1 ether}(0);

        uint256 shares = nav.balanceOf(alice) / 2;
        uint256 supplyBefore = nav.totalSupply();
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        (uint256 bnbOut,) = nav.previewEmergencyRedeem(shares);
        vm.expectRevert(abi.encodeWithSelector(NavBNBv2.PayoutTooSmall.selector, bnbOut, 1 ether));
        nav.emergencyRedeem(shares, 0);
        assertEq(nav.totalSupply(), supplyBefore);
        assertEq(alice.balance, balanceBefore);
    }

    function testWithdrawClaimableRejectsPayoutBelowMinimum() public {
        _setMinPayout(1 ether);
        stdstore.target(address(nav)).sig("claimableBNB(address)").with_key(alice).checked_write(0.5 ether);
        stdstore.target(address(nav)).sig("totalClaimableBNB()").checked_write(0.5 ether);
        vm.deal(address(nav), 0.5 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NavBNBv2.PayoutTooSmall.selector, 0.5 ether, 1 ether));
        nav.withdrawClaimable(0);

        assertEq(nav.claimableBNB(alice), 0.5 ether);
        assertEq(nav.totalClaimableBNB(), 0.5 ether);
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
        uint256 head = nav.queueHead();
        (address expectedUser,) = nav.getQueueEntry(nav.queueHead());

        nav.compactQueue(remaining + head);

        assertEq(nav.queueHead(), 0);
        assertEq(nav.queueLength(), remaining);
        (address compactedUser,) = nav.getQueueEntry(0);
        assertEq(compactedUser, expectedUser);
    }

    function testCompactQueuePartialMovesProgress() public {
        _setQueueLength(6);
        _setQueueEntry(0, alice, 1 ether);
        _setQueueEntry(1, bob, 1 ether);
        _setQueueEntry(2, recovery, 1 ether);
        _setQueueEntry(3, address(0x1111), 1 ether);
        _setQueueEntry(4, address(0x2222), 1 ether);
        _setQueueEntry(5, address(0x3333), 1 ether);
        _setQueueHead(2);

        uint256 remaining = nav.queueLength() - nav.queueHead();
        for (uint256 i = 0; i < remaining + nav.queueHead(); i++) {
            nav.compactQueue(1);
        }

        assertEq(nav.queueHead(), 0);
        assertEq(nav.queueLength(), remaining);
        (address firstUser,) = nav.getQueueEntry(0);
        assertEq(firstUser, recovery);
    }

    function testCompactQueueBoundedReducesStorageOverTime() public {
        uint256 len = 80;
        uint256 head = 40;
        _setQueueLength(len);
        for (uint256 i = 0; i < len; i++) {
            _setQueueEntry(i, address(uint160(0x2000 + i)), 1 ether);
        }
        _setQueueHead(head);

        uint256 remaining = len - head;
        for (uint256 i = 0; i < 20; i++) {
            nav.compactQueue(5);
        }

        assertEq(nav.queueHead(), 0);
        assertEq(nav.queueLength(), remaining);
    }

    function testAutoCompactionMaintainsQueueInvariants() public {
        uint256 minEntry = 0.01 ether;
        _setMinQueueEntry(minEntry);
        MockBNBYieldStrategy mock = _newMockStrategy();
        _activateStrategy(address(mock));
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);
        mock.setMaxWithdraw(1);

        vm.prank(alice);
        nav.deposit{value: 5 ether}(0);

        address[] memory users = new address[](5);
        for (uint256 i = 0; i < users.length; i++) {
            users[i] = address(uint160(0x1000 + i));
            vm.deal(users[i], 5 ether);
            vm.prank(users[i]);
            nav.deposit{value: 1 ether}(0);
        }

        uint256 entries = 40;
        address[] memory order = new address[](entries);
        uint256[] memory amounts = new uint256[](entries);
        for (uint256 i = 0; i < entries; i++) {
            address user = users[i % users.length];
            uint256 bnbTarget = nav.effectiveMinQueueEntry() * 2;
            uint256 shares = (bnbTarget * 1e18) / nav.nav();
            if (shares == 0) {
                shares = 1;
            }
            if (shares > nav.balanceOf(user)) {
                vm.prank(user);
                nav.deposit{value: 1 ether}(0);
            }
            (uint256 bnbOut,,) = nav.previewRedeem(user, shares);
            order[i] = user;
            amounts[i] = bnbOut;
            vm.prank(user);
            nav.redeem(shares, 0);
        }

        mock.setMaxWithdraw(100 ether);
        uint256 totalEntries = nav.queueLength();
        uint256 paySteps = 33;
        vm.prank(alice);
        nav.claim(paySteps);

        uint256 remaining = totalEntries - paySteps;
        assertEq(nav.queueHead(), 0);
        assertEq(nav.queueLength(), remaining);

        uint256 remainingStart = paySteps;
        (address headUser,) = nav.getQueueEntry(0);
        assertEq(headUser, order[remainingStart]);

        uint256 sum;
        for (uint256 i = 0; i < remaining; i++) {
            (, uint256 amount) = nav.getQueueEntry(i);
            sum += amount;
        }
        assertEq(nav.totalLiabilitiesBNB(), sum);
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
        vm.prank(address(0xBEEF));
        nav.setMinPayoutWei(1);
        vm.prank(address(0xBEEF));
        nav.setMinQueueEntryWei(1);
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

    function invariantTotalAssetsAboveObligations() public view {
        assertGe(nav.totalAssets(), nav.totalObligations());
    }

    function invariantClaimableTotalMatchesSum() public view {
        uint256 claimableSum;
        uint256 participants = handler.participantCount();
        for (uint256 i = 0; i < participants; i++) {
            address participant = handler.participants(i);
            claimableSum += nav.claimableBNB(participant);
        }
        assertEq(nav.totalClaimableBNB(), claimableSum);
    }

    function invariantNoDeadEnds() public {
        uint256 participants = handler.participantCount();
        for (uint256 i = 0; i < participants; i++) {
            address participant = handler.participants(i);
            uint256 shares = nav.balanceOf(participant);
            uint256 claimable = nav.claimableBNB(participant);
            uint256 queued = nav.queuedBNB(participant);
            if (shares == 0 && claimable == 0 && queued == 0) {
                continue;
            }
            if (nav.totalAssets() < nav.totalObligations()) {
                continue;
            }
            bool ok = false;
            if (claimable > 0) {
                ok = _canCall(participant, abi.encodeWithSignature("withdrawClaimable(uint256,bool)", 0, true));
            }
            if (!ok && shares > 0) {
                ok = _canCall(participant, abi.encodeWithSignature("emergencyRedeem(uint256,uint256)", shares, 0));
            }
            if (!ok && queued > 0) {
                ok = _canCall(participant, abi.encodeWithSignature("claim(uint256,bool)", 32, true));
            }
            assertTrue(ok, "dead-end: user owed value but no path works");
        }
    }

    function _canCall(address user, bytes memory data) internal returns (bool ok) {
        vm.prank(user);
        (ok,) = address(nav).call(data);
    }
}
