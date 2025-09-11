use anchor_lang::prelude::*;

#[error_code]
pub enum GatewayError {
    #[msg("Contract is paused")]
    PausedError,

    #[msg("Unauthorized access")]
    Unauthorized,

    #[msg("Invalid amount")]
    InvalidAmount,

    #[msg("Invalid recipient")]
    InvalidRecipient,

    #[msg("Amount below minimum cap")]
    BelowMinCap,

    #[msg("Amount above maximum cap")]
    AboveMaxCap,

    #[msg("Zero address not allowed")]
    ZeroAddress,

    #[msg("Invalid cap range")]
    InvalidCapRange,

    #[msg("Invalid payload")]
    InvalidPayload,

    #[msg("Deadline exceeded")]
    DeadlineExceeded,

    #[msg("Invalid price data")]
    InvalidPrice,

    #[msg("Token already whitelisted")]
    TokenAlreadyWhitelisted,

    #[msg("Token not whitelisted")]
    TokenNotWhitelisted,

    #[msg("Token transfer failed")]
    TokenTransferFailed,

    #[msg("Invalid token vault")]
    InvalidTokenVault,

    #[msg("Invalid owner")]
    InvalidOwner,

    #[msg("Slippage exceeded or expired")]
    SlippageExceededOrExpired,

    #[msg("Contract is paused")]
    Paused,

    #[msg("Invalid input")]
    InvalidInput,

    #[msg("Invalid mint")]
    InvalidMint,

    #[msg("Insufficient balance")]
    InsufficientBalance,

    #[msg("Invalid token")]
    InvalidToken,
}
