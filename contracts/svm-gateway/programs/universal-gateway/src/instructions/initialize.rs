use crate::state::*;
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        seeds = [CONFIG_SEED],
        bump,
        payer = admin,
        space = Config::LEN
    )]
    pub config: Account<'info, Config>,

    /// CHECK: Native SOL holder, not deserialized
    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump
    )]
    pub vault: UncheckedAccount<'info>,

    pub program: Program<'info, crate::program::UniversalGateway>,

    #[account(
        constraint = program.programdata_address()? == Some(program_data.key())
            @ crate::errors::GatewayError::Unauthorized
    )]
    pub program_data: Account<'info, ProgramData>,

    #[account(
        mut,
        constraint = program_data.upgrade_authority_address == Some(admin.key())
            @ crate::errors::GatewayError::Unauthorized
    )]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn initialize(
    ctx: Context<Initialize>,
    admin: Pubkey,
    pauser: Pubkey,
    tss: Pubkey,
    min_cap_usd: u128,
    max_cap_usd: u128,
    pyth_price_feed: Pubkey,
) -> Result<()> {
    require!(
        min_cap_usd <= max_cap_usd,
        crate::errors::GatewayError::InvalidCapRange
    );
    require!(
        admin != Pubkey::default(),
        crate::errors::GatewayError::ZeroAddress
    );
    require!(
        tss != Pubkey::default(),
        crate::errors::GatewayError::ZeroAddress
    );
    require!(
        pyth_price_feed != Pubkey::default(),
        crate::errors::GatewayError::ZeroAddress
    );

    let config = &mut ctx.accounts.config;
    config.admin = admin;
    config.pauser = pauser;
    config.tss_address = tss;
    config.min_cap_universal_tx_usd = min_cap_usd;
    config.max_cap_universal_tx_usd = max_cap_usd;
    config.paused = false;
    config.bump = ctx.bumps.config;
    config.vault_bump = ctx.bumps.vault;
    config.pyth_price_feed = pyth_price_feed;
    config.pyth_confidence_threshold = 1000000; // Default confidence threshold (1e6)
    config.pyth_max_age_seconds = 60; // Default staleness window (60 seconds)

    msg!("Gateway initialized with admin: {}, TSS: {}", admin, tss);
    Ok(())
}
