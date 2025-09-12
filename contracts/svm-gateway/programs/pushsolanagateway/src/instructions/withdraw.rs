use crate::instructions::tss::validate_message;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{program::invoke_signed, system_instruction};
use anchor_spl::token::{self, Mint, Token, Transfer};

// Legacy signer-based withdraw removed; use TSS-verified variants below

// =========================
//        TSS WITHDRAW
// =========================

#[derive(Accounts)]
pub struct WithdrawTss<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// CHECK: Recipient address
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn withdraw_tss(
    ctx: Context<WithdrawTss>,
    amount: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);

    // instruction_id = 1 for SOL withdraw
    let instruction_id: u8 = 1;
    let recipient_bytes = ctx.accounts.recipient.key().to_bytes();
    let additional: [&[u8]; 1] = [&recipient_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

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

    emit!(crate::state::WithdrawFunds {
        recipient: ctx.accounts.recipient.key(),
        amount,
        token: Pubkey::default(),
    });

    Ok(())
}

#[derive(Accounts)]
pub struct WithdrawSplTokenTss<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    #[account(
        constraint = whitelist.tokens.contains(&token_mint.key()) @ GatewayError::TokenNotWhitelisted
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Token vault ATA, derived from vault PDA and token mint
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// CHECK: Recipient token account
    #[account(mut)]
    pub recipient_token_account: UncheckedAccount<'info>,

    pub token_mint: Account<'info, Mint>,

    pub token_program: Program<'info, Token>,
}

pub fn withdraw_spl_token_tss(
    ctx: Context<WithdrawSplTokenTss>,
    amount: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);

    // instruction_id = 2 for SPL withdraw
    let instruction_id: u8 = 2;
    let mut mint_bytes = [0u8; 32];
    mint_bytes.copy_from_slice(&ctx.accounts.token_mint.key().to_bytes());
    let additional: [&[u8]; 1] = [&mint_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // Note: Recipient ATA must be created off-chain by the client
    // This is standard practice in Solana programs

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    let cpi_accounts = Transfer {
        from: ctx.accounts.token_vault.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.vault.to_account_info(),
    };
    let cpi_program = ctx.accounts.token_program.to_account_info();
    let seeds_array = [seeds];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, &seeds_array);
    token::transfer(cpi_ctx, amount)?;

    // ATA creation is handled off-chain by the client (standard practice)

    emit!(crate::state::WithdrawFunds {
        recipient: ctx.accounts.recipient_token_account.key(),
        amount,
        token: ctx.accounts.token_mint.key(),
    });

    Ok(())
}

// SPL Token withdraw instruction
// Legacy signer-based SPL withdraw removed; use TSS-verified variants below

// =========================
//   TSS REVERT WITHDRAW FUNCTIONS - FIXED WITH REAL TSS
// =========================

/// Revert withdraw for SOL (TSS-verified) - FIXED
#[derive(Accounts)]
pub struct RevertWithdraw<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// CHECK: Recipient address
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn revert_withdraw(
    ctx: Context<RevertWithdraw>,
    amount: u64,
    revert_cfg: RevertSettings,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // instruction_id = 3 for SOL revert withdraw (different from regular withdraw)
    let instruction_id: u8 = 3;
    let recipient_bytes = revert_cfg.fund_recipient.to_bytes();
    let additional: [&[u8]; 1] = [&recipient_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // Transfer SOL from vault to revert recipient
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

/// Revert withdraw for SPL tokens (TSS-verified) - FIXED
#[derive(Accounts)]
pub struct RevertWithdrawSplToken<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    #[account(
        constraint = whitelist.tokens.contains(&token_mint.key()) @ GatewayError::TokenNotWhitelisted
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: SOL-only PDA, no data - FIXED: Added vault account
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Token vault ATA, derived from vault PDA and token mint
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

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
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // instruction_id = 4 for SPL revert withdraw (different from regular SPL withdraw)
    let instruction_id: u8 = 4;
    let mut mint_bytes = [0u8; 32];
    mint_bytes.copy_from_slice(&ctx.accounts.token_mint.key().to_bytes());
    let additional: [&[u8]; 1] = [&mint_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // FIXED: Use vault PDA as authority with correct seeds
    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];

    let cpi_accounts = Transfer {
        from: ctx.accounts.token_vault.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.vault.to_account_info(), // FIXED: vault as authority
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
