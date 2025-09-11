use crate::utils::{calculate_sol_price, lamports_to_usd_amount_i128};
use crate::{errors::*, state::*, utils::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{program::invoke, system_instruction};
use pyth_solana_receiver_sdk::price_update::PriceUpdateV2;

/// Legacy event for fee-abstraction route (locker-compatible).
/// Matches `pushsolanalocker` `FundsAddedEvent` exactly for offchain compatibility.
#[event]
pub struct FundsAddedEvent {
    pub user: Pubkey,
    pub sol_amount: u64,
    pub usd_equivalent: i128,
    pub usd_exponent: i32,
    pub transaction_hash: [u8; 32],
}

/// Legacy add_funds accounts (locker-compatible).
#[derive(Accounts)]
pub struct AddFunds<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Pyth price update account (same as locker)
    pub price_update: Account<'info, PriceUpdateV2>,

    pub system_program: Program<'info, System>,
}

/// Legacy add_funds (locker-compatible): accepts native SOL and emits USD value via Pyth.
/// Amount is transferred to vault; emits `FundsAddedEvent`. No swaps.
pub fn add_funds(ctx: Context<AddFunds>, amount: u64, transaction_hash: [u8; 32]) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);

    // Fetch SOL price like locker
    let price_data = calculate_sol_price(&ctx.accounts.price_update)?;
    let usd_equivalent = lamports_to_usd_amount_i128(amount, &price_data);

    // Transfer SOL to vault PDA
    invoke(
        &system_instruction::transfer(ctx.accounts.user.key, &ctx.accounts.vault.key(), amount),
        &[
            ctx.accounts.user.to_account_info(),
            ctx.accounts.vault.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
    )?;

    // Emit legacy-compatible event (same fields as locker)
    emit!(FundsAddedEvent {
        user: ctx.accounts.user.key(),
        sol_amount: amount,
        usd_equivalent,
        usd_exponent: price_data.exponent,
        transaction_hash,
    });

    Ok(())
}
