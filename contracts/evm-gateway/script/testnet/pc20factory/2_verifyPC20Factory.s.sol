// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PC20Factory } from "../../../src/PC20Factory.sol";
import { PC20FactoryConfig } from "../../config/testnet/PC20FactoryConfig.sol";

/**
 * @title  VerifyPC20Factory
 * @notice Read-only verification of a deployed PC20Factory proxy.
 *
 * USAGE:
 *   PC20_FACTORY_PROXY=0x... forge script \
 *     script/testnet/pc20factory/2_verifyPC20Factory.s.sol:VerifyPC20Factory \
 *     --rpc-url $RPC_URL -vvv
 */
contract VerifyPC20Factory is Script, PC20FactoryConfig {
    function run() external view {
        Config memory cfg = getPC20Config();
        address proxy = vm.envAddress("PC20_FACTORY_PROXY");

        console.log("========================================");
        console.log("  VERIFY PC20Factory");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Proxy    :", proxy);
        console.log("");

        PC20Factory f = PC20Factory(proxy);

        console.log("--- Admin & Roles ---");
        address admin = f.defaultAdmin();
        console.log("  defaultAdmin() :", admin);
        require(admin == cfg.deployer, "admin mismatch");

        uint48 delay = f.defaultAdminDelay();
        console.log("  adminDelay()   :", uint256(delay));
        require(delay == 1 days, "delay not 1 day");

        address vault = f.vault();
        console.log("  vault()        :", vault);
        require(vault == cfg.vault, "vault mismatch");

        address gw = f.gateway();
        console.log("  gateway()      :", gw);
        require(gw == cfg.gateway, "gateway mismatch");

        bool hasRM = f.hasRole(f.ROLE_MANAGER_ROLE(), cfg.deployer);
        console.log("  ROLE_MANAGER   :", hasRM);
        require(hasRM, "ROLE_MANAGER missing");

        bool hasOP = f.hasRole(f.OPERATOR_ROLE(), cfg.deployer);
        console.log("  OPERATOR       :", hasOP);
        require(hasOP, "OPERATOR missing");

        bool hasPR = f.hasRole(f.PAUSER_ROLE(), cfg.pauser);
        console.log("  PAUSER         :", hasPR);
        require(hasPR, "PAUSER missing");

        bool hasVR = f.hasRole(f.VAULT_ROLE(), cfg.vault);
        console.log("  VAULT_ROLE     :", hasVR);
        require(hasVR, "VAULT_ROLE missing");

        bool hasGR = f.hasRole(f.GATEWAY_ROLE(), cfg.gateway);
        console.log("  GATEWAY_ROLE   :", hasGR);
        require(hasGR, "GATEWAY_ROLE missing");

        bool paused = f.paused();
        console.log("  paused()       :", paused);
        require(!paused, "should not be paused");

        console.log("");
        console.log("========================================");
        console.log("  VERIFICATION PASSED");
        console.log("========================================");
    }
}
