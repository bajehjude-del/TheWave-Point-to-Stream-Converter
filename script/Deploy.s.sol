// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {WaveConverter, IDrips} from "../src/WaveConverter.sol";

/**
 * @notice Deploys WaveConverter and registers it as a Drips driver.
 *
 * Required env vars:
 *   DRIPS_ADDRESS   – deployed Drips contract (see deployments/ in drips-network/contracts)
 *   MANAGER_ADDRESS – address that will manage sprints
 *
 * Example (Sepolia):
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 */
contract DeployScript is Script {
    function run() external returns (WaveConverter converter) {
        address dripsAddr = vm.envAddress("DRIPS_ADDRESS");
        address managerAddr = vm.envAddress("MANAGER_ADDRESS");

        vm.startBroadcast();
        converter = new WaveConverter(IDrips(dripsAddr), managerAddr);
        vm.stopBroadcast();

        console.log("WaveConverter deployed at:", address(converter));
        console.log("  driverId :", converter.driverId());
        console.log("  accountId:", converter.accountId());
        console.log("  manager  :", converter.manager());
    }
}
