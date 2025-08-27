pragma solidity ^0.8.20;

library Errors {

    // =========================
    //           Common ERRORS
    // =========================
    error InvalidInput();   
    error InvalidAmount();
    error ZeroAddress();
    error InvalidCapRange();
    // =========================
    //           ERRORS for UniversalGatewayV1
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
    //           TWAP and UniswapV3 Specific Errors
    // =========================
    error PairNotFound();
    error NoValidV3Pool();
    error NoValidTWAP();
    error InvalidPoolConfig();
    error PoolTooIlliquid();
    error LowCardinality();
    error TwapWindowTooShort();
    error PriceDeviationTooHigh();  // spread between USDC/USDT quotes too large (stability guard)
}