// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PC20Factory } from "../../../src/PC20Factory.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title  UpgradePC20Factory
 * @notice Deploy new PC20Factory implementation and upgrade the proxy.
 *
 * USAGE:
 *   PC20_FACTORY_PROXY=0x... forge script \
 *     script/testnet/pc20factory/3_upgradePC20Factory.s.sol:UpgradePC20Factory \
 *     --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract UpgradePC20Factory is Script {
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        address proxy = vm.envAddress("PC20_FACTORY_PROXY");

        address proxyAdmin = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address oldImpl = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));

        console.log("========================================");
        console.log("  UPGRADE PC20Factory");
        console.log("========================================");
        console.log("Chain ID    :", block.chainid);
        console.log("Proxy       :", proxy);
        console.log("ProxyAdmin  :", proxyAdmin);
        console.log("Old Impl    :", oldImpl);
        console.log("");

        vm.startBroadcast();

        PC20Factory newImpl = new PC20Factory();
        console.log("New Impl    :", address(newImpl));

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy), address(newImpl), bytes("")
        );

        vm.stopBroadcast();

        address currentImpl = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        require(currentImpl == address(newImpl), "impl not updated");

        PC20Factory f = PC20Factory(proxy);
        string memory ver = f.version();
        console.log("version()   :", ver);
        require(keccak256(bytes(ver)) == keccak256(bytes("1.0.0")), "version mismatch");

        require(f.vault() != address(0), "vault corrupted");
        require(f.gateway() != address(0), "gateway corrupted");
        require(f.defaultAdmin() != address(0), "admin corrupted");

        console.log("");
        console.log("========================================");
        console.log("  UPGRADE COMPLETE - version 1.0.0");
        console.log("========================================");
    }
}
