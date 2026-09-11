use crate::errors::GatewayError;
use crate::state::{FeeVault, VAULT_SEED};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{program::invoke_signed, system_instruction};
use anchor_spl::token::spl_token;

/// Transfer SOL from a PDA signer to a destination account.
pub fn pda_system_transfer<'info>(
    from: &AccountInfo<'info>,
    to: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    amount: u64,
    signer_seeds: &[&[u8]],
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }

    let transfer_ix = system_instruction::transfer(from.key, to.key, amount);
    invoke_signed(
        &transfer_ix,
        &[from.clone(), to.clone(), system_program.clone()],
        &[signer_seeds],
    )?;

    Ok(())
}

/// Transfer SPL tokens from a PDA signer to a destination token account.
pub fn pda_spl_transfer<'info>(
    from: &AccountInfo<'info>,
    to: &AccountInfo<'info>,
    authority: &AccountInfo<'info>,
    amount: u64,
    signer_seeds: &[&[u8]],
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }

    let transfer_ix = spl_token::instruction::transfer(
        &spl_token::ID,
        from.key,
        to.key,
        authority.key,
        &[],
        amount,
    )?;

    invoke_signed(
        &transfer_ix,
        &[from.clone(), to.clone(), authority.clone()],
        &[signer_seeds],
    )?;

    Ok(())
}

/// Reimburse relayer gas from the fee vault while preserving rent exemption.
/// Caller is responsible for emitting `InboundFeeReimbursed` (event_cpi requires handler ctx).
pub fn reimburse_relayer_from_fee_vault<'info>(
    fee_vault: &Account<'info, FeeVault>,
    caller: &AccountInfo<'info>,
    gas_fee: u64,
) -> Result<()> {
    if gas_fee == 0 {
        return Ok(());
    }

    let fee_vault_info = fee_vault.to_account_info();
    let min_balance = Rent::get()?.minimum_balance(FeeVault::LEN);
    let available = fee_vault_info
        .lamports()
        .checked_sub(min_balance)
        .ok_or(error!(GatewayError::InsufficientFeePool))?;
    require!(available >= gas_fee, GatewayError::InsufficientFeePool);

    **fee_vault_info.try_borrow_mut_lamports()? -= gas_fee;
    **caller.try_borrow_mut_lamports()? += gas_fee;

    Ok(())
}

/// Transfer gas fee from vault to caller (relayer reimbursement)
/// Used by finalize_universal_tx and revert functions
pub fn transfer_gas_fee_to_caller<'info>(
    vault_sol: &AccountInfo<'info>,
    caller: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    gas_fee: u64,
    vault_bump: u8,
) -> Result<()> {
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];
    pda_system_transfer(vault_sol, caller, system_program, gas_fee, vault_seeds)
}
