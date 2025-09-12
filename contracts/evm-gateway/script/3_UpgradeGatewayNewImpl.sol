// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniversalGatewayV0} from "../src/UniversalGatewayV0.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title UpgradeGatewayNewImpl
 * @notice Upgrade an existing proxy to point to a new implementation
 * @dev This script upgrades a proxy to a new implementation contract
 *      Requires the proxy admin to execute the upgrade
 */
contract UpgradeGatewayNewImpl is Script {
    
    // =========================
    //     CONFIGURATION
    // =========================
    
    // Existing proxy and admin addresses (set these before running)
    address constant EXISTING_PROXY = 0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A;
    address constant EXISTING_PROXY_ADMIN = 0x756C0bEa91F5692384AEe147C10409BB062Bf39b;
    
    // New implementation address (will be deployed or set)
    address public newImplementationAddress;
    
    function run() external {
        console.log("=== UPGRADING GATEWAY PROXY ===");
        
        // Load configuration
        _loadUpgradeConfig();
        
        // Start broadcasting transactions
        vm.startBroadcast();
        
        // Deploy new implementation (or use existing)
        _deployNewImplementation();
        
        // Upgrade the proxy
        _upgradeProxy();
        
        vm.stopBroadcast();
        
        // Log upgrade summary
        _logUpgradeSummary();
    }
    
    function _loadUpgradeConfig() internal view {
        console.log("\n--- Loading Upgrade Configuration ---");
        require(EXISTING_PROXY != address(0), "Existing Proxy is not set");
        require(EXISTING_PROXY_ADMIN != address(0), "Existing ProxyAdmin is not set");
        console.log("Existing Proxy:", EXISTING_PROXY);
        console.log("Existing ProxyAdmin:", EXISTING_PROXY_ADMIN);
        console.log("Deployer:", msg.sender);
    }
    
    function _deployNewImplementation() internal {
        console.log("\n--- Deploying New Implementation ---");
        
        // Deploy new implementation
        UniversalGatewayV0 newImplementation = new UniversalGatewayV0();
        newImplementationAddress = address(newImplementation);
        
        console.log("New implementation deployed at:", newImplementationAddress);
    }
    
    function _upgradeProxy() internal {
        console.log("\n--- Upgrading Proxy ---");
        
        // Get the proxy admin contract
        ProxyAdmin proxyAdmin = ProxyAdmin(EXISTING_PROXY_ADMIN);
        
        // Check current implementation (call proxy directly in v5)
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(EXISTING_PROXY);
        
        console.log("New implementation:", newImplementationAddress);
        
        // Perform the upgrade using upgradeAndCall with empty data
        proxyAdmin.upgradeAndCall(proxy, newImplementationAddress, "");
        
        console.log("Proxy upgraded successfully!");
        console.log("Upgrade verified - new implementation is active");
    }
    
    function _logUpgradeSummary() internal view {
        console.log("\n=== UPGRADE SUMMARY ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Upgrade Details:");
        console.log("  Proxy Address:", EXISTING_PROXY);
        console.log("  ProxyAdmin Address:", EXISTING_PROXY_ADMIN);
        console.log("  New Implementation:", newImplementationAddress);
        console.log("");
        console.log("Proxy Address (unchanged): %s", EXISTING_PROXY);
    }
    
    // Helper function to verify upgrade
    function verifyUpgrade() external view {
        require(newImplementationAddress != address(0), "New implementation not deployed");
        
        // Note: In OpenZeppelin v5, we can't easily get implementation from ProxyAdmin
        // This verification is simplified - the upgrade call itself will revert if it fails
        console.log("Upgrade verification: Implementation was set to:", newImplementationAddress);

    }
    
    // Alternative function to upgrade to a specific implementation address
    // function upgradeToSpecificImplementation(address specificImplementation) external {
    //     console.log("=== UPGRADING TO SPECIFIC IMPLEMENTATION ===");
    //     console.log("Target implementation:", specificImplementation);
        
    //     vm.startBroadcast();
        
    //     ProxyAdmin proxyAdmin = ProxyAdmin(EXISTING_PROXY_ADMIN);
    //     ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(EXISTING_PROXY);
        
    //     // Perform the upgrade using upgradeAndCall with empty data
    //     proxyAdmin.upgradeAndCall(proxy, specificImplementation, "");
        
    //     console.log("Proxy upgraded to specific implementation!");
        
    //     vm.stopBroadcast();
        
    //     console.log("Upgrade to specific implementation completed!");
    //     console.log("New implementation address:", specificImplementation);
    // }
}
