// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PC20Factory } from "../../../src/PC20Factory.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { PC20FactoryConfig } from "../../config/testnet/PC20FactoryConfig.sol";

/**
 * @title  DeployPC20Factory
 * @notice Deploy PC20Factory implementation + TransparentUpgradeableProxy.
 *
 * USAGE:
 *   forge script script/testnet/pc20factory/1_deployPC20Factory.s.sol:DeployPC20Factory \
 *     --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract DeployPC20Factory is Script, PC20FactoryConfig {
    function run() external {
        Config memory cfg = getPC20Config();

        console.log("========================================");
        console.log("  DEPLOY PC20Factory");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Deployer :", cfg.deployer);
        console.log("Pauser   :", cfg.pauser);
        console.log("Vault    :", cfg.vault);
        console.log("Gateway  :", cfg.gateway);
        console.log("");

        vm.startBroadcast();

        PC20Factory impl = new PC20Factory();
        console.log("Implementation:", address(impl));

        bytes memory initData = abi.encodeWithSelector(
            PC20Factory.initialize.selector,
            cfg.deployer,
            cfg.pauser,
            cfg.vault,
            cfg.gateway
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), cfg.deployer, initData);
        console.log("Proxy         :", address(proxy));

        vm.stopBroadcast();

        _postValidate(address(proxy), cfg);

        console.log("========================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("  Implementation :", address(impl));
        console.log("  Proxy          :", address(proxy));
        console.log("");
        console.log("NEXT: Verify contracts on block explorer");
        console.log("========================================");
    }

    function _postValidate(address proxy, Config memory cfg) internal view {
        console.log("");
        console.log("--- Post-Deploy Validation ---");

        PC20Factory f = PC20Factory(proxy);

        address admin = f.defaultAdmin();
        console.log("  defaultAdmin():", admin);
        require(admin == cfg.deployer, "admin mismatch");

        address vault = f.vault();
        console.log("  vault()       :", vault);
        require(vault == cfg.vault, "vault mismatch");

        address gw = f.gateway();
        console.log("  gateway()     :", gw);
        require(gw == cfg.gateway, "gateway mismatch");

        bool paused = f.paused();
        console.log("  paused()      :", paused);
        require(!paused, "should not be paused");

        bool hasVaultRole = f.hasRole(f.VAULT_ROLE(), cfg.vault);
        console.log("  vault has VAULT_ROLE  :", hasVaultRole);
        require(hasVaultRole, "VAULT_ROLE missing");

        bool hasGwRole = f.hasRole(f.GATEWAY_ROLE(), cfg.gateway);
        console.log("  gateway has GW_ROLE   :", hasGwRole);
        require(hasGwRole, "GATEWAY_ROLE missing");

        console.log("  OK");
        console.log("");
    }
}
