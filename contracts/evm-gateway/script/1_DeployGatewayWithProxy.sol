// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniversalGatewayV0} from "../src/UniversalGatewayV0.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployGatewayWithProxy
 * @notice Single deployment script for UniversalGatewayV0 on Sepolia testnet
 * @dev Deploys implementation, proxy admin, and transparent upgradeable proxy
 */
contract DeployGatewayWithProxy is Script {
    
    // Sepolia testnet constructor args
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address constant SEPOLIA_UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant SEPOLIA_USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
    address constant SEPOLIA_USDT_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    address constant DEPLOYER = 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6;
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    
    // Role addresses (to be set by deployer)
    address admin;
    address pauser;
    address tss;
    
    // Gateway configuration
    uint256 constant MIN_CAP_USD = 1e18;      // $1 USD (1e18 = $1)
    uint256 constant MAX_CAP_USD = 10e18;     // $10 USD (1e18 = $1)
    
    // Deployed contract addresses
    address public implementationAddress;
    address public proxyAddress;
    
    function run() external {
        console.log("=== DEPLOYING UNIVERSAL GATEWAY TO SEPOLIA ===");
        
        // Start broadcasting transactions
        vm.startBroadcast();

        _loadDeploymentConfig();
        
        // Deploy contracts
        _deployImplementation();
        _deployProxy();
        _configureGateway();

        // Verify contracts and ADMIN CONFIGS
        _verifyAllAdmins();
        _verifyDeployment();
        
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
            DEPLOYER,
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
        console.log("  Proxy (Gateway):", proxyAddress);
        console.log("  Proxy Admin:", getProxyAdmin());
        console.log("Deployment completed successfully!");
        console.log("");
        console.log("Gateway Address (use this): %s", proxyAddress);
    }

    function _verifyAllAdmins() internal view {
        console.log("--- Admin Verification ---");
        
        // Get admin of TransparentProxy
        address proxyAdmin = getProxyAdmin();
        console.log("TransparentProxy admin:", proxyAdmin);
        
        // Get admin (owner) of ProxyAdmin
        address proxyAdminOwner = getProxyAdminOwner();
        console.log("ProxyAdmin owner:", proxyAdminOwner);

        if (proxyAdminOwner == DEPLOYER) {
            console.log("OK: ProxyAdmin owner correctly points to DEPLOYER");
        } else {
            console.log("WARNING: ProxyAdmin owner does not point to DEPLOYER");
        }
        
        if (proxyAdmin != DEPLOYER) {
            console.log("OK: Proxy admin is auto-deployed and accurate");
        } else {
            console.log("WARNING: Proxy admin is not auto-deployed and points to DEPLOYER ADDRESS");
        }
        
        console.log("");
    }

        // Helper function to verify deployment
    function _verifyDeployment() internal view {
        require(implementationAddress != address(0), "Implementation not deployed");
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

    // HELPERS
     /**
     * @notice Get the admin of the TransparentProxy
     * @return proxyADMIN The address of the proxy admin
     */
    function getProxyAdmin() public view returns (address proxyADMIN) {
        // Read admin directly from the EIP-1967 admin slot on the proxy
        bytes32 raw = vm.load(proxyAddress, _ADMIN_SLOT);
        proxyADMIN = address(uint160(uint256(raw)));
    }

    /**
     * @notice Get the owner (admin) of the ProxyAdmin contract
     * @return owner The address of the ProxyAdmin owner
     */
    function getProxyAdminOwner() public view returns (address owner) {
        address proxyADMIN = getProxyAdmin();

        ProxyAdmin proxyAdmin = ProxyAdmin(proxyADMIN);
        owner = proxyAdmin.owner();
    }


}

// VERIFICATION COMMAND: 
// 1. For TransparentUpgradeableProxy: forge verify-contract --chain sepolia --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <IMPLEMENTATION_ADDR> <PROXY_ADMIN_ADDR 0x) <PROXY_ADDR lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProx
// 2. For Gateway: forge verify-contract --chain sepolia --constructor-args $(cast abi-encode "constructor()" ) <IMPLEMENTATION_ADDR> src/UniversalGatewayV0.sol:UniversalGatewayV0
// 3. For ProxyAdmin: forge verify-contract --chain sepolia --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDR>) <PROXY_ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin


// DEPLOYMENT COMMAND: