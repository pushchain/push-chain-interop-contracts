use crate::errors::GatewayError;
use crate::instructions::pc20::{
    is_pc20_burn_account_shape, pc20_burn_tx_type, pc20_prefixed_payload,
    validate_pc20_mint_authority, validate_pc20_state_fields,
};
use crate::state::*;
use crate::utils::*;
use anchor_lang::prelude::*;
use anchor_lang::system_program;
use anchor_spl::associated_token::spl_associated_token_account;
use anchor_spl::token::{self, spl_token, Token, Transfer};
use pyth_solana_receiver_sdk::price_update::PriceUpdateV2;
// =========================
//           DEPOSITS
// =========================

/// @notice Universal entrypoint (EVM parity): routes native/SPL deposits based on `TxType`.
/// @dev    Single entrypoint for all deposit types with internal routing mechanism.
///         `native_amount` mirrors `msg.value` on EVM chains - represents total native SOL sent.
///         Routes to GAS (instant) or FUNDS (standard) handlers based on derived tx type.
pub fn send_universal_tx<'info>(
    mut ctx: Context<'_, '_, '_, 'info, SendUniversalTx<'info>>,
    req: UniversalTxRequest,
    native_amount: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);
    require!(
        ctx.accounts.user.lamports() >= native_amount,
        GatewayError::InsufficientBalance
    );

    // Collect inbound fee first so all downstream routing sees post-fee native amount.
    let adjusted_native_amount = collect_inbound_fee(&mut ctx, native_amount)?;

    if is_pc20_burn_account_shape(ctx.program_id, ctx.remaining_accounts, req.token) {
        return route_pc20_universal_tx(&mut ctx, req, adjusted_native_amount);
    }

    let tx_type = fetch_tx_type(&req, adjusted_native_amount)?;
    let mut prc20_req = req;
    prc20_req.payload = prc20_prefixed_payload(&prc20_req.payload);
    route_universal_tx(&mut ctx, prc20_req, adjusted_native_amount, tx_type)
}

fn collect_inbound_fee(ctx: &mut Context<SendUniversalTx>, native_amount: u64) -> Result<u64> {
    let fee_lamports = ctx.accounts.fee_vault.inbound_fee_lamports;
    if fee_lamports == 0 {
        return Ok(native_amount);
    }

    require!(
        native_amount >= fee_lamports,
        GatewayError::InsufficientInboundFee
    );

    // Transfer fee from user → fee_vault (keeps bridge vault strictly 1:1 backed)
    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.user.to_account_info(),
            to: ctx.accounts.fee_vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, fee_lamports)?;

    let adjusted_native_amount = native_amount - fee_lamports;

    emit!(InboundFeeCollected {
        payer: ctx.accounts.user.key(),
        amount_lamports: fee_lamports,
        native_amount_before: native_amount,
        native_amount_after: adjusted_native_amount,
    });

    Ok(adjusted_native_amount)
}

/// @notice Internal router: dispatches to GAS or FUNDS handlers based on derived tx_type.
/// @dev    Route 1: GAS | GAS_AND_PAYLOAD → Instant route (fee abstraction)
///         Route 2: FUNDS | FUNDS_AND_PAYLOAD → Standard route (bridge deposits)
/// @dev    GAS routes require req.amount == 0 (funds leg disabled). native_amount represents gas.
///         FUNDS routes require req.amount > 0 (funds leg enabled); native_amount may batch gas.
fn route_universal_tx(
    ctx: &mut Context<SendUniversalTx>,
    req: UniversalTxRequest,
    native_amount: u64,
    tx_type: TxType,
) -> Result<()> {
    match tx_type {
        TxType::Gas | TxType::GasAndPayload => send_tx_with_gas_route(
            ctx,
            tx_type,
            native_amount,
            &req.payload,
            &req.revert_recipient,
            &req.signature_data,
        ),
        TxType::Funds | TxType::FundsAndPayload => {
            send_tx_with_funds_route(ctx, req, native_amount, tx_type)
        }
    }
}

