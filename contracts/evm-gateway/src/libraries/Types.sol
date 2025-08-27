// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

    // =========================
    //        STRUCTS / TYPES
    // =========================
struct RevertSettings {
    address fundRecipient; // Where funds go in revert / refund cases
    bytes   revertMsg;     // Arbitrary message for relayers/UEA
}

struct DepositUniversalTxParams {
    address token;
    uint256 amount;
    bytes   data;
}



// Signature verification types
enum VerificationType {
    signedVerification,
    universalTxVerification
}

struct UniversalPayload {
    // Core execution parameters
    address to; // Target contract address to call
    uint256 value; // Native token amount to send
    bytes data; // Call data for the function execution
    uint256 gasLimit; // Maximum gas to be used for this tx (caps refund amount)
    uint256 maxFeePerGas; // Maximum fee per gas unit
    uint256 maxPriorityFeePerGas; // Maximum priority fee per gas unit
    uint256 nonce; // Chain ID where this should be executed
    uint256 deadline; // Timestamp after which this payload is invalid
    VerificationType vType; // Type of verification to use before execution (signedVerification or universalTxVerification)
}

/// @notice Canonical WETH/USDC pool (fee tier e.g., 500 or 3000) & config.
struct PoolCfg {
    IUniswapV3Pool pool;    // must be WETH <-> USDC
    address stableToken;         // USDC
    uint8   stableTokenDecimals; // 6 for USDC
    bool    enabled;        // kill-switch
}

