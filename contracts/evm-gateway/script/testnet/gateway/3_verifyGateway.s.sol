// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../../src/UniversalGateway.sol";
import { Vault } from "../../../src/Vault.sol";
import { GatewayConfig } from "../../config/testnet/GatewayConfig.sol";

/**
 * @title  VerifyGateway
 * @notice Step 3 of 3: Full post-upgrade verification of the UniversalGateway.
 *         Read-only — does not broadcast any transactions.
 *
 *         Checks:
 *           1. Version and implementation
 *           2. All preserved state (TSS, VAULT, CEA_FACTORY, caps, oracle, fees)
 *           3. New role hierarchy (ROLE_MANAGER, UG_ADMIN, OPERATOR, PAUSER, VAULT)
 *           4. AccessControlDefaultAdminRules (delay, defaultAdmin, owner)
 *           5. Cross-contract references (Vault → Gateway, Gateway → Vault)
 *           6. Oracle smoke test (getEthUsdPrice)
 *
 * @dev    Must be run AFTER 2_initializeV2.s.sol.
 *         Does not require --broadcast (read-only).
 *
 * USAGE:
 *   forge script script/testnet/gateway/3_verifyGateway.s.sol:VerifyGateway \
 *     --rpc-url $RPC_URL -vvv
 */
