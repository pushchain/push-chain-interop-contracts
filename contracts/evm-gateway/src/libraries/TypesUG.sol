// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VerificationType } from "./Types.sol";

/// @notice Universal payload for execution on Push Chain.
/// @dev    NOT used by any src/ contract — only consumed by tests and UEA contracts.
struct UniversalPayload {
    address          to;             // target contract address to call
    uint256          value;          // native token amount to send
    bytes            data;           // call data for the function execution
    uint256          gasLimit;       // maximum gas to be used for this tx
    uint256          maxFeePerGas;   // maximum fee per gas unit
    uint256 maxPriorityFeePerGas;    // maximum priority fee per gas unit
    uint256          nonce;          // nonce for the transaction
    uint256          deadline;       // timestamp after which this payload is invalid
    VerificationType vType;          // signedVerification or universalTxVerification
}

/// @notice Universal transaction request for native token as gas.
struct UniversalTxRequest {
    address recipient;               // address(0) => credit to UEA on Push
    address token;                   // address(0) => native path (gas-only)
    uint256 amount;                  // native amount or ERC20 amount
    bytes   payload;                 // call data / memo = UNIVERSAL PAYLOAD
    address revertRecipient;         // address to receive funds in case of revert
    bytes   signatureData;           // signature data for further verification
}

/// @notice Universal transaction request for ERC20 token as gas.
struct UniversalTokenTxRequest {
    address recipient;               // address(0) => credit to UEA on Push
    address token;                   // address(0) => native path (gas-only)
    uint256 amount;                  // native amount or ERC20 amount
    address gasToken;                // token used for paying gas
    uint256 gasAmount;               // amount of the token to be used as gas
    bytes   payload;                 // call data / memo = UNIVERSAL PAYLOAD
    address revertRecipient;         // address to receive funds in case of revert
    bytes   signatureData;           // signature data for further verification
    uint256 amountOutMinETH;         // minimum amount of ETH to receive
    uint256 deadline;                // timestamp after which this request is invalid
}
