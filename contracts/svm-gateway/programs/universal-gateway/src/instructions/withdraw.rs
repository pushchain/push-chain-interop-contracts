use crate::errors::GatewayError;
use crate::instructions::execute::FinalizeUniversalTx;
use crate::state::{TxType, UniversalTx};
use crate::utils::{
    parse_token_account, pda_spl_transfer, pda_system_transfer, validate_token_and_consume_rate_limit,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hash;
use anchor_lang::solana_program::program::invoke_signed;
use anchor_spl::associated_token::spl_associated_token_account;
use anchor_spl::token::spl_token;

/// Transfer funds from CEA to recipient (withdraw mode).
/// SOL: system transfer CEA -> recipient.
/// SPL: token transfer CEA ATA -> recipient ATA. Returns `true` when this call
/// had to create the recipient ATA (caller pays rent; parent settles it in
/// `gas_used`).
pub fn internal_withdraw(
    ctx: &Context<FinalizeUniversalTx>,
    amount: u64,
    token: Pubkey,
    cea_seeds: &[&[u8]],
) -> Result<bool> {
    let recipient = ctx
        .accounts
        .recipient
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let target = recipient.key();
    let is_native = token == Pubkey::default();

    // If recipient == CEA, vault->CEA already completed in finalize flow.
    if target == ctx.accounts.cea_authority.key() {
        return Ok(false);
    }

    if is_native {
        pda_system_transfer(
            &ctx.accounts.cea_authority.to_account_info(),
            &recipient.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            amount,
            cea_seeds,
        )?;
        return Ok(false);
    } else {
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let recipient_ata = ctx
            .accounts
            .recipient_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_program = ctx
            .accounts
            .token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let rent = ctx
            .accounts
            .rent
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let ata_program = ctx
            .accounts
            .associated_token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        let expected_recipient_ata =
            spl_associated_token_account::get_associated_token_address(&target, &token_mint.key());
        require!(recipient_ata.key() == expected_recipient_ata, GatewayError::InvalidAccount);

        // Create recipient ATA if missing; caller pays rent (mirrors CEA ATA flow).
        // The `recipient_ata_created` flag is propagated up so `settle_relayer_gas_cost`
        // can fold the ATA rent into `gas_used` and reimburse the caller.
        let recipient_ata_info = recipient_ata.to_account_info();
        let recipient_ata_created = recipient_ata_info.data_is_empty();
        if recipient_ata_created {
            let create_ata_ix =
                spl_associated_token_account::instruction::create_associated_token_account(
                    &ctx.accounts.caller.key(),
                    &target,
                    &token_mint.key(),
                    &spl_token::ID,
                );
            invoke_signed(
                &create_ata_ix,
                &[
                    ctx.accounts.caller.to_account_info(),
                    recipient_ata_info.clone(),
                    recipient.to_account_info(),
                    token_mint.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                    token_program.to_account_info(),
                    ata_program.to_account_info(),
                    rent.to_account_info(),
                ],
                &[],
            )?;
        }

        // Validate mint + owner post-create (blocks a caller passing a same-address
        // account that happens to be a token account for a different mint/owner).
        let parsed = parse_token_account(&recipient_ata_info)?;
        require!(parsed.mint == token_mint.key(), GatewayError::InvalidMint);
        require!(parsed.owner == target, GatewayError::InvalidOwner);

        pda_spl_transfer(
            &cea_ata.to_account_info(),
            &recipient_ata_info,
            &ctx.accounts.cea_authority.to_account_info(),
            amount,
            cea_seeds,
        )?;
        Ok(recipient_ata_created)
    }
}

/// Args for the CEA -> UEA inbound route (target_program == gateway itself).
/// Layout: [8-byte discriminator][borsh(SendUniversalTxToUEAArgs)].
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct SendUniversalTxToUEAArgs {
    pub token: Pubkey,
    pub amount: u64,
    pub payload: Vec<u8>,
    pub revert_recipient: Pubkey,
}

/// CEA -> UEA inbound route: mirrors the inbound FUNDS deposit flow.
/// Called when target_program == gateway itself.
pub fn send_universal_tx_to_uea(
    ctx: &mut Context<FinalizeUniversalTx>,
    push_account: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<()> {
    let token = if let Some(mint) = ctx.accounts.mint.as_ref() {
        mint.key()
    } else {
        Pubkey::default()
    };

    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    let discr = &ix_data[..8];
    let expected = hash(b"global:send_universal_tx_to_uea").to_bytes();
    require!(discr == &expected[..8], GatewayError::InvalidInput);

    let args = SendUniversalTxToUEAArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;

    require!(args.token == token, GatewayError::InvalidMint);
    // At least one of amount or payload must be present
    require!(
        args.amount > 0 || !args.payload.is_empty(),
        GatewayError::InvalidInput
    );
    require!(
        args.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    let withdraw_amount = args.amount;

    if withdraw_amount > 0 {
        let rl_config = ctx
            .accounts
            .rate_limit_config
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_rate_limit = ctx
            .accounts
            .token_rate_limit
            .as_mut()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        validate_token_and_consume_rate_limit(
            token_rate_limit,
            token,
            withdraw_amount as u128,
            rl_config,
        )?;

        if token == Pubkey::default() {
            require!(
                withdraw_amount <= ctx.accounts.cea_authority.lamports(),
                GatewayError::InsufficientBalance
            );
            pda_system_transfer(
                &ctx.accounts.cea_authority.to_account_info(),
                &ctx.accounts.vault_sol.to_account_info(),
                &ctx.accounts.system_program.to_account_info(),
                withdraw_amount,
                cea_seeds,
            )?;
        } else {
            let cea_ata = ctx
                .accounts
                .cea_ata
                .as_ref()
                .ok_or(error!(GatewayError::InvalidAccount))?;
            let vault_ata = ctx
                .accounts
                .vault_ata
                .as_ref()
                .ok_or(error!(GatewayError::InvalidAccount))?;
            let parsed_cea_ata = parse_token_account(&cea_ata.to_account_info())?;
            require!(
                withdraw_amount <= parsed_cea_ata.amount,
                GatewayError::InsufficientBalance
            );
            pda_spl_transfer(
                &cea_ata.to_account_info(),
                &vault_ata.to_account_info(),
                &ctx.accounts.cea_authority.to_account_info(),
                withdraw_amount,
                cea_seeds,
            )?;
        }
    }

    let tx_type = match (withdraw_amount > 0, args.payload.is_empty()) {
        (true, true) => TxType::Funds,
        (true, false) => TxType::FundsAndPayload,
        (false, _) => TxType::GasAndPayload, // payload-only, no funds transferred
    };

    emit_cpi!(UniversalTx {
        sender: ctx.accounts.cea_authority.key(),
        recipient: push_account,
        token,
        amount: withdraw_amount,
        payload: args.payload,
        revert_recipient: args.revert_recipient,
        tx_type,
        signature_data: vec![],
        from_cea: true,
    });

    Ok(())
}
