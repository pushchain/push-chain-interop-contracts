use crate::instructions::pc20::{
    is_pc20_remint_account_shape, validate_pc20_mint_authority, validate_pc20_state_fields,
};
use crate::instructions::tss::validate_message;
use crate::utils::{
    encode_u64_be, ensure_associated_token_account, parse_token_account, pda_mint_to,
    pda_spl_transfer, pda_system_transfer, reimburse_relayer_from_fee_vault,
};
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak::hash;
use anchor_spl::associated_token::{spl_associated_token_account, AssociatedToken};
use anchor_spl::token::{Mint, Token, TokenAccount};

const SPL_TOKEN_ACCOUNT_LEN: usize = 165;

// =========================
//   TSS REVERT FUNCTION
// =========================
// Single entrypoint handles both SOL (token_mint = None) and SPL (token_mint = Some).
//
// TSS message format (instruction_id = 3 for both modes):
//   SOL: amount || [sub_tx_id, universal_tx_id, recipient, gas_fee, revert_msg_hash]
//   SPL: amount || [sub_tx_id, universal_tx_id, mint, recipient, gas_fee, revert_msg_hash]

#[event_cpi]
#[derive(Accounts)]
#[instruction(sub_tx_id: [u8; 32])]
pub struct RevertUniversalTx<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL vault PDA — holds bridged SOL and serves as authority for SPL vault ATAs.
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// Fee vault — relayer gas reimbursement source.
    #[account(mut, seeds = [FEE_VAULT_SEED], bump = fee_vault.bump)]
    pub fee_vault: Account<'info, FeeVault>,

    #[account(mut, seeds = [TSS_SEED], bump = tss_pda.bump)]
    pub tss_pda: Account<'info, TssPda>,

    /// CHECK: Recipient wallet — SOL goes here directly; for SPL, validated against
    /// recipient_token_account.owner and used as canonical identity in TSS message.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    /// Replay protection (EVM parity: isExecuted[subTxId]).
    #[account(
        init,
        payer = caller,
        space = ExecutedSubTx::LEN,
        seeds = [EXECUTED_SUB_TX_SEED, &sub_tx_id],
        bump
    )]
    pub executed_sub_tx: Account<'info, ExecutedSubTx>,

    /// The caller/relayer — pays transaction fees, receives gas_fee reimbursement.
    #[account(mut)]
    pub caller: Signer<'info>,

    pub system_program: Program<'info, System>,

    // --- Optional SPL accounts (all None for SOL, all Some for SPL) ---
    /// Vault ATA for this mint — holds bridged SPL tokens.
    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = vault,
    )]
    pub token_vault: Option<Account<'info, TokenAccount>>,

    /// Recipient token account — created via manual CPI if missing (legacy SPL path).
    /// Address, mint, and owner are validated in the handler after create.
    #[account(mut)]
    /// CHECK: validated in handler via `parse_token_account` post-create.
    pub recipient_token_account: Option<UncheckedAccount<'info>>,

    pub token_mint: Option<Account<'info, Mint>>,

    pub token_program: Option<Program<'info, Token>>,

    /// Required on the legacy SPL path (create recipient ATA if missing). Must be None on
    /// native and PC20 paths (PC20 sources atp/rent from `remaining_accounts`).
    pub associated_token_program: Option<Program<'info, AssociatedToken>>,

    /// Required on the legacy SPL path. Must be None on native and PC20 paths.
    pub rent: Option<Sysvar<'info, Rent>>,
}

