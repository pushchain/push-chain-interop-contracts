// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Errors
/// @notice Shared custom errors used across all gateway and vault contracts.
library Errors {
    // ==============================
    //        COMMON ERRORS
    // ==============================

    error ZeroAddress();
    error ZeroAmount();
    error InvalidData();
    error InvalidInput();
    error InvalidAmount();
    error InvalidTxType();
    error InvalidCapRange();
    error InvalidRecipient();
    error PayloadExecuted();
    error Unauthorized();

    // ==============================
    //     GATEWAY ERRORS
    // ==============================

    error NotSupported();
    error DepositFailed();
    error WithdrawFailed();
    error RateLimitExceeded();
    error BlockCapLimitExceeded();
    error SlippageExceededOrExpired();
    error InsufficientBalance();
    error InsufficientProtocolFee();
    error TokenBurnFailed(address token, uint256 amount);
}
