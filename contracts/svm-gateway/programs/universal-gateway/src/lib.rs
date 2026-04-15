use anchor_lang::prelude::*;

pub mod errors;
pub mod instructions;
pub mod state;
pub mod utils;

use instructions::*;

declare_id!("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");

#[program]
pub mod universal_gateway {
    use super::*;

    // =========================
    //           DEPOSITS
    // =========================

    /// @notice Universal transaction entrypoint with internal routing (EVM parity).
    /// @dev    Native amount parameter mirrors `msg.value` on EVM chains.
    ///         All routing (gas / funds / batching) is handled inside the deposit module.
    pub fn send_universal_tx(
        ctx: Context<SendUniversalTx>,
        req: UniversalTxRequest,
        native_amount: u64,
    ) -> Result<()> {
        instructions::deposit::send_universal_tx(ctx, req, native_amount)
    }

    // =========================
    //           ADMIN
    // =========================

    /// @notice Initialize the gateway
    pub fn initialize(
        ctx: Context<Initialize>,
        admin: Pubkey,
        pauser: Pubkey,
        tss: Pubkey,
        min_cap_usd: u128,
        max_cap_usd: u128,
        pyth_price_feed: Pubkey,
    ) -> Result<()> {
        instructions::initialize::initialize(
            ctx,
            admin,
            pauser,
            tss,
            min_cap_usd,
            max_cap_usd,
            pyth_price_feed,
        )
    }

    /// @notice Pause the gateway
    pub fn pause(ctx: Context<PauseAction>) -> Result<()> {
        instructions::admin::pause(ctx)
    }

    /// @notice Unpause the gateway
    pub fn unpause(ctx: Context<PauseAction>) -> Result<()> {
        instructions::admin::unpause(ctx)
    }

    /// @notice Propose new admin and/or pauser authority.
    pub fn propose_authorities(
        ctx: Context<ProposeAuthoritiesAction>,
        new_admin: Option<Pubkey>,
        new_pauser: Option<Pubkey>,
    ) -> Result<()> {
        instructions::admin::propose_authorities(ctx, new_admin, new_pauser)
    }

    /// @notice Accept pending admin authority.
    pub fn accept_admin(ctx: Context<AcceptAdminAction>) -> Result<()> {
        instructions::admin::accept_admin(ctx)
    }

    /// @notice Accept pending pauser authority.
    pub fn accept_pauser(ctx: Context<AcceptPauserAction>) -> Result<()> {
        instructions::admin::accept_pauser(ctx)
    }

    /// @notice Set USD caps
    pub fn set_caps_usd(ctx: Context<AdminAction>, min_cap: u128, max_cap: u128) -> Result<()> {
        instructions::admin::set_caps_usd(ctx, min_cap, max_cap)
    }

    /// @notice Set flat protocol fee (lamports) for inbound send_universal_tx.
    /// Not gated by `!config.paused` so the admin can disable fees during an emergency pause.
    pub fn set_protocol_fee(ctx: Context<FeeVaultAdminAction>, fee_lamports: u64) -> Result<()> {
        instructions::admin::set_protocol_fee(ctx, fee_lamports)
    }

    /// @notice Set Pyth price feed
    pub fn set_pyth_price_feed(ctx: Context<AdminAction>, price_feed: Pubkey) -> Result<()> {
        instructions::admin::set_pyth_price_feed(ctx, price_feed)
    }

    /// @notice Set Pyth confidence threshold
    pub fn set_pyth_confidence_threshold(ctx: Context<AdminAction>, threshold: u64) -> Result<()> {
        instructions::admin::set_pyth_confidence_threshold(ctx, threshold)
    }

    /// @notice Set Pyth price staleness window (seconds). Applies to inbound gas-route cap enforcement.
    pub fn set_pyth_max_age_seconds(ctx: Context<AdminAction>, max_age_seconds: u64) -> Result<()> {
        instructions::admin::set_pyth_max_age_seconds(ctx, max_age_seconds)
    }

    // =========================
    //        RATE LIMITING
    // =========================

    /// @notice Set block-based USD cap for rate limiting
    pub fn set_block_usd_cap(
        ctx: Context<RateLimitConfigAction>,
        block_usd_cap: u128,
    ) -> Result<()> {
        instructions::admin::set_block_usd_cap(ctx, block_usd_cap)
    }

