// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../../src/UniversalGateway.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { GatewayConfig } from "../../config/mainnet/GatewayConfig.sol";

/**
 * @title DeployGateway
 * @notice Deployment script for UniversalGateway on external EVM chains
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * USAGE:
 * forge script script/mainnet/gateway/deployGateway.s.sol:DeployGateway \
 *   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify \
 *   --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployGateway is Script, GatewayConfig {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ========================================
    //     ROLE ADDRESSES
    // ========================================
    address admin;
    address pauser;
    address tss;

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    Config cfg;
    address public gatewayImplementation;
    address public gatewayProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
        cfg = getConfig();
        deployChainId = block.chainid;

        console.log("========================================");
        console.log("  DEPLOYING UNIVERSAL GATEWAY");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", deployChainId);
        console.log("Deployer:", msg.sender);
        console.log("");

        _validateConfiguration();

        vm.startBroadcast();

        _loadRoles();
        _deployImplementation();
        _deployProxy();
        _configureGateway();
        _verifyDeployment();

        vm.stopBroadcast();

        _printDeploymentSummary();
    }

    // ========================================
    //         VALIDATION
    // ========================================
    function _validateConfiguration() internal view {
        console.log("--- Pre-Deployment Validation ---");
        console.log("");

        // Critical: Vault must be deployed first
        require(cfg.vault != address(0), "vault not set in config");
        uint256 vaultCodeSize;
        address vaultAddr = cfg.vault;
        assembly {
            vaultCodeSize := extcodesize(vaultAddr)
        }
        require(vaultCodeSize > 0, "Vault contract not found at config address");

        // Critical: TSS must be explicitly set (never deployer on mainnet)
        require(cfg.tssAddress != address(0), "tssAddress not set in config");

        // Critical: Admin must be explicitly set (multisig on mainnet)
        require(cfg.admin != address(0), "admin not set in config");

        // Validate USD caps from config
        require(cfg.minCapUsd > 0, "minCapUsd must be > 0");
        require(cfg.maxCapUsd > cfg.minCapUsd, "maxCapUsd must be > minCapUsd");

        // Validate oracle config
        require(cfg.ethUsdFeed != address(0), "ethUsdFeed is zero in config");
        require(cfg.chainlinkStalePeriodSec > 0, "chainlinkStalePeriodSec must be > 0");

        // Validate DEX addresses
        require(cfg.uniswapV3Factory != address(0), "uniswapV3Factory is zero in config");
        require(cfg.uniswapV3Router != address(0), "uniswapV3Router is zero in config");
        require(cfg.weth != address(0), "weth is zero in config");

        console.log("OK: All validation checks passed");
        console.log("");
    }

    function _loadRoles() internal {
        console.log("--- Loading Role Configuration ---");

        // Read from config — fallback to msg.sender only if not set
        admin = cfg.admin != address(0) ? cfg.admin : msg.sender;
        pauser = cfg.pauser != address(0) ? cfg.pauser : msg.sender;
        tss = cfg.tssAddress;

        console.log("Admin:", admin);
        console.log("Pauser:", pauser);
        console.log("TSS:", tss);
        console.log("");
    }

    // ========================================
    //         DEPLOYMENT STEPS
    // ========================================
    function _deployImplementation() internal {
        console.log("--- Deploying Gateway Implementation ---");

        UniversalGateway implementation = new UniversalGateway();
        gatewayImplementation = address(implementation);

        console.log("Implementation deployed at:", gatewayImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // initialize(admin, pauser, tss, vaultAddress, minCapUsd, maxCapUsd, factory, router, wethAddress)
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            pauser,
            tss,
            cfg.vault,
            cfg.minCapUsd,
            cfg.maxCapUsd,
            cfg.uniswapV3Factory,
            cfg.uniswapV3Router,
            cfg.weth
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(gatewayImplementation, cfg.deployer, initData);

        gatewayProxy = address(proxy);
        console.log("Proxy deployed at:", gatewayProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    function _configureGateway() internal {
        console.log("--- Configuring Gateway ---");

        UniversalGateway gateway = UniversalGateway(payable(gatewayProxy));

        // Set ETH/USD price feed (not part of initialize)
        console.log("Setting ETH/USD feed:", cfg.ethUsdFeed);
        gateway.setEthUsdFeed(cfg.ethUsdFeed);

        // Set Chainlink staleness period from config
        console.log("Setting Chainlink staleness period:", cfg.chainlinkStalePeriodSec, "sec");
        gateway.setChainlinkStalePeriod(cfg.chainlinkStalePeriodSec);

        // Set L2 sequencer feed (address(0) disables for L1)
        console.log("Setting L2 sequencer feed:", cfg.l2SequencerFeed);
        gateway.setL2SequencerFeed(cfg.l2SequencerFeed);
        if (cfg.l2SequencerGracePeriodSec > 0) {
            console.log("Setting L2 sequencer grace period:", cfg.l2SequencerGracePeriodSec, "sec");
            gateway.setL2SequencerGracePeriod(cfg.l2SequencerGracePeriodSec);
        }

        // Set CEA Factory if available
        if (cfg.ceaFactory != address(0)) {
            console.log("Setting CEA Factory:", cfg.ceaFactory);
            gateway.setCEAFactory(cfg.ceaFactory);
        }

        console.log("Configuration complete");
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(gatewayImplementation != address(0), "Implementation not deployed");
        require(gatewayProxy != address(0), "Proxy not deployed");

        UniversalGateway gateway = UniversalGateway(payable(gatewayProxy));

        // Verify initialization parameters
        require(gateway.VAULT() == cfg.vault, "Vault address mismatch");
        require(gateway.TSS_ADDRESS() == tss, "TSS address mismatch");
        require(gateway.MIN_CAP_UNIVERSAL_TX_USD() == cfg.minCapUsd, "Min cap mismatch");
        require(gateway.MAX_CAP_UNIVERSAL_TX_USD() == cfg.maxCapUsd, "Max cap mismatch");
        require(gateway.WETH() == cfg.weth, "WETH mismatch");
        require(address(gateway.ethUsdFeed()) == cfg.ethUsdFeed, "ETH/USD feed mismatch");
        require(gateway.chainlinkStalePeriod() == cfg.chainlinkStalePeriodSec, "Staleness mismatch");

        // Verify roles
        require(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        require(gateway.hasRole(gateway.PAUSER_ROLE(), pauser), "Pauser role not set");
        require(gateway.hasRole(gateway.TSS_ROLE(), tss), "TSS role not set");

        // Verify CEA Factory if set
        if (cfg.ceaFactory != address(0)) {
            require(gateway.CEA_FACTORY() == cfg.ceaFactory, "CEA_FACTORY mismatch");
        }

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
        console.log("  Gateway Implementation:", gatewayImplementation);
        console.log("  Gateway Proxy:         ", gatewayProxy);
        console.log("  Proxy Admin:           ", _getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  Vault:          ", cfg.vault);
        console.log("  Admin:          ", admin);
        console.log("  Pauser:         ", pauser);
        console.log("  TSS:            ", tss);
        console.log("  Min USD Cap:     $", cfg.minCapUsd / 1e18);
        console.log("  Max USD Cap:     $", cfg.maxCapUsd / 1e18);
        console.log("  WETH:           ", cfg.weth);
        console.log("  ETH/USD Feed:   ", cfg.ethUsdFeed);
        console.log("  Staleness:       ", cfg.chainlinkStalePeriodSec, "sec");
        console.log("");
        console.log("========================================");
        console.log("Gateway Address: %s", gatewayProxy);
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Update Vault.setGateway(%s)", gatewayProxy);
        console.log("2. Verify contracts on block explorer");
        console.log("3. Transfer DEFAULT_ADMIN_ROLE to multisig if not already set");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdmin) {
        bytes32 raw = vm.load(gatewayProxy, _ADMIN_SLOT);
        proxyAdmin = address(uint160(uint256(raw)));
    }
}

// ========================================
//      VERIFICATION COMMANDS
// ========================================
//
// 1. Verify Implementation:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <IMPL_ADDR> src/UniversalGateway.sol:UniversalGateway \
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
