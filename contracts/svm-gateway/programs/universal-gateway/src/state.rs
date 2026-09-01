use anchor_lang::prelude::*;

// PDA seeds
pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const FEE_VAULT_SEED: &[u8] = b"fee_vault";
pub const TSS_SEED: &[u8] = b"final_tss_pda";
pub const RATE_LIMIT_CONFIG_SEED: &[u8] = b"rate_limit_config";
pub const RATE_LIMIT_SEED: &[u8] = b"rate_limit";
pub const EXECUTED_SUB_TX_SEED: &[u8] = b"executed_sub_tx";
pub const STORED_IX_DATA_SEED: &[u8] = b"stored_ix_data";
pub const CEA_SEED: &[u8] = b"push_identity";
pub const MAX_INBOUND_FEE_LAMPORTS: u64 = 2_000_000;
/// Base Solana transaction fee per signature (protocol constant, unchanged since genesis).
///
/// PROTOCOL ASSUMPTION: `caller` is the sole fee payer and the finalize transaction has exactly
/// one required signature (the UV/relayer keypair). If the UV ever uses a separate fee-payer
/// account or a multi-signature setup, `gas_used` will under-estimate the actual tx cost and
/// the accounting will drift. This constraint is NOT enforced on-chain — it must be upheld
/// by the UV submission service and documented in its operational runbook.
pub const SIGNATURE_FEE_LAMPORTS: u64 = 5_000;

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

/// Epoch usage tracking for rate limiting (matching EVM EpochUsage struct)
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct EpochUsage {
    pub epoch: u64, // epoch index = block.timestamp / epochDurationSec
    pub used: u128, // amount consumed in this epoch (token's natural units)
}

/// Verification types for payload execution (parity with EVM).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerificationType {
    SignedVerification,
    UniversalTxVerification,
}

/// Revert instructions for failed transactions (parity with EVM `RevertInstructions`).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct RevertInstructions {
    pub revert_recipient: Pubkey,
    pub revert_msg: Vec<u8>,
}

/// Universal transaction request (parity with EVM `UniversalTxRequest`).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct UniversalTxRequest {
    pub recipient: [u8; 20],      // [0u8; 20] => credit to UEA on Push
    pub token: Pubkey,            // Pubkey::default() => native SOL
    pub amount: u64,              // native or SPL amount for bridging - Funds
    pub payload: Vec<u8>,         // serialized payload (may be empty)
    pub revert_recipient: Pubkey, // Solana address to receive funds if tx is reverted on Push
    pub signature_data: Vec<u8>,
}

/// Gateway configuration state (authorities, caps, oracle).
/// PDA: `[b"config"]`. Holds USD caps (8 decimals) for gas-route deposits and oracle config.
#[account]
pub struct Config {
    pub admin: Pubkey,
    /// Operator authority (reusing legacy slot to preserve deployed account layout).
    /// This field previously held an unused legacy value (`tss_address`).
    pub operator: Pubkey,
    pub pauser: Pubkey,
    pub min_cap_universal_tx_usd: u128, // 1e8 = $1 (Pyth format)
    pub max_cap_universal_tx_usd: u128, // 1e8 = $10 (Pyth format)
    pub paused: bool,
    pub bump: u8,
    pub vault_bump: u8,
    // Pyth oracle configuration
    pub pyth_price_feed: Pubkey,        // Pyth SOL/USD price feed
    pub pyth_confidence_threshold: u64, // Confidence threshold for price validation
    pub pending_admin: Pubkey,
    pub pending_pauser: Pubkey,
    /// Maximum allowed age for Pyth price updates (seconds). Admin-configurable.
    /// Default: 60. Applies to inbound gas-route USD cap enforcement only.
    pub pyth_max_age_seconds: u64,
}

impl Config {
    // discriminator + fields + padding
    // 8 + 32 + 32 + 32 + 16 + 16 + 1 + 1 + 1 + 32 + 8 + 32 + 32 + 8 + 28
    pub const LEN: usize = 8 + 32 + 32 + 32 + 16 + 16 + 1 + 1 + 1 + 32 + 8 + 32 + 32 + 8 + 28;
}

