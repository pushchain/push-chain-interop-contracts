pragma solidity ^0.8.20;

library Errors {
    // =========================
    //           ERRORS for UniversalGatewayV1
    // =========================
    error DepositFailed();
    error WithdrawFailed();
    error NotSupported();
    error NotSwapAllowed();
    error InvalidRecipient();
    error InvalidInput();   
    error InvalidAmount();
    error StalePrice();
    error InvalidToken();
    error PairNotFound();
    error SlippageExceededOrExpired();
    error ZeroAddress();
    error RateProviderNotSet();
}