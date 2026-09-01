use crate::errors::GatewayError;
use crate::instructions::tss::validate_message;
use crate::instructions::withdraw::{internal_withdraw, send_universal_tx_to_uea};
use crate::state::{
    Config, ExecutedSubTx, GatewayAccountMeta, RateLimitConfig, StoredIxData, TokenRateLimit,
    TssPda, UniversalTxFinalized, CEA_SEED, EXECUTED_SUB_TX_SEED, RATE_LIMIT_CONFIG_SEED,
    SIGNATURE_FEE_LAMPORTS, STORED_IX_DATA_SEED, TSS_SEED, VAULT_SEED,
};
use crate::utils::{
    encode_u64_be, parse_token_account, pda_spl_transfer, pda_system_transfer,
    serialize_gateway_accounts, serialize_ix_data, transfer_gas_fee_to_caller,
    validate_remaining_accounts,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta as SolanaAccountMeta, Instruction},
    keccak,
    program::invoke_signed,
};
use anchor_spl::associated_token::{spl_associated_token_account, AssociatedToken};
use anchor_spl::token::{spl_token, Mint, Token, TokenAccount};

/// SPL token account data size in bytes (spl_token::state::Account layout — stable protocol constant).
const SPL_TOKEN_ACCOUNT_LEN: usize = 165;

// =========================
//  UNIFIED FINALIZE_UNIVERSAL_TX
// =========================

#[event_cpi]
#[derive(Accounts)]
#[instruction(instruction_id: u8, sub_tx_id: [u8; 32], universal_tx_id: [u8; 32], amount: u64, push_account: [u8; 20])]
pub struct FinalizeUniversalTx<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        seeds = [b"config"],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    /// Vault SOL PDA - holds all bridged SOL
    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault_sol: SystemAccount<'info>,

    /// CEA (Chain Executor Account) - persistent identity per Push Chain user
    /// This PDA represents the user on Solana and can sign for target programs
    /// Auto-created by Solana on first transfer, persists across transactions
    #[account(
        mut,
        seeds = [CEA_SEED, push_account.as_ref()],
        bump,
    )]
    pub cea_authority: SystemAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// Executed transaction tracker (replay protection)
    /// Relayer pays for this account creation and gets reimbursed via gas_fee
    #[account(
        init,
        payer = caller,
        space = ExecutedSubTx::LEN,
        seeds = [EXECUTED_SUB_TX_SEED, sub_tx_id.as_ref()],
        bump
    )]
    pub executed_sub_tx: Account<'info, ExecutedSubTx>,

    pub system_program: Program<'info, System>,
    /// CHECK: Target program for execute mode
    /// Pass system program id for withdraw, it's ignored
    pub destination_program: UncheckedAccount<'info>,

    // --- Optional SPL accounts
    /// CHECK: Recipient wallet for withdraw mode
    #[account(mut)]
    pub recipient: Option<UncheckedAccount<'info>>,

    /// Vault ATA for this mint — always initialized (deposit path guarantees existence)
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = vault_sol,
    )]
    pub vault_ata: Option<Account<'info, TokenAccount>>,

    /// CHECK: CEA ATA (created if missing via manual CPI)
    #[account(mut)]
    pub cea_ata: Option<UncheckedAccount<'info>>,

    pub mint: Option<Account<'info, Mint>>,

    pub token_program: Option<Program<'info, Token>>,

    pub rent: Option<Sysvar<'info, Rent>>,

    pub associated_token_program: Option<Program<'info, AssociatedToken>>,

    // --- Optional recipient ATA (required for SPL withdraw mode; created if missing) ---
    /// CHECK: Recipient ATA — created via manual CPI if missing (mirrors CEA ATA).
    /// Address, mint, and owner are validated in `internal_withdraw` after create.
    #[account(mut)]
    pub recipient_ata: Option<UncheckedAccount<'info>>,

    // --- Optional rate limit accounts (CEA withdrawal path only) ---
    #[account(
        seeds = [RATE_LIMIT_CONFIG_SEED],
        bump,
    )]
    pub rate_limit_config: Option<Account<'info, RateLimitConfig>>,

    /// Token-specific rate limit state (CEA withdrawal path only)
    #[account(mut)]
    pub token_rate_limit: Option<Account<'info, TokenRateLimit>>,

    /// Optional stored ix_data account for additive finalize-by-reference.
    #[account(mut)]
    pub stored_ix_data: Option<Account<'info, StoredIxData>>,

    /// CHECK: Optional stored-route fee refund recipient. Verified in ref-finalize entrypoint.
    #[account(mut)]
    pub store_refund_recipient: Option<UncheckedAccount<'info>>,
}

#[derive(Accounts)]
#[instruction(sub_tx_id: [u8; 32], ix_data_hash: [u8; 32], ix_data: Vec<u8>)]
pub struct StoreExecuteIxData<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        init,
        payer = caller,
        space = StoredIxData::LEN_BASE + ix_data.len(),
        seeds = [STORED_IX_DATA_SEED, sub_tx_id.as_ref(), ix_data_hash.as_ref()],
        bump
    )]
    pub stored_ix_data: Account<'info, StoredIxData>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CloseStoredIxData<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    /// No seed constraint here — canonicality is verified manually inside close_stored_ix_data
    /// using sub_tx_id and ix_data stored in the account itself, enabling arg-free close.
    #[account(
        mut,
        close = store_refund_recipient
    )]
    pub stored_ix_data: Account<'info, StoredIxData>,

    /// CHECK: Must equal `stored_ix_data.store_refund_recipient`; close refunds rent here.
    #[account(
        mut,
        constraint = store_refund_recipient.key() == stored_ix_data.store_refund_recipient
            @ GatewayError::InvalidAccount
    )]
    pub store_refund_recipient: UncheckedAccount<'info>,

    /// CHECK: Optional success marker PDA. If present, must equal the canonical executed_sub_tx PDA
    /// derived from the stored sub_tx_id.
    pub executed_sub_tx: Option<UncheckedAccount<'info>>,
}

struct FinalizeRequestContext {
    is_withdraw: bool,
    is_native: bool,
    token: Pubkey,
    target: Pubkey,
}

pub fn store_execute_ix_data(
    ctx: Context<StoreExecuteIxData>,
    sub_tx_id: [u8; 32],
    ix_data_hash: [u8; 32],
    ix_data: Vec<u8>,
) -> Result<()> {
    require!(!ix_data.is_empty(), GatewayError::EmptyIxData);

    let computed = keccak::hashv(&[ix_data.as_slice()]).to_bytes();
    require!(computed == ix_data_hash, GatewayError::InvalidIxDataHash);

    let stored = &mut ctx.accounts.stored_ix_data;
    stored.bump = ctx.bumps.stored_ix_data;
    stored.sub_tx_id = sub_tx_id;
    stored.store_refund_recipient = ctx.accounts.caller.key();
    stored.ix_data = ix_data;
    Ok(())
}

pub fn close_stored_ix_data(ctx: Context<CloseStoredIxData>) -> Result<()> {
    let stored = &ctx.accounts.stored_ix_data;

    // Verify this is the canonical PDA for its own stored data (self-describing check).
    // Recompute ix_data_hash from stored bytes, then re-derive the expected PDA address.
    let ix_data_hash = keccak::hashv(&[stored.ix_data.as_slice()]).to_bytes();
    let expected_pda = Pubkey::create_program_address(
        &[
            STORED_IX_DATA_SEED,
            stored.sub_tx_id.as_ref(),
            ix_data_hash.as_ref(),
            &[stored.bump],
        ],
        ctx.program_id,
    )
    .map_err(|_| error!(GatewayError::InvalidAccount))?;
    require!(
        ctx.accounts.stored_ix_data.key() == expected_pda,
        GatewayError::InvalidAccount
    );

    let expected_executed_sub_tx = Pubkey::find_program_address(
        &[EXECUTED_SUB_TX_SEED, stored.sub_tx_id.as_ref()],
        ctx.program_id,
    )
    .0;

    let executed_sub_tx_exists = if let Some(executed_sub_tx) = &ctx.accounts.executed_sub_tx {
        require!(
            executed_sub_tx.key() == expected_executed_sub_tx,
            GatewayError::InvalidAccount
        );
        executed_sub_tx.owner == ctx.program_id && !executed_sub_tx.data_is_empty()
    } else {
        false
    };

    if !executed_sub_tx_exists
        && ctx.accounts.caller.key() != ctx.accounts.store_refund_recipient.key()
    {
        return err!(GatewayError::StoredIxDataNotClosable);
    }

    Ok(())
}