fn route_pc20_universal_tx<'info>(
    ctx: &mut Context<'_, '_, '_, 'info, SendUniversalTx<'info>>,
    req: UniversalTxRequest,
    adjusted_native_amount: u64,
) -> Result<()> {
    let tx_type = pc20_burn_tx_type(req.amount)?;
    require!(req.token != Pubkey::default(), GatewayError::InvalidMint);
    require!(req.recipient != [0u8; 20], GatewayError::InvalidRecipient);
    require!(
        req.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.gateway_token_account.is_none(),
        GatewayError::InvalidAccount
    );

    require!(
        ctx.remaining_accounts.len() == 2,
        GatewayError::AccountListLengthMismatch
    );
    let pc20_state = ctx.remaining_accounts[0].clone();
    let pc20_mint = ctx.remaining_accounts[1].clone();

    require!(pc20_mint.key() == req.token, GatewayError::InvalidMint);
    require!(
        pc20_state.owner == ctx.program_id,
        GatewayError::InvalidAccount
    );
    require!(
        !pc20_state.is_signer && !pc20_mint.is_signer,
        GatewayError::UnexpectedOuterSigner
    );
    require!(
        pc20_mint.is_writable,
        GatewayError::AccountWritableFlagMismatch
    );

    let state = Pc20State::try_deserialize(&mut &pc20_state.try_borrow_data()?[..])?;
    let _source_asset =
        validate_pc20_state_fields(ctx.program_id, pc20_state.key, &state, req.token)?;
    validate_pc20_mint_authority(&pc20_mint, req.token)?;

    let user_ata = ctx
        .accounts
        .user_token_account
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let parsed_user = parse_token_account(&user_ata.to_account_info())?;
    require!(
        parsed_user.owner == ctx.accounts.user.key(),
        GatewayError::InvalidOwner
    );
    require!(parsed_user.mint == req.token, GatewayError::InvalidMint);

    spl_burn(
        &pc20_mint,
        &user_ata.to_account_info(),
        &ctx.accounts.user.to_account_info(),
        req.amount,
    )?;

    let prefixed_payload = pc20_prefixed_payload(&req.payload);
    emit!(UniversalTx {
        sender: ctx.accounts.user.key(),
        recipient: req.recipient,
        token: req.token,
        amount: req.amount,
        payload: prefixed_payload,
        revert_recipient: req.revert_recipient,
        tx_type,
        signature_data: req.signature_data.clone(),
        from_cea: false,
    });

    if adjusted_native_amount > 0 {
        let native_req = UniversalTxRequest {
            recipient: req.recipient,
            token: Pubkey::default(),
            amount: adjusted_native_amount,
            payload: Vec::new(),
            revert_recipient: req.revert_recipient,
            signature_data: req.signature_data,
        };
        send_tx_with_funds_route(ctx, native_req, adjusted_native_amount, TxType::Funds)?;
    }

    Ok(())
}

fn prc20_prefixed_payload(payload: &[u8]) -> Vec<u8> {
    let mut prefixed = Vec::with_capacity(PRC20_SELECTOR.len() + payload.len());
    prefixed.extend_from_slice(&PRC20_SELECTOR);
    prefixed.extend_from_slice(payload);
    prefixed
}

fn fetch_tx_type(req: &UniversalTxRequest, native_amount: u64) -> Result<TxType> {
    let has_payload = !req.payload.is_empty();
    let has_funds = req.amount > 0;
    let funds_is_native = req.token == Pubkey::default();
    let has_native_value = native_amount > 0;

    if !has_funds {
        if has_payload {
            return Ok(TxType::GasAndPayload);
        }
        require!(has_native_value, GatewayError::InvalidInput);
        return Ok(TxType::Gas);
    }

    if has_payload {
        if funds_is_native {
            require!(native_amount >= req.amount, GatewayError::InvalidAmount);
        }

        return Ok(TxType::FundsAndPayload);
    }

    // FUNDS with no payload
    if funds_is_native {
        require!(native_amount == req.amount, GatewayError::InvalidAmount);
    } else {
        require!(!has_native_value, GatewayError::InvalidAmount);
    }

    Ok(TxType::Funds)
}

