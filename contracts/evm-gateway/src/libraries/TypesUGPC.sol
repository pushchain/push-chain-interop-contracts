// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Universal outbound transaction request for Push Chain.
struct UniversalOutboundTxRequest {
    bytes recipient; // raw destination address on source chain (bytes for SVM compat)
    // bytes("") => park funds in caller's CEA
    address token; // PRC20 token address on Push Chain
    uint256 amount; // amount to withdraw (burn on Push, unlock at origin)
    uint256 gasLimit; // gas limit for fee quote; 0 = per-chain default
    uint256 gasPrice; // gas price override; 0 = per-chain default from UniversalCore
    uint256 maxPCForGas; // max native PC for gas swap; 0 = no cap
    bytes payload; // ABI-encoded calldata to execute on origin chain (empty for funds-only)
    address revertRecipient; // address to receive funds in case of revert
}
