// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  Vault
 * @notice Token custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
 *         Retains the TSS_ADDRESS state variable for storage layout compatibility with
 *         the deployed proxy.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - Handles both ERC20 and native tokens
 *         - Routes withdrawals (empty payload) and executions (non-empty payload) through CEA contracts
 *         - Uses CEAFactory for deterministic CEA deployment
 */

import { Errors } from "./libraries/Errors.sol";
import { IVault } from "./interfaces/IVault.sol";
import { ICEA } from "./interfaces/ICEA.sol";
import { ICEAFactory } from "./interfaces/ICEAFactory.sol";
import { IUniversalGateway } from "./interfaces/IUniversalGateway.sol";
import { IPC20Factory } from "./interfaces/IPC20Factory.sol";
import { RevertInstructions, PC_20_SELECTOR } from "./libraries/Types.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract Vault is PausableUpgradeable, ReentrancyGuardUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IVault {
    using SafeERC20 for IERC20;

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");

    IUniversalGateway public gateway;

    /// @dev Deprecated in mainnet Vault (audit F-2026-15642: redundant with TSS_ROLE).
    ///      Retained here for storage layout compatibility with the deployed testnet proxy.
    address public TSS_ADDRESS;

    ICEAFactory public CEAFactory;

    IPC20Factory public pc20Factory;
    mapping(bytes32 => bool) public isPC20Executed;
    mapping(bytes32 => bool) public isPC20RevertExecuted;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable { }

    // ==============================
    //     Vault_1: ADMIN ACTIONS
    // ==============================

    function initialize(address admin, address pauser, address tss, address gw, address ceaFactory)
        external
        initializer
    {
        if (
            admin == address(0) || pauser == address(0) || tss == address(0) || gw == address(0)
                || ceaFactory == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlDefaultAdminRules_init(1 minutes, admin);

        _setRoleAdmin(VAULT_ADMIN_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(TSS_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(VAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(TSS_ROLE, tss);

        gateway = IUniversalGateway(gw);
        TSS_ADDRESS = tss;
        CEAFactory = ICEAFactory(ceaFactory);
    }

    /// @notice One-time migration: seeds AccessControlDefaultAdminRules storage and sets up
    /// @param admin The current DEFAULT_ADMIN_ROLE holder (must already have the role)
    function initializeV2(address admin) external reinitializer(2) {
        if (!hasRole(DEFAULT_ADMIN_ROLE, admin)) revert Errors.Unauthorized();

        __AccessControlDefaultAdminRules_init(1 minutes, admin);

        _setRoleAdmin(VAULT_ADMIN_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(TSS_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(VAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external whenPaused onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /// @notice                Updates the UniversalGateway address.
    /// @param gw              New UniversalGateway address.
    function updateGateway(address gw) external onlyRole(OPERATOR_ROLE) {
        if (gw == address(0)) revert Errors.ZeroAddress();
        address old = address(gateway);
        gateway = IUniversalGateway(gw);
        emit GatewayUpdated(old, gw);
    }

    /// @notice                Updates the CEAFactory address.
    /// @param newCEAFactory   New CEAFactory address.
    function updateCEAFactory(address newCEAFactory) external onlyRole(OPERATOR_ROLE) {
        if (newCEAFactory == address(0)) revert Errors.ZeroAddress();
        address old = address(CEAFactory);
        CEAFactory = ICEAFactory(newCEAFactory);
        emit CEAFactoryUpdated(old, newCEAFactory);
    }

    /// @dev Deprecated in mainnet Vault (audit F-2026-15642: redundant with TSS_ROLE).
    ///      Retained here for testnet compatibility. Updates TSS_ADDRESS and transfers TSS_ROLE.
    /// @param newTss          New TSS address.
    function setTSS(address newTss) external onlyRole(OPERATOR_ROLE) {
        if (newTss == address(0)) revert Errors.ZeroAddress();
        address old = TSS_ADDRESS;

        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTss);

        TSS_ADDRESS = newTss;
    }

    /// @inheritdoc IVault
    function updatePC20Factory(address newFactory) external onlyRole(OPERATOR_ROLE) {
        if (newFactory == address(0)) revert Errors.ZeroAddress();
        address old = address(pc20Factory);
        pc20Factory = IPC20Factory(newFactory);
        emit PC20FactoryUpdated(old, newFactory);
    }

    /// @notice                Migrates ERC20 balances and any native ETH to a new vault.
    /// @dev                   BOTH this vault AND the gateway MUST be paused.
    ///                        Call this BEFORE gateway.updateVault(newVault).
    ///                        Tokens with zero balance are silently skipped.
    /// @param newVault        Destination vault address
    /// @param tokens          ERC20 token addresses to sweep
    function migrateTokens(address newVault, address[] calldata tokens)
        external
        nonReentrant
        whenPaused
        onlyRole(VAULT_ADMIN_ROLE)
    {
        if (newVault == address(0)) revert Errors.ZeroAddress();
        if (tokens.length == 0) revert Errors.EmptyTokenList();
        if (!gateway.paused()) revert Errors.GatewayNotPaused();

        uint256 len = tokens.length;
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            amounts[i] = bal;
            if (bal > 0) {
                IERC20(tokens[i]).safeTransfer(newVault, bal);
            }
        }

        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) {
            (bool ok,) = newVault.call{ value: nativeBal }("");
            if (!ok) revert Errors.WithdrawFailed();
        }

        emit TokensMigrated(newVault, tokens, amounts, nativeBal);
    }

    // ==============================
    //  Vault_2: WITHDRAW & EXECUTION
    // ==============================

    /// @inheritdoc IVault
    function finalizeUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address pushAccount,
        address recipient,
        address token,
        uint256 amount,
        bytes calldata data
    ) external payable nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        if (_isPC20Export(data)) {
            _finalizePC20Export(subTxId, universalTxId, pushAccount, recipient, token, amount, data);
            return;
        }

        (address cea, bool isDeployed) = CEAFactory.getCEAForPushAccount(pushAccount);
        if (!isDeployed) {
            cea = CEAFactory.deployCEA(pushAccount);
        }

        _finalizeUniversalTx(subTxId, universalTxId, pushAccount, recipient, token, amount, data, cea);

        _emitUniversalTxFinalized(subTxId, universalTxId, address(0), pushAccount, recipient, token, amount, data);
    }

    /// @inheritdoc IVault
    function revertUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        _validateRevertParams(amount, revertInstruction.revertRecipient);

        if (_isPC20Wrapper(token)) {
            if (msg.value != 0) revert Errors.InvalidAmount();
            if (isPC20RevertExecuted[subTxId]) {
                revert Errors.PayloadExecuted();
            }
            isPC20RevertExecuted[subTxId] = true;
            pc20Factory.revertMint(
                token, revertInstruction.revertRecipient, amount
            );
            emit UniversalTxReverted(
                subTxId, universalTxId, token, amount,
                revertInstruction
            );
        } else if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
            gateway.revertUniversalTx{ value: amount }(subTxId, universalTxId, token, amount, revertInstruction);
            emit UniversalTxReverted(subTxId, universalTxId, token, amount, revertInstruction);
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            if (IERC20(token).balanceOf(address(this)) < amount) {
                revert Errors.InsufficientBalance();
            }
            IERC20(token).safeTransfer(address(gateway), amount);
            gateway.revertUniversalTx(subTxId, universalTxId, token, amount, revertInstruction);
            emit UniversalTxReverted(subTxId, universalTxId, token, amount, revertInstruction);
        }
    }

    /// @inheritdoc IVault
    function rescueFunds(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        _validateRevertParams(amount, revertInstruction.revertRecipient);

        if (_isPC20Wrapper(token)) {
            if (msg.value != 0) revert Errors.InvalidAmount();
            if (isPC20RevertExecuted[subTxId]) {
                revert Errors.PayloadExecuted();
            }
            isPC20RevertExecuted[subTxId] = true;
            pc20Factory.revertMint(
                token, revertInstruction.revertRecipient, amount
            );
            emit FundsRescued(
                subTxId, universalTxId, token, amount,
                revertInstruction
            );
        } else if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
            gateway.rescueFunds{ value: amount }(subTxId, universalTxId, token, amount, revertInstruction);
            emit FundsRescued(subTxId, universalTxId, token, amount, revertInstruction);
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            if (IERC20(token).balanceOf(address(this)) < amount) {
                revert Errors.InsufficientBalance();
            }
            IERC20(token).safeTransfer(address(gateway), amount);
            gateway.rescueFunds(subTxId, universalTxId, token, amount, revertInstruction);
            emit FundsRescued(subTxId, universalTxId, token, amount, revertInstruction);
        }
    }

    // ==============================
    //    Vault_2b: PC20 EXPORT
    // ==============================

    /// @dev PC20 export finalization. Called internally when data starts with PC_20_SELECTOR.
    ///      `token` carries the Push Chain sourceAsset address used as the wrapper key.
    ///      `data` layout: [PC_20_SELECTOR (4 B)][abi.encode(destChainNamespace, name, symbol, decimals)][raw userData]
    ///      destChainNamespace is discarded (Vault already lives on that chain).
    ///      userData is the raw tail bytes after the ABI-encoded tuple (may be empty).
    function _finalizePC20Export(
        bytes32 subTxId,
        bytes32 universalTxId,
        address pushAccount,
        address recipient,
        address sourceAsset,
        uint256 amount,
        bytes calldata data
    ) private {
        if (msg.value != 0) revert Errors.InvalidAmount();
        if (isPC20Executed[subTxId]) revert Errors.PayloadExecuted();
        isPC20Executed[subTxId] = true;

        if (pushAccount == address(0)) revert Errors.ZeroAddress();
        if (sourceAsset == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (recipient == address(0)) revert Errors.ZeroAddress();

        (string memory destChain, string memory name, string memory symbol, uint8 decimals) =
            abi.decode(data[4:], (string, string, string, uint8));

        bytes memory userData;
        uint256 tupleLen = abi.encode(destChain, name, symbol, decimals).length;
        uint256 userDataStart = 4 + tupleLen;
        if (data.length > userDataStart) {
            userData = data[userDataStart:];
        }

        if (pc20Factory.getWrapper(sourceAsset) == address(0)) {
            pc20Factory.deployWrapper(sourceAsset, name, symbol, decimals);
        }

        address wrapper = pc20Factory.getWrapper(sourceAsset);

        (address cea, bool isDeployed) = CEAFactory.getCEAForPushAccount(pushAccount);
        if (!isDeployed) {
            cea = CEAFactory.deployCEA(pushAccount);
        }
        pc20Factory.mintFor(sourceAsset, cea, amount);

        if (userData.length > 0) {
            ICEA(cea).executeUniversalTx(subTxId, universalTxId, pushAccount, recipient, userData);
        }

        _emitUniversalTxFinalized(subTxId, universalTxId, wrapper, pushAccount, recipient, sourceAsset, amount, userData);
    }

    // ==============================
    //    Vault_3: INTERNAL HELPERS
    // ==============================

    function _emitUniversalTxFinalized(
        bytes32 subTxId,
        bytes32 universalTxId,
        address wrapperAddress,
        address pushAccount,
        address recipient,
        address token,
        uint256 amount,
        bytes memory data
    ) private {
        emit UniversalTxFinalized(subTxId, universalTxId, wrapperAddress, pushAccount, recipient, token, amount, data);
    }

    /// @dev Validates common revert/rescue parameters.
    function _validateRevertParams(uint256 amount, address revertRecipient) private pure {
        if (amount == 0) revert Errors.InvalidAmount();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
    }

    /// @dev                   Validates push account and token/value invariants.
    /// @param pushAccount     Push Chain account (UEA).
    /// @param token           Token address (address(0) for native).
    /// @param amount          Expected amount.
    function _validateParams(address pushAccount, address token, uint256 amount) internal view {
        if (pushAccount == address(0)) revert Errors.ZeroAddress();

        if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
        }
    }

    /// @dev Returns true when token is a PC20 wrapper deployed by the factory.
    function _isPC20Wrapper(address token) private view returns (bool) {
        if (address(pc20Factory) == address(0)) return false;
        return pc20Factory.isPC20Wrapper(token);
    }

    /// @dev Returns true when data starts with PC_20_SELECTOR (PC20 export path).
    function _isPC20Export(bytes calldata data) private pure returns (bool) {
        if (data.length < 4) return false;
        return bytes4(data[:4]) == PC_20_SELECTOR;
    }

    /// @dev                   Unified execution handler — all operations route through CEA.
    /// @param subTxId         Gateway transaction ID
    /// @param universalTxId   Universal transaction ID
    /// @param pushAccount     Push Chain account (UEA) this transaction is attributed to
    /// @param recipient       Destination address on this chain; address(0) means park in CEA
    /// @param token           Token address (address(0) for native)
    /// @param amount          Amount of tokens to fund CEA with
    /// @param data            Multicall payload (abi.encode(Multicall[]))
    /// @param cea             CEA address (already deployed or newly created)
    function _finalizeUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address pushAccount,
        address recipient,
        address token,
        uint256 amount,
        bytes calldata data,
        address cea
    ) private {
        _validateParams(pushAccount, token, amount);

        if (token != address(0)) {
            if (amount > 0) {
                if (IERC20(token).balanceOf(address(this)) < amount) {
                    revert Errors.InvalidAmount();
                }
                IERC20(token).safeTransfer(cea, amount);
            }
            ICEA(cea).executeUniversalTx(subTxId, universalTxId, pushAccount, recipient, data);
        } else {
            ICEA(cea).executeUniversalTx{ value: amount }(subTxId, universalTxId, pushAccount, recipient, data);
        }
    }
}
