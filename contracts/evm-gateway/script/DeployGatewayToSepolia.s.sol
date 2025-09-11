// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniversalGatewayV0} from "../src/UniversalGatewayV0.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployGatewayToSepolia
 * @notice Single deployment script for UniversalGatewayV0 on Sepolia testnet
 * @dev Deploys implementation, proxy admin, and transparent upgradeable proxy
 */
contract DeployGatewayToSepolia is Script {
    
    // =========================
    //     SEPOLIA ADDRESSES
    // =========================
    
    // Sepolia testnet addresses
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address constant SEPOLIA_UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant SEPOLIA_USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
    address constant SEPOLIA_USDT_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    
    // =========================
    //     DEPLOYMENT CONFIG
    // =========================
    
    // Role addresses (to be set by deployer)
    address admin;
    address pauser;
    address tss;
    
    // Gateway configuration
    uint256 constant MIN_CAP_USD = 1e18;      // $1 USD (1e18 = $1)
    uint256 constant MAX_CAP_USD = 10e18;     // $10 USD (1e18 = $1)
    
    // Deployed contract addresses
    address public implementationAddress;
    address public proxyAdminAddress;
    address public proxyAddress;
    
    function run() external {
        console.log("=== DEPLOYING UNIVERSAL GATEWAY TO SEPOLIA ===");
        
        // Get deployment configuration
        _loadDeploymentConfig();
        
        // Start broadcasting transactions
        vm.startBroadcast();
        
        // Deploy contracts
        _deployImplementation();
        _deployProxyAdmin();
        _deployProxy();
        _configureGateway();
        
        vm.stopBroadcast();
        
        // Log deployment summary
        _logDeploymentSummary();
    }
    
    function _loadDeploymentConfig() internal {
        console.log("\n--- Loading Deployment Configuration ---");
        
        // Use deployer as admin for simplicity (can be changed later)
        admin = msg.sender;
        pauser = msg.sender;
        tss = msg.sender;
        
        console.log("Admin address:", admin);
        console.log("Pauser address:", pauser);
        console.log("TSS address:", tss);
        console.log("Min USD cap: $1");
        console.log("Max USD cap: $10");
        console.log("WETH address:", SEPOLIA_WETH);
        console.log("USDT address:", SEPOLIA_USDT);
        console.log("Uniswap V3 Factory:", SEPOLIA_UNISWAP_V3_FACTORY);
        console.log("Uniswap V3 Router:", SEPOLIA_UNISWAP_V3_ROUTER);
        console.log("ETH/USD Price Feed:", SEPOLIA_ETH_USD_FEED);
        console.log("USDT/USD Price Feed:", SEPOLIA_USDT_USD_FEED);
    }
    
    function _deployImplementation() internal {
        console.log("\n--- Deploying Implementation Contract ---");
        
        UniversalGatewayV0 implementation = new UniversalGatewayV0();
        implementationAddress = address(implementation);
        
        console.log("Implementation deployed at:", implementationAddress);
    }
    
    function _deployProxyAdmin() internal {
        console.log("\n--- Deploying ProxyAdmin ---");
        
        ProxyAdmin proxyAdmin = new ProxyAdmin(admin);
        proxyAdminAddress = address(proxyAdmin);
        
        console.log("ProxyAdmin deployed at:", proxyAdminAddress);
        console.log("ProxyAdmin owner:", ProxyAdmin(proxyAdminAddress).owner());
    }
    
    function _deployProxy() internal {
        console.log("\n--- Deploying Transparent Upgradeable Proxy ---");
        
        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayV0.initialize.selector,
            admin,                          // admin
            pauser,                         // pauser  
            tss,                           // tss
            MIN_CAP_USD,                   // minCapUsd
            MAX_CAP_USD,                   // maxCapUsd
            SEPOLIA_UNISWAP_V3_FACTORY,    // factory
            SEPOLIA_UNISWAP_V3_ROUTER,     // router
            SEPOLIA_WETH,                  // wethAddress
            SEPOLIA_USDT,                  // usdtAddress
            SEPOLIA_USDT_USD_FEED,         // usdtUsdPriceFeed
            SEPOLIA_ETH_USD_FEED           // ethUsdPriceFeed
        );
        
        // Deploy proxy with initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            implementationAddress,
            proxyAdminAddress,
            initData
        );
        
        proxyAddress = address(proxy);
        console.log("Proxy deployed at:", proxyAddress);
    }
    
    function _configureGateway() internal {
        console.log("\n--- Configuring Gateway ---");
        
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(proxyAddress));
        
        // ETH/USD price feed and USDT configuration are now set in initialize()
        console.log("ETH/USD feed and USDT config set during initialization");
        
        // Set a reasonable staleness period for testnet (24 hours)
        console.log("Setting staleness period...");
        gateway.setChainlinkStalePeriod(24 hours);
        
        // No L2 sequencer feed for Sepolia (it's L1 testnet)
        console.log("Disabling L2 sequencer feed for Sepolia...");
        gateway.setL2SequencerFeed(address(0));
        
        console.log("Gateway configuration completed!");
    }
    
    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  Implementation:", implementationAddress);
        console.log("  ProxyAdmin:", proxyAdminAddress);
        console.log("  Proxy (Gateway):", proxyAddress);
        console.log("");
        console.log("Configuration:");
        console.log("  Admin:", admin);
        console.log("  Pauser:", pauser);
        console.log("  TSS:", tss);
        console.log("  Min Cap: $1 USD");
        console.log("  Max Cap: $10 USD");
        console.log("  WETH:", SEPOLIA_WETH);
        console.log("  USDT:", SEPOLIA_USDT);
        console.log("  ETH/USD Feed:", SEPOLIA_ETH_USD_FEED);
        console.log("  USDT/USD Feed:", SEPOLIA_USDT_USD_FEED);
        console.log("  Staleness Period: 24 hours");
        console.log("");
        console.log("Deployment completed successfully!");
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify contracts on Etherscan");
        console.log("2. Add supported tokens for bridging");
        console.log("3. Update role assignments if needed");
        console.log("4. Test addFunds function with USDT swaps");
        console.log("");
        console.log("Gateway Address (use this): %s", proxyAddress);
    }
    
    // Helper function to verify deployment
    function verifyDeployment() external view {
        require(implementationAddress != address(0), "Implementation not deployed");
        require(proxyAdminAddress != address(0), "ProxyAdmin not deployed");
        require(proxyAddress != address(0), "Proxy not deployed");
        
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(proxyAddress));
        
        // Basic checks
        require(gateway.tssAddress() == tss, "TSS address mismatch");
        require(gateway.MIN_CAP_UNIVERSAL_TX_USD() == MIN_CAP_USD, "Min cap mismatch");
        require(gateway.MAX_CAP_UNIVERSAL_TX_USD() == MAX_CAP_USD, "Max cap mismatch");
        require(gateway.WETH() == SEPOLIA_WETH, "WETH address mismatch");
        require(gateway.USDT() == SEPOLIA_USDT, "USDT address mismatch");
        require(address(gateway.ethUsdFeed()) == SEPOLIA_ETH_USD_FEED, "ETH/USD feed mismatch");
        require(address(gateway.usdtUsdPriceFeed()) == SEPOLIA_USDT_USD_FEED, "USDT/USD feed mismatch");
        
        console.log("Deployment verification passed!");
    }
}
