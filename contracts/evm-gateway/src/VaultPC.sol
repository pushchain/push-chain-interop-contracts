// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  VaultPC
 * @notice Custody vault to store fees collected from outbound flows on Push Chain.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - Only supports PRC20 tokens.
 *         - Funds stored are managed by the VPC_ADMIN_ROLE.
 *         - All fees earned via outbound flows are stored and handled in this contract by VPC_ADMIN_ROLE.
 */

import { Errors } from "./libraries/Errors.sol";
import { IVaultPC } from "./interfaces/IVaultPC.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract VaultPC is
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IVaultPC
{
    using SafeERC20 for IERC20;

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant VPC_ADMIN_ROLE = keccak256("VPC_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==============================
    //    VaultPC_1: ADMIN ACTIONS
    // ==============================

    /// @param admin           DEFAULT_ADMIN_ROLE holder.
    /// @param pauser          PAUSER_ROLE holder.
    /// @param vpcAdmin        VPC_ADMIN_ROLE holder.
    function initialize(address admin, address pauser, address vpcAdmin) external initializer {
        if (admin == address(0) || pauser == address(0) || vpcAdmin == address(0)) {
            revert Errors.ZeroAddress();
        }

        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlDefaultAdminRules_init(1 days, admin);

        _setRoleAdmin(VPC_ADMIN_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(VPC_ADMIN_ROLE, vpcAdmin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external whenPaused onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    // ==============================
    //      VaultPC_2: WITHDRAW
    // ==============================

    /// @inheritdoc IVaultPC
    function withdraw(address to, uint256 amount) external nonReentrant whenNotPaused onlyRole(VPC_ADMIN_ROLE) {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        if (address(this).balance < amount) {
            revert Errors.InsufficientBalance();
        }

        (bool success,) = payable(to).call{ value: amount }("");
        if (!success) revert Errors.WithdrawFailed();

        emit FeesWithdrawn(msg.sender, to, address(0), amount);
    }

    /// @inheritdoc IVaultPC
    function withdrawToken(address token, address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(VPC_ADMIN_ROLE)
    {
        if (token == address(0) || to == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (amount == 0) revert Errors.InvalidAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) {
            revert Errors.InsufficientBalance();
        }

        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(msg.sender, to, token, amount);
    }

    /// @notice Allow contract to receive native PC tokens
    receive() external payable { }
}
