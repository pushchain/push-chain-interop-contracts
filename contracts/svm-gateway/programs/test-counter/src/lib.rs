use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{self, Token, TokenAccount};

declare_id!("4mpHkerNsaJPp35fyT5bkoXxuEBczGq6HUKTtrzFcptx");

#[program]
pub mod test_counter {
    use super::*;

    /// Initialize a counter account
    pub fn initialize(ctx: Context<Initialize>, initial_value: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        counter.value = initial_value;
        counter.authority = ctx.accounts.authority.key();
        msg!("Counter initialized with value: {}", initial_value);
        Ok(())
    }

    /// Increment counter (can be called via CPI from gateway)
    pub fn increment(ctx: Context<UpdateCounter>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;
        msg!(
            "Counter incremented by {}, new value: {}",
            amount,
            counter.value
        );

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_sub(amount),
            new_value: counter.value,
            operation: "increment".to_string(),
        });

        Ok(())
    }

    /// Decrement counter (can be called via CPI from gateway)
    pub fn decrement(ctx: Context<UpdateCounter>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        counter.value = counter
            .value
            .checked_sub(amount)
            .ok_or(CounterError::Underflow)?;
        msg!(
            "Counter decremented by {}, new value: {}",
            amount,
            counter.value
        );

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_add(amount),
            new_value: counter.value,
            operation: "decrement".to_string(),
        });

        Ok(())
    }

    /// Stake SOL - transfers SOL from authority (CEA) to stake_vault PDA
    /// This tests CEA identity preservation (same authority = same stake PDA)
    /// CEA is signed by gateway via invoke_signed with cea_seeds
    pub fn stake_sol(ctx: Context<StakeSol>, amount: u64) -> Result<()> {
        // Transfer SOL from authority (CEA) to stake_vault PDA
        // CEA is a signer (signed by gateway via cea_seeds in invoke_signed)
        anchor_lang::solana_program::program::invoke(
            &anchor_lang::solana_program::system_instruction::transfer(
                ctx.accounts.authority.key,
                ctx.accounts.stake_vault.key,
                amount,
            ),
            &[
                ctx.accounts.authority.to_account_info(),
                ctx.accounts.stake_vault.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;

        // Now update stake account (after transfer completes)
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;
        stake.authority = ctx.accounts.authority.key();
        stake.amount = stake
            .amount
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!("Staked {} SOL, total stake: {}", amount, stake.amount);
        Ok(())
    }

    /// Unstake SOL - transfers SOL from stake_vault PDA back to authority (CEA)
    pub fn unstake_sol(ctx: Context<UnstakeSol>, amount: u64) -> Result<()> {
        // Check stake amount first (before any borrows)
        require!(
            ctx.accounts.stake.amount >= amount,
            CounterError::InsufficientStake
        );

        // Transfer SOL from stake_vault PDA back to authority (CEA)
        let stake_vault_bump = ctx.bumps.stake_vault;
        let authority_key = ctx.accounts.authority.key();
        let stake_vault_seeds: &[&[u8]] =
            &[b"stake_vault", authority_key.as_ref(), &[stake_vault_bump]];

        anchor_lang::solana_program::program::invoke_signed(
            &anchor_lang::solana_program::system_instruction::transfer(
                ctx.accounts.stake_vault.key,
                ctx.accounts.authority.key,
                amount,
            ),
            &[
                ctx.accounts.stake_vault.to_account_info(),
                ctx.accounts.authority.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[stake_vault_seeds],
        )?;

        // Decrement stake tracking (after transfer completes)
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;
        stake.amount = stake
            .amount
            .checked_sub(amount)
            .ok_or(CounterError::Underflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!("Unstaked {} SOL, remaining stake: {}", amount, stake.amount);
        Ok(())
    }

    /// Receive SOL and increment counter (for non-CEA tests)
    pub fn receive_sol(ctx: Context<ReceiveSol>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Transfer SOL from cea_authority to recipient
        anchor_lang::solana_program::program::invoke(
            &anchor_lang::solana_program::system_instruction::transfer(
                ctx.accounts.cea_authority.key,
                ctx.accounts.recipient.key,
                amount,
            ),
            &[
                ctx.accounts.cea_authority.to_account_info(),
                ctx.accounts.recipient.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;

        // Increment counter by amount received
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Received {} lamports, counter incremented to: {}",
            amount,
            counter.value
        );
        Ok(())
    }

    /// Stake SPL tokens - transfers tokens from authority ATA to stake ATA
    /// CEA is signed by gateway via invoke_signed with cea_seeds
    pub fn stake_spl(ctx: Context<StakeSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;

        // Transfer tokens from authority_ata to stake_ata
        // CEA (authority) is a signer (signed by gateway via cea_seeds in invoke_signed)
        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.authority_ata.to_account_info(),
                    to: ctx.accounts.stake_ata.to_account_info(),
                    authority: ctx.accounts.authority.to_account_info(),
                },
            ),
            amount,
        )?;

        // Initialize or update stake account
        stake.authority = ctx.accounts.authority.key();
        stake.amount = stake
            .amount
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Staked {} SPL tokens, total stake: {}",
            amount,
            stake.amount
        );
        Ok(())
    }

    /// Unstake SPL tokens - transfers tokens from stake ATA back to authority ATA
    pub fn unstake_spl(ctx: Context<UnstakeSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Check stake amount first (before any borrows)
        require!(
            ctx.accounts.stake.amount >= amount,
            CounterError::InsufficientStake
        );

        // Transfer tokens from stake_ata back to authority_ata
        let stake_bump = ctx.bumps.stake;
        let authority_key = ctx.accounts.authority.key();
        let stake_seeds: &[&[u8]] = &[b"stake", authority_key.as_ref(), &[stake_bump]];

        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.stake_ata.to_account_info(),
                    to: ctx.accounts.authority_ata.to_account_info(),
                    authority: ctx.accounts.stake.to_account_info(),
                },
                &[stake_seeds],
            ),
            amount,
        )?;

        // Decrement stake tracking (after transfer completes)
        let stake = &mut ctx.accounts.stake;
        stake.amount = stake
            .amount
            .checked_sub(amount)
            .ok_or(CounterError::Underflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Unstaked {} SPL tokens, remaining stake: {}",
            amount,
            stake.amount
        );
        Ok(())
    }

    /// Receive SPL tokens and increment counter (for non-CEA tests)
    pub fn receive_spl(ctx: Context<ReceiveSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Transfer tokens from cea_ata to recipient_ata
        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.cea_ata.to_account_info(),
                    to: ctx.accounts.recipient_ata.to_account_info(),
                    authority: ctx.accounts.cea_authority.to_account_info(),
                },
            ),
            amount,
        )?;

        // Increment counter by amount received
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Received {} tokens, counter incremented to: {}",
            amount,
            counter.value
        );
        Ok(())
    }

    /// Heavy batch operation - simulates complex DeFi operation with many accounts and large data
    /// This function is designed to test transaction size limits
    /// Takes many accounts (10-15) and large instruction data (200-400 bytes)
    /// Does minimal computation (just increments counter) to focus on size testing
    pub fn batch_operation(
        ctx: Context<BatchOperation>,
        operation_id: u64,
        data: Vec<u8>,
    ) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Validate data size (should be large for testing)
        require!(data.len() >= 50, CounterError::InvalidDataSize);

        // Process remaining accounts (simulate checking/validating many accounts)
        // In real DeFi, this would validate token accounts, PDAs, etc.
        let account_count = ctx.remaining_accounts.len();
        msg!(
            "Batch operation {} with {} accounts and {} bytes of data",
            operation_id,
            account_count,
            data.len()
        );

        // Minimal computation - just increment counter by operation_id
        // This keeps compute units low while testing transaction size
        counter.value = counter
            .value
            .checked_add(operation_id)
            .ok_or(CounterError::Overflow)?;

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_sub(operation_id),
            new_value: counter.value,
            operation: format!("batch_operation_{}", operation_id),
        });

        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = 8 + Counter::LEN,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    #[account(mut)]
    pub authority: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateCounter<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump,
        has_one = authority @ CounterError::Unauthorized,
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Can be cea_authority from gateway or any other signer
    pub authority: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct StakeSol<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway) - signed by gateway via cea_seeds
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + Stake::LEN,
        seeds = [b"stake", authority.key().as_ref()],
        bump
    )]
    pub stake: Account<'info, Stake>,

    /// Stake vault PDA - holds staked SOL (SystemAccount, no data)
    /// Initialized manually if needed (SystemAccount with space=0 can't use init_if_needed)
    #[account(
        mut,
        seeds = [b"stake_vault", authority.key().as_ref()],
        bump
    )]
    pub stake_vault: SystemAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UnstakeSol<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway) - signed by gateway via cea_seeds
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(
        mut,
        seeds = [b"stake", authority.key().as_ref()],
        bump,
        has_one = authority @ CounterError::Unauthorized
    )]
    pub stake: Account<'info, Stake>,

    /// Stake vault PDA - holds staked SOL (SystemAccount, no data)
    /// Initialized manually if needed (SystemAccount with space=0 can't use init_if_needed)
    #[account(
        mut,
        seeds = [b"stake_vault", authority.key().as_ref()],
        bump
    )]
    pub stake_vault: SystemAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct StakeSpl<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway) - signed by gateway via cea_seeds
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + Stake::LEN,
        seeds = [b"stake", authority.key().as_ref()],
        bump
    )]
    pub stake: Account<'info, Stake>,

    pub mint: Account<'info, anchor_spl::token::Mint>,

    #[account(mut)]
    pub authority_ata: Account<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = authority,
        associated_token::mint = mint,
        associated_token::authority = stake
    )]
    pub stake_ata: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

