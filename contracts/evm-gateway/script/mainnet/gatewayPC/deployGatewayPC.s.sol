// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayPC } from "../../../src/UniversalGatewayPC.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { GatewayPCConfig } from "../../config/mainnet/GatewayPCConfig.sol";

/**
 * @title DeployGatewayPC
 * @notice Deployment script for UniversalGatewayPC on Push Chain
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * PREREQUISITES:
 * - VaultPC must be deployed first
 * - UniversalCore address must be known
 *
 * USAGE:
 * forge script script/gatewayPC/DeployGatewayPC.s.sol:DeployGatewayPC \
 *   --rpc-url $PUSH_CHAIN_RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployGatewayPC is Script, GatewayPCConfig {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Role addresses (set to msg.sender by default, transfer later)
    address admin;
    address pauser;

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    Config cfg;
    address public gatewayPCImplementation;
    address public gatewayPCProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
        cfg = getConfig();
        deployChainId = block.chainid;

        console.log("========================================");
        console.log("  DEPLOYING GATEWAYPC ON PUSH CHAIN");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", deployChainId);
        console.log("Deployer:", msg.sender);
        console.log("");

        // Pre-deployment validation
        _validateConfiguration();

        // Start broadcasting
        vm.startBroadcast();

        // Load roles
        _loadRoles();

        // Deploy implementation
        _deployImplementation();

        // Deploy proxy with initialization
        _deployProxy();

        // Verify deployment
        _verifyDeployment();

        vm.stopBroadcast();

        // Print summary
        _printDeploymentSummary();
    }

    // ========================================
    //         VALIDATION
    // ========================================
    function _validateConfiguration() internal view {
        console.log("--- Pre-Deployment Validation ---");
        console.log("");

        // Critical validation: UniversalCore must be set
        if (cfg.universalCore == address(0)) {
            console.log("ERROR: universalCore is not set in config!");
            console.log("Please set universalCore address in GatewayPCConfig.");
            revert("universalCore not set in config");
        }

        // Critical validation: VaultPC must be deployed
        if (cfg.vaultPC == address(0)) {
            console.log("ERROR: vaultPC is not set in config!");
            console.log("Please deploy VaultPC first and update GatewayPCConfig.");
            revert("vaultPC not set in config");
        }

        // Verify UniversalCore has code
        uint256 universalCoreCodeSize;
        address universalCoreAddr = cfg.universalCore;
        assembly {
            universalCoreCodeSize := extcodesize(universalCoreAddr)
        }
        require(universalCoreCodeSize > 0, "UniversalCore contract not found at config address");

        // Verify VaultPC has code
        uint256 vaultPCCodeSize;
        address vaultPCAddr = cfg.vaultPC;
        assembly {
            vaultPCCodeSize := extcodesize(vaultPCAddr)
        }
        require(vaultPCCodeSize > 0, "VaultPC contract not found at config address");

        console.log("OK: UniversalCore found at:", cfg.universalCore);
        console.log("OK: VaultPC found at:", cfg.vaultPC);
        console.log("OK: All validation checks passed");
        console.log("");
    }

    function _loadRoles() internal {
        console.log("--- Loading Role Configuration ---");

        // Default all roles to deployer (can transfer later)
        admin = msg.sender;
        pauser = msg.sender;

        console.log("Admin:", admin);
        console.log("Pauser:", pauser);
        console.log("");
    }

    // ========================================
    //         DEPLOYMENT STEPS
    // ========================================
    function _deployImplementation() internal {
        console.log("--- Deploying GatewayPC Implementation ---");

        UniversalGatewayPC implementation = new UniversalGatewayPC();
        gatewayPCImplementation = address(implementation);

        console.log("Implementation deployed at:", gatewayPCImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            cfg.universalCore,
            cfg.vaultPC
        );

        // Deploy proxy with implementation and initialization
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(gatewayPCImplementation, cfg.deployer, initData);

        gatewayPCProxy = address(proxy);
        console.log("Proxy deployed at:", gatewayPCProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(gatewayPCImplementation != address(0), "Implementation not deployed");
        require(gatewayPCProxy != address(0), "Proxy not deployed");

        UniversalGatewayPC gatewayPC = UniversalGatewayPC(gatewayPCProxy);

        // Verify initialization parameters
        require(gatewayPC.universalCore() == cfg.universalCore, "UniversalCore address mismatch");
        require(address(gatewayPC.vaultPC()) == cfg.vaultPC, "VaultPC address mismatch");

        // Verify roles
        require(gatewayPC.hasRole(gatewayPC.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        require(gatewayPC.hasRole(gatewayPC.PAUSER_ROLE(), pauser), "Pauser role not set");

        // Verify nonce initialized
        require(gatewayPC.nonce() == 0, "Nonce should be 0 on fresh deployment");

        console.log("OK: All parameters verified");
        console.log("OK: All roles assigned correctly");
        console.log("");
    }

    function _printDeploymentSummary() internal view {
        console.log("========================================");
        console.log("     DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", deployChainId);
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  GatewayPC Implementation:", gatewayPCImplementation);
        console.log("  GatewayPC Proxy:         ", gatewayPCProxy);
        console.log("  Proxy Admin:             ", _getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  UniversalCore:           ", cfg.universalCore);
        console.log("  VaultPC:                 ", cfg.vaultPC);
        console.log("  Admin:                   ", admin);
        console.log("  Pauser:                  ", pauser);
        console.log("");
        console.log("========================================");
        console.log("GatewayPC Address: %s", gatewayPCProxy);
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify contracts on block explorer");
        console.log("2. Transfer roles if needed");
        console.log("3. Test outbound transaction flow");
        console.log("4. Monitor nonce and fee collection");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdmin) {
        bytes32 raw = vm.load(gatewayPCProxy, _ADMIN_SLOT);
        proxyAdmin = address(uint160(uint256(raw)));
    }

    function _getProxyAdminOwner() internal view returns (address owner) {
        address proxyAdminAddr = _getProxyAdmin();
        ProxyAdmin proxyAdminContract = ProxyAdmin(proxyAdminAddr);
        owner = proxyAdminContract.owner();
    }
}

// ========================================
//      VERIFICATION COMMANDS
// ========================================
//
// 1. Verify Implementation:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <IMPL_ADDR> src/UniversalGatewayPC.sol:UniversalGatewayPC \
//   --etherscan-api-key $ETHERSCAN_API_KEY
//
// 2. Verify Proxy:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <IMPL_ADDR> <ADMIN_ADDR> <INIT_DATA>) \
//   <PROXY_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
//   --etherscan-api-key $ETHERSCAN_API_KEY
//
// 3. Verify ProxyAdmin:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER>) \
//   <ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin \
//   --etherscan-api-key $ETHERSCAN_API_KEY
