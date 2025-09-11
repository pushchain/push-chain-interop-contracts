use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{program::invoke_signed, system_instruction};
use anchor_spl::token::{self, Mint, Token, Transfer};

#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.tss_address == tss.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    pub tss: Signer<'info>,

    /// CHECK: Recipient address
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn withdraw(ctx: Context<Withdraw>, recipient: Pubkey, amount: u64) -> Result<()> {
    require!(
        recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(amount > 0, GatewayError::InvalidAmount);

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];

    invoke_signed(
        &system_instruction::transfer(ctx.accounts.vault.key, ctx.accounts.recipient.key, amount),
        &[
            ctx.accounts.vault.to_account_info(),
            ctx.accounts.recipient.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;

    // Emit withdraw event (ETH parity)
    emit!(crate::state::WithdrawFunds {
        recipient: ctx.accounts.recipient.key(),
        amount,
        token: Pubkey::default(), // Native SOL
    });

    Ok(())
}

// SPL Token withdraw instruction
#[derive(Accounts)]
pub struct WithdrawSplToken<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.tss_address == tss.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        constraint = whitelist.tokens.contains(&token_mint.key()) @ GatewayError::TokenNotWhitelisted
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: Token vault ATA, derived from config PDA and token mint (ZetaChain style)
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

    pub tss: Signer<'info>,

    /// CHECK: Recipient token account
    #[account(mut)]
    pub recipient_token_account: UncheckedAccount<'info>,

    pub token_mint: Account<'info, Mint>,

    pub token_program: Program<'info, Token>,
}

pub fn withdraw_spl_token(ctx: Context<WithdrawSplToken>, amount: u64) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);

    // Transfer tokens from vault to recipient
    // We need to derive the bump for the token vault PDA
    // Use config PDA as authority (ZetaChain style)
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[ctx.accounts.config.bump]];

    let cpi_accounts = Transfer {
        from: ctx.accounts.token_vault.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.config.to_account_info(),
    };

    let cpi_program = ctx.accounts.token_program.to_account_info();
    let seeds_array = [seeds];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, &seeds_array);

    token::transfer(cpi_ctx, amount)?;

    // Emit withdraw event (ETH parity)
    emit!(crate::state::WithdrawFunds {
        recipient: ctx.accounts.recipient_token_account.key(),
        amount,
        token: ctx.accounts.token_mint.key(),
    });

    Ok(())
}

// =========================
//   REVERT WITHDRAW FUNCTIONS
// =========================

/// Revert withdraw for SOL (TSS-only)
#[derive(Accounts)]
pub struct RevertWithdraw<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.tss_address == tss.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    pub tss: Signer<'info>,

    /// CHECK: Recipient address
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn revert_withdraw(
    ctx: Context<RevertWithdraw>,
    amount: u64,
    revert_cfg: RevertSettings,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // Transfer SOL from vault to revert recipient
    // Use invoke_signed with vault PDA seeds
    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    invoke_signed(
        &system_instruction::transfer(
            &ctx.accounts.vault.key(),
            &revert_cfg.fund_recipient,
            amount,
        ),
        &[
            ctx.accounts.vault.to_account_info(),
            ctx.accounts.recipient.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;

    // Emit withdraw event (ETH parity)
    emit!(crate::state::WithdrawFunds {
        recipient: revert_cfg.fund_recipient,
        amount,
        token: Pubkey::default(),
    });

    Ok(())
}

/// Revert withdraw for SPL tokens (TSS-only)
#[derive(Accounts)]
pub struct RevertWithdrawSplToken<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.tss_address == tss.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        constraint = whitelist.tokens.contains(&token_mint.key()) @ GatewayError::TokenNotWhitelisted
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: Token vault ATA, derived from config PDA and token mint
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

    pub tss: Signer<'info>,

    /// CHECK: Recipient token account
    #[account(mut)]
    pub recipient_token_account: UncheckedAccount<'info>,

    pub token_mint: Account<'info, Mint>,

    pub token_program: Program<'info, Token>,
}

pub fn revert_withdraw_spl_token(
    ctx: Context<RevertWithdrawSplToken>,
    amount: u64,
    revert_cfg: RevertSettings,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // Transfer tokens from vault to revert recipient
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[ctx.accounts.config.bump]];

    let cpi_accounts = Transfer {
        from: ctx.accounts.token_vault.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.config.to_account_info(),
    };

    let cpi_program = ctx.accounts.token_program.to_account_info();
    let seeds_array = [seeds];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, &seeds_array);

    token::transfer(cpi_ctx, amount)?;

    // Emit withdraw event (ETH parity)
    emit!(crate::state::WithdrawFunds {
        recipient: revert_cfg.fund_recipient,
        amount,
        token: ctx.accounts.token_mint.key(),
    });

    Ok(())
}
