// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../../../src/Vault.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { VaultConfig } from "../../config/mainnet/VaultConfig.sol";

/**
 * @title DeployVault
 * @notice Deployment script for Vault on external EVM chains
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * PREREQUISITES:
 * - CEAFactory must be deployed first
 * - Gateway can be set to address(0) initially, then updated via setGateway()
 *
 * USAGE:
 * forge script script/vault/DeployVault.s.sol:DeployVault \
 *   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployVault is Script, VaultConfig {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Role addresses (set to msg.sender by default, transfer later)
    address admin;
    address pauser;
    address tss;

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    Config cfg;
    address public vaultImplementation;
    address public vaultProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
        cfg = getConfig();
        deployChainId = block.chainid;

        console.log("========================================");
        console.log("  DEPLOYING VAULT");
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

        // Critical validation: CEAFactory must be deployed
        if (cfg.ceaFactory == address(0)) {
            console.log("ERROR: ceaFactory is not set in config!");
            console.log("Please deploy CEAFactory first and update VaultConfig.");
            revert("ceaFactory not set in config");
        }

        // Verify CEAFactory has code
        uint256 ceaFactoryCodeSize;
        address ceaFactoryAddr = cfg.ceaFactory;
        assembly {
            ceaFactoryCodeSize := extcodesize(ceaFactoryAddr)
        }
        require(ceaFactoryCodeSize > 0, "CEAFactory contract not found at config address");

        // Gateway validation (optional - can be set later)
        if (cfg.gateway != address(0)) {
            uint256 gatewayCodeSize;
            address gatewayAddr = cfg.gateway;
            assembly {
                gatewayCodeSize := extcodesize(gatewayAddr)
            }
            require(gatewayCodeSize > 0, "Gateway contract not found at config address");
            console.log("OK: Gateway found at:", cfg.gateway);
        } else {
            console.log("INFO: Gateway not set - will need to call setGateway() after deployment");
        }

        console.log("OK: CEAFactory found at:", cfg.ceaFactory);
        console.log("OK: All validation checks passed");
        console.log("");
    }

    function _loadRoles() internal {
        console.log("--- Loading Role Configuration ---");

        // Read from config — fallback to msg.sender only if not set
        admin = cfg.admin != address(0) ? cfg.admin : msg.sender;
        pauser = cfg.pauser != address(0) ? cfg.pauser : msg.sender;
        tss = cfg.tssAddress != address(0) ? cfg.tssAddress : msg.sender;

        console.log("Admin:", admin);
        console.log("Pauser:", pauser);
        console.log("TSS:", tss);
        console.log("");
    }

    // ========================================
    //         DEPLOYMENT STEPS
    // ========================================
    function _deployImplementation() internal {
        console.log("--- Deploying Vault Implementation ---");

        Vault implementation = new Vault();
        vaultImplementation = address(implementation);

        console.log("Implementation deployed at:", vaultImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            cfg.gateway,
            cfg.ceaFactory
        );

        // Deploy proxy with implementation and initialization
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(vaultImplementation, cfg.deployer, initData);

        vaultProxy = address(proxy);
        console.log("Proxy deployed at:", vaultProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(vaultImplementation != address(0), "Implementation not deployed");
        require(vaultProxy != address(0), "Proxy not deployed");

        Vault vault = Vault(vaultProxy);

        // Verify initialization parameters
        require(address(vault.gateway()) == cfg.gateway, "Gateway address mismatch");
        require(address(vault.CEAFactory()) == cfg.ceaFactory, "CEAFactory address mismatch");
        require(vault.TSS_ADDRESS() == tss, "TSS address mismatch");

        // Verify roles
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        require(vault.hasRole(vault.PAUSER_ROLE(), pauser), "Pauser role not set");
        require(vault.hasRole(vault.TSS_ROLE(), tss), "TSS role not set");

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
        console.log("  Vault Implementation:  ", vaultImplementation);
        console.log("  Vault Proxy:           ", vaultProxy);
        console.log("  Proxy Admin:           ", _getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  Gateway:               ", cfg.gateway);
        console.log("  CEAFactory:            ", cfg.ceaFactory);
        console.log("  Admin:                 ", admin);
        console.log("  Pauser:                ", pauser);
        console.log("  TSS:                   ", tss);
        console.log("");
        console.log("========================================");
        console.log("Vault Address: %s", vaultProxy);
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        if (cfg.gateway == address(0)) {
            console.log("1. Deploy UniversalGateway with VAULT_ADDRESS=%s", vaultProxy);
            console.log("2. Call vault.setGateway(<gateway_proxy_address>)");
        } else {
            console.log("1. Call gateway.updateVault(%s)", vaultProxy);
            console.log("2. Verify integration between Gateway and Vault");
        }
        console.log("3. Verify contracts on block explorer");
        console.log("4. Transfer roles if needed");
        console.log("5. Test CEA deployment functionality");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdmin) {
        bytes32 raw = vm.load(vaultProxy, _ADMIN_SLOT);
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
//   <IMPL_ADDR> src/Vault.sol:Vault \
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
