// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

    // =========================
    //        STRUCTS / TYPES
    // =========================

enum TX_TYPE {
    /// @dev only for funding the UEA on Push Chain
    ///      doesn't support movement of high value funds or payload for execution.
    GAS_FUND_TX,
    /// @dev only for bridging the funds to a recipient on the target chain
    ///      doesn't support arbitrary execution payload via UEAs.
    FUNDS_BRIDGE_TX,
    /// @dev for bridging both funds and payload to Push Chain for execution. 
    ///      supports arbitrary execution payload via UEAs.
    FUNDS_AND_PAYLOAD_TX,
    /// @dev for bridging both funds and payload to Push Chain for instant execution through universal transaction route. 
    /// @dev allows for lower fund size bridging and requires lower block confirmations to achieve instant execution on Push Chain.
    FUNDS_AND_PAYLOAD_INSTANT_TX
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