/// @notice Internal helper function to deposit for Instant TX (GAS route).
/// @dev    Handles rate-limit checks for Fee Abstraction Tx Route.
///         - Validates revert instruction recipient
///         - Supports payload-only execution (gas_amount == 0) for EVM V0 parity
///         - Enforces USD caps ($1-$10) and block-based USD cap via Pyth oracle
///         - Transfers native SOL to vault (recipient as Pubkey::default() → UEA)
fn send_tx_with_gas_route(
    ctx: &mut Context<SendUniversalTx>,
    tx_type: TxType,
    gas_amount: u64,
    payload: &[u8],
    revert_recipient: &Pubkey,
    signature_data: &[u8],
) -> Result<()> {
    // Validate tx_type
    require!(
        matches!(tx_type, TxType::Gas | TxType::GasAndPayload),
        GatewayError::InvalidTxType
    );

    require!(
        *revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // Payload-only execution (gas_amount == 0) - EVM V0 parity
    // User already has UEA with gas on Push Chain, just execute payload
    if gas_amount == 0 {
        require!(
            tx_type == TxType::GasAndPayload,
            GatewayError::InvalidAmount
        );

        emit!(UniversalTx {
            sender: ctx.accounts.user.key(),
            recipient: [0u8; 20],
            token: Pubkey::default(),
            amount: 0,
            payload: payload.to_vec(),
            revert_recipient: *revert_recipient,
            tx_type,
            signature_data: signature_data.to_vec(),
            from_cea: false,
        });

        return Ok(());
    }

    // Performs rate-limit checks and handle deposit
    // USD caps: min $1, max $10 (enforced via Pyth oracle)
    let usd_amount = check_usd_caps(&ctx.accounts.config, gas_amount, &ctx.accounts.price_update)?;
    // Block-based USD cap: per-slot limit (disabled if block_usd_cap == 0)
    check_block_usd_cap(&mut ctx.accounts.rate_limit_config, usd_amount)?;

    // Transfer native SOL to vault (like _handleNativeDeposit in ETH)
    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.user.to_account_info(),
            to: ctx.accounts.vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, gas_amount)?;

    // Emit UniversalTx event (recipient as Pubkey::default() → UEA)
    emit!(UniversalTx {
        sender: ctx.accounts.user.key(),
        recipient: [0u8; 20],
        token: Pubkey::default(),
        amount: gas_amount,
        payload: payload.to_vec(),
        revert_recipient: *revert_recipient,
        tx_type,
        signature_data: signature_data.to_vec(),
        from_cea: false,
    });

    Ok(())
}

/// Dispatcher for FUNDS / FUNDS_AND_PAYLOAD routes.
/// Branches on asset type first, then delegates behavior differences to each handler.
fn send_tx_with_funds_route(
    ctx: &mut Context<SendUniversalTx>,
    req: UniversalTxRequest,
    native_amount: u64,
    tx_type: TxType,
) -> Result<()> {
    require!(
        req.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(req.amount > 0, GatewayError::InvalidAmount);

    if req.token == Pubkey::default() {
        handle_native_funds_route(ctx, &req, native_amount, tx_type)?;
    } else {
        handle_spl_funds_route(ctx, &req, native_amount, tx_type)?;
    }

    emit_funds_route_event(ctx, req, tx_type);
    Ok(())
}

/// Native SOL path for FUNDS and FUNDS_AND_PAYLOAD.
/// FUNDS:           native_amount must equal req.amount exactly.
/// FUNDS_AND_PAYLOAD: native_amount >= req.amount; excess becomes a gas leg.
fn handle_native_funds_route(
    ctx: &mut Context<SendUniversalTx>,
    req: &UniversalTxRequest,
    native_amount: u64,
    tx_type: TxType,
) -> Result<()> {
    require!(native_amount >= req.amount, GatewayError::InvalidAmount);
    if tx_type == TxType::Funds {
        require!(native_amount == req.amount, GatewayError::InvalidAmount);
    }

    let gas_amount = native_amount.saturating_sub(req.amount);
    if gas_amount > 0 {
        send_tx_with_gas_route(
            ctx,
            TxType::Gas,
            gas_amount,
            &[],
            &req.revert_recipient,
            &req.signature_data,
        )?;
    }

    validate_token_and_consume_rate_limit(
        &mut ctx.accounts.token_rate_limit,
        Pubkey::default(),
        req.amount as u128,
        &ctx.accounts.rate_limit_config,
    )?;
    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.user.to_account_info(),
            to: ctx.accounts.vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, req.amount)
}

/// SPL token path for FUNDS and FUNDS_AND_PAYLOAD.
/// FUNDS:           native_amount must be zero (no gas batching).
/// FUNDS_AND_PAYLOAD: native_amount is optional gas top-up.
fn handle_spl_funds_route(
    ctx: &mut Context<SendUniversalTx>,
    req: &UniversalTxRequest,
    native_amount: u64,
    tx_type: TxType,
) -> Result<()> {
    if tx_type == TxType::Funds {
        require!(native_amount == 0, GatewayError::InvalidAmount);
    } else if native_amount > 0 {
        send_tx_with_gas_route(
            ctx,
            TxType::Gas,
            native_amount,
            &[],
            &req.revert_recipient,
            &req.signature_data,
        )?;
    }

    validate_token_and_consume_rate_limit(
        &mut ctx.accounts.token_rate_limit,
        req.token,
        req.amount as u128,
        &ctx.accounts.rate_limit_config,
    )?;
    deposit_spl_to_vault(ctx, req.token, req.amount)
}

