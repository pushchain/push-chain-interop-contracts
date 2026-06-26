// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../../src/testnetV0/UniversalGatewayV0.sol";
import { GatewayConfig } from "../../config/testnet/GatewayConfig.sol";

/**
 * @title RegisterVault
 * @notice Registers the Vault and CEAFactory addresses on the upgraded UniversalGatewayV0.
 *         Reads gatewayProxy and vault from GatewayConfig.
 *         CEAFactory address is passed as a CLI argument.
 *
 * @dev  Must be run AFTER upgradeGatewayV0_upgrade1.s.sol and BEFORE moveFunds.s.sol.
 *
 * USAGE:
 * forge script script/gatewayV0/registerVault.s.sol:RegisterVault \
 *   --sig "run(address)" <CEA_FACTORY_ADDRESS> \
 *   --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract RegisterVault is Script, GatewayConfig {
    Config cfg;

    function run(address ceaFactory) external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  REGISTERING VAULT & CEAFactory");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Caller:  ", msg.sender);
        console.log("");

        _validateConfiguration(ceaFactory);

        vm.startBroadcast();
        _registerVault();
        _registerCEAFactory(ceaFactory);
        vm.stopBroadcast();

        _verifyRegistration(ceaFactory);
        _printSummary(ceaFactory);
    }

    function _validateConfiguration(address ceaFactory) internal view {
        console.log("--- Pre-Registration Validation ---");
        console.log("");

        require(cfg.gatewayProxy != address(0), "gatewayProxy not set in config");
        require(cfg.vault != address(0), "vault not set in config");
        require(ceaFactory != address(0), "ceaFactory argument is zero");

        uint256 vaultCodeSize;
        address vaultAddr = cfg.vault;
        assembly {
            vaultCodeSize := extcodesize(vaultAddr)
        }
        require(vaultCodeSize > 0, "Vault contract not found");

        uint256 ceaCodeSize;
        assembly {
            ceaCodeSize := extcodesize(ceaFactory)
        }
        require(ceaCodeSize > 0, "CEAFactory contract not found");

        console.log("OK: Gateway proxy:", cfg.gatewayProxy);
        console.log("OK: Vault:", cfg.vault);
        console.log("OK: CEAFactory:", ceaFactory);
        console.log("");
    }

    function _registerVault() internal {
        console.log("--- Registering Vault ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(cfg.gatewayProxy));
        gateway.updateVault(cfg.vault);
        console.log("updateVault() called with:", cfg.vault);
        console.log("");
    }

    function _registerCEAFactory(address ceaFactory) internal {
        console.log("--- Registering CEAFactory ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(cfg.gatewayProxy));
        gateway.updateCEAFactory(ceaFactory);
        console.log("updateCEAFactory() called with:", ceaFactory);
        console.log("");
    }

    function _verifyRegistration(address ceaFactory) internal view {
        console.log("--- Registration Verification ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(cfg.gatewayProxy));

        address vault = gateway.VAULT();
        address factory = gateway.CEA_FACTORY();

        require(vault == cfg.vault, "VAULT not set correctly");
        require(factory == ceaFactory, "CEA_FACTORY not set correctly");

        bytes32 vaultRole = gateway.VAULT_ROLE();
        require(gateway.hasRole(vaultRole, cfg.vault), "VAULT_ROLE not granted");

        console.log("OK: VAULT =", vault);
        console.log("OK: CEA_FACTORY =", factory);
        console.log("OK: VAULT_ROLE granted to Vault");
        console.log("");
    }

    function _printSummary(address ceaFactory) internal view {
        console.log("========================================");
        console.log("     REGISTRATION SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Gateway Proxy:   ", cfg.gatewayProxy);
        console.log("Vault:           ", cfg.vault);
        console.log("CEAFactory:      ", ceaFactory);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Run moveFunds.s.sol to migrate tokens to Vault");
        console.log("========================================");
    }
}
