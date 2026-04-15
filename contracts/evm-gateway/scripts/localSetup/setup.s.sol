// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { VaultPC } from "../../src/VaultPC.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract LocalSetupScript is Script {
    address owner = 0x778D3206374f8AC265728E18E3fE2Ae6b93E4ce4;
    address universalCore = 0x00000000000000000000000000000000000000C0;

    // Reserved proxy address
    address constant PROXY = 0x00000000000000000000000000000000000000C1;

    // ProxyAdmin controlling the proxy
    address constant PROXY_ADMIN = 0xF2000000000000000000000000000000000000C1;

    function run() external {
        vm.startBroadcast();

        VaultPC vaultPc = new VaultPC();

        // 1. Deploy new implementation with fixed event
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();

        ProxyAdmin proxyAdmin = ProxyAdmin(PROXY_ADMIN);

        // 3. Upgrade the proxy
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(PROXY));

        proxyAdmin.upgradeAndCall(proxy, address(newImplementation), "");

        // 2. Upgrade proxy -> new implementation (NO initialize call)
        ProxyAdmin(PROXY_ADMIN).upgradeAndCall(
            proxy,
            address(newImplementation),
            ""
        );

        UniversalGatewayPC(PROXY).initialize(owner, owner, universalCore, address(vaultPc));

        vm.stopBroadcast();
    }
}
