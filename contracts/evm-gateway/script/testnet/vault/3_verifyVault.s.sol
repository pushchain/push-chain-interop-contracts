// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../../../src/Vault.sol";
import { UniversalGateway } from "../../../src/UniversalGateway.sol";
import { VaultConfig } from "../../config/testnet/VaultConfig.sol";

/**
 * @title  VerifyVault
 * @notice Step 3 of 3: Full post-upgrade verification of the Vault.
 *         Read-only - does not broadcast any transactions.
 *
 *         Checks:
 *           1. All preserved state (gateway, TSS_ADDRESS, CEAFactory)
 *           2. New role hierarchy (ROLE_MANAGER, VAULT_ADMIN, OPERATOR, PAUSER, TSS)
 *           3. AccessControlDefaultAdminRules (delay, defaultAdmin, owner)
 *           4. Cross-contract references (Gateway -> Vault, Vault -> Gateway)
 *
 * @dev    Must be run AFTER 2_initializeV2.s.sol.
 *         Does not require --broadcast (read-only).
 *
 * USAGE:
 *   forge script script/testnet/vault/3_verifyVault.s.sol:VerifyVault \
 *     --rpc-url $RPC_URL -vvv
 */
contract VerifyVault is Script, VaultConfig {
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    Config cfg;

    function run() external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  STEP 3: VERIFY Vault");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Proxy    :", cfg.vaultProxy);
        console.log("Deployer :", cfg.deployer);
        console.log("");

        Vault v = Vault(payable(cfg.vaultProxy));

        _checkState(v);
        _checkRoles(v);
        _checkAdminRules(v);
        _checkCrossContract(v);

        console.log("========================================");
        console.log("  VERIFICATION COMPLETE");
        console.log("========================================");
    }

    // --- 1. preserved state ---

    function _checkState(Vault v) internal view {
        console.log("--- 1. Preserved State ---");

        address gw = address(v.gateway());
        console.log("  gateway      :", gw);
        _require(gw == cfg.gateway, "gateway mismatch with config");

        address tss = v.TSS_ADDRESS();
        console.log("  TSS_ADDRESS  :", tss);
        _require(tss != address(0), "TSS_ADDRESS is zero");

        address ceaFactory = address(v.CEAFactory());
        console.log("  CEAFactory   :", ceaFactory);
        _require(ceaFactory == cfg.ceaFactory, "CEAFactory mismatch");

        bool paused = v.paused();
        console.log("  paused       :", paused);

        console.log("  OK");
        console.log("");
    }

    // --- 2. roles ---

    function _checkRoles(Vault v) internal view {
        console.log("--- 2. Role Hierarchy ---");
        address deployer = cfg.deployer;

        bool hasRM = v.hasRole(v.ROLE_MANAGER_ROLE(), deployer);
        console.log("  deployer has ROLE_MANAGER_ROLE:", hasRM);
        _require(hasRM, "ROLE_MANAGER_ROLE missing");

        bool hasVA = v.hasRole(v.VAULT_ADMIN_ROLE(), deployer);
        console.log("  deployer has VAULT_ADMIN_ROLE :", hasVA);
        _require(hasVA, "VAULT_ADMIN_ROLE missing");

        bool hasOP = v.hasRole(v.OPERATOR_ROLE(), deployer);
        console.log("  deployer has OPERATOR_ROLE    :", hasOP);
        _require(hasOP, "OPERATOR_ROLE missing");

        bool hasPR = v.hasRole(v.PAUSER_ROLE(), deployer);
        console.log("  deployer has PAUSER_ROLE      :", hasPR);
        if (!hasPR) {
            console.log(
                "  WARN: PAUSER_ROLE not held by deployer"
                " (check who holds it)"
            );
        }

        address tss = v.TSS_ADDRESS();
        bool hasTSS = v.hasRole(v.TSS_ROLE(), tss);
        console.log("  TSS_ADDRESS has TSS_ROLE      :", hasTSS);
        _require(hasTSS, "TSS_ROLE not held by TSS_ADDRESS");

        // Role admin checks
        bytes32 expectedRM = v.ROLE_MANAGER_ROLE();

        bytes32 vaAdmin = v.getRoleAdmin(v.VAULT_ADMIN_ROLE());
        console.log("  VAULT_ADMIN admin = ROLE_MANAGER:", vaAdmin == expectedRM);
        _require(vaAdmin == expectedRM, "VAULT_ADMIN_ROLE admin wrong");

        bytes32 opAdmin = v.getRoleAdmin(v.OPERATOR_ROLE());
        console.log("  OPERATOR admin = ROLE_MANAGER   :", opAdmin == expectedRM);
        _require(opAdmin == expectedRM, "OPERATOR_ROLE admin wrong");

        bytes32 prAdmin = v.getRoleAdmin(v.PAUSER_ROLE());
        console.log("  PAUSER admin = ROLE_MANAGER     :", prAdmin == expectedRM);
        _require(prAdmin == expectedRM, "PAUSER_ROLE admin wrong");

        bytes32 tssAdmin = v.getRoleAdmin(v.TSS_ROLE());
        console.log("  TSS admin = ROLE_MANAGER        :", tssAdmin == expectedRM);
        _require(tssAdmin == expectedRM, "TSS_ROLE admin wrong");

        console.log("  OK");
        console.log("");
    }

    // --- 3. AccessControlDefaultAdminRules ---

    function _checkAdminRules(Vault v) internal view {
        console.log("--- 3. Admin Rules (ACDARU) ---");

        address admin = v.defaultAdmin();
        console.log("  defaultAdmin()     :", admin);
        _require(admin == cfg.deployer, "defaultAdmin mismatch");

        uint48 delay = v.defaultAdminDelay();
        console.log("  defaultAdminDelay():", uint256(delay));
        _require(delay == 60, "delay not 60s");

        address owner = v.owner();
        console.log("  owner()            :", owner);
        _require(owner == cfg.deployer, "owner mismatch");

        console.log("  OK");
        console.log("");
    }

    // --- 4. cross-contract refs ---

    function _checkCrossContract(Vault v) internal view {
        console.log("--- 4. Cross-Contract References ---");

        address gw = address(v.gateway());
        console.log("  Vault.gateway()    :", gw);
        console.log("  Config gateway     :", cfg.gateway);
        _require(gw == cfg.gateway, "Vault.gateway does not match config");

        if (gw != address(0)) {
            address gwVault = UniversalGateway(payable(gw)).VAULT();
            console.log("  Gateway.VAULT()    :", gwVault);
            console.log("  Vault proxy        :", cfg.vaultProxy);
            _require(
                gwVault == cfg.vaultProxy,
                "Gateway.VAULT does not point to this Vault proxy"
            );
        }

        console.log("  OK");
        console.log("");
    }

    // --- helper ---

    function _require(bool condition, string memory message) internal pure {
        if (!condition) {
            revert(message);
        }
    }
}
