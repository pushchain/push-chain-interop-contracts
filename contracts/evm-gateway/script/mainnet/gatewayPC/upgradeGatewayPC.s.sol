// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayPC } from "../../../src/UniversalGatewayPC.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { GatewayPCConfig } from "../../config/mainnet/GatewayPCConfig.sol";

/**
 * @title UpgradeGatewayPC
 * @notice Upgrade script for UniversalGatewayPC proxy on Push Chain
 * @dev Deploys new implementation and upgrades existing proxy
 *
 * USAGE:
 * forge script script/gatewayPC/UpgradeGatewayPC.s.sol:UpgradeGatewayPC \
 *   --rpc-url $PUSH_CHAIN_RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract UpgradeGatewayPC is Script, GatewayPCConfig {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ========================================
    //         UPGRADE STATE
    // ========================================
    Config cfg;
    address public oldImplementation;
    address public newImplementation;
    address public proxyAdmin;
    uint256 public upgradeChainId;

    // ========================================
    //         MAIN UPGRADE
    // ========================================
    function run() external {
        cfg = getConfig();
        upgradeChainId = block.chainid;

        console.log("========================================");
        console.log("  UPGRADING GATEWAYPC ON PUSH CHAIN");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", upgradeChainId);
        console.log("Upgrader:", msg.sender);
        console.log("");

        // Pre-upgrade validation
        _validateConfiguration();

        // Get old implementation
        _recordOldImplementation();

        // Start broadcasting
        vm.startBroadcast();

        // Deploy new implementation
        _deployNewImplementation();

        // Perform upgrade
        _performUpgrade();

        // Verify upgrade
        _verifyUpgrade();

        vm.stopBroadcast();

        // Print summary
        _printUpgradeSummary();
    }

    // ========================================
    //         VALIDATION
    // ========================================
    function _validateConfiguration() internal view {
        console.log("--- Pre-Upgrade Validation ---");
        console.log("");

        // Validate proxy address
        require(cfg.gatewayPCProxy != address(0), "gatewayPCProxy not set in config");

        // Verify proxy has code
        uint256 proxyCodeSize;
        address proxyAddr = cfg.gatewayPCProxy;
        assembly {
            proxyCodeSize := extcodesize(proxyAddr)
        }
        require(proxyCodeSize > 0, "GatewayPC proxy not found at config address");

        // Verify msg.sender is ProxyAdmin owner
        address proxyAdminAddr = _getProxyAdmin();
        ProxyAdmin admin = ProxyAdmin(proxyAdminAddr);
        address owner = admin.owner();

        require(msg.sender == owner, "Caller is not ProxyAdmin owner");

        console.log("OK: Proxy found at:", cfg.gatewayPCProxy);
        console.log("OK: ProxyAdmin:", proxyAdminAddr);
        console.log("OK: ProxyAdmin owner:", owner);
        console.log("OK: Caller authorized for upgrade");
        console.log("");
    }

    function _recordOldImplementation() internal {
        console.log("--- Recording Old Implementation ---");

        proxyAdmin = _getProxyAdmin();
        oldImplementation = _getImplementation();

        console.log("Old Implementation:", oldImplementation);
        console.log("");
    }

    // ========================================
    //         UPGRADE STEPS
    // ========================================
    function _deployNewImplementation() internal {
        console.log("--- Deploying New Implementation ---");

        UniversalGatewayPC implementation = new UniversalGatewayPC();
        newImplementation = address(implementation);

        console.log("New Implementation deployed at:", newImplementation, "");
        console.log("");
    }

    function _performUpgrade() internal {
        console.log("--- Performing Upgrade ---");

        ProxyAdmin admin = ProxyAdmin(proxyAdmin);

        // Upgrade the proxy to new implementation
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(cfg.gatewayPCProxy), newImplementation, ""
        );

        console.log("Upgrade executed");
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyUpgrade() internal view {
        console.log("--- Upgrade Verification ---");

        address currentImplementation = _getImplementation();

        require(currentImplementation == newImplementation, "Implementation not updated");
        require(currentImplementation != oldImplementation, "Implementation unchanged");

        // Verify proxy still works (call a view function)
        UniversalGatewayPC gatewayPC = UniversalGatewayPC(cfg.gatewayPCProxy);
        address universalCore = gatewayPC.universalCore();
        address vaultPC = address(gatewayPC.vaultPC());
        uint256 currentNonce = gatewayPC.nonce();

        require(universalCore != address(0), "GatewayPC state corrupted");
        require(vaultPC != address(0), "GatewayPC state corrupted");

        console.log("OK: Implementation updated successfully");
        console.log("OK: GatewayPC state preserved");
        console.log("OK: UniversalCore reference intact:", universalCore);
        console.log("OK: VaultPC reference intact:", vaultPC);
        console.log("OK: Current nonce:", currentNonce);
        console.log("");
    }

    function _printUpgradeSummary() internal view {
        console.log("========================================");
        console.log("     UPGRADE SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", upgradeChainId);
        console.log("Upgrader:", msg.sender);
        console.log("");
        console.log("GatewayPC Proxy:      ", cfg.gatewayPCProxy);
        console.log("Proxy Admin:          ", proxyAdmin);
        console.log("");
        console.log("Old Implementation:   ", oldImplementation);
        console.log("New Implementation:   ", newImplementation, "");
        console.log("");
        console.log("========================================");
        console.log("Upgrade Complete!");
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify new implementation on block explorer");
        console.log("2. Test GatewayPC functionality");
        console.log("3. Test outbound transaction flow");
        console.log("4. Monitor nonce and fee collection");
        console.log("5. Update frontend to use new ABI if needed");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdminAddr) {
        bytes32 raw = vm.load(cfg.gatewayPCProxy, _ADMIN_SLOT);
        proxyAdminAddr = address(uint160(uint256(raw)));
    }

    function _getImplementation() internal view returns (address implementation) {
        bytes32 raw = vm.load(cfg.gatewayPCProxy, _IMPLEMENTATION_SLOT);
        implementation = address(uint160(uint256(raw)));
    }
}

// ========================================
//      VERIFICATION COMMANDS
// ========================================
//
// Verify New Implementation:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <NEW_IMPL_ADDR> src/UniversalGatewayPC.sol:UniversalGatewayPC \
//   --etherscan-api-key $ETHERSCAN_API_KEY