pub fn finalize_universal_tx_common<'info>(
    ctx: &mut Context<FinalizeUniversalTx<'info>>,
    instruction_id: u8,
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    push_account: [u8; 20],
    writable_flags: Vec<u8>,
    ix_data: Vec<u8>,
    store_upload_fee_lamports: u64,
    store_refund_recipient: Option<&AccountInfo<'info>>,
    gas_fee: u64,
    deadline: i64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(!ctx.accounts.config.paused, GatewayError::Paused);

    let request = validate_finalize_request(
        ctx,
        instruction_id,
        amount,
        push_account,
        &writable_flags,
        &ix_data,
    )?;

    let execute_accounts = verify_finalize_tss(
        ctx,
        &request,
        universal_tx_id,
        sub_tx_id,
        push_account,
        &writable_flags,
        &ix_data,
        gas_fee,
        deadline,
        amount,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    let vault_bump = [ctx.accounts.config.vault_bump];
    let vault_seeds = [VAULT_SEED, &vault_bump[..]];
    let cea_bump = [ctx.bumps.cea_authority];
    let cea_seeds = [CEA_SEED, push_account.as_ref(), &cea_bump[..]];

    // Stage assets vault → CEA. Returns whether CEA ATA was created.
    let ata_created = stage_assets_to_cea(&ctx, &request, amount, &vault_seeds)?;

    // Dispatch runs BEFORE settle so any ATAs created inside dispatch (e.g. the
    // recipient ATA in `internal_withdraw`) can be folded into `gas_used` and
    // the caller reimbursed for that rent.
    let recipient_ata_created = dispatch_finalize_action(
        ctx,
        &request,
        execute_accounts,
        amount,
        push_account,
        &ix_data,
        &cea_seeds,
    )?;

    let (gas_used, gas_to_refund) = settle_relayer_gas_cost(
        &ctx,
        gas_fee,
        ata_created,
        recipient_ata_created,
        store_upload_fee_lamports,
        store_refund_recipient,
    )?;

    emit_cpi!(UniversalTxFinalized {
        sub_tx_id,
        universal_tx_id,
        gas_fee,
        gas_used,
        gas_to_refund,
        ata_created,
        recipient_ata_created,
        push_account,
        target: request.target,
        token: request.token,
        amount,
        payload: ix_data,
    });

    Ok(())
}

