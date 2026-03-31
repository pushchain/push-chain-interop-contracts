// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../../src/UniversalGateway.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { GatewayConfig } from "../../config/mainnet/GatewayConfig.sol";

/**
 * @title UpgradeGateway
 * @notice Upgrade script for UniversalGateway proxy
 * @dev Deploys new implementation and upgrades existing proxy
 *
 * USAGE:
 * forge script script/gateway/UpgradeGateway.s.sol:UpgradeGateway \
 *   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract UpgradeGateway is Script, GatewayConfig {
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
        console.log("  UPGRADING UNIVERSAL GATEWAY");
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
        require(cfg.gatewayProxy != address(0), "gatewayProxy not set in config");

        // Verify proxy has code
        uint256 proxyCodeSize;
        address proxyAddr = cfg.gatewayProxy;
        assembly {
            proxyCodeSize := extcodesize(proxyAddr)
        }
        require(proxyCodeSize > 0, "Gateway proxy not found at config address");

        // Verify msg.sender is ProxyAdmin owner
        address proxyAdminAddr = _getProxyAdmin();
        ProxyAdmin admin = ProxyAdmin(proxyAdminAddr);
        address owner = admin.owner();

        require(msg.sender == owner, "Caller is not ProxyAdmin owner");

        console.log("OK: Proxy found at:", cfg.gatewayProxy);
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

        UniversalGateway implementation = new UniversalGateway();
        newImplementation = address(implementation);

        console.log("New Implementation deployed at:", newImplementation);
        console.log("");
    }

    function _performUpgrade() internal {
        console.log("--- Performing Upgrade ---");

        ProxyAdmin admin = ProxyAdmin(proxyAdmin);

        // Upgrade the proxy to new implementation (OpenZeppelin v5 uses upgradeAndCall)
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(cfg.gatewayProxy), newImplementation, ""
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

        UniversalGateway gateway = UniversalGateway(payable(cfg.gatewayProxy));

        // Verify all critical state preserved
        address vault = gateway.VAULT();
        address tssAddr = gateway.TSS_ADDRESS();
        address ceaFactory = gateway.CEA_FACTORY();
        uint256 minCap = gateway.MIN_CAP_UNIVERSAL_TX_USD();
        uint256 maxCap = gateway.MAX_CAP_UNIVERSAL_TX_USD();

        require(vault != address(0), "VAULT lost after upgrade");
        require(tssAddr != address(0), "TSS_ADDRESS lost after upgrade");
        require(ceaFactory != address(0), "CEA_FACTORY lost after upgrade");
        require(minCap > 0, "MIN_CAP lost after upgrade");
        require(maxCap > minCap, "MAX_CAP invalid after upgrade");
        require(gateway.epochDurationSec() > 0, "epochDurationSec lost after upgrade");
        require(gateway.chainlinkStalePeriod() > 0, "chainlinkStalePeriod lost after upgrade");
        require(address(gateway.ethUsdFeed()) != address(0), "ethUsdFeed lost after upgrade");
        require(address(gateway.uniV3Factory()) != address(0), "uniV3Factory lost after upgrade");
        require(address(gateway.uniV3Router()) != address(0), "uniV3Router lost after upgrade");

        // Verify roles preserved
        require(gateway.hasRole(gateway.VAULT_ROLE(), vault), "VAULT_ROLE lost after upgrade");
        require(gateway.hasRole(gateway.TSS_ROLE(), tssAddr), "TSS_ROLE lost after upgrade");

        console.log("OK: Implementation updated successfully");
        console.log("OK: VAULT:", vault);
        console.log("OK: TSS_ADDRESS:", tssAddr);
        console.log("OK: CEA_FACTORY:", ceaFactory);
        console.log("OK: MIN_CAP:", minCap);
        console.log("OK: MAX_CAP:", maxCap);
        console.log("OK: Roles preserved");
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
        console.log("Gateway Proxy:        ", cfg.gatewayProxy);
        console.log("Proxy Admin:          ", proxyAdmin);
        console.log("");
        console.log("Old Implementation:   ", oldImplementation);
        console.log("New Implementation:   ", newImplementation);
        console.log("");
        console.log("========================================");
        console.log("Upgrade Complete!");
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify new implementation on block explorer");
        console.log("2. Test gateway functionality");
        console.log("3. Monitor for any issues");
        console.log("4. Update frontend to use new ABI if needed");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdminAddr) {
        bytes32 raw = vm.load(cfg.gatewayProxy, _ADMIN_SLOT);
        proxyAdminAddr = address(uint160(uint256(raw)));
    }

    function _getImplementation() internal view returns (address implementation) {
        bytes32 raw = vm.load(cfg.gatewayProxy, _IMPLEMENTATION_SLOT);
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
//   <NEW_IMPL_ADDR> src/UniversalGateway.sol:UniversalGateway \
//   --etherscan-api-key $ETHERSCAN_API_KEY
