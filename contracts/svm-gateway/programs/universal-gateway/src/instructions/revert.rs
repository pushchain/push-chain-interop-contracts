use crate::instructions::tss::validate_message;
use crate::utils::{encode_u64_be, pda_spl_transfer, pda_system_transfer, reimburse_relayer_from_fee_vault};
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak::hash;
use anchor_spl::token::{Mint, Token, TokenAccount};

// =========================
//   TSS REVERT FUNCTION
// =========================
// Single entrypoint handles both SOL (token_mint = None) and SPL (token_mint = Some).
//
// TSS message format (instruction_id = 3 for both modes):
//   SOL: amount || [sub_tx_id, universal_tx_id, recipient, gas_fee, revert_msg_hash]
//   SPL: amount || [sub_tx_id, universal_tx_id, mint, recipient, gas_fee, revert_msg_hash]

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

    /// Recipient token account — must be owned by recipient and match token_mint.
    #[account(mut)]
    pub recipient_token_account: Option<Account<'info, TokenAccount>>,

    pub token_mint: Option<Account<'info, Mint>>,

    pub token_program: Option<Program<'info, Token>>,
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
    if is_native {
        require!(
            ctx.accounts.token_vault.is_none()
                && ctx.accounts.recipient_token_account.is_none()
                && ctx.accounts.token_program.is_none(),
            GatewayError::InvalidAccount
        );
    } else {
        let token_vault = ctx.accounts.token_vault.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
        let recipient_ta = ctx.accounts.recipient_token_account.as_ref().ok_or(error!(GatewayError::InvalidAccount))?;
        let mint_key = ctx.accounts.token_mint.as_ref().unwrap().key(); // Safe: !is_native ⟹ token_mint.is_some()
        require!(token_vault.mint == mint_key, GatewayError::InvalidMint);
        require!(recipient_ta.mint == mint_key, GatewayError::InvalidMint);
        require!(recipient_ta.owner == recipient, GatewayError::InvalidRecipient);
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

    if is_native {
        pda_system_transfer(
            &ctx.accounts.vault.to_account_info(),
            &ctx.accounts.recipient.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            amount,
            seeds,
        )?;
    } else {
        pda_spl_transfer(
            &ctx.accounts.token_vault.as_ref().unwrap().to_account_info(),
            &ctx.accounts.recipient_token_account.as_ref().unwrap().to_account_info(),
            &ctx.accounts.vault.to_account_info(),
            amount,
            seeds,
        )?;
    }

    emit!(crate::state::RevertUniversalTx {
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
        sub_tx_id,
        gas_fee,
    )?;

    Ok(())
}
