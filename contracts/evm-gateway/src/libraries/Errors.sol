pragma solidity ^0.8.20;

library Errors {

    // =========================
    //           Common ERRORS
    // =========================
    error InvalidInput();   
    error InvalidAmount();
    error ZeroAddress();
    error InvalidCapRange();
    error InvalidData();
    error InvalidTxType();
    // =========================
    //           ERRORS for UniversalGateway
    // =========================
    error DepositFailed();
    error WithdrawFailed();
    error NotSupported();
    error NotSwapAllowed();
    error InvalidRecipient();
    error StalePrice();
    error InvalidToken();
    error SlippageExceededOrExpired();

    // =========================
    //      Price Oracle & AMM Errors
    // =========================

    // --- Uniswap V3 / AMM (kept; used by swapToNative etc.)
    error PairNotFound();
    error NoValidV3Pool();

    // --- Chainlink price feed (new)
    error MissingEthUsdFeed();
    error L2SequencerDownOrGrace();
    error InvalidChainlinkAnswer();
}