/// Compute gas accounting and reimburse relayer for actual cost.
///
/// Marked `inline(never)` to keep `finalize_universal_tx` stack usage below the
/// BPF frame limit.
#[inline(never)]
fn settle_relayer_gas_cost<'info>(
    ctx: &Context<FinalizeUniversalTx<'info>>,
    gas_fee: u64,
    cea_ata_created: bool,
    recipient_ata_created: bool,
    store_upload_fee_lamports: u64,
    store_refund_recipient: Option<&AccountInfo<'info>>,
) -> Result<(u64, u64)> {
    let sub_tx_rent = Rent::get()?.minimum_balance(ExecutedSubTx::LEN);
    let per_ata_rent = Rent::get()?.minimum_balance(SPL_TOKEN_ACCOUNT_LEN);
    let ata_rent = (cea_ata_created as u64 + recipient_ata_created as u64) * per_ata_rent;
    let base_finalize_gas = SIGNATURE_FEE_LAMPORTS + sub_tx_rent + ata_rent;
    let gas_used = base_finalize_gas + store_upload_fee_lamports;
    require!(gas_fee >= gas_used, GatewayError::InsufficientGasBudget);
    let gas_to_refund = gas_fee - gas_used;

    // Reimburse relayer for actual cost only. Remaining gas_to_refund stays in vault
    // until UVs return it to the user on Push Chain via the emitted event.
    transfer_gas_fee_to_caller(
        &ctx.accounts.vault_sol.to_account_info(),
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        base_finalize_gas,
        ctx.accounts.config.vault_bump,
    )?;

    if let Some(refund_recipient) = store_refund_recipient {
        transfer_gas_fee_to_caller(
            &ctx.accounts.vault_sol.to_account_info(),
            refund_recipient,
            &ctx.accounts.system_program.to_account_info(),
            store_upload_fee_lamports,
            ctx.accounts.config.vault_bump,
        )?;
    }

    Ok((gas_used, gas_to_refund))
}

// ============================================
//    VALIDATION HELPERS (PHASE 1)
// ============================================

/// Enforce SPL/SOL account presence based on token type
fn validate_account_presence(ctx: &Context<FinalizeUniversalTx>, is_native: bool) -> Result<()> {
    if is_native {
        require!(
            ctx.accounts.vault_ata.is_none()
                && ctx.accounts.cea_ata.is_none()
                && ctx.accounts.mint.is_none()
                && ctx.accounts.token_program.is_none()
                && ctx.accounts.rent.is_none()
                && ctx.accounts.associated_token_program.is_none(),
            GatewayError::InvalidAccount
        );
    } else {
        require!(
            ctx.accounts.vault_ata.is_some()
                && ctx.accounts.cea_ata.is_some()
                && ctx.accounts.mint.is_some()
                && ctx.accounts.token_program.is_some()
                && ctx.accounts.rent.is_some()
                && ctx.accounts.associated_token_program.is_some(),
            GatewayError::InvalidAccount
        );
    }
    Ok(())
}

/// Validate the finalize request and return the normalized mode context.
fn validate_finalize_request(
    ctx: &Context<FinalizeUniversalTx>,
    instruction_id: u8,
    amount: u64,
    push_account: [u8; 20],
    writable_flags: &[u8],
    ix_data: &[u8],
) -> Result<FinalizeRequestContext> {
    let is_withdraw = match instruction_id {
        1 => true,
        2 => false,
        _ => return Err(error!(GatewayError::InvalidInstruction)),
    };

    let is_native = ctx.accounts.mint.is_none();
    let token = ctx.accounts.mint.as_ref().map_or(Pubkey::default(), |m| m.key());
    validate_account_presence(ctx, is_native)?;
    require!(push_account != [0u8; 20], GatewayError::InvalidInput);

    let target = if is_withdraw {
        let recipient = ctx
            .accounts
            .recipient
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        recipient.key()
    } else {
        require!(ctx.accounts.recipient.is_none(), GatewayError::InvalidAccount);
        ctx.accounts.destination_program.key()
    };

    if is_withdraw {
        require!(amount > 0, GatewayError::InvalidAmount);
        require!(writable_flags.is_empty(), GatewayError::InvalidInput);
        require!(ix_data.is_empty(), GatewayError::InvalidInput);

        if !is_native {
            require!(
                ctx.accounts.recipient_ata.is_some(),
                GatewayError::InvalidAccount
            );
        }

        require!(
            ctx.remaining_accounts.is_empty(),
            GatewayError::InvalidInput
        );
    } else {
        require!(
            ctx.accounts.recipient_ata.is_none(),
            GatewayError::InvalidInput
        );

        let accounts_count = ctx.remaining_accounts.len();
        let expected_writable_flags_len = (accounts_count + 7) / 8;
        require!(
            writable_flags.len() == expected_writable_flags_len,
            GatewayError::InvalidAccount
        );
    }

    Ok(FinalizeRequestContext {
        is_withdraw,
        is_native,
        token,
        target,
    })
}

