// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../../src/UniversalGateway.sol";
import { Vault } from "../../../src/Vault.sol";
import { ICEAFactory } from "../../../src/interfaces/ICEAFactory.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title VerifyDeployment
 * @notice Read-only verification script for Gateway + Vault deployments
 * @dev Runs all critical invariant checks and reports PASS/FAIL for each.
 *      Does NOT revert on first failure — shows ALL results, then fails at the end.
 *
 * USAGE:
 * forge script script/mainnet/verify/VerifyDeployment.s.sol:VerifyDeployment \
 *   --sig "run(address,address)" <GATEWAY_PROXY> <VAULT_PROXY> \
 *   --rpc-url $RPC_URL -vvv
 */
contract VerifyDeployment is Script {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 public failCount;

    function run(address gatewayProxy, address vaultProxy) external view {
        console.log("========================================");
        console.log("  DEPLOYMENT VERIFICATION");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Gateway Proxy:", gatewayProxy);
        console.log("Vault Proxy:", vaultProxy);
        console.log("");

        uint256 failures = 0;

        UniversalGateway gateway = UniversalGateway(payable(gatewayProxy));
        Vault vault = Vault(vaultProxy);

        // ============================================================
        //  Category 1: Contract Existence
        // ============================================================
        console.log("--- Category 1: Contract Existence ---");

        failures += _check(_hasCode(gatewayProxy), "Gateway proxy has code");
        failures += _check(_hasCode(vaultProxy), "Vault proxy has code");

        address gwImpl = _readSlotAsAddress(gatewayProxy, _IMPLEMENTATION_SLOT);
        address vImpl = _readSlotAsAddress(vaultProxy, _IMPLEMENTATION_SLOT);
        failures += _check(_hasCode(gwImpl), "Gateway implementation has code");
        failures += _check(_hasCode(vImpl), "Vault implementation has code");
        console.log("");

        // ============================================================
        //  Category 2: Cross-Contract Consistency
        // ============================================================
        console.log("--- Category 2: Cross-Contract Consistency ---");

        address gwVault = gateway.VAULT();
        address vGateway = address(vault.gateway());
        address gwTss = gateway.TSS_ADDRESS();
        address gwCeaFactory = gateway.CEA_FACTORY();
        address vCeaFactory = address(vault.CEAFactory());

        failures += _check(gwVault == vaultProxy, "Gateway.VAULT == Vault proxy");
        failures += _check(vGateway == gatewayProxy, "Vault.gateway == Gateway proxy");
        failures += _check(gwCeaFactory == vCeaFactory, "Gateway.CEA_FACTORY == Vault.CEAFactory");
        failures += _check(vault.hasRole(vault.TSS_ROLE(), gwTss), "Vault.TSS_ROLE granted to Gateway.TSS_ADDRESS");

        console.log("  TSS_ADDRESS:", gwTss);
        console.log("  CEA_FACTORY:", gwCeaFactory);
        console.log("");

        // ============================================================
        //  Category 3: Oracle & DEX Dependencies
        // ============================================================
        console.log("--- Category 3: Oracle & DEX Dependencies ---");

        address ethUsdFeed = address(gateway.ethUsdFeed());
        failures += _check(ethUsdFeed != address(0), "ethUsdFeed is set");
        failures += _check(_hasCode(ethUsdFeed), "ethUsdFeed has code");

        // Try calling getEthUsdPrice — wrap in try/catch via static call
        (bool priceOk, bytes memory priceData) =
            gatewayProxy.staticcall(abi.encodeWithSignature("getEthUsdPrice()"));
        if (priceOk && priceData.length >= 64) {
            (uint256 price, uint8 decimals) = abi.decode(priceData, (uint256, uint8));
            console.log("  ETH/USD price:", price);
            console.log("  ETH/USD decimals:", decimals);
            failures += _check(price > 0, "getEthUsdPrice returns non-zero");
        } else {
            console.log("  [FAIL] getEthUsdPrice() call failed");
            failures++;
        }

        uint256 stalePeriod = gateway.chainlinkStalePeriod();
        failures += _check(stalePeriod > 0, "chainlinkStalePeriod > 0");
        failures += _check(stalePeriod <= 86400, "chainlinkStalePeriod <= 86400");
        console.log("  chainlinkStalePeriod:", stalePeriod, "sec");

        address weth = gateway.WETH();
        failures += _check(weth != address(0), "WETH is set");
        failures += _check(_hasCode(weth), "WETH has code");

        address factory = address(gateway.uniV3Factory());
        address router = address(gateway.uniV3Router());
        failures += _check(factory != address(0), "uniV3Factory is set");
        failures += _check(_hasCode(factory), "uniV3Factory has code");
        failures += _check(router != address(0), "uniV3Router is set");
        failures += _check(_hasCode(router), "uniV3Router has code");

        // L2 sequencer check
        address l2Seq = address(gateway.l2SequencerFeed());
        if (block.chainid == 42161 || block.chainid == 8453) {
            failures += _check(l2Seq != address(0), "L2: sequencer feed is set");
        } else if (block.chainid == 1 || block.chainid == 56) {
            failures += _check(l2Seq == address(0), "L1: sequencer feed is not set");
        }
        console.log("");

        // ============================================================
        //  Category 4: Role Verification
        // ============================================================
        console.log("--- Category 4: Role Verification ---");

        bytes32 vaultRole = keccak256("VAULT_ROLE");
        bytes32 tssRole = keccak256("TSS_ROLE");

        failures += _check(gateway.hasRole(vaultRole, gwVault), "Gateway: VAULT_ROLE granted to Vault");
        // UG no longer manages TSS_ROLE; verify TSS_ADDRESS directly.
        failures += _check(gateway.TSS_ADDRESS() == gwTss, "Gateway: TSS_ADDRESS set to TSS");
        failures += _check(vault.hasRole(tssRole, gwTss), "Vault: TSS_ROLE granted to TSS");

        // ProxyAdmin owners
        address gwProxyAdmin = _readSlotAsAddress(gatewayProxy, _ADMIN_SLOT);
        address vProxyAdmin = _readSlotAsAddress(vaultProxy, _ADMIN_SLOT);
        if (_hasCode(gwProxyAdmin)) {
            address gwPAOwner = ProxyAdmin(gwProxyAdmin).owner();
            failures += _check(gwPAOwner != address(0), "Gateway ProxyAdmin owner is set");
            console.log("  Gateway ProxyAdmin owner:", gwPAOwner);
        }
        if (_hasCode(vProxyAdmin)) {
            address vPAOwner = ProxyAdmin(vProxyAdmin).owner();
            failures += _check(vPAOwner != address(0), "Vault ProxyAdmin owner is set");
            console.log("  Vault ProxyAdmin owner:", vPAOwner);
        }
        console.log("");

        // ============================================================
        //  Category 5: Rate Limits & Config
        // ============================================================
        console.log("--- Category 5: Rate Limits & Config ---");

        uint256 minCap = gateway.MIN_CAP_UNIVERSAL_TX_USD();
        uint256 maxCap = gateway.MAX_CAP_UNIVERSAL_TX_USD();
        uint256 epochDuration = gateway.epochDurationSec();
        uint256 swapDeadline = gateway.defaultSwapDeadlineSec();

        failures += _check(minCap > 0, "MIN_CAP_UNIVERSAL_TX_USD > 0");
        failures += _check(maxCap > minCap, "MAX_CAP > MIN_CAP");
        failures += _check(epochDuration > 0, "epochDurationSec > 0");
        failures += _check(swapDeadline > 0, "defaultSwapDeadlineSec > 0");

        console.log("  MIN_CAP:", minCap);
        console.log("  MAX_CAP:", maxCap);
        console.log("  epochDurationSec:", epochDuration);
        console.log("  defaultSwapDeadlineSec:", swapDeadline);
        console.log("");

        // ============================================================
        //  Category 6: Pause State
        // ============================================================
        console.log("--- Category 6: Pause State ---");

        bool gwPaused = gateway.paused();
        bool vPaused = vault.paused();
        if (gwPaused) {
            console.log("  [WARN] Gateway is PAUSED");
        } else {
            console.log("  [PASS] Gateway is not paused");
        }
        if (vPaused) {
            console.log("  [WARN] Vault is PAUSED");
        } else {
            console.log("  [PASS] Vault is not paused");
        }
        console.log("");

        // ============================================================
        //  Category 7: CEA Factory
        // ============================================================
        console.log("--- Category 7: CEA Factory ---");

        failures += _check(gwCeaFactory != address(0), "CEA_FACTORY is set");
        failures += _check(_hasCode(gwCeaFactory), "CEA_FACTORY has code");

        if (gwCeaFactory != address(0) && _hasCode(gwCeaFactory)) {
            (bool isCeaOk, bytes memory isCeaData) = gwCeaFactory.staticcall(
                abi.encodeWithSelector(ICEAFactory.isCEA.selector, address(0))
            );
            if (isCeaOk && isCeaData.length >= 32) {
                bool result = abi.decode(isCeaData, (bool));
                failures += _check(!result, "CEAFactory.isCEA(address(0)) returns false");
            } else {
                console.log("  [FAIL] CEAFactory.isCEA() call failed");
                failures++;
            }
        }
        console.log("");

        // ============================================================
        //  Category 8: Fee & Protocol (Informational)
        // ============================================================
        console.log("--- Category 8: Fee & Protocol (Info) ---");

        uint256 inboundFee = gateway.INBOUND_FEE();
        uint256 totalFees = gateway.totalProtocolFeesCollected();
        console.log("  INBOUND_FEE:", inboundFee, "wei");
        console.log("  totalProtocolFeesCollected:", totalFees, "wei");
        console.log("");

        // ============================================================
        //  SUMMARY
        // ============================================================
        console.log("========================================");
        if (failures == 0) {
            console.log("  ALL CHECKS PASSED");
        } else {
            console.log("  FAILURES:", failures);
        }
        console.log("========================================");

        require(failures == 0, "Verification failed - see [FAIL] entries above");
    }

    // ========================================
    //         HELPERS
    // ========================================

    function _check(bool condition, string memory label) internal pure returns (uint256) {
        if (condition) {
            console.log("  [PASS]", label);
            return 0;
        } else {
            console.log("  [FAIL]", label);
            return 1;
        }
    }

    function _hasCode(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function _readSlotAsAddress(address proxy, bytes32 slot) internal view returns (address) {
        bytes32 raw = vm.load(proxy, slot);
        return address(uint160(uint256(raw)));
    }
}
