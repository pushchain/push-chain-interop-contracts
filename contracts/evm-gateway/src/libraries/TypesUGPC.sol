// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// =========================
//    STRUCTS
// =========================

/// @notice Universal outbound transaction request for Push Chain.
/// @dev    Used for both PRC20 outbound and PC20 export flows via sendUniversalTxOutbound().
///         For PC20 exports, the payload field must be prefixed with PC_20_SELECTOR followed by
///         abi.encode(destChainNamespace, name, symbol, decimals) and optional user calldata.
struct UniversalOutboundTxRequest {
    bytes   recipient;               // raw destination address on source chain (bytes for SVM compat)
                                     // bytes("") => park funds in caller's CEA
    address token;                   // PRC20 or PC20 token address on Push Chain
    uint256 amount;                  // amount to withdraw/lock (burn for PRC20, lock for PC20)
    uint256 gasLimit;                // gas limit for fee quote; 0 = per-chain default
    uint256 gasPrice;                // gas price override; 0 = per-chain default (PRC20 only)
    uint256 maxPCForGas;             // max native PC for gas swap; 0 = no cap
    bytes   payload;                 // calldata or PC20-encoded payload (see PC_20_SELECTOR)
    address revertRecipient;         // address to receive funds in case of revert
}

// =========================
//    CONSTANTS
// =========================

/// @dev Magic prefix for PC20 export payloads. ASCII encoding of "PC20" (0x50433230).
///      When the first 4 bytes of req.payload match this selector, sendUniversalTxOutbound()
///      routes to the PC20 export path (lock in VaultPC20) instead of the PRC20 path (burn).
bytes4 constant PC_20_SELECTOR = 0x50433230;