pub fn revert_universal_tx<'info>(
    ctx: Context<'_, '_, '_, 'info, RevertUniversalTx<'info>>,
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    gas_fee: u64,
    deadline: i64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);

    let recipient = ctx.accounts.recipient.key();
    require!(
        revert_instruction.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        recipient == revert_instruction.revert_recipient,
        GatewayError::InvalidRecipient
    );
    let revert_msg_hash = hash(revert_instruction.revert_msg.as_slice()).to_bytes();

    let is_native = ctx.accounts.token_mint.is_none();
    let is_pc20 = ctx
        .accounts
        .token_mint
        .as_ref()
        .map(|mint| {
            is_pc20_remint_account_shape(ctx.program_id, ctx.remaining_accounts, mint.key())
        })
        .unwrap_or(false);

    // --- Account presence + cross-account consistency ---
    // Note: atp and rent are typed as `Option<Program<AssociatedToken>>` / `Option<Sysvar<Rent>>`
    // — Anchor validates the program id / sysvar id when Some, and the Anchor JS client
    // auto-populates these slots. We therefore don't gate on `is_none()` for non-SPL paths
    // (they may arrive as Some from auto-population and are simply unused).
    if is_native {
        require!(
            ctx.accounts.token_vault.is_none()
                && ctx.accounts.recipient_token_account.is_none()
                && ctx.accounts.token_program.is_none(),
            GatewayError::InvalidAccount
        );
    } else if is_pc20 {
        require!(
            ctx.accounts.token_vault.is_none(),
            GatewayError::InvalidAccount
        );
        require!(
            ctx.accounts.recipient_token_account.is_none(),
            GatewayError::InvalidAccount
        );
        require!(
            ctx.accounts.token_program.is_some(),
            GatewayError::InvalidAccount
        );
        require!(
            ctx.remaining_accounts.len() == 5,
            GatewayError::AccountListLengthMismatch
        );
    } else {
        // Legacy SPL: token_vault + recipient_token_account + token_program + atp + rent all required.
        // Recipient ATA mint/owner are validated below, after ensure_associated_token_account,
        // so the check works uniformly whether the ATA already existed or was created.
        let token_vault = ctx
            .accounts
            .token_vault
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        require!(
            ctx.accounts.recipient_token_account.is_some()
                && ctx.accounts.token_program.is_some()
                && ctx.accounts.associated_token_program.is_some()
                && ctx.accounts.rent.is_some(),
            GatewayError::InvalidAccount
        );
        let mint_key = ctx.accounts.token_mint.as_ref().unwrap().key(); // Safe: !is_native ⟹ token_mint.is_some()
        require!(token_vault.mint == mint_key, GatewayError::InvalidMint);
    }
    let pc20_source_asset = if is_pc20 {
        Some(read_pc20_source_asset(
            ctx.program_id,
            ctx.accounts.token_mint.as_ref().unwrap().key(),
            ctx.remaining_accounts,
        )?)
    } else {
        None
    };

    // TSS message: instruction_id=3 || amount || [sub_tx_id, universal_tx_id, (mint,) recipient, gas_fee, revert_msg_hash]
    let recipient_bytes = recipient.to_bytes();
    let gas_fee_buf = encode_u64_be(gas_fee);
    if is_native {
        let additional: [&[u8]; 5] = [
            &sub_tx_id,
            &universal_tx_id,
            &recipient_bytes,
            &gas_fee_buf,
            &revert_msg_hash,
        ];
        validate_message(
            &mut ctx.accounts.tss_pda,
            3,
            Some(amount),
            deadline,
            &additional,
            &message_hash,
            &signature,
            recovery_id,
        )?;
    } else if let Some(source_asset) = pc20_source_asset.as_ref() {
        let mint_bytes = ctx.accounts.token_mint.as_ref().unwrap().key().to_bytes();
        let additional: [&[u8]; 8] = [
            &sub_tx_id,
            &universal_tx_id,
            &mint_bytes,
            &recipient_bytes,
            &gas_fee_buf,
            &revert_msg_hash,
            PC20_SELECTOR.as_ref(),
            source_asset.as_ref(),
        ];
        validate_message(
            &mut ctx.accounts.tss_pda,
            3,
            Some(amount),
            deadline,
            &additional,
            &message_hash,
            &signature,
            recovery_id,
        )?;
    } else {
        let mint_bytes = ctx.accounts.token_mint.as_ref().unwrap().key().to_bytes();
        let additional: [&[u8]; 6] = [
            &sub_tx_id,
            &universal_tx_id,
            &mint_bytes,
            &recipient_bytes,
            &gas_fee_buf,
            &revert_msg_hash,
        ];
        validate_message(
            &mut ctx.accounts.tss_pda,
            3,
            Some(amount),
            deadline,
            &additional,
            &message_hash,
            &signature,
            recovery_id,
        )?;
    }

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];

    let recipient_ata_lamports_paid = if is_native {
        pda_system_transfer(
            &ctx.accounts.vault.to_account_info(),
            &ctx.accounts.recipient.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            amount,
            seeds,
        )?;
        0
    } else if is_pc20 {
        remint_pc20_from_generic_revert(
            &ctx.accounts,
            ctx.remaining_accounts,
            ctx.program_id,
            recipient,
            amount,
        )?
    } else {
        // Legacy SPL: ensure recipient ATA exists (create-if-missing) before transferring.
        // Rent is folded into measured gas_used below so the caller is reimbursed atomically.
        let recipient_ta = ctx
            .accounts
            .recipient_token_account
            .as_ref()
            .unwrap()
            .to_account_info();
        let mint_info = ctx.accounts.token_mint.as_ref().unwrap().to_account_info();
        let token_program_info = ctx
            .accounts
            .token_program
            .as_ref()
            .unwrap()
            .to_account_info();
        let atp_info = ctx
            .accounts
            .associated_token_program
            .as_ref()
            .unwrap()
            .to_account_info();
        let rent_info = ctx.accounts.rent.as_ref().unwrap().to_account_info();

        let recipient_ata_lamports_before = recipient_ta.lamports();
        let ata_created = ensure_associated_token_account(
            &ctx.accounts.caller.to_account_info(),
            &recipient_ta,
            &ctx.accounts.recipient.to_account_info(),
            &mint_info,
            &ctx.accounts.system_program.to_account_info(),
            &token_program_info,
            &atp_info,
            &rent_info,
        )?;
        let ata_rent_paid = if ata_created {
            Rent::get()?
                .minimum_balance(SPL_TOKEN_ACCOUNT_LEN)
                .saturating_sub(recipient_ata_lamports_before)
        } else {
            0
        };

        // Post-create validation: matches the previous typed-slot invariants uniformly.
        let parsed = parse_token_account(&recipient_ta)?;
        require!(parsed.mint == mint_info.key(), GatewayError::InvalidMint);
        require!(parsed.owner == recipient, GatewayError::InvalidRecipient);

        pda_spl_transfer(
            &ctx.accounts.token_vault.as_ref().unwrap().to_account_info(),
            &recipient_ta,
            &ctx.accounts.vault.to_account_info(),
            amount,
            seeds,
        )?;
        ata_rent_paid
    };

    // Reimbursement source stays fee_vault (SVM-originated inbound failure; the user already
    // paid the inbound fee into fee_vault). The signed `gas_fee` is a ceiling for the
    // two-phase commit with Push; the on-chain program measures actual cost and reimburses
    // that, so the delta stays in fee_vault instead of being silently overpaid to the caller.
    // Measured cost is uniform: signature fee + ExecutedSubTx rent, plus recipient ATA rent
    // when this call had to create it (0 for native; may be non-zero for legacy SPL and PC20).
    let reimbursement = SIGNATURE_FEE_LAMPORTS
        .checked_add(Rent::get()?.minimum_balance(ExecutedSubTx::LEN))
        .and_then(|n| n.checked_add(recipient_ata_lamports_paid))
        .ok_or(error!(GatewayError::InvalidAmount))?;
    require!(
        gas_fee >= reimbursement,
        GatewayError::InsufficientGasBudget
    );

    emit_cpi!(crate::state::RevertUniversalTx {
        sub_tx_id,
        universal_tx_id,
        revert_recipient: revert_instruction.revert_recipient,
        token: ctx
            .accounts
            .token_mint
            .as_ref()
            .map_or(Pubkey::default(), |m| m.key()),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    reimburse_relayer_from_fee_vault(
        &ctx.accounts.fee_vault,
        &ctx.accounts.caller.to_account_info(),
        reimbursement,
    )?;
    if reimbursement > 0 {
        emit_cpi!(crate::state::InboundFeeReimbursed {
            sub_tx_id,
            relayer: ctx.accounts.caller.key(),
            amount_lamports: reimbursement,
        });
    }

    Ok(())
}

fn read_pc20_source_asset<'info>(
    program_id: &Pubkey,
    token_mint: Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
) -> Result<[u8; 20]> {
    let pc20_state = &remaining_accounts[0];
    let pc20_mint = &remaining_accounts[1];
    require!(pc20_mint.key() == token_mint, GatewayError::InvalidMint);
    require!(pc20_state.owner == program_id, GatewayError::InvalidAccount);

    let state = Pc20State::try_deserialize(&mut &pc20_state.try_borrow_data()?[..])?;
    validate_pc20_state_fields(program_id, pc20_state.key, &state, token_mint)
}

