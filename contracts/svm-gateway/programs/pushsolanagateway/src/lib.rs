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
    //           WITHDRAWALS
    // =========================

    /// @notice TSS-controlled withdraw of native SOL
    pub fn withdraw_funds(ctx: Context<Withdraw>, recipient: Pubkey, amount: u64) -> Result<()> {
        instructions::withdraw::withdraw(ctx, recipient, amount)
    }

    /// @notice TSS-controlled revert withdraw of native SOL
    pub fn revert_withdraw_funds(
        ctx: Context<RevertWithdraw>,
        amount: u64,
        revert_cfg: RevertSettings,
    ) -> Result<()> {
        instructions::withdraw::revert_withdraw(ctx, amount, revert_cfg)
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
}

// Re-export account structs and types
pub use instructions::admin::{AdminAction, PauseAction, WhitelistAction};
pub use instructions::deposit::{SendFunds, SendFundsNative, SendTxWithFunds, SendTxWithGas};
pub use instructions::initialize::Initialize;
pub use instructions::withdraw::{RevertWithdraw, Withdraw};

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
