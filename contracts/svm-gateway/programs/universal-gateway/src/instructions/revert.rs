use crate::instructions::tss::validate_message;
use crate::utils::{
    encode_u64_be, parse_token_account, pda_spl_transfer, pda_system_transfer,
    reimburse_relayer_from_fee_vault,
};
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak::hash;
use anchor_lang::solana_program::program::invoke_signed;
use anchor_spl::associated_token::{spl_associated_token_account, AssociatedToken};
use anchor_spl::token::{spl_token, Mint, Token, TokenAccount};

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

    /// Required on the legacy SPL path (create recipient ATA if missing). Anchor validates the
    /// program id when Some; on the native path the slot may be auto-populated by the client
    /// and is simply unused.
    pub associated_token_program: Option<Program<'info, AssociatedToken>>,

    /// Required on the legacy SPL path. Anchor validates the sysvar id when Some.
    pub rent: Option<Sysvar<'info, Rent>>,
}

pub fn revert_universal_tx(
    ctx: Context<RevertUniversalTx>,
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
    require!(revert_instruction.revert_recipient != Pubkey::default(), GatewayError::InvalidRecipient);
    require!(recipient == revert_instruction.revert_recipient, GatewayError::InvalidRecipient);
    let revert_msg_hash = hash(revert_instruction.revert_msg.as_slice()).to_bytes();

    let is_native = ctx.accounts.token_mint.is_none();

    // --- Account presence + cross-account consistency ---
    // Note: atp and rent are typed as `Option<Program<AssociatedToken>>` / `Option<Sysvar<Rent>>`
    // — Anchor validates the program id / sysvar id when Some, and the Anchor JS client
    // auto-populates these slots. We therefore don't gate on `is_none()` on the native path
    // (they may arrive as Some from auto-population and are simply unused).
    if is_native {
        require!(
            ctx.accounts.token_vault.is_none()
                && ctx.accounts.recipient_token_account.is_none()
                && ctx.accounts.token_program.is_none(),
            GatewayError::InvalidAccount
        );
    } else {
        // Legacy SPL: token_vault + recipient_token_account + token_program + atp + rent all required.
        // Recipient ATA mint/owner are validated below, after the create-if-missing step, so the
        // check works uniformly whether the ATA already existed or was created.
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

    // TSS message: instruction_id=3 || amount || [sub_tx_id, universal_tx_id, (mint,) recipient, gas_fee, revert_msg_hash]
    let recipient_bytes = recipient.to_bytes();
    let gas_fee_buf = encode_u64_be(gas_fee);
    if is_native {
        let additional: [&[u8]; 5] = [&sub_tx_id, &universal_tx_id, &recipient_bytes, &gas_fee_buf, &revert_msg_hash];
        validate_message(&mut ctx.accounts.tss_pda, 3, Some(amount), deadline, &additional, &message_hash, &signature, recovery_id)?;
    } else {
        let mint_bytes = ctx.accounts.token_mint.as_ref().unwrap().key().to_bytes();
        let additional: [&[u8]; 6] = [&sub_tx_id, &universal_tx_id, &mint_bytes, &recipient_bytes, &gas_fee_buf, &revert_msg_hash];
        validate_message(&mut ctx.accounts.tss_pda, 3, Some(amount), deadline, &additional, &message_hash, &signature, recovery_id)?;
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
    } else {
        // Legacy SPL: ensure recipient ATA exists (create-if-missing) before transferring.
        // Rent is folded into measured `reimbursement` below so the caller is reimbursed
        // atomically. Mirrors the inline create-if-missing pattern in `internal_withdraw`.
        let recipient_ta = ctx
            .accounts
            .recipient_token_account
            .as_ref()
            .unwrap()
            .to_account_info();
        let token_mint = ctx.accounts.token_mint.as_ref().unwrap();
        let mint_info = token_mint.to_account_info();
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

        let expected_recipient_ata = spl_associated_token_account::get_associated_token_address(
            &recipient,
            &token_mint.key(),
        );
        require!(
            recipient_ta.key() == expected_recipient_ata,
            GatewayError::InvalidAccount
        );

        let recipient_ata_lamports_before = recipient_ta.lamports();
        let ata_created = recipient_ta.data_is_empty();
        if ata_created {
            let create_ata_ix =
                spl_associated_token_account::instruction::create_associated_token_account(
                    &ctx.accounts.caller.key(),
                    &recipient,
                    &token_mint.key(),
                    &spl_token::ID,
                );
            invoke_signed(
                &create_ata_ix,
                &[
                    ctx.accounts.caller.to_account_info(),
                    recipient_ta.clone(),
                    ctx.accounts.recipient.to_account_info(),
                    mint_info.clone(),
                    ctx.accounts.system_program.to_account_info(),
                    token_program_info.clone(),
                    atp_info,
                    rent_info,
                ],
                &[],
            )?;
        }
        let ata_rent_paid = if ata_created {
            Rent::get()?
                .minimum_balance(SPL_TOKEN_ACCOUNT_LEN)
                .saturating_sub(recipient_ata_lamports_before)
        } else {
            0
        };

        // Post-create validation: matches the previous typed-slot invariants uniformly.
        let parsed = parse_token_account(&recipient_ta)?;
        require!(parsed.mint == token_mint.key(), GatewayError::InvalidMint);
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

    // The signed `gas_fee` is a ceiling; the on-chain program measures actual cost and
    // reimburses that. Delta stays in fee_vault instead of being silently overpaid.
    // Measured cost is uniform: signature fee + ExecutedSubTx rent + recipient ATA rent
    // when this call had to create it (0 for native and pre-existing SPL ATAs).
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
        token: ctx.accounts.token_mint.as_ref().map_or(Pubkey::default(), |m| m.key()),
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