    /// @notice Update epoch duration for rate limiting
    pub fn update_epoch_duration(
        ctx: Context<RateLimitConfigAction>,
        epoch_duration_sec: u64,
    ) -> Result<()> {
        instructions::admin::update_epoch_duration(ctx, epoch_duration_sec)
    }

    /// @notice Set token-specific rate limit threshold
    pub fn set_token_rate_limit(
        ctx: Context<TokenRateLimitAction>,
        limit_threshold: u128,
    ) -> Result<()> {
        instructions::admin::set_token_rate_limit(ctx, limit_threshold)
    }

    // =========================
    //             TSS
    // =========================
    pub fn init_tss(
        ctx: Context<InitTss>,
        tss_eth_address: [u8; 20],
        chain_id: String,
    ) -> Result<()> {
        instructions::tss::init_tss(ctx, tss_eth_address, chain_id)
    }

    pub fn update_tss(
        ctx: Context<UpdateTss>,
        tss_eth_address: [u8; 20],
        chain_id: String,
    ) -> Result<()> {
        instructions::tss::update_tss(ctx, tss_eth_address, chain_id)
    }

    // =========================
    //    FINALIZE UNIVERSAL TX
    // =========================
    /// @notice Unified outbound entrypoint: withdraw (mode 1) or execute (mode 2)
    /// @param instruction_id 1=withdraw (vault→CEA→recipient), 2=execute (vault→CEA→CPI)
    pub fn finalize_universal_tx(
        ctx: Context<FinalizeUniversalTx>,
        instruction_id: u8,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        push_account: [u8; 20],
        writable_flags: Vec<u8>,
        ix_data: Vec<u8>,
        gas_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::execute::finalize_universal_tx(
            ctx,
            instruction_id,
            sub_tx_id,
            universal_tx_id,
            amount,
            push_account,
            writable_flags,
            ix_data,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
        )
    }

    // =========================
    //          RESCUE
    // =========================
    /// @notice TSS-verified emergency rescue of locked funds from vault.
    ///         SOL path: token_mint = None. SPL path: token_mint = Some.
    ///         Replay-protected via ExecutedSubTx PDA
    pub fn rescue_funds(
        ctx: Context<RescueFunds>,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        gas_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::rescue::rescue_funds(
            ctx,
            sub_tx_id,
            universal_tx_id,
            amount,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
        )
    }

    // =========================
    //        REVERT
    // =========================
    /// @notice TSS-verified unified revert (SOL and SPL) — EVM parity: `revertUniversalTx`.
    ///         SOL path: token_mint = None. SPL path: token_mint = Some.
    pub fn revert_universal_tx(
        ctx: Context<RevertUniversalTx>,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        revert_instruction: RevertInstructions,
        gas_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::revert::revert_universal_tx(
            ctx,
            sub_tx_id,
            universal_tx_id,
            amount,
            revert_instruction,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
        )
    }

    // =========================
    //         UTILS
    // =========================
    /// @notice View function for SOL price (locker-compatible)
    pub fn get_sol_price(ctx: Context<GetSolPrice>) -> Result<PriceData> {
        utils::get_sol_price(&ctx.accounts.price_update)
    }
}

/// Accounts for get_sol_price view function
#[derive(Accounts)]
pub struct GetSolPrice<'info> {
    pub price_update: Account<'info, pyth_solana_receiver_sdk::price_update::PriceUpdateV2>,
}

// Re-export account structs and types
pub use instructions::admin::{
    AdminAction, FeeVaultAdminAction, PauseAction, ProposeAuthoritiesAction, RateLimitConfigAction,
    TokenRateLimitAction,
};
pub use instructions::deposit::SendUniversalTx;
pub use instructions::execute::FinalizeUniversalTx;
pub use instructions::initialize::Initialize;
pub use instructions::rescue::RescueFunds;
pub use instructions::revert::RevertUniversalTx;
pub use utils::PriceData;

pub use state::{
    // Events
    CapsUpdated,
    Config,
    ExecutedSubTx,
    FeeVault,
    FundsRescued,
    GatewayAccountMeta,
    ProtocolFeeCollected,
    ProtocolFeeReimbursed,
    ProtocolFeeUpdated,
    RevertInstructions,
    TxType,
    UniversalTx,
    UniversalTxFinalized,
    UniversalTxRequest,
    VerificationType,
    CONFIG_SEED,
    EXECUTED_SUB_TX_SEED,
    FEED_ID,
    FEE_VAULT_SEED,
    VAULT_SEED,
};
