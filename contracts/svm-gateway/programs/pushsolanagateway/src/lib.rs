use anchor_lang::prelude::*;

pub mod errors;
pub mod instructions;
pub mod state;
pub mod utils;

use instructions::*;

declare_id!("9nokRuXvtKyT32vvEQ1gkM3o8HzNooStpCuKuYD8BoX5");

#[program]
pub mod pushsolanagateway {
    use super::*;

    // =========================
    //           DEPOSITS
    // =========================

    /// @notice Allows initiating a TX for funding UEA with gas deposits from source chain.
    /// @dev    Supports only native SOL deposits for gas funding.
    ///         The route emits TxWithGas event - important for Instant TX Route.
    pub fn send_tx_with_gas(
        ctx: Context<SendTxWithGas>,
        payload: UniversalPayload,
        revert_cfg: RevertSettings,
        amount: u64,
    ) -> Result<()> {
        instructions::deposit::send_tx_with_gas(ctx, payload, revert_cfg, amount)
    }

    /// @notice Allows initiating a TX for movement of funds from source chain to Push Chain.
    /// @dev    Supports both native SOL and SPL token deposits.
    ///         The route emits TxWithFunds event.
    pub fn send_funds(
        ctx: Context<SendFunds>,
        recipient: Pubkey,
        bridge_token: Pubkey,
        bridge_amount: u64,
        revert_cfg: RevertSettings,
    ) -> Result<()> {
        instructions::deposit::send_funds(ctx, recipient, bridge_token, bridge_amount, revert_cfg)
    }

    /// @notice Allows initiating a TX for movement of native SOL from source chain to Push Chain.
    pub fn send_funds_native(
        ctx: Context<SendFundsNative>,
        recipient: Pubkey,
        bridge_amount: u64,
        revert_cfg: RevertSettings,
    ) -> Result<()> {
        instructions::deposit::send_funds_native(ctx, recipient, bridge_amount, revert_cfg)
    }

    /// @notice Allows initiating a TX for movement of funds and payload from source chain to Push Chain.
    /// @dev    Supports both native SOL and SPL token deposits with payload execution.
    ///         The route emits both TxWithGas and TxWithFunds events.
    pub fn send_tx_with_funds(
        ctx: Context<SendTxWithFunds>,
        bridge_token: Pubkey,
        bridge_amount: u64,
        payload: UniversalPayload,
        revert_cfg: RevertSettings,
        gas_amount: u64,
    ) -> Result<()> {
        instructions::deposit::send_tx_with_funds(
            ctx,
            bridge_token,
            bridge_amount,
            payload,
            revert_cfg,
            gas_amount,
        )
    }

    // =========================
    //        WITHDRAWALS
    // =========================

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

    /// @notice Set TSS address
    pub fn set_tss_address(ctx: Context<AdminAction>, new_tss: Pubkey) -> Result<()> {
        instructions::admin::set_tss_address(ctx, new_tss)
    }

    /// @notice Set USD caps
    pub fn set_caps_usd(ctx: Context<AdminAction>, min_cap: u128, max_cap: u128) -> Result<()> {
        instructions::admin::set_caps_usd(ctx, min_cap, max_cap)
    }

    /// @notice Whitelist a token
    pub fn whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
        instructions::admin::whitelist_token(ctx, token)
    }

    /// @notice Remove token from whitelist
    pub fn remove_whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
        instructions::admin::remove_whitelist_token(ctx, token)
    }

    /// @notice Set Pyth price feed
    pub fn set_pyth_price_feed(ctx: Context<AdminAction>, price_feed: Pubkey) -> Result<()> {
        instructions::admin::set_pyth_price_feed(ctx, price_feed)
    }

    /// @notice Set Pyth confidence threshold
    pub fn set_pyth_confidence_threshold(ctx: Context<AdminAction>, threshold: u64) -> Result<()> {
        instructions::admin::set_pyth_confidence_threshold(ctx, threshold)
    }

    // =========================
    //             TSS
    // =========================
    pub fn init_tss(ctx: Context<InitTss>, tss_eth_address: [u8; 20], chain_id: u64) -> Result<()> {
        instructions::tss::init_tss(ctx, tss_eth_address, chain_id)
    }

    pub fn update_tss(
        ctx: Context<UpdateTss>,
        tss_eth_address: [u8; 20],
        chain_id: u64,
    ) -> Result<()> {
        instructions::tss::update_tss(ctx, tss_eth_address, chain_id)
    }

    pub fn reset_nonce(ctx: Context<ResetNonce>, new_nonce: u64) -> Result<()> {
        instructions::tss::reset_nonce(ctx, new_nonce)
    }

    /// @notice TSS-verified withdraw of native SOL
    pub fn withdraw_tss(
        ctx: Context<WithdrawTss>,
        amount: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
        nonce: u64,
    ) -> Result<()> {
        instructions::withdraw::withdraw_tss(
            ctx,
            amount,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    /// @notice TSS-verified withdraw of SPL tokens
    pub fn withdraw_spl_token_tss(
        ctx: Context<WithdrawSplTokenTss>,
        amount: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
        nonce: u64,
    ) -> Result<()> {
        instructions::withdraw::withdraw_spl_token_tss(
            ctx,
            amount,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    // =========================
    //         LEGACY (V0)
    // =========================
    /// @notice Legacy-compatible add funds event for offchain relayers (pushsolanalocker)
    pub fn add_funds(
        ctx: Context<AddFunds>,
        amount: u64,
        transaction_hash: [u8; 32],
    ) -> Result<()> {
        instructions::legacy::add_funds(ctx, amount, transaction_hash)
    }
}

// Re-export account structs and types
pub use instructions::admin::{AdminAction, PauseAction, WhitelistAction};
pub use instructions::deposit::{SendFunds, SendFundsNative, SendTxWithFunds, SendTxWithGas};
pub use instructions::initialize::Initialize;
pub use instructions::legacy::{AddFunds, FundsAddedEvent};
pub use instructions::withdraw::RevertWithdraw;

pub use state::{
    // Events
    CapsUpdated,
    Config,
    RevertSettings,
    TSSAddressUpdated,
    TokenRemovedFromWhitelist,
    TokenWhitelist,
    TokenWhitelisted,
    TxType,
    TxWithFunds,
    TxWithGas,
    UniversalPayload,
    VerificationType,
    WithdrawFunds,
    CONFIG_SEED,
    FEED_ID,
    VAULT_SEED,
    WHITELIST_SEED,
};
