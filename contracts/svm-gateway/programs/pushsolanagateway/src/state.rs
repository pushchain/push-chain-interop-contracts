use anchor_lang::prelude::*;

// PDA seeds
pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const WHITELIST_SEED: &[u8] = b"whitelist";

// Price feed ID (Pyth SOL/USD), same as locker for now
pub const FEED_ID: &str = "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";

/// Transaction types matching the EVM Universal Gateway `TX_TYPE`.
/// Kept 1:1 for relayer/event parity with the EVM implementation.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TxType {
    /// GAS-only route; funds instant UEA gas on Push Chain. No payload execution or high-value movement.
    Gas,
    /// GAS + PAYLOAD route (instant). Low-value movement with caps. Executes payload via UEA.
    GasAndPayload,
    /// High-value FUNDS-only bridge (no payload). Requires longer finality.
    Funds,
    /// FUNDS + PAYLOAD bridge. Requires longer finality. No strict caps for funds (gas caps still apply).
    FundsAndPayload,
}

/// Verification types for payload execution (parity with EVM).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerificationType {
    SignedVerification,
    UniversalTxVerification,
}

/// Universal payload for cross-chain execution (parity with EVM `UniversalPayload`).
/// Serialized and hashed for event parity with EVM (payload bytes/hash).
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

/// Revert settings for failed transactions (parity with EVM `RevertSettings`).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct RevertSettings {
    pub fund_recipient: Pubkey,
    pub revert_msg: Vec<u8>,
}

/// Gateway configuration state (authorities, caps, oracle).
/// PDA: `[b"config"]`. Holds USD caps (8 decimals) for gas-route deposits and oracle config.
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

/// SPL token whitelist state.
/// PDA: `[b"whitelist"]`. Simple list of supported SPL mints.
#[account]
pub struct TokenWhitelist {
    pub tokens: Vec<Pubkey>,
    pub bump: u8,
}

impl TokenWhitelist {
    pub const LEN: usize = 8 + 4 + (32 * 50) + 1 + 100; // discriminator + vec length + 50 tokens max + bump + padding
}

/// GAS deposit event (parity with EVM `TxWithGas`). Emitted for gas funding on both GAS and GAS+PAYLOAD routes.
#[event]
pub struct TxWithGas {
    pub sender: Pubkey,
    pub payload_hash: [u8; 32],
    pub native_token_deposited: u64,
    pub revert_cfg: RevertSettings,
    pub tx_type: TxType,
}

/// FUNDS deposit event (parity with EVM `TxWithFunds`). Emitted for FUNDS-only and FUNDS+PAYLOAD routes.
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

/// Withdraw event (parity with EVM `WithdrawFunds`).
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