/// Fee vault: holds protocol fee lamports and the per-tx fee config.
/// PDA: `[b"fee_vault"]`.
/// Lamports above rent-exempt minimum = spendable relayer reimbursement pool.
/// Vault (bridge funds) is never touched by fee logic — 1:1 invariant is structurally enforced.
#[account]
pub struct FeeVault {
    pub inbound_fee_lamports: u64, // Flat fee charged per inbound send_universal_tx; 0 disables
    pub bump: u8,
}

impl FeeVault {
    // 8 (discriminator) + 8 (fee) + 1 (bump) + 50 (padding)
    pub const LEN: usize = 8 + 8 + 1 + 50;
}

/// Rate limiting configuration (separate account for backward compatibility)
/// PDA: `[b"rate_limit_config"]`. Stores global rate limiting settings.
#[account]
pub struct RateLimitConfig {
    pub block_usd_cap: u128,     // Per-block USD cap (8 decimals). 0 disables.
    pub epoch_duration_sec: u64, // Epoch duration in seconds for rate limiting
    pub last_slot: u64,          // Last slot for block-based cap tracking
    pub consumed_usd_in_block: u128, // USD consumed in current block
    pub bump: u8,
}

impl RateLimitConfig {
    pub const LEN: usize = 8 + 16 + 8 + 8 + 16 + 1 + 100; // discriminator + fields + bump + padding
}

/// Token-specific rate limiting state (matching EVM implementation)
/// PDA: `[b"rate_limit", token_mint]`. Tracks epoch-based usage per token.
#[account]
pub struct TokenRateLimit {
    pub token_mint: Pubkey,      // The SPL token mint
    pub limit_threshold: u128,   // Max amount per epoch (token's natural units)
    pub epoch_usage: EpochUsage, // Current epoch usage tracking
    pub bump: u8,
}

impl TokenRateLimit {
    pub const LEN: usize = 8 + 32 + 16 + 8 + 16 + 1 + 100; // discriminator + token_mint + limit_threshold + epoch + used + bump + padding
}

/// TSS state PDA for ECDSA verification (Ethereum-style secp256k1).
/// Stores 20-byte ETH address and chain id (Solana cluster pubkey as String).
#[account]
pub struct TssPda {
    pub tss_eth_address: [u8; 20],
    pub chain_id: String, // Solana cluster pubkey (e.g., "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" for mainnet)
    pub bump: u8,
}

impl TssPda {
    // discriminator (8) + tss_eth_address (20) + chain_id String (4 + 64 max) + bump (1)
    // String: 4 bytes length prefix + up to 64 bytes for cluster pubkey (base58, max ~44 chars, but allow buffer)
    pub const LEN: usize = 8 + 20 + 4 + 64 + 1;
}

/// Executed transaction tracker (parity with EVM `isExecuted[subTxID]` mapping).
/// PDA: `[b"executed_sub_tx", sub_tx_id]`.
/// Account existence = transaction executed (replay protection via `init` constraint).
#[account]
pub struct ExecutedSubTx {}

impl ExecutedSubTx {
    // discriminator (8) only - account existence is the flag
    pub const LEN: usize = 8;
}

/// Stored raw ix_data for ref-finalize flow.
/// PDA: `[b"stored_ix_data", sub_tx_id, ix_data_hash]`.
#[account]
pub struct StoredIxData {
    pub bump: u8,
    /// The sub_tx_id used to derive this PDA. Stored so close_stored_ix_data
    /// needs no args — a UV can recover orphaned PDAs via getProgramAccounts
    /// and close them with accounts only, no local state required.
    pub sub_tx_id: [u8; 32],
    /// Rent refund recipient on close, and success-path recipient of the extra store-route
    /// signature reimbursement. Because `StoreExecuteIxData` uses `payer = caller`, the rent
    /// payer is always this signer. The extra `SIGNATURE_FEE_LAMPORTS` reimbursement also
    /// assumes the same signer paid the store transaction fee operationally.
    pub store_refund_recipient: Pubkey,
    pub ix_data: Vec<u8>,
}

impl StoredIxData {
    // discriminator + bump + sub_tx_id + store_refund_recipient + vec len prefix
    pub const LEN_BASE: usize = 8 + 1 + 32 + 32 + 4;
}