/// Emit the UniversalTx event for FUNDS / FUNDS_AND_PAYLOAD routes.
/// FUNDS carries the user-specified recipient; FUNDS_AND_PAYLOAD targets UEA (zero address).
fn emit_funds_route_event(
    ctx: &Context<SendUniversalTx>,
    req: UniversalTxRequest,
    tx_type: TxType,
) {
    let recipient = if tx_type == TxType::Funds {
        req.recipient
    } else {
        [0u8; 20]
    };
    emit!(UniversalTx {
        sender: ctx.accounts.user.key(),
        recipient,
        token: req.token,
        amount: req.amount,
        payload: req.payload,
        revert_recipient: req.revert_recipient,
        tx_type,
        signature_data: req.signature_data,
        from_cea: false,
    });
}

/// Transfer SPL tokens from user's token account to the vault's ATA.
/// SECURITY: validates vault ownership and mint before transferring.
fn deposit_spl_to_vault(ctx: &Context<SendUniversalTx>, token: Pubkey, amount: u64) -> Result<()> {
    let user_token_account = ctx
        .accounts
        .user_token_account
        .as_ref()
        .ok_or_else(|| error!(GatewayError::InvalidAccount))?;
    let gateway_token_account = ctx
        .accounts
        .gateway_token_account
        .as_ref()
        .ok_or_else(|| error!(GatewayError::InvalidAccount))?;

    let user_token_info = user_token_account.to_account_info();
    require!(
        user_token_info.owner == &spl_token::ID,
        GatewayError::InvalidOwner
    );

    // Validate source: authority must be the signer, mint must match requested token.
    // Without this, a malicious user could pass someone else's token account.
    let parsed_user = parse_token_account(&user_token_info)?;
    require!(
        parsed_user.owner == ctx.accounts.user.key(),
        GatewayError::InvalidOwner
    );
    require!(parsed_user.mint == token, GatewayError::InvalidMint);

    // SECURITY: Validate gateway_token_account is the vault's ATA for this token.
    // This prevents users from providing their own token account and stealing funds.
    let parsed = parse_token_account(&gateway_token_account.to_account_info())?;
    require!(
        parsed.owner == ctx.accounts.vault.key(),
        GatewayError::InvalidOwner
    );
    require!(parsed.mint == token, GatewayError::InvalidMint);
    let expected_gateway_ata = spl_associated_token_account::get_associated_token_address(
        &ctx.accounts.vault.key(),
        &token,
    );
    require!(
        gateway_token_account.key() == expected_gateway_ata,
        GatewayError::InvalidAccount
    );

    let cpi_ctx = CpiContext::new(
        ctx.accounts.token_program.to_account_info(),
        Transfer {
            from: user_token_info,
            to: gateway_token_account.to_account_info(),
            authority: ctx.accounts.user.to_account_info(),
        },
    );
    token::transfer(cpi_ctx, amount)
}

// =========================
//        ACCOUNT STRUCTS
// =========================

#[derive(Accounts)]
pub struct SendUniversalTx<'info> {
    #[account(
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

    /// Fee vault: receives the flat protocol fee per inbound tx.
    /// Separate from bridge vault to preserve the 1:1 bridge invariant.
    #[account(
        mut,
        seeds = [FEE_VAULT_SEED],
        bump = fee_vault.bump,
    )]
    pub fee_vault: Account<'info, FeeVault>,

    /// Only required for SPL token routes; can be omitted (pass null) on native SOL routes.
    #[account(mut)]
    pub user_token_account: Option<UncheckedAccount<'info>>,

    /// Only required for SPL token routes; can be omitted (pass null) on native SOL routes.
    #[account(mut)]
    pub gateway_token_account: Option<UncheckedAccount<'info>>,

    #[account(mut)]
    pub user: Signer<'info>,

    #[account(constraint = price_update.key() == config.pyth_price_feed @ GatewayError::InvalidAccount)]
    pub price_update: Account<'info, PriceUpdateV2>,

    /// Rate limit config - REQUIRED for universal entrypoint
    #[account(
        mut,
        seeds = [RATE_LIMIT_CONFIG_SEED],
        bump,
    )]
    pub rate_limit_config: Account<'info, RateLimitConfig>,

    /// Token rate limit - REQUIRED for universal entrypoint
    /// NOTE: For native SOL, use Pubkey::default() as the token_mint when deriving this PDA
    #[account(mut)]
    pub token_rate_limit: Account<'info, TokenRateLimit>,

    pub token_program: Program<'info, Token>,

    pub system_program: Program<'info, System>,
}
