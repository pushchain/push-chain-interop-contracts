// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  Vault
 * @notice Token custody vault for outbound flows managed by TSS.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - Handles both ERC20 and native tokens
 *         - finalizeUniversalTx is the single TSS entry point for both:
 *           • PRC20 path: unlock tokens from Vault and route through CEA
 *           • PC20 path: mint wrapped ERC-20 via PC20Factory (detected by PC_20_SELECTOR prefix)
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
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract Vault is
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IVault
{
    using SafeERC20 for IERC20;

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");

    IUniversalGateway public gateway;
    ICEAFactory public CEAFactory;
    IPC20Factory public pc20Factory;
    mapping(bytes32 => bool) public isPC20Executed;
    mapping(bytes32 => bool) public isPC20RevertExecuted;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

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
        __AccessControlDefaultAdminRules_init(1 days, admin);

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
        CEAFactory = ICEAFactory(ceaFactory);
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
    function migrateTokens(
        address newVault,
        address[] calldata tokens
    ) external nonReentrant whenPaused onlyRole(VAULT_ADMIN_ROLE) {
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

        _finalizeUniversalTxPRC20(subTxId, universalTxId, pushAccount, recipient, token, amount, data, cea);

        emit UniversalTxFinalized(subTxId, universalTxId, pushAccount, recipient, token, amount, data);
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
            gateway.revertUniversalTx{ value: amount }(
                subTxId, universalTxId, token, amount, revertInstruction
            );
            emit UniversalTxReverted(
                subTxId, universalTxId, token, amount, revertInstruction
            );
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            if (IERC20(token).balanceOf(address(this)) < amount) {
                revert Errors.InsufficientBalance();
            }
            IERC20(token).safeTransfer(address(gateway), amount);
            gateway.revertUniversalTx(
                subTxId, universalTxId, token, amount, revertInstruction
            );
            emit UniversalTxReverted(
                subTxId, universalTxId, token, amount, revertInstruction
            );
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
            gateway.rescueFunds{ value: amount }(
                subTxId, universalTxId, token, amount, revertInstruction
            );
            emit FundsRescued(
                subTxId, universalTxId, token, amount, revertInstruction
            );
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            if (IERC20(token).balanceOf(address(this)) < amount) {
                revert Errors.InsufficientBalance();
            }
            IERC20(token).safeTransfer(address(gateway), amount);
            gateway.rescueFunds(
                subTxId, universalTxId, token, amount, revertInstruction
            );
            emit FundsRescued(
                subTxId, universalTxId, token, amount, revertInstruction
            );
        }
    }

    // ==============================
    //    Vault_2b: PC20 EXPORT
    // ==============================

    /// @dev PC20 export finalization. Called internally when data starts with PC_20_SELECTOR.
    ///      `token` carries the Push Chain sourceAsset address used as the wrapper key.
    ///      `data` layout: [PC_20_SELECTOR (4 B)][abi.encode(name, symbol, decimals, userData)]
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

        (string memory name, string memory symbol, uint8 decimals, bytes memory userData) =
            abi.decode(data[4:], (string, string, uint8, bytes));

        if (pc20Factory.getWrapper(sourceAsset) == address(0)) {
            pc20Factory.deployWrapper(sourceAsset, name, symbol, decimals);
        }

        if (userData.length == 0) {
            pc20Factory.mintFor(sourceAsset, recipient, amount);
        } else {
            (address cea, bool isDeployed) = CEAFactory.getCEAForPushAccount(pushAccount);
            if (!isDeployed) {
                cea = CEAFactory.deployCEA(pushAccount);
            }
            pc20Factory.mintFor(sourceAsset, cea, amount);
            ICEA(cea).executeUniversalTx(subTxId, universalTxId, pushAccount, recipient, userData);
        }

        emit UniversalTxFinalized(subTxId, universalTxId, pushAccount, recipient, sourceAsset, amount, userData);
    }

    // ==============================
    //    Vault_3: INTERNAL HELPERS
    // ==============================

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

    /// @dev PRC20 execution handler — unlocks tokens from Vault and routes through CEA.
    function _finalizeUniversalTxPRC20(
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
