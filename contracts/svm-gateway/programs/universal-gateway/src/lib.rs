use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak;
use crate::errors::GatewayError;

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
        operator: Pubkey,
        min_cap_usd: u128,
        max_cap_usd: u128,
        pyth_price_feed: Pubkey,
    ) -> Result<()> {
        instructions::initialize::initialize(
            ctx,
            admin,
            pauser,
            operator,
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
    pub fn unpause(ctx: Context<UnpauseAction>) -> Result<()> {
        instructions::admin::unpause(ctx)
    }

    /// @notice Set operator authority
    pub fn set_operator(ctx: Context<AdminAction>, new_operator: Pubkey) -> Result<()> {
        instructions::admin::set_operator(ctx, new_operator)
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

    /// @notice Set flat inbound fee (lamports) charged per send_universal_tx.
    /// Must be <= `MAX_INBOUND_FEE_LAMPORTS`.
    /// Not gated by `!config.paused` so the admin can disable fees during an emergency pause.
    pub fn set_inbound_fee(ctx: Context<FeeVaultAdminAction>, fee_lamports: u64) -> Result<()> {
        instructions::admin::set_inbound_fee(ctx, fee_lamports)
    }

    /// @notice Withdraw accumulated inbound fee surplus from the fee vault to a recipient.
    /// Only lamports above rent-exemption are withdrawable.
    /// Admin-only — involves fund movement out of the fee vault.
    pub fn withdraw_inbound_fees(
        ctx: Context<WithdrawInboundFees>,
        amount: u64,
    ) -> Result<()> {
        instructions::admin::withdraw_inbound_fees(ctx, amount)
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
        trusted_mint_authority: bool,
        trusted_freeze_authority: bool,
    ) -> Result<()> {
        instructions::admin::set_token_rate_limit(
            ctx,
            limit_threshold,
            trusted_mint_authority,
            trusted_freeze_authority,
        )
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
    /// @param deadline Unix timestamp (seconds) after which TSS signature is invalid.
    ///        Prevents late first-execution on Solana after source-chain revert/refund.
    pub fn finalize_universal_tx<'a, 'b, 'c, 'info>(
        mut ctx: Context<'a, 'b, 'c, 'info, FinalizeUniversalTx<'info>>,
        instruction_id: u8,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        push_account: [u8; 20],
        writable_flags: Vec<u8>,
        ix_data: Vec<u8>,
        gas_fee: u64,
        deadline: i64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::execute::finalize_universal_tx_common(
            &mut ctx,
            instruction_id,
            sub_tx_id,
            universal_tx_id,
            amount,
            push_account,
            writable_flags,
            ix_data,
            0,
            None,
            gas_fee,
            deadline,
            signature,
            recovery_id,
            message_hash,
        )
    }

    /// @notice Store raw ix_data bytes on-chain for later finalize-by-reference.
    pub fn store_execute_ix_data(
        ctx: Context<StoreExecuteIxData>,
        sub_tx_id: [u8; 32],
        ix_data_hash: [u8; 32],
        ix_data: Vec<u8>,
    ) -> Result<()> {
        instructions::execute::store_execute_ix_data(ctx, sub_tx_id, ix_data_hash, ix_data)
    }

    /// @notice Additive ref-finalize route. Executes the same finalize flow using ix_data loaded from PDA.
    /// @param deadline Unix timestamp (seconds) after which TSS signature is invalid.
    pub fn finalize_universal_tx_with_ix_data_ref<'a, 'b, 'c, 'info>(
        mut ctx: Context<'a, 'b, 'c, 'info, FinalizeUniversalTx<'info>>,
        instruction_id: u8,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        push_account: [u8; 20],
        ix_data_hash: [u8; 32],
        writable_flags: Vec<u8>,
        gas_fee: u64,
        deadline: i64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        let stored_ix_data = ctx
            .accounts
            .stored_ix_data
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let store_refund_recipient = ctx
            .accounts
            .store_refund_recipient
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        let ix_data = stored_ix_data.ix_data.clone();
        let computed = keccak::hashv(&[ix_data.as_slice()]).to_bytes();
        require!(computed == ix_data_hash, GatewayError::InvalidIxDataHash);
        require!(
            store_refund_recipient.key() == stored_ix_data.store_refund_recipient,
            GatewayError::InvalidAccount
        );
        require!(
            stored_ix_data.sub_tx_id == sub_tx_id,
            GatewayError::InvalidAccount
        );

        let (expected_stored_ix_data, _) = Pubkey::find_program_address(
            &[state::STORED_IX_DATA_SEED, sub_tx_id.as_ref(), computed.as_ref()],
            ctx.program_id,
        );
        require!(
            stored_ix_data.key() == expected_stored_ix_data,
            GatewayError::InvalidAccount
        );

        let store_refund_recipient_info = store_refund_recipient.to_account_info();

        instructions::execute::finalize_universal_tx_common(
            &mut ctx,
            instruction_id,
            sub_tx_id,
            universal_tx_id,
            amount,
            push_account,
            writable_flags,
            ix_data,
            state::SIGNATURE_FEE_LAMPORTS,
            Some(&store_refund_recipient_info),
            gas_fee,
            deadline,
            signature,
            recovery_id,
            message_hash,
        )?;

        // Auto-close the StoredIxData PDA on finalize success — rent returns to store_refund_recipient.
        ctx.accounts.stored_ix_data.as_ref().unwrap().close(store_refund_recipient_info)?;

        Ok(())
    }

    /// @notice Close stored ix_data PDA and recover rent to the stored store_refund_recipient.
    pub fn close_stored_ix_data(ctx: Context<CloseStoredIxData>) -> Result<()> {
        instructions::execute::close_stored_ix_data(ctx)
    }

    // =========================
    //            PC20
    // =========================
    /// @notice TSS-authorized Push -> Solana PC20 export settlement.
    pub fn finalize_pc20_export(
        ctx: Context<FinalizePc20Export>,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        source_asset: [u8; 20],
        amount: u64,
        push_account: [u8; 20],
        recipient: Pubkey,
        name: String,
        symbol: String,
        decimals: u8,
        user_data: Vec<u8>,
        gas_fee: u64,
        deadline: i64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::pc20::finalize_pc20_export(
            ctx, sub_tx_id, universal_tx_id, source_asset, amount, push_account,
            recipient, name, symbol, decimals, user_data, gas_fee, deadline,
            signature, recovery_id, message_hash,
        )
    }

    pub fn send_pc20_universal_tx(
        ctx: Context<SendPc20UniversalTx>,
        sub_tx_id: [u8; 32],
        source_asset: [u8; 20],
        amount: u64,
        recipient: [u8; 20],
        payload: Vec<u8>,
        revert_recipient: Pubkey,
    ) -> Result<()> {
        instructions::pc20::send_pc20_universal_tx(
            ctx, sub_tx_id, source_asset, amount, recipient, payload, revert_recipient,
        )
    }

    pub fn revert_pc20_burn(
        ctx: Context<RevertPc20Burn>,
        sub_tx_id: [u8; 32],
        original_burn_sub_tx_id: [u8; 32],
        source_asset: [u8; 20],
        amount: u64,
        revert_recipient: Pubkey,
        gas_fee: u64,
        deadline: i64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::pc20::revert_pc20_burn(
            ctx, sub_tx_id, original_burn_sub_tx_id, source_asset, amount,
            revert_recipient, gas_fee, deadline, signature, recovery_id, message_hash,
        )
    }

    // =========================
    //          RESCUE
    // =========================
    /// @notice TSS-verified emergency rescue of locked funds from vault.
    ///         SOL path: token_mint = None. SPL path: token_mint = Some.
    ///         Replay-protected via ExecutedSubTx PDA
    /// @param deadline Unix timestamp (seconds) after which TSS signature is invalid.
    pub fn rescue_funds(
        ctx: Context<RescueFunds>,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        gas_fee: u64,
        deadline: i64,
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
            deadline,
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
    /// @param deadline Unix timestamp (seconds) after which TSS signature is invalid.
    pub fn revert_universal_tx(
        ctx: Context<RevertUniversalTx>,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        revert_instruction: RevertInstructions,
        gas_fee: u64,
        deadline: i64,
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
            deadline,
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
    TokenRateLimitAction, WithdrawInboundFees,
};
pub use instructions::deposit::SendUniversalTx;
pub use instructions::execute::{CloseStoredIxData, FinalizeUniversalTx, StoreExecuteIxData};
pub use instructions::initialize::Initialize;
pub use instructions::rescue::RescueFunds;
pub use instructions::revert::RevertUniversalTx;
pub use instructions::pc20::{FinalizePc20Export, RevertPc20Burn, SendPc20UniversalTx};
pub use utils::PriceData;

pub use state::{
    Pc20BurnReverted, Pc20ExportFinalized, Pc20UniversalTx, PC20_MINT_SEED,
    // Events
    CapsUpdated,
    Config,
    ExecutedSubTx,
    FeeVault,
    FundsRescued,
    GatewayAccountMeta,
    InboundFeeCollected,
    InboundFeeReimbursed,
    InboundFeeUpdated,
    InboundFeesWithdrawn,
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
    STORED_IX_DATA_SEED,
    StoredIxData,
    VAULT_SEED,
};
