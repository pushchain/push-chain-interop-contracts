// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../../src/UniversalGateway.sol";
import { GatewayConfig } from "../../config/testnet/GatewayConfig.sol";

/**
 * @title  InitializeV2
 * @notice Step 2 of 3: Call initializeV2(deployer) on the upgraded gateway proxy.
 *         Seeds the AccessControlDefaultAdminRules storage and sets up the
 *         granular role hierarchy (ROLE_MANAGER → UG_ADMIN, OPERATOR, PAUSER, VAULT).
 *
 * @dev    Must be run AFTER 1_upgradeGateway.s.sol.
 *         The caller MUST hold DEFAULT_ADMIN_ROLE on the gateway (= deployer).
 *
 * USAGE:
 *   forge script script/testnet/gateway/2_initializeV2.s.sol:InitializeV2 \
 *     --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract InitializeV2 is Script, GatewayConfig {
    Config cfg;

    function run() external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  STEP 2: initializeV2");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Caller   :", msg.sender);
        console.log("Proxy    :", cfg.gatewayProxy);
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

        UniversalGateway gw = UniversalGateway(payable(cfg.gatewayProxy));

        string memory ver = gw.version();
        require(
            keccak256(bytes(ver)) == keccak256(bytes("2.0.0")),
            "version mismatch - run 1_upgradeGateway first"
        );
        console.log("  OK: version =", ver);

        bool isAdmin = gw.hasRole(gw.DEFAULT_ADMIN_ROLE(), msg.sender);
        require(isAdmin, "caller does not hold DEFAULT_ADMIN_ROLE");
        console.log("  OK: caller holds DEFAULT_ADMIN_ROLE");

        console.log("");
    }

    // --- initialize ---

    function _callInitializeV2() internal {
        console.log("--- Calling initializeV2 ---");

        UniversalGateway gw = UniversalGateway(payable(cfg.gatewayProxy));
        gw.initializeV2(msg.sender);

        console.log("  initializeV2(", msg.sender, ") executed");
        console.log("");
    }

    // --- post checks ---

    function _postValidate() internal view {
        console.log("--- Post-InitializeV2 Validation ---");

        UniversalGateway gw = UniversalGateway(payable(cfg.gatewayProxy));

        // Default admin delay
        uint48 delay = gw.defaultAdminDelay();
        require(delay == 60, "defaultAdminDelay not 1 minute");
        console.log("  OK: defaultAdminDelay = 60s");

        // defaultAdmin
        address admin = gw.defaultAdmin();
        require(admin == msg.sender, "defaultAdmin mismatch");
        console.log("  OK: defaultAdmin =", admin);

        // ROLE_MANAGER_ROLE
        bool hasRM = gw.hasRole(gw.ROLE_MANAGER_ROLE(), msg.sender);
        require(hasRM, "ROLE_MANAGER_ROLE not granted");
        console.log("  OK: ROLE_MANAGER_ROLE granted");

        // UG_ADMIN_ROLE
        bool hasUA = gw.hasRole(gw.UG_ADMIN_ROLE(), msg.sender);
        require(hasUA, "UG_ADMIN_ROLE not granted");
        console.log("  OK: UG_ADMIN_ROLE granted");

        // OPERATOR_ROLE
        bool hasOP = gw.hasRole(gw.OPERATOR_ROLE(), msg.sender);
        require(hasOP, "OPERATOR_ROLE not granted");
        console.log("  OK: OPERATOR_ROLE granted");

        // PAUSER_ROLE — not granted by initializeV2, but should survive from V1
        console.log("  NOTE: PAUSER_ROLE was NOT granted by initializeV2");
        console.log("        It must already exist from V1 initialization.");
        bool hasPauser = gw.hasRole(gw.PAUSER_ROLE(), msg.sender);
        console.log("  PAUSER_ROLE held by caller:", hasPauser);

        // VAULT_ROLE — should survive from V1 setVault call
        address vault = gw.VAULT();
        bool hasVR = gw.hasRole(gw.VAULT_ROLE(), vault);
        console.log("  VAULT_ROLE held by Vault  :", hasVR);
        if (!hasVR) {
            console.log("  WARNING: VAULT_ROLE not held by Vault.");
            console.log("  You must grant it manually after this script.");
        }

        console.log("");
    }

    function _summary() internal view {
        console.log("========================================");
        console.log("  initializeV2 COMPLETE");
        console.log("========================================");
        console.log("  Proxy      :", cfg.gatewayProxy);
        console.log("  Admin      :", msg.sender);
        console.log("  Delay      : 60s (1 minute)");
        console.log("");
        console.log("NEXT STEP:");
        console.log("  Run 3_verifyGateway.s.sol");
        console.log("========================================");
    }
}
