// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../../../src/Vault.sol";
import { VaultConfig } from "../../config/testnet/VaultConfig.sol";

/**
 * @title  InitializeV2 (Vault)
 * @notice Step 2 of 3: Call initializeV2(deployer) on the upgraded Vault proxy.
 *         Seeds the AccessControlDefaultAdminRules storage and sets up the
 *         granular role hierarchy (ROLE_MANAGER -> VAULT_ADMIN, OPERATOR, PAUSER, TSS).
 *
 * @dev    Must be run AFTER 1_upgradeVault.s.sol.
 *         The caller MUST hold DEFAULT_ADMIN_ROLE on the Vault (= deployer).
 *
 * USAGE:
 *   forge script script/testnet/vault/2_initializeV2.s.sol:InitializeV2 \
 *     --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract InitializeV2 is Script, VaultConfig {
    Config cfg;

    function run() external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  STEP 2: Vault initializeV2");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Caller   :", msg.sender);
        console.log("Proxy    :", cfg.vaultProxy);
        console.log("");

        _preValidate();

        vm.startBroadcast();
        _callInitializeV2();
        vm.stopBroadcast();

        _postValidate();
        _summary();
    }

    // --- validation ---

    function _preValidate() internal view {
        console.log("--- Pre-InitializeV2 Validation ---");

        Vault v = Vault(payable(cfg.vaultProxy));

        bool isAdmin = v.hasRole(v.DEFAULT_ADMIN_ROLE(), msg.sender);
        require(isAdmin, "caller does not hold DEFAULT_ADMIN_ROLE");
        console.log("  OK: caller holds DEFAULT_ADMIN_ROLE");

        console.log("");
    }

    // --- initialize ---

    function _callInitializeV2() internal {
        console.log("--- Calling initializeV2 ---");

        Vault v = Vault(payable(cfg.vaultProxy));
        v.initializeV2(msg.sender);

        console.log("  initializeV2(", msg.sender, ") executed");
        console.log("");
    }

    // --- post checks ---

    function _postValidate() internal view {
        console.log("--- Post-InitializeV2 Validation ---");

        Vault v = Vault(payable(cfg.vaultProxy));

        uint48 delay = v.defaultAdminDelay();
        require(delay == 60, "defaultAdminDelay not 1 minute");
        console.log("  OK: defaultAdminDelay = 60s");

        address admin = v.defaultAdmin();
        require(admin == msg.sender, "defaultAdmin mismatch");
        console.log("  OK: defaultAdmin =", admin);

        bool hasRM = v.hasRole(v.ROLE_MANAGER_ROLE(), msg.sender);
        require(hasRM, "ROLE_MANAGER_ROLE not granted");
        console.log("  OK: ROLE_MANAGER_ROLE granted");

        bool hasVA = v.hasRole(v.VAULT_ADMIN_ROLE(), msg.sender);
        require(hasVA, "VAULT_ADMIN_ROLE not granted");
        console.log("  OK: VAULT_ADMIN_ROLE granted");

        bool hasOP = v.hasRole(v.OPERATOR_ROLE(), msg.sender);
        require(hasOP, "OPERATOR_ROLE not granted");
        console.log("  OK: OPERATOR_ROLE granted");

        // PAUSER_ROLE - not granted by initializeV2, survives from V1
        console.log("  NOTE: PAUSER_ROLE was NOT granted by initializeV2");
        console.log("        It must already exist from V1 initialization.");
        bool hasPauser = v.hasRole(v.PAUSER_ROLE(), msg.sender);
        console.log("  PAUSER_ROLE held by caller:", hasPauser);

        // TSS_ROLE - not granted by initializeV2, survives from V1
        console.log("  NOTE: TSS_ROLE was NOT granted by initializeV2");
        console.log("        It must already exist from V1 initialization.");
        address tss = v.TSS_ADDRESS();
        bool hasTSS = v.hasRole(v.TSS_ROLE(), tss);
        console.log("  TSS_ADDRESS               :", tss);
        console.log("  TSS_ROLE held by TSS_ADDR :", hasTSS);
        if (!hasTSS) {
            console.log("  WARNING: TSS_ROLE not held by TSS_ADDRESS.");
            console.log("  You must grant it manually after this script.");
        }

        console.log("");
    }

    function _summary() internal view {
        console.log("========================================");
        console.log("  Vault initializeV2 COMPLETE");
        console.log("========================================");
        console.log("  Proxy      :", cfg.vaultProxy);
        console.log("  Admin      :", msg.sender);
        console.log("  Delay      : 60s (1 minute)");
        console.log("");
        console.log("NEXT STEP:");
        console.log("  Run 3_verifyVault.s.sol");
        console.log("========================================");
    }
}
