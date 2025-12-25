// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {AnkrBNBYieldStrategy} from "src/strategies/AnkrBNBYieldStrategy.sol";

contract DeployStrategy is Script {
    function run() external returns (AnkrBNBYieldStrategy strategy) {
        address vault = vm.envAddress("VAULT");
        address guardian = vm.envAddress("GUARDIAN");
        address stakingPool = vm.envAddress("ANKR_STAKING_POOL");
        address ankrBNB = vm.envAddress("ANKR_BNB");
        address router = vm.envAddress("DEX_ROUTER");
        address wbnb = vm.envAddress("WBNB");
        address recovery = vm.envAddress("RECOVERY");

        vm.startBroadcast();
        strategy = new AnkrBNBYieldStrategy(vault, guardian, stakingPool, ankrBNB, router, wbnb, recovery);
        vm.stopBroadcast();
    }
}
