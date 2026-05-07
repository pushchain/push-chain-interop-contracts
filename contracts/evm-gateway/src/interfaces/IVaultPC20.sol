// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IVaultPC20
 * @notice Interface for VaultPC20 — custody vault for PC20 tokens during cross-chain export.
 * @dev    Locks tokens when user exports, releases on unlock (burn on dest) or revert (settlement failure).
 */
interface IVaultPC20 {
    // ==============================
    //      EVENTS
    // ==============================

    event TokensLocked(
        address indexed token,
        uint256 amount,
        uint256 totalLocked
    );

    event TokensUnlocked(
        bytes32 indexed subTxId,
        address indexed token,
        uint256 amount,
        address indexed recipient
    );

    event ExportReverted(
        bytes32 indexed subTxId,
        address indexed token,
        uint256 amount,
        address indexed revertRecipient
    );

    event EmergencyWithdrawal(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    event UniversalGatewayPCUpdated(
        address indexed oldGatewayPC,
        address indexed newGatewayPC
    );

    // ==============================
    //      LOCK (GATEWAY_ROLE)
    // ==============================

    /// @notice Records a token lock after UGPC transfers tokens to this contract.
    /// @dev    Only callable by GATEWAY_ROLE (UGPC). Validates balanceOf >= totalLocked.
    /// @param token  PC20 token address
    /// @param amount Amount locked
    function recordLock(address token, uint256 amount) external;

    // ==============================
    //      UNLOCK / REVERT (TSS_ROLE)
    // ==============================

    /// @notice Releases locked PC20 tokens to recipient after wrapped tokens burned on dest chain.
    /// @param subTxId   Unique sub-transaction identifier (replay-protected)
    /// @param token     PC20 token address
    /// @param amount    Amount to unlock
    /// @param recipient Address to receive the unlocked tokens
    function unlock(
        bytes32 subTxId,
        address token,
        uint256 amount,
        address recipient
    ) external;

    /// @notice Returns locked PC20 tokens when destination settlement fails.
    /// @param subTxId          Unique sub-transaction identifier (replay-protected)
    /// @param token            PC20 token address
    /// @param amount           Amount to return
    /// @param revertRecipient  Address to receive the returned tokens
    function revertExport(
        bytes32 subTxId,
        address token,
        uint256 amount,
        address revertRecipient
    ) external;

    // ==============================
    //      EMERGENCY (ADMIN)
    // ==============================

    /// @notice Emergency token withdrawal. Only when paused, by DEFAULT_ADMIN_ROLE.
    /// @dev    Does NOT decrement totalLocked — emergency override.
    /// @param token  Token address to withdraw
    /// @param to     Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external;

    // ==============================
    //      VIEW
    // ==============================

    /// @notice Returns the total locked amount for a token.
    function totalLocked(address token) external view returns (uint256);

    /// @notice Returns whether a subTxId has been executed.
    function isExecuted(bytes32 subTxId) external view returns (bool);
}