// ============================================
//    TSS VALIDATION HELPERS (PHASE 2)
// ============================================

fn verify_finalize_tss(
    ctx: &mut Context<FinalizeUniversalTx>,
    request: &FinalizeRequestContext,
    universal_tx_id: [u8; 32],
    sub_tx_id: [u8; 32],
    push_account: [u8; 20],
    writable_flags: &[u8],
    ix_data: &[u8],
    gas_fee: u64,
    deadline: i64,
    amount: u64,
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
) -> Result<Option<Vec<GatewayAccountMeta>>> {
    if request.is_withdraw {
        build_and_validate_tss_withdraw(
            &mut ctx.accounts.tss_pda,
            universal_tx_id,
            sub_tx_id,
            push_account,
            request.token,
            request.target,
            gas_fee,
            deadline,
            amount,
            message_hash,
            signature,
            recovery_id,
        )?;
        return Ok(None);
    }

    let accounts = build_and_validate_tss_execute(
        &mut ctx.accounts.tss_pda,
        ctx.remaining_accounts,
        universal_tx_id,
        sub_tx_id,
        push_account,
        request.target,
        request.token,
        writable_flags,
        ix_data,
        gas_fee,
        deadline,
        amount,
        message_hash,
        signature,
        recovery_id,
    )?;

    require!(
        ctx.accounts.destination_program.executable,
        GatewayError::InvalidProgram
    );

    Ok(Some(accounts))
}

/// Stage bridged assets from vault to CEA. Returns `ata_created` indicating whether
/// the CEA ATA had to be created (SPL path only; always false for native SOL).
/// Gas transfer to caller is intentionally NOT performed here — it is computed and
/// paid separately after this call, once actual gas_used is known.
fn stage_assets_to_cea(
    ctx: &Context<FinalizeUniversalTx>,
    request: &FinalizeRequestContext,
    amount: u64,
    vault_seeds: &[&[u8]],
) -> Result<bool> {
    if request.is_native {
        pda_system_transfer(
            &ctx.accounts.vault_sol.to_account_info(),
            &ctx.accounts.cea_authority.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            amount,
            vault_seeds,
        )?;
        Ok(false)
    } else {
        process_spl_vault_to_cea_transfer(ctx, amount, vault_seeds)
    }
}

