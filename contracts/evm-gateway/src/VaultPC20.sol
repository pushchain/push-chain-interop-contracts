// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  VaultPC20
 * @notice Custody vault for PC20 tokens during cross-chain export.
 *         Locks tokens when a user exports to an external chain and releases
 *         them on unlock (wrapped tokens burned on dest) or revert (settlement failure).
 * @dev    Structurally modeled on VaultPC but holds user tokens, not fees.
 *         Uses isExecuted mapping for replay protection on unlock/revert.
 */

import {Errors} from "./libraries/Errors.sol";
import {IVaultPC20} from "./interfaces/IVaultPC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract VaultPC20 is
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IVaultPC20
{
    using SafeERC20 for IERC20;

    // ==============================
    //   PROTOCOL CONSTANTS
    // ==============================

    address public immutable UNIVERSAL_EXECUTOR_MODULE = 0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7;

    // ==============================
    //      ROLES
    // ==============================

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    // ==============================
    //      MODIFIERS
    // ==============================

    modifier onlyUEModule() {
        if (msg.sender != UNIVERSAL_EXECUTOR_MODULE) {
            revert Errors.CallerIsNotUEModule();
        }
        _;
    }

    // ==============================
    //      STATE
    // ==============================

    address public universalGatewayPC;
    mapping(address => uint256) public totalLocked;
    mapping(bytes32 => bool) public isExecuted;

    // ==============================
    //      CONSTRUCTOR
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==============================
    //      INITIALIZER
    // ==============================

    /// @param admin     DEFAULT_ADMIN_ROLE + ROLE_MANAGER_ROLE + OPERATOR_ROLE holder
    /// @param pauser    PAUSER_ROLE holder
    /// @param gatewayPC GATEWAY_ROLE holder (UGPC address)
    function initialize(
        address admin,
        address pauser,
        address gatewayPC
    ) external initializer {
        if (
            admin == address(0) ||
            pauser == address(0) ||
            gatewayPC == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlDefaultAdminRules_init(1 days, admin);

        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(GATEWAY_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(GATEWAY_ROLE, gatewayPC);

        universalGatewayPC = gatewayPC;
    }

    // ==============================
    //      LOCK (GATEWAY_ROLE)
    // ==============================

    /// @inheritdoc IVaultPC20
    function recordLock(address token, uint256 amount)
        external
        onlyRole(GATEWAY_ROLE)
    {
        totalLocked[token] += amount;

        if (IERC20(token).balanceOf(address(this)) < totalLocked[token]) {
            revert Errors.InsufficientBalance();
        }

        emit TokensLocked(token, amount, totalLocked[token]);
    }

    // ==============================
    //   UNLOCK (UE MODULE)
    // ==============================

    /// @inheritdoc IVaultPC20
    function unlock(
        bytes32 subTxId,
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant whenNotPaused onlyUEModule {
        if (isExecuted[subTxId]) revert Errors.PayloadExecuted();
        isExecuted[subTxId] = true;

        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (recipient == address(0)) revert Errors.InvalidRecipient();
        if (totalLocked[token] < amount) revert Errors.InsufficientBalance();

        totalLocked[token] -= amount;

        IERC20(token).safeTransfer(recipient, amount);

        emit TokensUnlocked(subTxId, token, amount, recipient);
    }

    // ==============================
    //   REVERT (UE MODULE)
    // ==============================

    /// @inheritdoc IVaultPC20
    function revertExport(
        bytes32 subTxId,
        address token,
        uint256 amount,
        address revertRecipient
    ) external nonReentrant whenNotPaused onlyUEModule {
        if (isExecuted[subTxId]) revert Errors.PayloadExecuted();
        isExecuted[subTxId] = true;

        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
        if (totalLocked[token] < amount) revert Errors.InsufficientBalance();

        totalLocked[token] -= amount;

        IERC20(token).safeTransfer(revertRecipient, amount);

        emit ExportReverted(subTxId, token, amount, revertRecipient);
    }

    // ==============================
    //      EMERGENCY (ADMIN)
    // ==============================

    /// @inheritdoc IVaultPC20
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, to, amount);
    }

    // ==============================
    //      ADMIN
    // ==============================

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /// @notice Updates the UGPC address and rotates GATEWAY_ROLE.
    /// @param newGatewayPC New UGPC address
    function updateUniversalGatewayPC(address newGatewayPC)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (newGatewayPC == address(0)) revert Errors.ZeroAddress();

        address oldGatewayPC = universalGatewayPC;
        _revokeRole(GATEWAY_ROLE, oldGatewayPC);
        universalGatewayPC = newGatewayPC;
        _grantRole(GATEWAY_ROLE, newGatewayPC);

        emit UniversalGatewayPCUpdated(oldGatewayPC, newGatewayPC);
    }
}
