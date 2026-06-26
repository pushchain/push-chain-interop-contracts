use crate::errors::GatewayError;
use crate::instructions::execute::FinalizeUniversalTx;
use crate::state::{TxType, UniversalTx};
use crate::utils::{
    parse_token_account, pda_spl_transfer, pda_system_transfer, validate_token_and_consume_rate_limit,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hash;
use anchor_spl::associated_token::spl_associated_token_account;

/// Transfer funds from CEA to recipient (withdraw mode).
/// SOL: system transfer CEA -> recipient.
/// SPL: token transfer CEA ATA -> recipient ATA.
pub fn internal_withdraw(
    ctx: &Context<FinalizeUniversalTx>,
    amount: u64,
    token: Pubkey,
    cea_seeds: &[&[u8]],
) -> Result<()> {
    let recipient = ctx
        .accounts
        .recipient
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let target = recipient.key();
    let is_native = token == Pubkey::default();

    // If recipient == CEA, vault->CEA already completed in finalize flow.
    if target == ctx.accounts.cea_authority.key() {
        return Ok(());
    }

    if is_native {
        pda_system_transfer(
            &ctx.accounts.cea_authority.to_account_info(),
            &recipient.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            amount,
            cea_seeds,
        )?;
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

        let expected_recipient_ata =
            spl_associated_token_account::get_associated_token_address(&target, &token_mint.key());
        require!(recipient_ata.key() == expected_recipient_ata, GatewayError::InvalidAccount);

        pda_spl_transfer(
            &cea_ata.to_account_info(),
            &recipient_ata.to_account_info(),
            &ctx.accounts.cea_authority.to_account_info(),
            amount,
            cea_seeds,
        )?;
    }

    Ok(())
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

    emit!(UniversalTx {
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
