// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {NavBNBv2} from "src/NavBNBv2.sol";
import {AnkrBNBYieldStrategy} from "src/strategies/AnkrBNBYieldStrategy.sol";
import {MockAnkrPool} from "test/mocks/MockAnkrPool.sol";
import {MockERC20, MockWBNB} from "test/mocks/MockERC20.sol";
import {MockERC20NoReturn} from "test/mocks/MockERC20NoReturn.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";
import {MockPancakePair} from "test/mocks/MockPancakePair.sol";

contract AnkrBNBYieldStrategyTest is Test {
    uint256 private constant ONE = 1e18;

    AnkrBNBYieldStrategy internal strategy;
    MockAnkrPool internal pool;
    MockERC20 internal ankrBNB;
    MockWBNB internal wbnb;
    MockRouter internal router;
    MockPancakePair internal pair;

    address internal guardian = address(0xBEEF);
    address internal recovery = address(0xCAFE);
    address internal alice = address(0xA11CE);

    receive() external payable {}

    function setUp() public {
        ankrBNB = new MockERC20("ankrBNB", "ankrBNB");
        wbnb = new MockWBNB();
        pool = new MockAnkrPool(address(ankrBNB), ONE);
        router = new MockRouter(address(ankrBNB), address(wbnb));
        pair = new MockPancakePair(address(ankrBNB), address(wbnb));
        strategy = new AnkrBNBYieldStrategy(
            address(this),
            guardian,
            address(pool),
            address(ankrBNB),
            address(router),
            address(wbnb),
            recovery,
            address(pair)
        );

        wbnb.mint(address(router), 1_000 ether);
        vm.deal(address(wbnb), 1_000 ether);
        vm.deal(address(this), 1_000 ether);
        vm.deal(alice, 100 ether);
        _primeTwap(1e18);
    }

    function _primeTwap(uint256 price) internal {
        pair.setReserves(100 ether, uint112((100 ether * price) / ONE));
        strategy.updateTwap();
        vm.warp(block.timestamp + strategy.MIN_TWAP_ELAPSED());
        pair.setReserves(100 ether, uint112((100 ether * price) / ONE));
        strategy.updateTwap();
    }

    function _primeTwapFor(AnkrBNBYieldStrategy localStrategy, MockPancakePair localPair, uint256 price) internal {
        localPair.setReserves(100 ether, uint112((100 ether * price) / ONE));
        localStrategy.updateTwap();
        vm.warp(block.timestamp + localStrategy.MIN_TWAP_ELAPSED());
        localPair.setReserves(100 ether, uint112((100 ether * price) / ONE));
        localStrategy.updateTwap();
    }

    function testDepositMintsAnkrBNBAndIncreasesTotalAssets() public {
        strategy.deposit{value: 10 ether}();

        assertEq(ankrBNB.balanceOf(address(strategy)), 10 ether);
        uint256 expected = (10 ether * (strategy.BPS() - strategy.valuationHaircutBps())) / strategy.BPS();
        assertEq(strategy.totalAssets(), expected);
    }

    function testTotalAssetsTracksExchangeRatioYield() public {
        strategy.deposit{value: 10 ether}();
        pool.setExchangeRatio((ONE * 11) / 10);

        uint256 ratioValue = (ankrBNB.balanceOf(address(strategy)) * pool.exchangeRatio()) / ONE;
        uint256 expected = (ratioValue * (strategy.BPS() - strategy.valuationHaircutBps())) / strategy.BPS();
        assertEq(strategy.totalAssets(), expected);
        assertGt(strategy.totalAssets(), 10 ether);
    }

    function testWithdrawUsesRatioForMinOut() public {
        strategy.deposit{value: 10 ether}();

        vm.prank(guardian);
        strategy.setMaxSlippageBps(100);

        pool.setExchangeRatio(2e18);
        router.setRate(2e18);
        router.setLiquidityOut(2 ether);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(1 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertGt(received, 0);
        uint256 expectedOut = (5e17 * pool.exchangeRatio()) / ONE;
        uint256 afterHaircut = (expectedOut * (strategy.BPS() - strategy.valuationHaircutBps())) / strategy.BPS();
        uint256 expectedMinOut = (afterHaircut * (strategy.BPS() - strategy.maxSlippageBps())) / strategy.BPS();
        assertEq(router.lastAmountOutMin(), expectedMinOut);
    }

    function testWithdrawCanReturnPartialWhenLiquidityLimited() public {
        strategy.deposit{value: 10 ether}();

        vm.prank(guardian);
        strategy.setMaxSlippageBps(300);

        uint256 expectedOut = 5 ether;
        uint256 availableOut = (expectedOut * 99) / 100;
        router.setLiquidityOut(availableOut);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(5 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertLt(received, 5 ether);
        assertGt(received, 0);
    }

    function testOnlyVaultCanCallDepositWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(AnkrBNBYieldStrategy.NotVault.selector);
        strategy.deposit{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert(AnkrBNBYieldStrategy.NotVault.selector);
        strategy.withdraw(1 ether);
    }

    function testGuardianCanPauseAndSetSlippageWithinBounds() public {
        vm.prank(guardian);
        strategy.setMaxSlippageBps(250);
        assertEq(strategy.maxSlippageBps(), 250);

        vm.prank(guardian);
        vm.expectRevert(AnkrBNBYieldStrategy.SlippageTooHigh.selector);
        strategy.setMaxSlippageBps(600);

        vm.prank(guardian);
        strategy.pause();
        vm.expectRevert(AnkrBNBYieldStrategy.PausedError.selector);
        strategy.deposit{value: 1 ether}();

        vm.prank(guardian);
        strategy.unpause();
        strategy.deposit{value: 1 ether}();
    }

    function testTotalAssetsAppliesValuationHaircut() public {
        strategy.deposit{value: 10 ether}();
        pool.setExchangeRatio((ONE * 101) / 100);

        vm.prank(guardian);
        strategy.setValuationHaircutBps(500);

        uint256 ratioValue = (ankrBNB.balanceOf(address(strategy)) * pool.exchangeRatio()) / ONE;
        uint256 expected = (ratioValue * (strategy.BPS() - strategy.valuationHaircutBps())) / strategy.BPS();
        assertEq(strategy.totalAssets(), expected);
        assertLt(strategy.totalAssets(), ratioValue);
    }

    function testTotalAssetsMonotonicWithHoldings() public {
        vm.prank(guardian);
        strategy.setValuationHaircutBps(500);

        strategy.deposit{value: 5 ether}();
        uint256 assetsBefore = strategy.totalAssets();

        strategy.deposit{value: 5 ether}();
        uint256 assetsAfter = strategy.totalAssets();

        assertGt(assetsAfter, assetsBefore);
    }

    function testRecoverTokenRequiresPauseAndProtectsCoreAssets() public {
        MockERC20 misc = new MockERC20("misc", "misc");
        misc.mint(address(strategy), 10 ether);

        vm.expectRevert(AnkrBNBYieldStrategy.NotPaused.selector);
        vm.prank(guardian);
        strategy.recoverToken(address(misc), address(this), 1 ether);

        vm.prank(guardian);
        strategy.pause();

        vm.expectRevert(AnkrBNBYieldStrategy.InvalidRecoveryToken.selector);
        vm.prank(guardian);
        strategy.recoverToken(address(ankrBNB), address(this), 1 ether);

        vm.expectRevert(AnkrBNBYieldStrategy.InvalidRecoveryToken.selector);
        vm.prank(guardian);
        strategy.recoverToken(address(wbnb), address(this), 1 ether);

        vm.expectRevert(AnkrBNBYieldStrategy.InvalidRecipient.selector);
        vm.prank(guardian);
        strategy.recoverToken(address(misc), address(0x1234), 1 ether);

        vm.prank(guardian);
        strategy.recoverToken(address(misc), recovery, 1 ether);
        assertEq(misc.balanceOf(recovery), 1 ether);
    }

    function testWithdrawAllToVaultEmptiesStrategy() public {
        strategy.deposit{value: 5 ether}();

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdrawAllToVault();
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertEq(strategy.totalAssets(), 0);
        assertEq(ankrBNB.balanceOf(address(strategy)), 0);
    }

    function testWithdrawClampsToHoldingsWhenRequestExceedsBalance() public {
        strategy.deposit{value: 5 ether}();

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(10 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertEq(received, 5 ether);
        assertEq(strategy.totalAssets(), 0);
    }

    function testWithdrawSupportsApproveNoReturnToken() public {
        MockERC20NoReturn noReturnToken = new MockERC20NoReturn("ankrBNB", "ankrBNB");
        MockWBNB localWbnb = new MockWBNB();
        MockAnkrPool localPool = new MockAnkrPool(address(noReturnToken), ONE);
        MockRouter localRouter = new MockRouter(address(noReturnToken), address(localWbnb));
        MockPancakePair localPair = new MockPancakePair(address(noReturnToken), address(localWbnb));
        AnkrBNBYieldStrategy localStrategy = new AnkrBNBYieldStrategy(
            address(this),
            guardian,
            address(localPool),
            address(noReturnToken),
            address(localRouter),
            address(localWbnb),
            recovery,
            address(localPair)
        );
        _primeTwapFor(localStrategy, localPair, 1e18);

        localWbnb.mint(address(localRouter), 10 ether);
        vm.deal(address(localWbnb), 10 ether);

        localStrategy.deposit{value: 5 ether}();
        uint256 balanceBefore = address(this).balance;
        uint256 received = localStrategy.withdraw(1 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertGt(received, 0);
    }

    function testSwapDeadlineUsesBuffer() public {
        strategy.deposit{value: 1 ether}();
        vm.prank(guardian);
        strategy.setDeadlineSeconds(600);

        uint256 expectedDeadline = block.timestamp + 600;
        strategy.withdraw(1 ether);
        assertEq(router.lastDeadline(), expectedDeadline);
    }

    function testSwapDeadlineUsesDefaultBuffer() public {
        strategy.deposit{value: 1 ether}();

        uint256 expectedDeadline = block.timestamp + 300;
        strategy.withdraw(1 ether);
        assertEq(router.lastDeadline(), expectedDeadline);
    }

    function testDeadlineSecondsBounds() public {
        vm.prank(guardian);
        vm.expectRevert(AnkrBNBYieldStrategy.InvalidDeadline.selector);
        strategy.setDeadlineSeconds(0);

        uint32 maxDeadline = uint32(strategy.MAX_DEADLINE_SECONDS());
        vm.prank(guardian);
        vm.expectRevert(AnkrBNBYieldStrategy.InvalidDeadline.selector);
        strategy.setDeadlineSeconds(maxDeadline + 1);
    }

    function testSwapChunkingSplitsLargeSwap() public {
        strategy.deposit{value: 10 ether}();
        vm.prank(guardian);
        strategy.setMaxChunkAnkr(2 ether);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(9 ether);
        uint256 balanceAfter = address(this).balance;

        assertGt(router.swapCallCount(), 1);
        assertEq(received, balanceAfter - balanceBefore);
        assertEq(received, 9 ether);
    }

    function testWithdrawRevertsOnTwapDeviation() public {
        strategy.deposit{value: 1 ether}();
        vm.prank(guardian);
        strategy.setMaxDeviationBps(100);
        router.setRate(5e17);

        vm.expectRevert(abi.encodeWithSelector(AnkrBNBYieldStrategy.TwapDeviation.selector, 5e17, 1e18));
        strategy.withdraw(1 ether);
    }

    function testMulDivUpHandlesLargeValues() public {
        AnkrBNBYieldStrategyHarness harness = new AnkrBNBYieldStrategyHarness(
            address(this),
            guardian,
            address(pool),
            address(ankrBNB),
            address(router),
            address(wbnb),
            recovery,
            address(pair)
        );
        uint256 a = type(uint128).max;
        uint256 b = 1e18;
        uint256 denominator = 1e18 - 1;
        uint256 product = a * b;
        uint256 expected = product / denominator + (product % denominator == 0 ? 0 : 1);
        uint256 value = harness.exposedMulDivUp(a, b, denominator);
        assertEq(value, expected);
    }

    function testWbnbDustDoesNotBlockWithdrawAll() public {
        wbnb.mint(address(strategy), 1 ether);
        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdrawAllToVault();
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertEq(received, 1 ether);
    }

    function testWithdrawContinuesOnRatioJump() public {
        strategy.deposit{value: 1 ether}();
        uint256 lastGood = strategy.lastRatio();
        pool.setExchangeRatio((ONE * 120) / 100);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(1 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertGt(received, 0);
        assertEq(strategy.lastRatio(), lastGood);
    }

    function testWithdrawClampsLowRatioOutOfBounds() public {
        strategy.deposit{value: 1 ether}();
        pool.setExchangeRatio(5e17);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(1 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertGt(received, 0);
    }

    function testWithdrawClampsHighRatioOutOfBounds() public {
        strategy.deposit{value: 1 ether}();
        pool.setExchangeRatio(3e18);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(1 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertGt(received, 0);
    }

    function testWbnbDustIsUnwrappedOnWithdraw() public {
        strategy.deposit{value: 1 ether}();
        wbnb.mint(address(strategy), 1 ether);

        uint256 balanceBefore = address(this).balance;
        uint256 received = strategy.withdraw(1 ether);
        uint256 balanceAfter = address(this).balance;

        assertEq(received, balanceAfter - balanceBefore);
        assertEq(received, 2 ether);
    }
}

contract AnkrBNBYieldStrategyHarness is AnkrBNBYieldStrategy {
    constructor(
        address vault_,
        address guardian_,
        address bnbStakingPool_,
        address ankrBNB_,
        address router_,
        address wbnb_,
        address recovery_,
        address twapPair_
    ) AnkrBNBYieldStrategy(vault_, guardian_, bnbStakingPool_, ankrBNB_, router_, wbnb_, recovery_, twapPair_) {}

    function exposedMulDivUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return _mulDivUp(a, b, denominator);
    }
}

contract NavBNBv2StrategyWiringTest is Test {
    function _deployStrategyForVault(
        address vault,
        address guardian,
        MockAnkrPool pool,
        MockERC20 ankrBNB,
        MockRouter router,
        MockWBNB wbnb,
        MockPancakePair pair
    ) internal returns (AnkrBNBYieldStrategy) {
        vm.prank(vault);
        return new AnkrBNBYieldStrategy(
            vault,
            guardian,
            address(pool),
            address(ankrBNB),
            address(router),
            address(wbnb),
            address(0xCAFE),
            address(pair)
        );
    }

    function _primeTwap(AnkrBNBYieldStrategy strategy, MockPancakePair pair, uint256 price) internal {
        pair.setReserves(100 ether, uint112((100 ether * price) / 1e18));
        strategy.updateTwap();
        vm.warp(block.timestamp + strategy.MIN_TWAP_ELAPSED());
        pair.setReserves(100 ether, uint112((100 ether * price) / 1e18));
        strategy.updateTwap();
    }

    function _deployFreshStrategy(NavBNBv2 nav, address guardian) internal returns (AnkrBNBYieldStrategy strategy) {
        MockERC20 ankrBNBNext = new MockERC20("ankrBNB", "ankrBNB");
        MockWBNB wbnbNext = new MockWBNB();
        MockAnkrPool poolNext = new MockAnkrPool(address(ankrBNBNext), 1e18);
        MockRouter routerNext = new MockRouter(address(ankrBNBNext), address(wbnbNext));
        MockPancakePair pairNext = new MockPancakePair(address(ankrBNBNext), address(wbnbNext));
        strategy =
            _deployStrategyForVault(address(nav), guardian, poolNext, ankrBNBNext, routerNext, wbnbNext, pairNext);
        _primeTwap(strategy, pairNext, 1e18);
    }

    function testNavBNBv2CanSetAnkrStrategyWhenEmpty() public {
        address guardian = address(0xBEEF);
        address recovery = address(0xCAFE);
        NavBNBv2 nav = new NavBNBv2(guardian, recovery);

        MockERC20 ankrBNB = new MockERC20("ankrBNB", "ankrBNB");
        MockWBNB wbnb = new MockWBNB();
        MockAnkrPool pool = new MockAnkrPool(address(ankrBNB), 1e18);
        MockRouter router = new MockRouter(address(ankrBNB), address(wbnb));
        MockPancakePair pair = new MockPancakePair(address(ankrBNB), address(wbnb));
        AnkrBNBYieldStrategy strategy =
            _deployStrategyForVault(address(nav), guardian, pool, ankrBNB, router, wbnb, pair);
        _primeTwap(strategy, pair, 1e18);

        vm.prank(guardian);
        nav.proposeStrategy(address(strategy));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        nav.activateStrategy();
        assertEq(address(nav.strategy()), address(strategy));
    }

    function testStrategyWithdrawAllAllowsStrategySwitch() public {
        address guardian = address(0xBEEF);
        address recovery = address(0xCAFE);
        NavBNBv2 nav = new NavBNBv2(guardian, recovery);

        MockERC20 ankrBNB = new MockERC20("ankrBNB", "ankrBNB");
        MockWBNB wbnb = new MockWBNB();
        MockAnkrPool pool = new MockAnkrPool(address(ankrBNB), 1e18);
        MockRouter router = new MockRouter(address(ankrBNB), address(wbnb));
        MockPancakePair pair = new MockPancakePair(address(ankrBNB), address(wbnb));
        AnkrBNBYieldStrategy strategy =
            _deployStrategyForVault(address(nav), guardian, pool, ankrBNB, router, wbnb, pair);
        _primeTwap(strategy, pair, 1e18);

        vm.prank(guardian);
        nav.proposeStrategy(address(strategy));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        nav.activateStrategy();

        wbnb.mint(address(router), 20 ether);
        vm.deal(address(wbnb), 20 ether);
        vm.deal(address(nav), 10 ether);
        vm.prank(address(nav));
        strategy.deposit{value: 10 ether}();
        assertGt(strategy.totalAssets(), 0);

        vm.prank(address(nav));
        strategy.withdrawAllToVault();
        assertEq(strategy.totalAssets(), 0);

        AnkrBNBYieldStrategy nextStrategy = _deployFreshStrategy(nav, guardian);

        vm.prank(guardian);
        nav.proposeStrategy(address(nextStrategy));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        nav.activateStrategy();
        assertEq(address(nav.strategy()), address(nextStrategy));
    }

    function testEmergencyRedeemInKindBypassesTwapDeviation() public {
        address guardian = address(0xBEEF);
        address recovery = address(0xCAFE);
        NavBNBv2 nav = new NavBNBv2(guardian, recovery);

        MockERC20 ankrBNB = new MockERC20("ankrBNB", "ankrBNB");
        MockWBNB wbnb = new MockWBNB();
        MockAnkrPool pool = new MockAnkrPool(address(ankrBNB), 1e18);
        MockRouter router = new MockRouter(address(ankrBNB), address(wbnb));
        MockPancakePair pair = new MockPancakePair(address(ankrBNB), address(wbnb));
        AnkrBNBYieldStrategy strategy =
            _deployStrategyForVault(address(nav), guardian, pool, ankrBNB, router, wbnb, pair);
        _primeTwap(strategy, pair, 1e18);

        vm.prank(guardian);
        nav.proposeStrategy(address(strategy));
        vm.warp(nav.strategyActivationTime());
        vm.prank(guardian);
        nav.activateStrategy();
        vm.prank(guardian);
        nav.setLiquidityBufferBPS(0);

        wbnb.mint(address(router), 20 ether);
        vm.deal(address(wbnb), 20 ether);
        vm.deal(address(this), 10 ether);
        nav.deposit{value: 10 ether}(0);

        vm.prank(guardian);
        strategy.setMaxDeviationBps(100);
        router.setRate(5e17);

        uint256 shares = nav.balanceOf(address(this)) / 2;
        (uint256 bnbOut,,,) = nav.previewRedeem(shares);
        uint256 expectedSpotOut = (bnbOut * 5e17) / 1e18;
        uint256 expectedTwapOut = bnbOut;
        vm.expectRevert(
            abi.encodeWithSelector(AnkrBNBYieldStrategy.TwapDeviation.selector, expectedSpotOut, expectedTwapOut)
        );
        nav.redeem(shares, 0);

        uint256 ankrBefore = ankrBNB.balanceOf(address(this));
        nav.emergencyRedeemInKind(nav.balanceOf(address(this)));
        uint256 ankrAfter = ankrBNB.balanceOf(address(this));

        assertGt(ankrAfter - ankrBefore, 0);
    }
}
