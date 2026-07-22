use crate::errors::GatewayError;
use crate::state::GatewayAccountMeta;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_pack::Pack;
use anchor_lang::solana_program::{
    instruction::{AccountMeta as SolanaAccountMeta, Instruction},
    program::invoke_signed,
};
use anchor_spl::token::spl_token;
use spl_token::state::Account as SplAccount;

/// Parse a token account and normalize unpack failures to the program's error surface.
pub fn parse_token_account(account: &AccountInfo) -> Result<SplAccount> {
    let data = account.try_borrow_data()?;
    SplAccount::unpack(&data).map_err(|_| error!(GatewayError::InvalidAccount))
}

/// Validate remaining_accounts match signed accounts.
/// CRITICAL: No account in remaining_accounts can have is_signer == true.
/// Only gateway PDAs (vault, cea_authority) become signers via invoke_signed.
pub fn validate_remaining_accounts(
    signed_accounts: &[GatewayAccountMeta],
    remaining: &[AccountInfo],
) -> Result<()> {
    require!(
        remaining.len() == signed_accounts.len(),
        GatewayError::AccountListLengthMismatch
    );

    for (signed, actual) in signed_accounts.iter().zip(remaining.iter()) {
        // Validate pubkey matches
        require!(
            actual.key == &signed.pubkey,
            GatewayError::AccountPubkeyMismatch
        );

        // Validate writable flag matches
        // Signed metadata requires the account to be writable -> actual must also be writable.
        // It's safe if actual is writable while signed metadata marks it read-only;
        // CPI metas are built from signed metadata, so the target instruction won't
        // gain extra write privileges.
        if signed.is_writable && !actual.is_writable {
            msg!(
                "Account writable mismatch: {} expected writable",
                signed.pubkey
            );
            return err!(GatewayError::AccountWritableFlagMismatch);
        }

        // CRITICAL: No outer signer allowed in target account list
        // cea_authority becomes signer only via invoke_signed, not here
        require!(!actual.is_signer, GatewayError::UnexpectedOuterSigner);
    }

    Ok(())
}

/// Invoke a signed CEA CPI using account metas already validated against remaining_accounts.
pub fn invoke_signed_gateway_instruction<'info>(
    target_program: Pubkey,
    signed_accounts: &[GatewayAccountMeta],
    instruction_data: &[u8],
    cea_key: Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[u8]],
) -> Result<()> {
    let cpi_metas: Vec<SolanaAccountMeta> = signed_accounts
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
        program_id: target_program,
        accounts: cpi_metas,
        data: instruction_data.to_vec(),
    };

    invoke_signed(&cpi_ix, remaining_accounts, &[signer_seeds])?;
    Ok(())
}
