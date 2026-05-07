// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Universal outbound transaction request for Push Chain.
struct UniversalOutboundTxRequest {
    bytes   recipient;               // raw destination address on source chain (bytes for SVM compat)
                                     // bytes("") => park funds in caller's CEA
    address token;                   // PRC20 token address on Push Chain
    uint256 amount;                  // amount to withdraw (burn on Push, unlock at origin)
    uint256 gasLimit;                // gas limit for fee quote; 0 = per-chain default
    uint256 gasPrice;                // gas price override; 0 = per-chain default from UniversalCore
    uint256 maxPCForGas;             // max native PC for gas swap; 0 = no cap
    bytes   payload;                 // ABI-encoded calldata to execute on origin chain (empty for funds-only)
    address revertRecipient;         // address to receive funds in case of revert
}

/// @notice PC20 export request — lock Push-native tokens for cross-chain wrapped representation.
struct PC20ExportRequest {
    bytes   recipient;               // destination address (bytes for cross-VM compat)
    address token;                   // PC20 token on Push Chain
    uint256 amount;                  // amount to lock and export (must be > 0)
    string  destChainNamespace;      // destination chain (CAIP-2, e.g., "eip155:1")
    uint256 gasLimit;                // gas limit for destination (0 = per-chain default)
    uint256 maxPCForGas;             // max native PC for gas swap (0 = no cap)
    bytes   payload;                 // optional: ABI-encoded calldata for dest execution
    address revertRecipient;         // fund recipient on revert (receives PC20 back on Push Chain)
}
