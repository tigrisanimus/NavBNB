// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {NavBNBv2} from "src/NavBNBv2.sol";
import {AnkrBNBYieldStrategy} from "src/strategies/AnkrBNBYieldStrategy.sol";
import {MockAnkrPool} from "test/mocks/MockAnkrPool.sol";
import {MockERC20, MockWBNB} from "test/mocks/MockERC20.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";

contract AnkrBNBYieldStrategyTest is Test {
    uint256 private constant ONE = 1e18;

    AnkrBNBYieldStrategy internal strategy;
    MockAnkrPool internal pool;
    MockERC20 internal ankrBNB;
    MockWBNB internal wbnb;
    MockRouter internal router;

    address internal guardian = address(0xBEEF);
    address internal alice = address(0xA11CE);

    function setUp() public {
        ankrBNB = new MockERC20("ankrBNB", "ankrBNB");
        wbnb = new MockWBNB();
        pool = new MockAnkrPool(address(ankrBNB), ONE);
        router = new MockRouter(address(ankrBNB), address(wbnb));
        strategy = new AnkrBNBYieldStrategy(guardian, address(pool), address(ankrBNB), address(router), address(wbnb));

        wbnb.mint(address(router), 1_000 ether);
        vm.deal(address(this), 1_000 ether);
        vm.deal(alice, 100 ether);
    }

    function testDepositMintsAnkrBNBAndIncreasesTotalAssets() public {
        strategy.deposit{value: 10 ether}();

        assertEq(ankrBNB.balanceOf(address(strategy)), 10 ether);
        assertEq(strategy.totalAssets(), 10 ether);
    }

    function testTotalAssetsTracksExchangeRatioYield() public {
        strategy.deposit{value: 10 ether}();
        pool.setExchangeRatio((ONE * 9) / 10);

        uint256 expected = (ankrBNB.balanceOf(address(strategy)) * ONE) / pool.exchangeRatio();
        assertEq(strategy.totalAssets(), expected);
        assertGt(strategy.totalAssets(), 10 ether);
    }

    function testWithdrawUsesSwapAndRespectsSlippageBps() public {
        strategy.deposit{value: 10 ether}();

        vm.prank(guardian);
        strategy.setMaxSlippageBps(100);

        uint256 expectedOut = 1 ether;
        uint256 availableOut = (expectedOut * 98) / 100;
        router.setLiquidityOut(availableOut);

        vm.expectRevert(bytes("SLIPPAGE"));
        strategy.withdraw(1 ether);
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
        strategy.setMaxSlippageBps(400);

        vm.prank(guardian);
        strategy.pause();
        vm.expectRevert(AnkrBNBYieldStrategy.PausedError.selector);
        strategy.deposit{value: 1 ether}();

        vm.prank(guardian);
        strategy.unpause();
        strategy.deposit{value: 1 ether}();
    }
}

contract NavBNBv2StrategyWiringTest is Test {
    function _deployStrategyForVault(
        address vault,
        address guardian,
        MockAnkrPool pool,
        MockERC20 ankrBNB,
        MockRouter router,
        MockWBNB wbnb
    ) internal returns (AnkrBNBYieldStrategy) {
        vm.prank(vault);
        return new AnkrBNBYieldStrategy(guardian, address(pool), address(ankrBNB), address(router), address(wbnb));
    }

    function testNavBNBv2CanSetAnkrStrategyWhenEmpty() public {
        address guardian = address(0xBEEF);
        address recovery = address(0xCAFE);
        NavBNBv2 nav = new NavBNBv2(guardian, recovery);

        MockERC20 ankrBNB = new MockERC20("ankrBNB", "ankrBNB");
        MockWBNB wbnb = new MockWBNB();
        MockAnkrPool pool = new MockAnkrPool(address(ankrBNB), 1e18);
        MockRouter router = new MockRouter(address(ankrBNB), address(wbnb));
        AnkrBNBYieldStrategy strategy = _deployStrategyForVault(
            address(nav),
            guardian,
            pool,
            ankrBNB,
            router,
            wbnb
        );

        vm.prank(guardian);
        nav.setStrategy(address(strategy));
        assertEq(address(nav.strategy()), address(strategy));
    }
}
