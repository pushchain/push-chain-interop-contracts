use anchor_lang::prelude::*;

// PDA seeds
pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const WHITELIST_SEED: &[u8] = b"whitelist";

// Price feed ID (Pyth SOL/USD), same as locker for now
pub const FEED_ID: &str = "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";

// Transaction types EXACTLY matching EVM gateway
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TxType {
    /// @dev only for funding the UEA on Push Chain with GAS
    ///      doesn't support movement of high value funds or payload for execution.
    Gas,
    /// @dev for funding UEA and execute a payload instantly via UEA on Push Chain. versal transaction route.
    ///      allows movement of funds between CAP_RANGES ( low fund size ) & requires lower block confirmations.
    GasAndPayload,
    /// @dev for bridging of large funds only from external chain to Push Chain.
    ///      doesn't support arbitrary payload movement and requires longer block confirmations.
    Funds,
    /// @dev for bridging both funds and payload to Push Chain for execution.
    /// @dev no strict cap ranges for fund amount and requires longer block confirmations.
    FundsAndPayload,
}

// Verification types for payload execution
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerificationType {
    SignedVerification,
    UniversalTxVerification,
}

// Universal payload for cross-chain execution (matching EVM)
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct UniversalPayload {
    pub to: Pubkey,
    pub value: u64,
    pub data: Vec<u8>,
    pub gas_limit: u64,
    pub max_fee_per_gas: u64,
    pub max_priority_fee_per_gas: u64,
    pub nonce: u64,
    pub deadline: i64,
    pub v_type: VerificationType,
}

// Revert settings for failed transactions (matching EVM)
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct RevertSettings {
    pub fund_recipient: Pubkey,
    pub revert_msg: Vec<u8>,
}

// Gateway configuration state
#[account]
pub struct Config {
    pub admin: Pubkey,
    pub tss_address: Pubkey,
    pub pauser: Pubkey,
    pub min_cap_universal_tx_usd: u128, // 1e8 = $1 (Pyth format)
    pub max_cap_universal_tx_usd: u128, // 1e8 = $10 (Pyth format)
    pub paused: bool,
    pub bump: u8,
    pub vault_bump: u8,
    // Pyth oracle configuration
    pub pyth_price_feed: Pubkey,        // Pyth SOL/USD price feed
    pub pyth_confidence_threshold: u64, // Confidence threshold for price validation
}

impl Config {
    // discriminator + fields + padding
    pub const LEN: usize = 8 + 32 + 32 + 32 + 16 + 16 + 1 + 1 + 1 + 32 + 8 + 100;
}

// SPL Token whitelist state
#[account]
pub struct TokenWhitelist {
    pub tokens: Vec<Pubkey>,
    pub bump: u8,
}

impl TokenWhitelist {
    pub const LEN: usize = 8 + 4 + (32 * 50) + 1 + 100; // discriminator + vec length + 50 tokens max + bump + padding
}

// Event definitions matching EVM gateway
// TxWithGas(sender, payloadHash, nativeTokenDeposited, revertCFG, txType)
#[event]
pub struct TxWithGas {
    pub sender: Pubkey,
    pub payload_hash: [u8; 32],
    pub native_token_deposited: u64,
    pub revert_cfg: RevertSettings,
    pub tx_type: TxType,
}

// TxWithFunds(sender, recipient, bridgeAmount, gasAmount, bridgeToken, data, revertCFG, txType)
#[event]
pub struct TxWithFunds {
    pub sender: Pubkey,
    pub recipient: Pubkey,
    pub bridge_amount: u64,
    pub gas_amount: u64,
    pub bridge_token: Pubkey,
    pub data: Vec<u8>,
    pub revert_cfg: RevertSettings,
    pub tx_type: TxType,
}

// WithdrawFunds(recipient, amount, token)
#[event]
pub struct WithdrawFunds {
    pub recipient: Pubkey,
    pub amount: u64,
    pub token: Pubkey,
}

#[event]
pub struct TSSAddressUpdated {
    pub old_tss: Pubkey,
    pub new_tss: Pubkey,
}

#[event]
pub struct TokenWhitelisted {
    pub token_address: Pubkey,
}

#[event]
pub struct TokenRemovedFromWhitelist {
    pub token_address: Pubkey,
}

#[event]
pub struct CapsUpdated {
    pub min_cap_usd: u128,
    pub max_cap_usd: u128,
}

// Keep legacy if referenced; prefer TxWithGas above
