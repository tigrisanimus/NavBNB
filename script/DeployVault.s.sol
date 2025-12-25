// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {NavBNBv2} from "src/NavBNBv2.sol";

contract DeployVault is Script {
    function run() external returns (NavBNBv2 vault) {
        address guardian = vm.envAddress("GUARDIAN");
        address recovery = vm.envAddress("RECOVERY");

        vm.startBroadcast();
        vault = new NavBNBv2(guardian, recovery);
        vm.stopBroadcast();
    }
}
