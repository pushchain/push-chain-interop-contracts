use crate::errors::GatewayError;
use crate::state::{FeeVault, InboundFeeReimbursed, VAULT_SEED};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    program::{invoke, invoke_signed},
    system_instruction, system_program,
};
use anchor_spl::associated_token::spl_associated_token_account;
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
pub fn reimburse_relayer_from_fee_vault<'info>(
    fee_vault: &Account<'info, FeeVault>,
    caller: &AccountInfo<'info>,
    sub_tx_id: [u8; 32],
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

    emit!(InboundFeeReimbursed {
        sub_tx_id,
        relayer: *caller.key,
        amount_lamports: gas_fee,
    });

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

pub fn create_pda_account<'info>(
    account: &AccountInfo<'info>,
    payer: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    owner: &Pubkey,
    space: usize,
    lamports: u64,
    signer_seeds: &[&[u8]],
    invalid_account_error: impl Fn() -> Error,
) -> Result<u64> {
    let lamports_before = account.lamports();
    if account.lamports() > 0 {
        if account.owner != &system_program::ID {
            return Err(invalid_account_error());
        }

        let required_lamports = lamports.saturating_sub(account.lamports());
        if required_lamports > 0 {
            invoke(
                &system_instruction::transfer(payer.key, account.key, required_lamports),
                &[payer.clone(), account.clone(), system_program.clone()],
            )?;
        }

        invoke_signed(
            &system_instruction::allocate(account.key, space as u64),
            &[account.clone(), system_program.clone()],
            &[signer_seeds],
        )?;
        invoke_signed(
            &system_instruction::assign(account.key, owner),
            &[account.clone(), system_program.clone()],
            &[signer_seeds],
        )?;
    } else {
        invoke_signed(
            &system_instruction::create_account(
                payer.key,
                account.key,
                lamports,
                space as u64,
                owner,
            ),
            &[payer.clone(), account.clone(), system_program.clone()],
            &[signer_seeds],
        )?;
    }

    if account.owner != owner {
        return Err(invalid_account_error());
    }
    Ok(lamports.saturating_sub(lamports_before))
}

/// Ensure the supplied account is the canonical ATA and create it when missing.
pub fn ensure_associated_token_account<'info>(
    payer: &AccountInfo<'info>,
    ata: &AccountInfo<'info>,
    owner: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    token_program: &AccountInfo<'info>,
    associated_token_program: &AccountInfo<'info>,
    rent: &AccountInfo<'info>,
) -> Result<bool> {
    let expected_ata =
        spl_associated_token_account::get_associated_token_address(owner.key, mint.key);
    require!(ata.key() == expected_ata, GatewayError::InvalidAccount);

    let ata_created = ata.data_is_empty();
    if ata_created {
        let create_ata_ix =
            spl_associated_token_account::instruction::create_associated_token_account(
                payer.key,
                owner.key,
                mint.key,
                &spl_token::ID,
            );
        invoke_signed(
            &create_ata_ix,
            &[
                payer.clone(),
                ata.clone(),
                owner.clone(),
                mint.clone(),
                system_program.clone(),
                token_program.clone(),
                associated_token_program.clone(),
                rent.clone(),
            ],
            &[],
        )?;
    }

    Ok(ata_created)
}

/// Mint SPL tokens from a PDA mint authority.
pub fn pda_mint_to<'info>(
    mint: &AccountInfo<'info>,
    destination: &AccountInfo<'info>,
    authority: &AccountInfo<'info>,
    amount: u64,
    signer_seeds: &[&[u8]],
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }

    let mint_ix = spl_token::instruction::mint_to(
        &spl_token::ID,
        mint.key,
        destination.key,
        authority.key,
        &[],
        amount,
    )?;

    invoke_signed(
        &mint_ix,
        &[mint.clone(), destination.clone(), authority.clone()],
        &[signer_seeds],
    )?;

    Ok(())
}

/// Burn SPL tokens from a signer-owned token account.
pub fn spl_burn<'info>(
    mint: &AccountInfo<'info>,
    source: &AccountInfo<'info>,
    authority: &AccountInfo<'info>,
    amount: u64,
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }

    let burn_ix = spl_token::instruction::burn(
        &spl_token::ID,
        source.key,
        mint.key,
        authority.key,
        &[],
        amount,
    )?;

    anchor_lang::solana_program::program::invoke(
        &burn_ix,
        &[source.clone(), mint.clone(), authority.clone()],
    )?;

    Ok(())
}

/// Burn SPL tokens from a PDA-owned token account.
pub fn pda_burn<'info>(
    mint: &AccountInfo<'info>,
    source: &AccountInfo<'info>,
    authority: &AccountInfo<'info>,
    amount: u64,
    signer_seeds: &[&[u8]],
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }

    let burn_ix = spl_token::instruction::burn(
        &spl_token::ID,
        source.key,
        mint.key,
        authority.key,
        &[],
        amount,
    )?;

    invoke_signed(
        &burn_ix,
        &[source.clone(), mint.clone(), authority.clone()],
        &[signer_seeds],
    )?;

    Ok(())
}