#[derive(Accounts)]
pub struct UnstakeSpl<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway)
    pub authority: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [b"stake", authority.key().as_ref()],
        bump,
        has_one = authority @ CounterError::Unauthorized
    )]
    pub stake: Account<'info, Stake>,

    pub mint: Account<'info, anchor_spl::token::Mint>,

    #[account(mut)]
    pub authority_ata: Account<'info, TokenAccount>,

    #[account(mut)]
    pub stake_ata: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ReceiveSol<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Recipient account that will receive SOL
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    /// CHECK: CEA authority from gateway (will have SOL, signs via invoke_signed)
    #[account(mut)]
    pub cea_authority: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ReceiveSpl<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: CEA ATA from gateway (will have tokens)
    #[account(mut)]
    pub cea_ata: Account<'info, TokenAccount>,

    /// CHECK: Recipient ATA (will receive tokens)
    #[account(mut)]
    pub recipient_ata: Account<'info, TokenAccount>,

    /// CHECK: CEA authority from gateway (signs for cea_ata)
    pub cea_authority: Signer<'info>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct BatchOperation<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway)
    pub authority: UncheckedAccount<'info>,
}

#[account]
pub struct Counter {
    pub value: u64,
    pub authority: Pubkey,
}

impl Counter {
    pub const LEN: usize = 8 + 8 + 32; // discriminator + u64 + Pubkey
}

#[account]
pub struct Stake {
    pub authority: Pubkey,
    pub amount: u64,
}

impl Stake {
    pub const LEN: usize = 32 + 8; // Pubkey + u64
}

#[event]
pub struct CounterUpdated {
    pub counter: Pubkey,
    pub old_value: u64,
    pub new_value: u64,
    pub operation: String,
}

#[error_code]
pub enum CounterError {
    #[msg("Counter overflow")]
    Overflow,
    #[msg("Counter underflow")]
    Underflow,
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Insufficient stake")]
    InsufficientStake,
    #[msg("Invalid data size")]
    InvalidDataSize,
}
