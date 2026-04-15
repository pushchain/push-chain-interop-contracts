use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct AdminAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
}

/// Authority update action (available while paused).
/// Proposes admin and/or pauser updates. Proposed authorities must accept explicitly.
#[derive(Accounts)]
pub struct ProposeAuthoritiesAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct AcceptAdminAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.pending_admin == pending_admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub pending_admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct AcceptPauserAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.pending_pauser == pending_pauser.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub pending_pauser: Signer<'info>,
}

#[derive(Accounts)]
pub struct PauseAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.pauser == pauser.key() || config.admin == pauser.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub pauser: Signer<'info>,
}

pub fn pause(ctx: Context<PauseAction>) -> Result<()> {
    ctx.accounts.config.paused = true;
    Ok(())
}

pub fn unpause(ctx: Context<PauseAction>) -> Result<()> {
    ctx.accounts.config.paused = false;
    Ok(())
}

pub fn propose_authorities(
    ctx: Context<ProposeAuthoritiesAction>,
    new_admin: Option<Pubkey>,
    new_pauser: Option<Pubkey>,
) -> Result<()> {
    require!(
        new_admin.is_some() || new_pauser.is_some(),
        GatewayError::InvalidInput
    );

    let config = &mut ctx.accounts.config;

    if let Some(next) = new_admin {
        require!(next != Pubkey::default(), GatewayError::ZeroAddress);
        config.pending_admin = next;
    }

    if let Some(next) = new_pauser {
        require!(next != Pubkey::default(), GatewayError::ZeroAddress);
        config.pending_pauser = next;
    }

    Ok(())
}

pub fn accept_admin(ctx: Context<AcceptAdminAction>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.admin = ctx.accounts.pending_admin.key();
    config.pending_admin = Pubkey::default();
    Ok(())
}

pub fn accept_pauser(ctx: Context<AcceptPauserAction>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.pauser = ctx.accounts.pending_pauser.key();
    config.pending_pauser = Pubkey::default();
    Ok(())
}

pub fn set_caps_usd(ctx: Context<AdminAction>, min_cap_usd: u128, max_cap_usd: u128) -> Result<()> {
    require!(min_cap_usd <= max_cap_usd, GatewayError::InvalidCapRange);
    let config = &mut ctx.accounts.config;
    config.min_cap_universal_tx_usd = min_cap_usd;
    config.max_cap_universal_tx_usd = max_cap_usd;

    // Emit caps updated event
    emit!(crate::state::CapsUpdated {
        min_cap_usd,
        max_cap_usd,
    });

    Ok(())
}

/// Admin action for fee vault operations (intentionally no `!config.paused` guard —
/// the admin must be able to disable the fee even while paused).
#[derive(Accounts)]
pub struct FeeVaultAdminAction<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = FeeVault::LEN,
        seeds = [FEE_VAULT_SEED],
        bump,
    )]
    pub fee_vault: Account<'info, FeeVault>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn set_protocol_fee(ctx: Context<FeeVaultAdminAction>, fee_lamports: u64) -> Result<()> {
    // Keep bump persisted so seeded constraints continue to validate consistently.
    ctx.accounts.fee_vault.bump = ctx.bumps.fee_vault;
    ctx.accounts.fee_vault.protocol_fee_lamports = fee_lamports;
    emit!(ProtocolFeeUpdated {
        new_fee_lamports: fee_lamports
    });
    Ok(())
}

// Pyth oracle configuration functions
pub fn set_pyth_price_feed(ctx: Context<AdminAction>, price_feed: Pubkey) -> Result<()> {
    require!(price_feed != Pubkey::default(), GatewayError::ZeroAddress);
    ctx.accounts.config.pyth_price_feed = price_feed;
    Ok(())
}

pub fn set_pyth_confidence_threshold(ctx: Context<AdminAction>, threshold: u64) -> Result<()> {
    require!(threshold > 0, GatewayError::InvalidAmount);
    ctx.accounts.config.pyth_confidence_threshold = threshold;
    Ok(())
}

// =========================
// RATE LIMITING ADMIN FUNCTIONS
// =========================

/// Set block-based USD cap for rate limiting (matching EVM setBlockUsdCap)
#[derive(Accounts)]
pub struct RateLimitConfigAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = RateLimitConfig::LEN,
        seeds = [RATE_LIMIT_CONFIG_SEED],
        bump
    )]
    pub rate_limit_config: Account<'info, RateLimitConfig>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn set_block_usd_cap(ctx: Context<RateLimitConfigAction>, block_usd_cap: u128) -> Result<()> {
    let rate_limit_config = &mut ctx.accounts.rate_limit_config;
    rate_limit_config.block_usd_cap = block_usd_cap;
    rate_limit_config.bump = ctx.bumps.rate_limit_config;

    // Emit event
    emit!(BlockUsdCapUpdated { block_usd_cap });

    Ok(())
}

/// Update epoch duration for rate limiting (matching EVM updateEpochDuration)
/// @param epoch_duration_sec Epoch duration in seconds. Set to 0 to disable epoch-based rate limiting.
pub fn update_epoch_duration(
    ctx: Context<RateLimitConfigAction>,
    epoch_duration_sec: u64,
) -> Result<()> {
    // Allow 0 to disable epoch-based rate limiting
    let rate_limit_config = &mut ctx.accounts.rate_limit_config;
    rate_limit_config.epoch_duration_sec = epoch_duration_sec;
    rate_limit_config.bump = ctx.bumps.rate_limit_config;

    // Emit event
    emit!(EpochDurationUpdated { epoch_duration_sec });

    Ok(())
}

/// Set token-specific rate limit threshold (matching EVM setTokenToLimitThreshold)
#[derive(Accounts)]
pub struct TokenRateLimitAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = TokenRateLimit::LEN,
        seeds = [RATE_LIMIT_SEED, token_mint.key().as_ref()],
        bump
    )]
    pub token_rate_limit: Account<'info, TokenRateLimit>,

    /// CHECK: Token mint address
    pub token_mint: UncheckedAccount<'info>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

/// Set token-specific rate limit threshold (matching EVM setTokenToLimitThreshold)
/// @param limit_threshold Max amount per epoch (token's natural units).
///        Set to 0 to remove support for this token — deposits will be rejected with NotSupported.
///        To disable epoch consumption while keeping the token supported, set epoch_duration_sec to 0.
pub fn set_token_rate_limit(
    ctx: Context<TokenRateLimitAction>,
    limit_threshold: u128,
) -> Result<()> {
    // limit_threshold == 0 means token is not supported; deposits are rejected with NotSupported.
    let token_rate_limit = &mut ctx.accounts.token_rate_limit;
    token_rate_limit.token_mint = ctx.accounts.token_mint.key();
    token_rate_limit.limit_threshold = limit_threshold;
    token_rate_limit.epoch_usage = EpochUsage { epoch: 0, used: 0 };

    // Emit event
    emit!(TokenRateLimitUpdated {
        token_mint: ctx.accounts.token_mint.key(),
        limit_threshold,
    });

    Ok(())
}
