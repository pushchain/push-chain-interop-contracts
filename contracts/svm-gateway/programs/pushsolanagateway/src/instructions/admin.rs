use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct AdminAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
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

pub fn set_tss_address(ctx: Context<AdminAction>, new_tss: Pubkey) -> Result<()> {
    require!(new_tss != Pubkey::default(), GatewayError::ZeroAddress);
    ctx.accounts.config.tss_address = new_tss;
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

#[derive(Accounts)]
pub struct WhitelistAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = TokenWhitelist::LEN,
        seeds = [WHITELIST_SEED],
        bump
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
    require!(token != Pubkey::default(), GatewayError::ZeroAddress);

    let whitelist = &mut ctx.accounts.whitelist;

    // Check if token is already whitelisted
    if whitelist.tokens.contains(&token) {
        return Err(GatewayError::TokenAlreadyWhitelisted.into());
    }

    // Add token to whitelist
    whitelist.tokens.push(token);

    // Emit event
    emit!(TokenWhitelisted {
        token_address: token,
    });

    Ok(())
}

pub fn remove_whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
    require!(token != Pubkey::default(), GatewayError::ZeroAddress);

    let whitelist = &mut ctx.accounts.whitelist;

    // Find and remove token from whitelist
    if let Some(pos) = whitelist.tokens.iter().position(|&x| x == token) {
        whitelist.tokens.remove(pos);

        // Emit event
        emit!(TokenRemovedFromWhitelist {
            token_address: token,
        });
    } else {
        return Err(GatewayError::TokenNotWhitelisted.into());
    }

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
