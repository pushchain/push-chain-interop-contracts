// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  Vault
 * @notice Token custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
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
import { RevertInstructions } from "./libraries/Types.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract Vault is
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IVault
{
    using SafeERC20 for IERC20;

    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IUniversalGateway public gateway;
    ICEAFactory public CEAFactory;

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

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(TSS_ROLE, tss);

        gateway = IUniversalGateway(gw);
        CEAFactory = ICEAFactory(ceaFactory);
    }

    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external whenPaused onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice                Updates the UniversalGateway address.
    /// @param gw              New UniversalGateway address.
    function setGateway(address gw) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gw == address(0)) revert Errors.ZeroAddress();
        address old = address(gateway);
        gateway = IUniversalGateway(gw);
        emit GatewayUpdated(old, gw);
    }

    /// @notice                Updates the CEAFactory address.
    /// @param newCEAFactory   New CEAFactory address.
    function setCEAFactory(address newCEAFactory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCEAFactory == address(0)) revert Errors.ZeroAddress();
        address old = address(CEAFactory);
        CEAFactory = ICEAFactory(newCEAFactory);
        emit CEAFactoryUpdated(old, newCEAFactory);
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
    ) external nonReentrant whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
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
        (address cea, bool isDeployed) = CEAFactory.getCEAForPushAccount(pushAccount);
        if (!isDeployed) {
            cea = CEAFactory.deployCEA(pushAccount);
        }

        _finalizeUniversalTx(subTxId, universalTxId, pushAccount, recipient, token, amount, data, cea);

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

        if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
            gateway.revertUniversalTx{ value: amount }(
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
        }

        emit UniversalTxReverted(
            subTxId, universalTxId, token, amount, revertInstruction
        );
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

        if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
            gateway.rescueFunds{ value: amount }(
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
        }

        emit FundsRescued(
            subTxId, universalTxId, token, amount, revertInstruction
        );
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
