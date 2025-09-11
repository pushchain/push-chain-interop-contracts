use crate::errors::GatewayError;
use crate::state::*;
use crate::utils::*;
use anchor_lang::prelude::*;
use anchor_lang::system_program;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};
use pyth_solana_receiver_sdk::price_update::PriceUpdateV2;

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
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // Use the amount parameter (equivalent to msg.value in ETH)
    let gas_amount = amount;
    require!(gas_amount > 0, GatewayError::InvalidAmount);

    // Check user has enough SOL
    require!(
        ctx.accounts.user.lamports() >= gas_amount,
        GatewayError::InsufficientBalance
    );

    // Check USD caps for gas deposits using Pyth oracle
    check_usd_caps(config, gas_amount, &ctx.accounts.price_update)?;

    // Transfer SOL to vault (like _handleNativeDeposit in ETH)
    let cpi_context = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: user.to_account_info(),
            to: vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_context, gas_amount)?;

    // Calculate payload hash
    let _payload_hash = payload_hash(&payload);

    // Emit TxWithGas event (exactly like ETH contract)
    emit!(TxWithGas {
        sender: user.key(),
        payload_hash: _payload_hash,
        native_token_deposited: gas_amount,
        revert_cfg,
        tx_type: TxType::GasAndPayload,
    });

    Ok(())
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
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(
        recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(bridge_amount > 0, GatewayError::InvalidAmount);

    // This function only handles SPL tokens, use send_funds_native for SOL
    require!(
        bridge_token != Pubkey::default(),
        GatewayError::InvalidToken
    );

    // Check if token is whitelisted
    let token_whitelist = &ctx.accounts.token_whitelist;
    require!(
        token_whitelist.tokens.contains(&bridge_token),
        GatewayError::TokenNotWhitelisted
    );

    // Transfer SPL tokens to gateway vault
    let cpi_context = CpiContext::new(
        ctx.accounts.token_program.to_account_info(),
        Transfer {
            from: ctx.accounts.user_token_account.to_account_info(),
            to: ctx.accounts.gateway_token_account.to_account_info(),
            authority: user.to_account_info(),
        },
    );
    token::transfer(cpi_context, bridge_amount)?;

    // Emit TxWithFunds event for SPL token
    emit!(TxWithFunds {
        sender: user.key(),
        recipient,
        bridge_amount,
        gas_amount: 0,
        bridge_token,
        data: vec![],
        revert_cfg,
        tx_type: TxType::Funds,
    });

    Ok(())
}

/// @notice Allows initiating a TX for movement of native SOL from source chain to Push Chain.
/// @dev    The route emits TxWithFunds event.
pub fn send_funds_native(
    ctx: Context<SendFundsNative>,
    recipient: Pubkey,
    bridge_amount: u64,
    revert_cfg: RevertSettings,
) -> Result<()> {
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(
        recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(bridge_amount > 0, GatewayError::InvalidAmount);

    // Check user has enough SOL
    require!(
        user.lamports() >= bridge_amount,
        GatewayError::InsufficientBalance
    );

    // Transfer SOL to vault
    let cpi_context = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: user.to_account_info(),
            to: vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_context, bridge_amount)?;

    // Emit TxWithFunds event for native SOL
    emit!(TxWithFunds {
        sender: user.key(),
        recipient,
        bridge_amount,
        gas_amount: 0,
        bridge_token: Pubkey::default(), // Native SOL
        data: vec![],
        revert_cfg,
        tx_type: TxType::Funds,
    });

    Ok(())
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
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(bridge_amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_cfg.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    require!(gas_amount > 0, GatewayError::InvalidAmount);

    // Check USD caps for gas deposits using Pyth oracle
    check_usd_caps(config, gas_amount, &ctx.accounts.price_update)?;

    // Handle gas deposit (native SOL)
    let cpi_context = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: user.to_account_info(),
            to: vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_context, gas_amount)?;

    // Emit TxWithGas event for gas funding
    emit!(TxWithGas {
        sender: user.key(),
        payload_hash: [0u8; 32], // Empty payload hash for gas-only
        native_token_deposited: gas_amount,
        revert_cfg: RevertSettings {
            fund_recipient: user.key(),
            revert_msg: b"Gas funding".to_vec(),
        },
        tx_type: TxType::Gas,
    });

    // Handle bridge deposit
    if bridge_token == Pubkey::default() {
        // Native SOL bridge
        require!(
            ctx.accounts.user.lamports() >= bridge_amount + gas_amount,
            GatewayError::InsufficientBalance
        );

        let cpi_context = CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            system_program::Transfer {
                from: user.to_account_info(),
                to: vault.to_account_info(),
            },
        );
        system_program::transfer(cpi_context, bridge_amount)?;
    } else {
        // SPL token bridge
        require!(
            ctx.accounts.user.lamports() >= gas_amount,
            GatewayError::InsufficientBalance
        );

        // Check if token is whitelisted
        let token_whitelist = &ctx.accounts.token_whitelist;
        require!(
            token_whitelist.tokens.contains(&bridge_token),
            GatewayError::TokenNotWhitelisted
        );

        // Transfer SPL tokens to gateway vault
        let cpi_context = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.user_token_account.to_account_info(),
                to: ctx.accounts.gateway_token_account.to_account_info(),
                authority: user.to_account_info(),
            },
        );
        token::transfer(cpi_context, bridge_amount)?;
    }

    // Calculate payload hash
    let _payload_hash = payload_hash(&payload);

    // Emit TxWithFunds event for bridge + payload
    emit!(TxWithFunds {
        sender: user.key(),
        recipient: Pubkey::default(), // address(0) for moving funds + payload for execution
        bridge_amount,
        gas_amount,
        bridge_token,
        data: payload_to_bytes(&payload),
        revert_cfg,
        tx_type: TxType::FundsAndPayload,
    });

    Ok(())
}

// =========================
//        ACCOUNT STRUCTS
// =========================

#[derive(Accounts)]
pub struct SendTxWithGas<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Pyth price update account for USD cap validation
    pub price_update: Account<'info, PriceUpdateV2>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SendFundsNative<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SendFunds<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(
        seeds = [WHITELIST_SEED],
        bump,
    )]
    pub token_whitelist: Account<'info, TokenWhitelist>,

    #[account(
        mut,
        constraint = user_token_account.owner == user.key() @ GatewayError::InvalidOwner,
        constraint = user_token_account.mint == bridge_token.key() @ GatewayError::InvalidMint,
    )]
    pub user_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = gateway_token_account.owner == vault.key() @ GatewayError::InvalidOwner,
        constraint = gateway_token_account.mint == bridge_token.key() @ GatewayError::InvalidMint,
    )]
    pub gateway_token_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Note: No price_update needed for SPL-only functions (no USD caps)
    pub bridge_token: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SendTxWithFunds<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(
        seeds = [WHITELIST_SEED],
        bump,
    )]
    pub token_whitelist: Account<'info, TokenWhitelist>,

    #[account(
        mut,
        constraint = user_token_account.owner == user.key() @ GatewayError::InvalidOwner,
        constraint = user_token_account.mint == bridge_token.key() @ GatewayError::InvalidMint,
    )]
    pub user_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = gateway_token_account.owner == vault.key() @ GatewayError::InvalidOwner,
        constraint = gateway_token_account.mint == bridge_token.key() @ GatewayError::InvalidMint,
    )]
    pub gateway_token_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Pyth price update account for USD cap validation
    pub price_update: Account<'info, PriceUpdateV2>,

    pub bridge_token: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}