/// Returns `true` when the withdraw branch created the recipient ATA. Parent uses
/// this to include the ATA rent in `gas_used` so the caller is reimbursed atomically.
fn dispatch_finalize_action(
    ctx: &mut Context<FinalizeUniversalTx>,
    request: &FinalizeRequestContext,
    execute_accounts: Option<Vec<GatewayAccountMeta>>,
    amount: u64,
    push_account: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<bool> {
    if request.is_withdraw {
        return internal_withdraw(ctx, amount, request.token, cea_seeds);
    }

    if request.target == *ctx.program_id {
        send_universal_tx_to_uea(ctx, push_account, ix_data, cea_seeds)?;
        return Ok(false);
    }

    let cea_key = ctx.accounts.cea_authority.key();
    let accounts = execute_accounts.ok_or(error!(GatewayError::InvalidAccount))?;
    let cpi_metas: Vec<SolanaAccountMeta> = accounts
        .iter()
        .map(|account| {
            let is_signer = account.pubkey == cea_key;
            if account.is_writable {
                SolanaAccountMeta::new(account.pubkey, is_signer)
            } else {
                SolanaAccountMeta::new_readonly(account.pubkey, is_signer)
            }
        })
        .collect();

    let cpi_ix = Instruction {
        program_id: request.target,
        accounts: cpi_metas,
        data: ix_data.to_vec(),
    };

    // F-2026-18980 — Pre-CPI snapshot of every CEA-owned SPL token account this
    // tx exposes. Current-mint ATA (typed slot) has budget = `amount`. Bystanders
    // in remaining_accounts have budget = 0 (strictly unchanged). Token-2022
    // accounts are not currently supported; extend the SPL-Token owner check if
    // added later.
    let cea_ata_key = ctx.accounts.cea_ata.as_ref().map(|a| a.key());
    let current_snapshot = ctx
        .accounts
        .cea_ata
        .as_ref()
        .map(|a| parse_token_account(&a.to_account_info()))
        .transpose()?;

    let mut bystanders: Vec<(usize, spl_token::state::Account)> = Vec::new();
    // Mint keys present in remaining_accounts. Used post-CPI to derive canonical
    // CEA ATA addresses for G1 (retest) check: any CEA-owned SPL account that
    // appeared during the CPI at a canonical ATA address for one of these mints
    // is treated as a planted-delegate risk and rejected.
    let mut mint_keys: Vec<Pubkey> = Vec::new();
    for (idx, info) in ctx.remaining_accounts.iter().enumerate() {
        // Collect mint accounts (SPL Token owned, 82 bytes = Mint layout size).
        const SPL_MINT_LEN: usize = 82;
        if info.owner == &spl_token::ID && info.data_len() == SPL_MINT_LEN {
            mint_keys.push(info.key());
        }
        if Some(info.key()) == cea_ata_key {
            continue;
        }
        if info.owner != &spl_token::ID {
            continue;
        }
        let Ok(parsed) = parse_token_account(info) else {
            continue;
        };
        if parsed.owner != cea_key {
            continue;
        }
        bystanders.push((idx, parsed));
    }

    invoke_signed(&cpi_ix, ctx.remaining_accounts, &[cea_seeds])?;

    // CEA account must remain System-owned and empty (blocks `assign` brick).
    let cea = ctx.accounts.cea_authority.to_account_info();
    require!(
        cea.owner == &anchor_lang::system_program::ID && cea.data_is_empty(),
        GatewayError::InvalidAccount
    );

    // Current-mint ATA: budget = `amount`.
    if let (Some(cea_ata), Some(before)) =
        (ctx.accounts.cea_ata.as_ref(), current_snapshot)
    {
        let after = parse_token_account(&cea_ata.to_account_info())?;
        check_cea_ata_invariants(&after, &before, amount)?;
    }

    // Bystander CEA-owned ATAs: budget = 0 (strictly unchanged).
    for (idx, before) in &bystanders {
        let after = parse_token_account(&ctx.remaining_accounts[*idx])?;
        check_cea_ata_invariants(&after, before, 0)?;
    }

    // G1 (retest): flag CEA-owned SPL token accounts that appeared during the
    // CPI at a canonical CEA ATA address for any mint present in this tx. The
    // target could have created such an account and installed a delegate; a
    // later bridge for the same mint would derive the same address and fund
    // it. Enforce strict-nothing invariants on newly-appeared canonical ATAs.
    for (idx, info) in ctx.remaining_accounts.iter().enumerate() {
        if Some(info.key()) == cea_ata_key {
            continue;
        }
        if bystanders.iter().any(|(bi, _)| *bi == idx) {
            continue; // pre-CPI bystander — already checked strictly-unchanged above
        }
        if info.owner != &spl_token::ID {
            continue;
        }
        let Ok(parsed) = parse_token_account(info) else {
            continue;
        };
        if parsed.owner != cea_key {
            continue;
        }
        let is_canonical = mint_keys.iter().any(|mint_key| {
            spl_associated_token_account::get_associated_token_address(&cea_key, mint_key)
                == *info.key
        });
        if is_canonical {
            require!(parsed.delegate.is_none(), GatewayError::InvalidAccount);
            require!(parsed.delegated_amount == 0, GatewayError::InvalidAccount);
            require!(parsed.close_authority.is_none(), GatewayError::InvalidAccount);
        }
    }

    Ok(false)
}

/// Post-CPI invariants on a CEA-owned SPL token account. Blocks
/// `SetAuthority(AccountOwner)`, `SetAuthority(CloseAccount)`, and any allowance
/// left over funds the target doesn't have.
///
/// - Bystanders (`budget == 0`, i.e. accounts in `remaining_accounts` unrelated
///   to the current mint): delegate identity and allowance must be strictly
///   unchanged (including `Revoke`).
/// - Current-mint ATA (`budget > 0`): identity-swap guard from an active prior
///   delegate is preserved; and the surviving allowance must be backed by the
///   surviving balance (`delegated_amount <= amount`). This is the coverage
///   rule (F-2026-18980 retest / gaps G2 + G3): SPL owner-authority transfers
///   do not decrement `delegated_amount`, so absent this check a target could
///   `Approve(attacker, N)` and drain N tokens as owner in the same CPI,
///   leaving a live allowance over an empty balance that later refills would
///   satisfy.
#[inline(never)]
fn check_cea_ata_invariants(
    after: &spl_token::state::Account,
    before: &spl_token::state::Account,
    budget: u64,
) -> Result<()> {
    require!(after.owner == before.owner, GatewayError::InvalidOwner);
    require!(
        after.close_authority == before.close_authority,
        GatewayError::InvalidAccount
    );
    if budget == 0 {
        require!(after.delegate == before.delegate, GatewayError::InvalidAccount);
        require!(
            after.delegated_amount == before.delegated_amount,
            GatewayError::InvalidAccount
        );
        return Ok(());
    }
    // Identity-swap guard (T12): can't divert an active allowance to a new party
    // by swapping the delegate at equal or lower balance.
    if after.delegate != before.delegate {
        require!(
            after.delegate.is_none()
                || before.delegate.is_none()
                || before.delegated_amount == 0,
            GatewayError::InvalidAccount
        );
    }
    // Coverage rule: any surviving allowance must be backed by the surviving
    // balance. Applies whether delegate changed or not.
    require!(
        after.delegated_amount <= after.amount,
        GatewayError::InvalidAccount
    );
    Ok(())
}

fn reconstruct_accounts_from_flags<'info>(
    remaining_accounts: &[AccountInfo<'info>],
    writable_flags: &[u8],
) -> Vec<GatewayAccountMeta> {
    remaining_accounts
        .iter()
        .enumerate()
        .map(|(i, acc)| GatewayAccountMeta {
            pubkey: *acc.key,
            is_writable: (writable_flags[i / 8] >> (7 - (i % 8))) & 1 == 1,
        })
        .collect()
}

/// Build and validate TSS signature for withdraw mode (instruction_id=1)
///
/// TSS Message Format (common fields first):
/// 1. sub_tx_id (32 bytes)
/// 2. universal_tx_id (32 bytes)
/// 3. push_account (20 bytes)
/// 4. token (32 bytes)
/// 5. gas_fee (u64 BE)
/// 6. target (32 bytes) - withdraw specific
fn build_and_validate_tss_withdraw(
    tss_pda: &mut Account<TssPda>,
    universal_tx_id: [u8; 32],
    sub_tx_id: [u8; 32],
    push_account: [u8; 20],
    token: Pubkey,
    target: Pubkey,
    gas_fee: u64,
    deadline: i64,
    amount: u64,
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
) -> Result<()> {
    let gas_fee_buf = encode_u64_be(gas_fee);
    let additional: [&[u8]; 6] = [
        &sub_tx_id,
        &universal_tx_id,
        &push_account,
        &token.to_bytes(),
        &gas_fee_buf,
        &target.to_bytes(),
    ];
    validate_message(tss_pda, 1, Some(amount), deadline, &additional, message_hash, signature, recovery_id)
}

/// Build and validate TSS signature for execute mode (instruction_id=2)
///
/// TSS Message Format (common fields first):
/// 1. sub_tx_id (32 bytes)
/// 2. universal_tx_id (32 bytes)
/// 3. push_account (20 bytes)
/// 4. token (32 bytes)
/// 5. gas_fee (u64 BE)
/// 6. target_program (32 bytes) - execute specific
/// 7. accounts_buf (variable) - execute specific
/// 8. ix_data_buf (variable) - execute specific
fn build_and_validate_tss_execute<'info>(
    tss_pda: &mut Account<TssPda>,
    remaining_accounts: &[AccountInfo<'info>],
    universal_tx_id: [u8; 32],
    sub_tx_id: [u8; 32],
    push_account: [u8; 20],
    target: Pubkey,
    token: Pubkey,
    writable_flags: &[u8],
    ix_data: &[u8],
    gas_fee: u64,
    deadline: i64,
    amount: u64,
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
) -> Result<Vec<GatewayAccountMeta>> {
    let accounts = reconstruct_accounts_from_flags(remaining_accounts, writable_flags);
    validate_remaining_accounts(&accounts, remaining_accounts)?;

    let accounts_buf = serialize_gateway_accounts(&accounts);
    let ix_data_buf = serialize_ix_data(ix_data);
    let gas_fee_buf = encode_u64_be(gas_fee);
    let additional: [&[u8]; 8] = [
        &sub_tx_id,
        &universal_tx_id,
        &push_account,
        &token.to_bytes(),
        &gas_fee_buf,
        &target.to_bytes(),
        &accounts_buf,
        &ix_data_buf,
    ];

    validate_message(tss_pda, 2, Some(amount), deadline, &additional, message_hash, signature, recovery_id)?;
    Ok(accounts)
}

// ============================================
//    SPL ACCOUNT HELPERS (PHASE 3)
// ============================================

/// Validate and process SPL token transfer from vault to CEA.
/// Returns `true` if the CEA ATA did not exist and had to be created.
fn process_spl_vault_to_cea_transfer<'info>(
    ctx: &Context<FinalizeUniversalTx<'info>>,
    amount: u64,
    vault_seeds: &[&[u8]],
) -> Result<bool> {
    // Unpack SPL accounts (guaranteed Some by validate_account_presence)
    let vault_ata = ctx.accounts.vault_ata.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
    let cea_ata = ctx.accounts.cea_ata.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
    let mint = ctx.accounts.mint.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
    let token_program = ctx.accounts.token_program.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
    let rent = ctx.accounts.rent.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
    let ata_program = ctx.accounts.associated_token_program.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;

    // Validate vault_ata mint matches the supplied mint account.
    // Ownership (vault_sol) is enforced by the Anchor token::authority constraint.
    require!(vault_ata.mint == mint.key(), GatewayError::InvalidMint);

    // Derive expected CEA ATA and validate
    let expected_cea_ata = spl_associated_token_account::get_associated_token_address(
        &ctx.accounts.cea_authority.key(),
        &mint.key(),
    );
    require!(
        cea_ata.key() == expected_cea_ata,
        GatewayError::InvalidAccount
    );

    // Create CEA ATA if it doesn't exist; capture whether creation happened.
    let cea_ata_info = cea_ata.to_account_info();
    let ata_created = cea_ata_info.data_is_empty();
    if ata_created {
        let create_ata_ix =
            spl_associated_token_account::instruction::create_associated_token_account(
                &ctx.accounts.caller.key(),
                &ctx.accounts.cea_authority.key(),
                &mint.key(),
                &spl_token::ID,
            );
        invoke_signed(
            &create_ata_ix,
            &[
                ctx.accounts.caller.to_account_info(),
                cea_ata.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                mint.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
                token_program.to_account_info(),
                ata_program.to_account_info(),
                rent.to_account_info(),
            ],
            &[],
        )?;
    }

    // Validate existing CEA ATA: mint + owner
    let parsed_cea_ata = parse_token_account(&cea_ata.to_account_info())?;
    require!(parsed_cea_ata.mint == mint.key(), GatewayError::InvalidMint);
    require!(
        parsed_cea_ata.owner == ctx.accounts.cea_authority.key(),
        GatewayError::InvalidOwner
    );

    pda_spl_transfer(
        &vault_ata.to_account_info(),
        &cea_ata.to_account_info(),
        &ctx.accounts.vault_sol.to_account_info(),
        amount,
        vault_seeds,
    )?;

    Ok(ata_created)
}