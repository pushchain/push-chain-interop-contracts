// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0_temp } from "../../../src/testnetV0/UniversalGatewayV0_temp.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GatewayConfig } from "../../config/testnet/GatewayConfig.sol";

/**
 * @title MoveFunds
 * @notice Calls moveFunds_temp(token) on the upgraded UniversalGatewayV0_temp to migrate
 *         token balances from the Gateway to the Vault on the current chain.
 *
 * @dev  Must run AFTER registerVault.s.sol and BEFORE upgradeGatewayV0_upgrade2.s.sol.
 *       Reads gatewayProxy and vault from GatewayConfig.
 *       Token address is passed as the first CLI argument via --sig "run(address)" <TOKEN>.
 *       Pass address(0) to migrate native balance.
 *
 * USAGE (ERC20):
 * forge script script/gatewayV0/moveFunds.s.sol:MoveFunds \
 *   --sig "run(address)" <TOKEN_ADDRESS> \
 *   --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 *
 * USAGE (native):
 * forge script script/gatewayV0/moveFunds.s.sol:MoveFunds \
 *   --sig "run(address)" 0x0000000000000000000000000000000000000000 \
 *   --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract MoveFunds is Script, GatewayConfig {
    Config cfg;

    function run(address token) external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  MIGRATE FUNDS: Gateway -> Vault");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Caller:  ", msg.sender);
        console.log("Token:   ", token);
        console.log("");

        UniversalGatewayV0_temp gateway = UniversalGatewayV0_temp(payable(cfg.gatewayProxy));

        // Validate VAULT is registered
        address vault = gateway.VAULT();
        require(vault == cfg.vault, "VAULT not registered - run registerVault first");
        require(vault != address(0), "VAULT is zero - run registerVault first");
        console.log("OK: VAULT registered:", vault);

        // Record balances before
        uint256 gwBefore;
        uint256 vaultBefore;

        if (token == address(0)) {
            gwBefore = cfg.gatewayProxy.balance;
            vaultBefore = vault.balance;
        } else {
            gwBefore = IERC20(token).balanceOf(cfg.gatewayProxy);
            vaultBefore = IERC20(token).balanceOf(vault);
        }

        console.log("Gateway balance before:", gwBefore);
        console.log("Vault balance before:  ", vaultBefore);
        require(gwBefore > 0, "Gateway has no balance to migrate");
        console.log("");

        // Execute migration
        vm.startBroadcast();
        gateway.moveFunds_temp(token);
        vm.stopBroadcast();

        // Verify balances after
        uint256 gwAfter;
        uint256 vaultAfter;

        if (token == address(0)) {
            gwAfter = cfg.gatewayProxy.balance;
            vaultAfter = vault.balance;
        } else {
            gwAfter = IERC20(token).balanceOf(cfg.gatewayProxy);
            vaultAfter = IERC20(token).balanceOf(vault);
        }

        console.log("Gateway balance after: ", gwAfter);
        console.log("Vault balance after:   ", vaultAfter);

        require(gwAfter == 0, "Gateway balance is not 0 after migration");
        require(
            vaultAfter == vaultBefore + gwBefore,
            "Vault did not increase by migrated amount"
        );

        console.log("");
        console.log("========================================");
        console.log("OK: Migration complete -", gwBefore, "migrated to Vault");
        console.log("========================================");
    }
}
