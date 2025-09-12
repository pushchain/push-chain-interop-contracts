// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniversalGatewayV0} from "../src/UniversalGatewayV0.sol";

/**
 * @title DeployGatewayImpl
 * @notice Deploy only the UniversalGatewayV0 implementation contract
 * @dev This script deploys just the implementation without proxy setup
 *      Useful for testing or when you want to deploy implementation separately
 */
contract DeployGatewayImpl is Script {
    
    // Deployed implementation address
    address public implementationAddress;
    
    function run() external {
        console.log("=== DEPLOYING GATEWAY IMPLEMENTATION ONLY ===");
        
        // Start broadcasting transactions
        vm.startBroadcast();
        
        // Deploy implementation
        _deployImplementation();
        
        vm.stopBroadcast();
        
        // Log deployment summary
        _logDeploymentSummary();
    }
    
    function _deployImplementation() internal {
        console.log("\n--- Deploying Implementation Contract ---");
        
        UniversalGatewayV0 implementation = new UniversalGatewayV0();
        implementationAddress = address(implementation);
        
        console.log("Implementation deployed at:", implementationAddress);
    }
    
    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contract:");
        console.log("  Implementation:", implementationAddress);
        console.log("");
        console.log("Note: This is just the implementation contract.");
        console.log("To use it, you need to deploy a proxy pointing to this implementation.");
        console.log("Use DeployGatewayToSepolia.s.sol for complete proxy deployment.");
        console.log("");
        console.log("Implementation Address: %s", implementationAddress);
    }
    
    // Helper function to verify implementation deployment
    function verifyImplementation() external view {
        require(implementationAddress != address(0), "Implementation not deployed");
        
        // Basic check that the contract exists and is not empty
        require(implementationAddress.code.length > 0, "Implementation has no code");
        
        console.log("Implementation verification passed!");
        console.log("Implementation Address:", implementationAddress);
    }
}
