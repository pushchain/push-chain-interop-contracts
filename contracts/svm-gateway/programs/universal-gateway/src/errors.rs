use anchor_lang::prelude::*;

#[error_code]
pub enum GatewayError {
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

    #[msg("Invalid price data")]
    InvalidPrice,

    #[msg("Invalid owner")]
    InvalidOwner,

    #[msg("Contract is paused")]
    Paused,

    #[msg("Invalid input")]
    InvalidInput,

    #[msg("Invalid transaction type")]
    InvalidTxType,

    #[msg("Invalid mint")]
    InvalidMint,

    #[msg("Insufficient balance")]
    InsufficientBalance,

    #[msg("Invalid token")]
    InvalidToken,

    // Rate limiting errors
    #[msg("Block USD cap exceeded")]
    BlockUsdCapExceeded,

    #[msg("Rate limit exceeded")]
    RateLimitExceeded,

    #[msg("Invalid account")]
    InvalidAccount,

    #[msg("Token not supported")]
    NotSupported,

    // Execute-specific errors
    #[msg("Message hash mismatch")]
    MessageHashMismatch,

    #[msg("TSS authentication failed")]
    TssAuthFailed,

    #[msg("Account list length mismatch")]
    AccountListLengthMismatch,

    #[msg("Account pubkey mismatch")]
    AccountPubkeyMismatch,

    #[msg("Account writable flag mismatch")]
    AccountWritableFlagMismatch,

    #[msg("Unexpected outer signer in remaining accounts")]
    UnexpectedOuterSigner,

    #[msg("Destination program is not executable")]
    InvalidProgram,
    
    #[msg("Invalid instruction")]
    InvalidInstruction,

    #[msg("Insufficient inbound fee")]
    InsufficientInboundFee,

    #[msg("Fee vault has insufficient balance to reimburse relayer")]
    InsufficientFeePool,

    #[msg("gas_fee is below the minimum required gas_used for this finalize")]
    InsufficientGasBudget,

    #[msg("Invalid ix_data hash")]
    InvalidIxDataHash,

    #[msg("ix_data cannot be empty")]
    EmptyIxData,

    #[msg("Stored ix_data account is not closable by caller")]
    StoredIxDataNotClosable,

    #[msg("TSS signature has expired (current time is past deadline)")]
    SignatureExpired,
}