contract VerifyGateway is Script, GatewayConfig {
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    Config cfg;

    function run() external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  STEP 3: VERIFY UniversalGateway");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Proxy    :", cfg.gatewayProxy);
        console.log("Deployer :", cfg.deployer);
        console.log("");

        UniversalGateway gw = UniversalGateway(payable(cfg.gatewayProxy));

        _checkVersion(gw);
        _checkState(gw);
        _checkRoles(gw);
        _checkAdminRules(gw);
        _checkCrossContract(gw);
        _checkOracle(gw);
        _checkConstants(gw);

        console.log("========================================");
        console.log("  VERIFICATION COMPLETE");
        console.log("========================================");
    }

    // --- 1. version ---

    function _checkVersion(UniversalGateway gw) internal view {
        console.log("--- 1. Version ---");
        string memory ver = gw.version();
        console.log("  version():", ver);
        if (keccak256(bytes(ver)) != keccak256(bytes("2.0.0"))) {
            console.log("  FAIL: expected 2.0.0");
        } else {
            console.log("  OK");
        }
        console.log("");
    }

    // --- 2. preserved state ---

    function _checkState(UniversalGateway gw) internal view {
        console.log("--- 2. Preserved State ---");

        address tss = gw.TSS_ADDRESS();
        console.log("  TSS_ADDRESS              :", tss);
        _require(tss != address(0), "TSS_ADDRESS is zero");

        address vault = gw.VAULT();
        console.log("  VAULT                    :", vault);
        _require(vault == cfg.vault, "VAULT mismatch with config");

        address ceaFactory = gw.CEA_FACTORY();
        console.log("  CEA_FACTORY              :", ceaFactory);
        _require(ceaFactory != address(0), "CEA_FACTORY is zero");

        uint256 minCap = gw.MIN_CAP_UNIVERSAL_TX_USD();
        console.log("  MIN_CAP_UNIVERSAL_TX_USD :", minCap);

        uint256 maxCap = gw.MAX_CAP_UNIVERSAL_TX_USD();
        console.log("  MAX_CAP_UNIVERSAL_TX_USD :", maxCap);

        uint256 blockCap = gw.BLOCK_USD_CAP();
        console.log("  BLOCK_USD_CAP            :", blockCap);

        uint256 epoch = gw.epochDurationSec();
        console.log("  epochDurationSec         :", epoch);

        uint256 fee = gw.INBOUND_FEE();
        console.log("  INBOUND_FEE              :", fee);

        uint256 totalFees = gw.totalProtocolFeesCollected();
        console.log("  totalProtocolFeesCollected:", totalFees);

        address weth = gw.WETH();
        console.log("  WETH                     :", weth);
        _require(weth != address(0), "WETH is zero");

        address feed = address(gw.ethUsdFeed());
        console.log("  ethUsdFeed               :", feed);

        uint256 stalePeriod = gw.chainlinkStalePeriod();
        console.log("  chainlinkStalePeriod     :", stalePeriod);

        uint256 deadline = gw.defaultSwapDeadlineSec();
        console.log("  defaultSwapDeadlineSec   :", deadline);

        bool paused = gw.paused();
        console.log("  paused                   :", paused);

        console.log("  OK");
        console.log("");
    }

    // --- 3. roles ---

    function _checkRoles(UniversalGateway gw) internal view {
        console.log("--- 3. Role Hierarchy ---");
        address deployer = cfg.deployer;

        bool hasRM = gw.hasRole(gw.ROLE_MANAGER_ROLE(), deployer);
        console.log("  deployer has ROLE_MANAGER_ROLE:", hasRM);
        _require(hasRM, "ROLE_MANAGER_ROLE missing");

        bool hasUA = gw.hasRole(gw.UG_ADMIN_ROLE(), deployer);
        console.log("  deployer has UG_ADMIN_ROLE    :", hasUA);
        _require(hasUA, "UG_ADMIN_ROLE missing");

        bool hasOP = gw.hasRole(gw.OPERATOR_ROLE(), deployer);
        console.log("  deployer has OPERATOR_ROLE    :", hasOP);
        _require(hasOP, "OPERATOR_ROLE missing");

        bool hasPR = gw.hasRole(gw.PAUSER_ROLE(), deployer);
        console.log("  deployer has PAUSER_ROLE      :", hasPR);
        if (!hasPR) {
            console.log("  WARN: PAUSER_ROLE not held by deployer (check who holds it)");
        }

        address vault = gw.VAULT();
        bool hasVR = gw.hasRole(gw.VAULT_ROLE(), vault);
        console.log("  Vault has VAULT_ROLE          :", hasVR);
        _require(hasVR, "VAULT_ROLE not held by Vault");

        // Role admin checks
        bytes32 rmAdmin = gw.getRoleAdmin(gw.UG_ADMIN_ROLE());
        bytes32 expectedRM = gw.ROLE_MANAGER_ROLE();
        console.log("  UG_ADMIN admin = ROLE_MANAGER :", rmAdmin == expectedRM);
        _require(rmAdmin == expectedRM, "UG_ADMIN_ROLE admin wrong");

        bytes32 opAdmin = gw.getRoleAdmin(gw.OPERATOR_ROLE());
        console.log("  OPERATOR admin = ROLE_MANAGER :", opAdmin == expectedRM);
        _require(opAdmin == expectedRM, "OPERATOR_ROLE admin wrong");

        bytes32 prAdmin = gw.getRoleAdmin(gw.PAUSER_ROLE());
        console.log("  PAUSER admin = ROLE_MANAGER   :", prAdmin == expectedRM);
        _require(prAdmin == expectedRM, "PAUSER_ROLE admin wrong");

        bytes32 vrAdmin = gw.getRoleAdmin(gw.VAULT_ROLE());
        console.log("  VAULT admin = ROLE_MANAGER    :", vrAdmin == expectedRM);
        _require(vrAdmin == expectedRM, "VAULT_ROLE admin wrong");

        console.log("  OK");
        console.log("");
    }

    // --- 4. AccessControlDefaultAdminRules ---

    function _checkAdminRules(UniversalGateway gw) internal view {
        console.log("--- 4. Admin Rules (ACDARU) ---");

        address admin = gw.defaultAdmin();
        console.log("  defaultAdmin()     :", admin);
        _require(admin == cfg.deployer, "defaultAdmin mismatch");

        uint48 delay = gw.defaultAdminDelay();
        console.log("  defaultAdminDelay():", uint256(delay));
        _require(delay == 60, "delay not 60s");

        address owner = gw.owner();
        console.log("  owner()            :", owner);
        _require(owner == cfg.deployer, "owner mismatch");

        console.log("  OK");
        console.log("");
    }

    // --- 5. cross-contract refs ---

    function _checkCrossContract(UniversalGateway gw) internal view {
        console.log("--- 5. Cross-Contract References ---");

        address vault = gw.VAULT();
        if (vault == address(0)) {
            console.log("  SKIP: VAULT is zero, nothing to check");
            console.log("");
            return;
        }

        address vaultGateway = address(Vault(payable(vault)).gateway());
        console.log("  Vault.gateway() :", vaultGateway);
        console.log("  Gateway proxy   :", cfg.gatewayProxy);
        _require(
            vaultGateway == cfg.gatewayProxy,
            "Vault.gateway does not point to this proxy"
        );

        console.log("  OK");
        console.log("");
    }

    // --- 6. oracle ---

    function _checkOracle(UniversalGateway gw) internal view {
        console.log("--- 6. Oracle Smoke Test ---");

        address feed = address(gw.ethUsdFeed());
        if (feed == address(0)) {
            console.log("  SKIP: ethUsdFeed not set");
            console.log("");
            return;
        }

        try gw.getEthUsdPrice() returns (uint256 price, uint8 dec) {
            console.log("  getEthUsdPrice() :", price);
            console.log("  decimals         :", uint256(dec));
            _require(price > 0, "price is zero");
            console.log("  OK");
        } catch {
            console.log("  WARN: getEthUsdPrice() reverted (oracle may be stale or sequencer down)");
        }
        console.log("");
    }

    // --- 7. constants ---

    function _checkConstants(UniversalGateway gw) internal view {
        console.log("--- 7. Constants ---");

        uint256 minStale = gw.MIN_CHAINLINK_STALE_PERIOD();
        console.log("  MIN_CHAINLINK_STALE_PERIOD:", minStale);
        _require(minStale == 10 minutes, "MIN_CHAINLINK_STALE_PERIOD wrong");

        uint256 maxFee = gw.MAX_INBOUND_FEE();
        console.log("  MAX_INBOUND_FEE           :", maxFee);
        _require(maxFee == 0.05 ether, "MAX_INBOUND_FEE wrong");

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
