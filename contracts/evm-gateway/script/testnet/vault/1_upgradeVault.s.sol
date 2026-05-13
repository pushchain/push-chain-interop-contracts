// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../../../src/Vault.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { VaultConfig } from "../../config/testnet/VaultConfig.sol";

/**
 * @title  UpgradeVault
 * @notice Step 1 of 3: Deploy new Vault implementation and upgrade the proxy.
 *         Does NOT call initializeV2 - that is a separate step (2_initializeV2.s.sol).
 *
 * @dev    Reads vaultProxy from VaultConfig for the current chain.
 *         The caller MUST be the ProxyAdmin owner.
 *
 * USAGE:
 *   forge script script/testnet/vault/1_upgradeVault.s.sol:UpgradeVault \
 *     --rpc-url $RPC_URL --private-key $KEY --broadcast -vvv
 */
contract UpgradeVault is Script, VaultConfig {
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    Config cfg;
    address public oldImpl;
    address public newImpl;
    address public proxyAdmin;

    function run() external {
        cfg = getConfig();

        console.log("========================================");
        console.log("  STEP 1: UPGRADE Vault");
        console.log("========================================");
        console.log("Chain ID :", block.chainid);
        console.log("Caller   :", msg.sender);
        console.log("Proxy    :", cfg.vaultProxy);
        console.log("");

        _preValidate();
        _snapshotState();

        vm.startBroadcast();
        _deployImpl();
        _upgrade();
        vm.stopBroadcast();

        _postValidate();
        _summary();
    }

    // --- validation ---

    function _preValidate() internal view {
        console.log("--- Pre-Upgrade Validation ---");

        require(cfg.vaultProxy != address(0), "vaultProxy not configured");

        uint256 sz;
        address p = cfg.vaultProxy;
        assembly { sz := extcodesize(p) }
        require(sz > 0, "no code at vaultProxy");

        address pa = _readProxyAdmin();
        address owner = ProxyAdmin(pa).owner();
        require(msg.sender == owner, "caller is not ProxyAdmin owner");

        console.log("  ProxyAdmin     :", pa);
        console.log("  ProxyAdmin owner:", owner);
        console.log("");
    }

    function _snapshotState() internal {
        proxyAdmin = _readProxyAdmin();
        oldImpl = _readImpl();

        Vault v = Vault(payable(cfg.vaultProxy));

        console.log("--- Pre-Upgrade State Snapshot ---");
        console.log("  Old Impl       :", oldImpl);
        console.log("  gateway        :", address(v.gateway()));
        console.log("  TSS_ADDRESS    :", v.TSS_ADDRESS());
        console.log("  CEAFactory     :", address(v.CEAFactory()));
        console.log("  paused         :", v.paused());
        console.log("");
    }

    // --- deploy + upgrade ---

    function _deployImpl() internal {
        console.log("--- Deploying New Implementation ---");
        Vault impl = new Vault();
        newImpl = address(impl);
        console.log("  New Impl:", newImpl);
        console.log("");
    }

    function _upgrade() internal {
        console.log("--- Upgrading Proxy (no initializeV2) ---");
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(cfg.vaultProxy),
            newImpl,
            bytes("")
        );
        console.log("  upgradeAndCall executed (empty calldata)");
        console.log("");
    }

    // --- post-upgrade checks ---

    function _postValidate() internal view {
        console.log("--- Post-Upgrade Validation ---");

        address currentImpl = _readImpl();
        require(currentImpl == newImpl, "impl not updated");
        require(currentImpl != oldImpl, "impl unchanged");

        Vault v = Vault(payable(cfg.vaultProxy));

        address gw = address(v.gateway());
        require(gw == cfg.gateway, "gateway corrupted");

        address tss = v.TSS_ADDRESS();
        require(tss != address(0), "TSS_ADDRESS corrupted");

        address ceaFactory = address(v.CEAFactory());
        require(ceaFactory == cfg.ceaFactory, "CEAFactory corrupted");

        console.log("  OK: impl updated to :", currentImpl);
        console.log("  OK: gateway          :", gw);
        console.log("  OK: TSS_ADDRESS      :", tss);
        console.log("  OK: CEAFactory       :", ceaFactory);
        console.log("");
    }

    function _summary() internal view {
        console.log("========================================");
        console.log("  UPGRADE COMPLETE");
        console.log("========================================");
        console.log("  Proxy          :", cfg.vaultProxy);
        console.log("  Old Impl       :", oldImpl);
        console.log("  New Impl       :", newImpl);
        console.log("");
        console.log("NEXT STEP:");
        console.log("  Run 2_initializeV2.s.sol");
        console.log("========================================");
    }

    // --- helpers ---

    function _readProxyAdmin() internal view returns (address a) {
        bytes32 raw = vm.load(cfg.vaultProxy, _ADMIN_SLOT);
        a = address(uint160(uint256(raw)));
    }

    function _readImpl() internal view returns (address a) {
        bytes32 raw = vm.load(cfg.vaultProxy, _IMPLEMENTATION_SLOT);
        a = address(uint160(uint256(raw)));
    }
}