// ============================================
//    EXECUTE ARBITRARY CALLS (NEW)
// ============================================

/// Account metadata for execute messages (no isSigner in payload).
/// Off-chain builds this from target instruction's account list.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug, PartialEq, Eq)]
pub struct GatewayAccountMeta {
    pub pubkey: Pubkey,
    pub is_writable: bool,
}

/// Execute event (parity with EVM `UniversalTxFinalized`).
#[event]
pub struct UniversalTxFinalized {
    pub sub_tx_id: [u8; 32],
    pub universal_tx_id: [u8; 32], // Universal transaction ID from source chain
    pub gas_fee: u64,              // Signed gas budget (lamports) — what TSS authorized
    pub gas_used: u64,             // Actual relayer reimbursement (lamports)
    pub gas_to_refund: u64,        // Unused gas returned to user on Push Chain
    pub ata_created: bool,         // Whether CEA ATA was created in this finalize
    pub recipient_ata_created: bool, // Whether recipient ATA was created (SPL withdraw path)
    pub push_account: [u8; 20],    // EVM address
    pub target: Pubkey,            // Target program
    pub token: Pubkey,             // Token (Pubkey::default() for SOL)
    pub amount: u64,
    pub payload: Vec<u8>, // ix_data
}

/// Universal transaction event (parity with EVM V0 `UniversalTx`).
/// Single event for both gas funding and funds movement.
#[event]
pub struct UniversalTx {
    pub sender: Pubkey,
    pub recipient: [u8; 20],      // Ethereum address (20 bytes)
    pub token: Pubkey,            // Bridge token (Pubkey::default() for native SOL)
    pub amount: u64,              // Bridge amount (not gas amount)
    pub payload: Vec<u8>,         // Payload data
    pub revert_recipient: Pubkey, // Solana address to receive funds if tx is reverted on Push
    pub tx_type: TxType,
    pub signature_data: Vec<u8>,
    pub from_cea: bool, // true = emitted from CEA withdrawal; Push Chain UE uses recipient directly as UEA
}

/// Revert withdraw event (parity with EVM `RevertUniversalTx`).
#[event]
pub struct RevertUniversalTx {
    pub sub_tx_id: [u8; 32],       // Transaction ID
    pub universal_tx_id: [u8; 32], // Universal transaction ID from source chain
    pub revert_recipient: Pubkey,  // Recipient of reverted funds
    pub token: Pubkey,             // Token address (Pubkey::default() for native SOL)
    pub amount: u64,               // Amount
    pub revert_instruction: RevertInstructions,
}

#[event]
pub struct OperatorChanged {
    pub old_operator: Pubkey,
    pub new_operator: Pubkey,
}

#[event]
pub struct CapsUpdated {
    pub min_cap_usd: u128,
    pub max_cap_usd: u128,
}

// Rate limiting events
#[event]
pub struct BlockUsdCapUpdated {
    pub block_usd_cap: u128,
}

#[event]
pub struct EpochDurationUpdated {
    pub epoch_duration_sec: u64,
}

#[event]
pub struct TokenRateLimitUpdated {
    pub token_mint: Pubkey,
    pub limit_threshold: u128,
}

#[event]
pub struct InboundFeeUpdated {
    pub new_fee_lamports: u64,
}

#[event]
pub struct InboundFeeCollected {
    pub payer: Pubkey,
    pub amount_lamports: u64,
    pub native_amount_before: u64,
    pub native_amount_after: u64,
}

#[event]
pub struct InboundFeeReimbursed {
    pub sub_tx_id: [u8; 32],
    pub relayer: Pubkey,
    pub amount_lamports: u64,
}

#[event]
pub struct InboundFeesWithdrawn {
    pub recipient: Pubkey,
    pub amount: u64,
}

/// Emitted when locked funds are rescued back to recipient via TSS-verified rescue instruction.
#[event]
pub struct FundsRescued {
    pub sub_tx_id: [u8; 32],
    pub universal_tx_id: [u8; 32],
    pub token: Pubkey,
    pub amount: u64,
    pub gas_used: u64,             // Actual lamports reimbursed to the relayer from fee_vault
    pub revert_instruction: RevertInstructions,
}