fn remint_pc20_from_generic_revert<'info>(
    accounts: &RevertUniversalTx<'info>,
    remaining_accounts: &[AccountInfo<'info>],
    program_id: &Pubkey,
    recipient: Pubkey,
    amount: u64,
) -> Result<u64> {
    let token_mint = accounts
        .token_mint
        .as_ref()
        .ok_or(error!(GatewayError::InvalidMint))?;
    let token_program = accounts
        .token_program
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;

    let pc20_state = &remaining_accounts[0];
    let pc20_mint = &remaining_accounts[1];
    let recipient_ata = &remaining_accounts[2];
    let associated_token_program = &remaining_accounts[3];
    let rent = &remaining_accounts[4];

    require!(
        pc20_mint.key() == token_mint.key(),
        GatewayError::InvalidMint
    );
    require!(pc20_state.owner == program_id, GatewayError::InvalidAccount);
    require!(
        !pc20_state.is_signer
            && !pc20_mint.is_signer
            && !recipient_ata.is_signer
            && !associated_token_program.is_signer
            && !rent.is_signer,
        GatewayError::UnexpectedOuterSigner
    );
    require!(
        pc20_mint.is_writable,
        GatewayError::AccountWritableFlagMismatch
    );
    require!(
        recipient_ata.is_writable,
        GatewayError::AccountWritableFlagMismatch
    );
    require!(
        associated_token_program.key() == spl_associated_token_account::ID,
        GatewayError::InvalidAccount
    );
    require!(
        rent.key() == anchor_lang::solana_program::sysvar::rent::id(),
        GatewayError::InvalidAccount
    );

    let state = Pc20State::try_deserialize(&mut &pc20_state.try_borrow_data()?[..])?;
    let source_asset =
        validate_pc20_state_fields(program_id, pc20_state.key, &state, pc20_mint.key())?;
    validate_pc20_mint_authority(pc20_mint, pc20_mint.key())?;

    let recipient_ata_lamports_before = recipient_ata.lamports();
    let recipient_ata_created = ensure_associated_token_account(
        &accounts.caller.to_account_info(),
        recipient_ata,
        &accounts.recipient.to_account_info(),
        pc20_mint,
        &accounts.system_program.to_account_info(),
        &token_program.to_account_info(),
        associated_token_program,
        rent,
    )?;
    let recipient_ata_lamports_paid = if recipient_ata_created {
        Rent::get()?
            .minimum_balance(SPL_TOKEN_ACCOUNT_LEN)
            .saturating_sub(recipient_ata_lamports_before)
    } else {
        0
    };
    let parsed_ata = parse_token_account(recipient_ata)?;
    require!(
        parsed_ata.owner == recipient && parsed_ata.mint == pc20_mint.key(),
        GatewayError::InvalidAccount
    );

    let (expected_mint, mint_bump) =
        Pubkey::find_program_address(&[PC20_MINT_SEED, source_asset.as_ref()], program_id);
    require!(
        expected_mint == pc20_mint.key(),
        GatewayError::InvalidPc20Mint
    );
    let mint_bump_bytes = [mint_bump];
    let mint_seeds = [PC20_MINT_SEED, source_asset.as_ref(), &mint_bump_bytes[..]];
    pda_mint_to(pc20_mint, recipient_ata, pc20_mint, amount, &mint_seeds)?;
    Ok(recipient_ata_lamports_paid)
}
