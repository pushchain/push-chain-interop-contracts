// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Transaction types in Universal Gateway.
enum TX_TYPE {
    /// @dev    Only for funding the UEA on Push Chain with gas.
    ///         Does not support movement of high-value funds or payload execution.
    GAS,
    /// @dev    For funding UEA and executing a payload instantly via UEA on Push Chain.
    ///         Allows movement of funds between cap ranges (low fund size)
    ///         and requires lower block confirmations.
    GAS_AND_PAYLOAD,
    /// @dev    For bridging large funds only from external chain to Push Chain.
    ///         Does not support arbitrary payload and requires longer block confirmations.
    FUNDS,
    /// @dev    For bridging both funds and payload to Push Chain for execution.
    ///         No strict cap ranges for fund amount and requires longer block confirmations.
    FUNDS_AND_PAYLOAD,
    /// @dev    For rescuing funds locked in a Vault on an external chain.
    ///         Initiated on Push Chain, executed by TSS on the source chain.
    RESCUE_FUNDS
}

/// @notice Revert/refund instructions for failed transactions.
struct RevertInstructions {
    address revertRecipient;         // where funds go in revert/refund cases
    bytes   revertMsg;               // arbitrary message for relayers/UEA
}

/// @notice Multicall structure for CEA execution.
struct Multicall {
    address to;                      // target contract address
    uint256 value;                   // native token amount to send with call
    bytes   data;                    // call data to execute
}

/// @notice Packed per-token usage for the current epoch only (no on-chain history kept).
struct EpochUsage {
    uint64  epoch;                   // epoch index = block.timestamp / epochDurationSec
    uint192 used;                    // amount consumed in this epoch (token's natural units)
}

/// @notice Signature verification types.
/// @dev    NOT used by any src/ contract — only consumed by tests and UEA contracts.
enum VerificationType {
    signedVerification,
    universalTxVerification
}

/// @dev Magic prefix for PC20 export payloads. ASCII "PC20" (0x50433230).
///      When the first 4 bytes of the data parameter match this selector,
///      Vault.finalizeUniversalTx() routes to the PC20 export path (mint wrapped ERC-20)
///      instead of the PRC20 path (unlock from Vault).
bytes4 constant PC_20_SELECTOR = 0x50433230;
