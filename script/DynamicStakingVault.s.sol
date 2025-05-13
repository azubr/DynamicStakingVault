// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {DynamicStakingVault} from "../src/DynamicStakingVault.sol";

contract DynamicStakingVaultScript is Script {
    DynamicStakingVault public vault;

    function setUp() public {}

    function run(address assetTokenAddress, uint assetDecimals) public {
        vm.startBroadcast();

        vault = new DynamicStakingVault(assetTokenAddress, assetDecimals);

        vm.stopBroadcast();
    }
}
