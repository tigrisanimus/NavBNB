// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {NavBNBv2} from "src/NavBNBv2.sol";

contract WireStrategyAndParams is Script {
    function run() external {
        address vaultAddress = vm.envAddress("VAULT");
        address strategy = vm.envOr("STRATEGY", address(0));
        uint256 minPayoutWei = vm.envOr("MIN_PAYOUT_WEI", uint256(1e14));
        uint256 minQueueEntryWei = vm.envOr("MIN_QUEUE_ENTRY_WEI", uint256(1e14));
        uint256 liquidityBufferBps = vm.envOr("LIQUIDITY_BUFFER_BPS", uint256(1000));
        uint256 minExitSeconds = vm.envOr("MIN_EXIT_SECONDS", uint256(0));
        uint256 fullExitSeconds = vm.envOr("FULL_EXIT_SECONDS", uint256(30 days));
        uint256 maxExitFeeBps = vm.envOr("MAX_EXIT_FEE_BPS", uint256(500));

        NavBNBv2 vault = NavBNBv2(payable(vaultAddress));

        vm.startBroadcast();
        if (strategy != address(0)) {
            vault.setStrategyTimelockSeconds(0);
            vault.setStrategy(strategy);
        }
        vault.setMinPayoutWei(minPayoutWei);
        vault.setMinQueueEntryWei(minQueueEntryWei);
        vault.setLiquidityBufferBPS(liquidityBufferBps);
        vault.setExitFeeConfig(minExitSeconds, fullExitSeconds, maxExitFeeBps);
        vm.stopBroadcast();
    }
}
