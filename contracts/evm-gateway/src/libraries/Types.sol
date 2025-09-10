// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

    // =========================
    //        STRUCTS / TYPES
    // =========================

// Transaction Types in Universal Gateway
enum TX_TYPE {
    /// @dev only for funding the UEA on Push Chain with GAS 
    ///      doesn't support movement of high value funds or payload for execution.
    GAS,
    /// @dev for funding UEA and execute a payload instantly via UEA on Push Chain. versal transaction route. 
    ///      allows movement of funds between CAP_RANGES ( low fund size ) & requires lower block confirmations.
    GAS_AND_PAYLOAD,
    /// @dev for bridging of large funds only from external chain to Push Chain.
    ///      doesn't support arbitrary payload movement and requires longer block confirmations.
    FUNDS,
    /// @dev for bridging both funds and payload to Push Chain for execution. 
    /// @dev no strict cap ranges for fund amount and requires longer block confirmations.
    FUNDS_AND_PAYLOAD
}

struct RevertSettings {
    /// @dev where funds go in revert / refund cases
    address fundRecipient; 
    /// @dev arbitrary message for relayers/UEA
    bytes   revertMsg;     
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

