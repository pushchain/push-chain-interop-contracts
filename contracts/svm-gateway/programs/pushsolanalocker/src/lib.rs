use anchor_lang::prelude::*;
use anchor_lang::solana_program::{program::invoke, program::invoke_signed, system_instruction};
use pyth_solana_receiver_sdk::price_update::{get_feed_id_from_hex, PriceUpdateV2};

declare_id!("3zrWaMknHTRQpZSxY4BvQxw9TStSXiHcmcp3NMPTFkke");

pub const FEED_ID: &str = "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";
pub const MAXIMUM_AGE: u64 = 6000;

// Private helper function for price calculation
fn calculate_sol_price(price_update: &Account<PriceUpdateV2>) -> Result<PriceData> {
    let price = price_update.get_price_no_older_than(
        &Clock::get()?,
        MAXIMUM_AGE,
        &get_feed_id_from_hex(FEED_ID)?,
    )?;

    require!(price.price > 0, LockerError::InvalidPrice);

    Ok(PriceData {
        price: price.price,
        exponent: price.exponent,
        publish_time: price.publish_time,
        confidence: price.conf,
    })
}

#[program]
pub mod pushsolanalocker {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        let locker = &mut ctx.accounts.locker_data;
        locker.admin = ctx.accounts.admin.key();
        locker.bump = ctx.bumps.locker_data;
        locker.vault_bump = ctx.bumps.vault;

        msg!("Locker initialized by {}", locker.admin);
        Ok(())
    }

    // 1. User adds funds - emits USD amount
    pub fn add_funds(
        ctx: Context<AddFunds>,
        amount: u64,
        transaction_hash: [u8; 32],
    ) -> Result<()> {
        require!(amount > 0, LockerError::NoFundsSent);

        // Get SOL price using helper function
        let price_data = calculate_sol_price(&ctx.accounts.price_update)?;

        // Calculate USD equivalent
        // amount is in lamports (1 SOL = 1e9 lamports)
        let sol_amount_f64 = amount as f64 / 1_000_000_000.0;
        let price_f64 = price_data.price as f64;
        let usd_equivalent = (sol_amount_f64 * price_f64).round() as i128;  // Keep raw number with price's exponent

        // Transfer SOL to vault
        invoke(
            &system_instruction::transfer(ctx.accounts.user.key, &ctx.accounts.vault.key(), amount),
            &[
                ctx.accounts.user.to_account_info(),
                ctx.accounts.vault.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;

        // Emit event with SOL and USD amounts
        emit!(FundsAddedEvent {
            user: ctx.accounts.user.key(),
            sol_amount: amount,
            usd_equivalent,
            usd_exponent: price_data.exponent,
            transaction_hash,
        });

        Ok(())
    }

    // 2. Admin can recover SOL
    pub fn recover_tokens(ctx: Context<RecoverTokens>, amount: u64) -> Result<()> {
        require_keys_eq!(
            ctx.accounts.admin.key(),
            ctx.accounts.locker_data.admin,
            LockerError::Unauthorized
        );

        let seeds: &[&[u8]; 2] = &[b"vault", &[ctx.accounts.locker_data.vault_bump]];

        invoke_signed(
            &system_instruction::transfer(
                ctx.accounts.vault.key,
                ctx.accounts.recipient.key,
                amount,
            ),
            &[
                ctx.accounts.vault.to_account_info(),
                ctx.accounts.recipient.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[seeds],
        )?;

        emit!(TokenRecoveredEvent {
            admin: ctx.accounts.admin.key(),
            amount,
        });

        Ok(())
    }

    // 3. Anyone can fetch SOL price in USD
    pub fn get_sol_price(ctx: Context<GetSolPrice>) -> Result<PriceData> {
        calculate_sol_price(&ctx.accounts.price_update)
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        seeds = [b"locker"],
        bump,
        payer = admin,
        space = 8 + 32 + 1 + 1
    )]
    pub locker_data: Account<'info, Locker>,

    /// CHECK: Native SOL holder, not deserialized
    #[account(
        mut,
        seeds = [b"vault"],
        bump
    )]
    pub vault: UncheckedAccount<'info>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AddFunds<'info> {
    #[account(seeds = [b"locker"], bump = locker.bump)]
    pub locker: Account<'info, Locker>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [b"vault"], bump = locker.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Price update account for getting SOL price
    pub price_update: Account<'info, PriceUpdateV2>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RecoverTokens<'info> {
    pub locker_data: Account<'info, Locker>,

    /// CHECK: vault PDA used only for lamports
    #[account(mut, seeds = [b"vault"], bump = locker_data.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    #[account(mut)]
    pub recipient: Signer<'info>,
    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct GetSolPrice<'info> {
    pub price_update: Account<'info, PriceUpdateV2>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PriceData {
    pub price: i64,            // Raw price from Pyth
    pub exponent: i32,         // Exponent to apply
    pub publish_time: i64,     // When the price was published
    pub confidence: u64,       // Price confidence interval
}

#[account]
pub struct Locker {
    pub admin: Pubkey,
    pub bump: u8,
    pub vault_bump: u8,
}

#[error_code]
pub enum LockerError {
    #[msg("No SOL sent")]
    NoFundsSent,

    #[msg("Unauthorized")]
    Unauthorized,

    #[msg("Invalid price data")]
    InvalidPrice,
}

#[event]
pub struct FundsAddedEvent {
    pub user: Pubkey,
    pub sol_amount: u64,            // Amount in lamports
    pub usd_equivalent: i128,       // USD amount as integer
    pub usd_exponent: i32,          // Exponent, like Pyth (e.g., -6)
    pub transaction_hash: [u8; 32],
}

#[event]
pub struct TokenRecoveredEvent {
    pub admin: Pubkey,
    pub amount: u64,
}
