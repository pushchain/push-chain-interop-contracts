use crate::errors::GatewayError;
use crate::instructions::execute::FinalizeUniversalTx;
use crate::instructions::tss::validate_message;
use crate::state::{
    ExecutedSubTx, GatewayAccountMeta, Pc20State, TxType, UniversalTx, UniversalTxFinalized,
    CEA_SEED, PC20_MINT_SEED, PC20_SELECTOR, PC20_STATE_SEED,
};
use crate::utils::{
    create_pda_account, encode_u64_be, ensure_associated_token_account,
    invoke_signed_gateway_instruction, parse_token_account, pda_burn, pda_mint_to,
    serialize_ix_data, serialize_string, transfer_gas_fee_to_caller, validate_remaining_accounts,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{hash::hash as solana_hash, program::invoke, program_pack::Pack};
use anchor_spl::associated_token::spl_associated_token_account;
use anchor_spl::token::spl_token;

const SIGNATURE_FEE_LAMPORTS: u64 = 5_000;
const SPL_TOKEN_ACCOUNT_LEN: usize = 165;
const SPL_MINT_ACCOUNT_LEN: usize = spl_token::state::Mint::LEN;
pub const PC20_FINALIZE_INSTRUCTION_ID: u8 = 5;

struct DecodedExecutePayload {
    accounts: Vec<GatewayAccountMeta>,
    ix_data: Vec<u8>,
    instruction_id: u8,
    target_program: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct Pc20ExportIxData {
    pub source_asset: [u8; 20],
    pub name: String,
    pub symbol: String,
    pub decimals: u8,
    pub user_data: Vec<u8>,
}

struct Pc20FinalizeParams {
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    source_asset: [u8; 20],
    amount: u64,
    push_account: [u8; 20],
    recipient: Pubkey,
    name: String,
    symbol: String,
    decimals: u8,
    user_data: Vec<u8>,
    ix_data: Vec<u8>,
    gas_fee: u64,
    deadline: i64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
}

struct Pc20FinalizeAccountSet<'a, 'info> {
    program_id: &'a Pubkey,
    caller: AccountInfo<'info>,
    vault_sol: AccountInfo<'info>,
    pc20_mint: AccountInfo<'info>,
    pc20_state: AccountInfo<'info>,
    recipient: AccountInfo<'info>,
    recipient_ata: Option<AccountInfo<'info>>,
    cea_authority: AccountInfo<'info>,
    cea_ata: Option<AccountInfo<'info>>,
    tss_pda: &'a mut Account<'info, crate::state::TssPda>,
    system_program: AccountInfo<'info>,
    token_program: AccountInfo<'info>,
    associated_token_program: AccountInfo<'info>,
    rent: AccountInfo<'info>,
    destination_program: AccountInfo<'info>,
    remaining_accounts: &'a [AccountInfo<'info>],
    vault_bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
struct SendPc20UniversalTxArgs {
    pub sub_tx_id: [u8; 32],
    pub source_asset: [u8; 20],
    pub amount: u64,
    pub recipient: [u8; 20],
    pub payload: Vec<u8>,
    pub revert_recipient: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
struct SendUniversalTxIxArgs {
    pub req: crate::state::UniversalTxRequest,
    pub native_amount: u64,
}

struct ParsedPc20BurnArgs {
    pub source_asset: Option<[u8; 20]>,
    pub wrapped_mint: Option<Pubkey>,
    pub amount: u64,
    pub recipient: [u8; 20],
    pub payload: Vec<u8>,
    pub revert_recipient: Pubkey,
    pub signature_data: Vec<u8>,
}

pub fn pc20_burn_tx_type(amount: u64) -> Result<TxType> {
    require!(amount > 0, GatewayError::InvalidAmount);
    Ok(TxType::FundsAndPayload)
}

pub fn parse_pc20_export_ix_data(ix_data: &[u8]) -> Result<Option<Pc20ExportIxData>> {
    if ix_data.len() < PC20_SELECTOR.len()
        || &ix_data[..PC20_SELECTOR.len()] != PC20_SELECTOR.as_ref()
    {
        return Ok(None);
    }

    Pc20ExportIxData::try_from_slice(&ix_data[PC20_SELECTOR.len()..])
        .map(Some)
        .map_err(|_| error!(GatewayError::InvalidInput))
}

pub fn handle_pc20_export_from_universal<'a, 'b, 'c, 'info>(
    ctx: &mut Context<'a, 'b, 'c, 'info, FinalizeUniversalTx<'info>>,
    instruction_id: u8,
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    push_account: [u8; 20],
    writable_flags: Vec<u8>,
    ix_data: Vec<u8>,
    export_args: Pc20ExportIxData,
    store_upload_fee_lamports: u64,
    store_refund_recipient: Option<&AccountInfo<'info>>,
    gas_fee: u64,
    deadline: i64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(
        instruction_id == PC20_FINALIZE_INSTRUCTION_ID,
        GatewayError::InvalidInstruction
    );
    require!(writable_flags.is_empty(), GatewayError::InvalidInput);
    require!(
        ctx.accounts.vault_ata.is_none()
            && ctx.accounts.mint.is_none()
            && ctx.accounts.recipient_ata.is_none()
            && ctx.accounts.rate_limit_config.is_none()
            && ctx.accounts.token_rate_limit.is_none(),
        GatewayError::InvalidAccount
    );

    let recipient = ctx
        .accounts
        .recipient
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?
        .to_account_info();
    let token_program = ctx
        .accounts
        .token_program
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?
        .to_account_info();
    let associated_token_program = ctx
        .accounts
        .associated_token_program
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?
        .to_account_info();
    let rent = ctx
        .accounts
        .rent
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?
        .to_account_info();
    let has_payload = !export_args.user_data.is_empty();
    let control_accounts_len = if has_payload { 2 } else { 3 };
    require!(
        ctx.remaining_accounts.len() >= control_accounts_len,
        GatewayError::AccountListLengthMismatch
    );

    let pc20_state = ctx.remaining_accounts[0].clone();
    let pc20_mint = ctx.remaining_accounts[1].clone();
    let recipient_ata = if has_payload {
        None
    } else {
        Some(ctx.remaining_accounts[2].clone())
    };
    let payload_remaining_accounts = &ctx.remaining_accounts[control_accounts_len..];
    if !has_payload {
        require!(
            payload_remaining_accounts.is_empty(),
            GatewayError::AccountListLengthMismatch
        );
    }

    let accounts = Pc20FinalizeAccountSet {
        program_id: ctx.program_id,
        caller: ctx.accounts.caller.to_account_info(),
        vault_sol: ctx.accounts.vault_sol.to_account_info(),
        pc20_mint,
        pc20_state,
        recipient: recipient.clone(),
        recipient_ata,
        cea_authority: ctx.accounts.cea_authority.to_account_info(),
        cea_ata: ctx
            .accounts
            .cea_ata
            .as_ref()
            .map(|account| account.to_account_info()),
        tss_pda: &mut ctx.accounts.tss_pda,
        system_program: ctx.accounts.system_program.to_account_info(),
        token_program,
        associated_token_program,
        rent,
        destination_program: ctx.accounts.destination_program.to_account_info(),
        remaining_accounts: payload_remaining_accounts,
        vault_bump: ctx.accounts.config.vault_bump,
    };
    let params = Pc20FinalizeParams {
        sub_tx_id,
        universal_tx_id,
        source_asset: export_args.source_asset,
        amount,
        push_account,
        recipient: *recipient.key,
        name: export_args.name,
        symbol: export_args.symbol,
        decimals: export_args.decimals,
        user_data: export_args.user_data,
        ix_data,
        gas_fee,
        deadline,
        signature,
        recovery_id,
        message_hash,
    };
    process_pc20_export(
        accounts,
        params,
        store_upload_fee_lamports,
        store_refund_recipient,
    )
}

pub fn send_pc20_universal_tx_from_finalize_cea<'info>(
    program_id: &Pubkey,
    cea_authority: &AccountInfo<'info>,
    remaining_accounts: &[AccountInfo<'info>],
    sub_tx_id: [u8; 32],
    push_account: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<()> {
    let args = parse_pc20_burn_ix(sub_tx_id, ix_data)?;
    let tx_type = pc20_burn_tx_type(args.amount)?;
    require!(push_account != [0u8; 20], GatewayError::ZeroAddress);
    require!(
        args.recipient == push_account,
        GatewayError::InvalidRecipient
    );
    require!(
        args.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    let route_accounts = parse_pc20_cea_burn_accounts(
        program_id,
        cea_authority,
        remaining_accounts,
        args.source_asset,
        args.wrapped_mint,
    )?;

    pda_burn(
        &route_accounts.pc20_mint,
        &route_accounts.cea_ata,
        cea_authority,
        args.amount,
        cea_seeds,
    )?;

    emit!(UniversalTx {
        sender: *cea_authority.key,
        recipient: args.recipient,
        token: *route_accounts.pc20_mint.key,
        amount: args.amount,
        payload: pc20_prefixed_payload(route_accounts.source_asset, &args.payload),
        revert_recipient: args.revert_recipient,
        tx_type,
        signature_data: args.signature_data.clone(),
        from_cea: true,
    });

    Ok(())
}

fn parse_pc20_burn_ix(sub_tx_id: [u8; 32], ix_data: &[u8]) -> Result<ParsedPc20BurnArgs> {
    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    if is_send_pc20_universal_tx_ix(ix_data) {
        let args = SendPc20UniversalTxArgs::try_from_slice(&ix_data[8..])
            .map_err(|_| error!(GatewayError::InvalidInput))?;
        require!(args.sub_tx_id == sub_tx_id, GatewayError::InvalidInput);
        return Ok(ParsedPc20BurnArgs {
            source_asset: Some(args.source_asset),
            wrapped_mint: None,
            amount: args.amount,
            recipient: args.recipient,
            payload: args.payload,
            revert_recipient: args.revert_recipient,
            signature_data: vec![],
        });
    }

    if is_send_universal_tx_ix(ix_data) {
        let args = SendUniversalTxIxArgs::try_from_slice(&ix_data[8..])
            .map_err(|_| error!(GatewayError::InvalidInput))?;
        require!(args.native_amount == 0, GatewayError::InvalidAmount);
        return Ok(ParsedPc20BurnArgs {
            source_asset: None,
            wrapped_mint: Some(args.req.token),
            amount: args.req.amount,
            recipient: args.req.recipient,
            payload: args.req.payload,
            revert_recipient: args.req.revert_recipient,
            signature_data: args.req.signature_data,
        });
    }

    err!(GatewayError::InvalidInput)
}

fn process_pc20_export<'a, 'info>(
    accounts: Pc20FinalizeAccountSet<'a, 'info>,
    params: Pc20FinalizeParams,
    store_upload_fee_lamports: u64,
    store_refund_recipient: Option<&AccountInfo<'info>>,
) -> Result<()> {
    require!(params.amount > 0, GatewayError::InvalidAmount);
    require!(
        params.recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        *accounts.recipient.key == params.recipient,
        GatewayError::InvalidRecipient
    );
    require!(params.push_account != [0u8; 20], GatewayError::ZeroAddress);
    require!(params.source_asset != [0u8; 20], GatewayError::ZeroAddress);
    require!(
        accounts.token_program.key() == spl_token::ID,
        GatewayError::InvalidAccount
    );
    require!(
        accounts.associated_token_program.key() == spl_associated_token_account::ID,
        GatewayError::InvalidAccount
    );
    require!(
        accounts.rent.key() == anchor_lang::solana_program::sysvar::rent::id(),
        GatewayError::InvalidAccount
    );

    let (expected_mint, mint_bump) = Pubkey::find_program_address(
        &[PC20_MINT_SEED, params.source_asset.as_ref()],
        accounts.program_id,
    );
    require!(
        accounts.pc20_mint.key() == expected_mint,
        GatewayError::InvalidPc20Mint
    );
    let (expected_cea, cea_bump) = Pubkey::find_program_address(
        &[CEA_SEED, params.push_account.as_ref()],
        accounts.program_id,
    );
    require!(
        accounts.cea_authority.key() == expected_cea,
        GatewayError::InvalidAccount
    );

    let mint_created = accounts.pc20_mint.data_is_empty();
    let mint_lamports_paid = if mint_created {
        let lamports_paid = create_pc20_mint(
            &accounts.caller,
            &accounts.pc20_mint,
            &accounts.system_program,
            &accounts.rent,
            params.decimals,
            &params.source_asset,
            mint_bump,
        )?;
        validate_pc20_mint(
            &accounts.pc20_mint,
            *accounts.pc20_mint.key,
            params.decimals,
        )?;
        lamports_paid
    } else {
        validate_pc20_mint_authority(&accounts.pc20_mint, *accounts.pc20_mint.key)?;
        0
    };
    let (_pc20_state_created, pc20_state_lamports_paid) = create_or_validate_pc20_state(
        accounts.program_id,
        &accounts.caller,
        &accounts.pc20_mint,
        &accounts.pc20_state,
        &accounts.system_program,
        params.source_asset,
        params.decimals,
    )?;

    let decoded_payload = if params.user_data.is_empty() {
        None
    } else {
        let payload = decode_execute_payload(&params.user_data)?;
        require!(
            payload.instruction_id == 2,
            GatewayError::InvalidInstruction
        );
        require!(
            payload.target_program == *accounts.destination_program.key,
            GatewayError::InvalidProgram
        );
        require!(
            accounts.destination_program.executable,
            GatewayError::InvalidProgram
        );
        validate_remaining_accounts(&payload.accounts, accounts.remaining_accounts)?;
        Some(payload)
    };

    build_and_validate_pc20_finalize_tss(
        accounts.tss_pda,
        params.universal_tx_id,
        params.sub_tx_id,
        params.source_asset,
        params.push_account,
        params.recipient,
        &params.name,
        &params.symbol,
        params.decimals,
        params.gas_fee,
        params.amount,
        if params.user_data.is_empty() {
            None
        } else {
            Some(params.user_data.as_slice())
        },
        params.deadline,
        &params.message_hash,
        &params.signature,
        params.recovery_id,
    )?;

    let (
        recipient_ata_created,
        recipient_ata_lamports_paid,
        cea_ata_created,
        cea_ata_lamports_paid,
        mint_destination,
    ) = if decoded_payload.is_some() {
            let cea_ata = accounts
                .cea_ata
                .as_ref()
                .ok_or(error!(GatewayError::InvalidAccount))?;
            let cea_ata_lamports_before = cea_ata.lamports();
            let cea_ata_created = ensure_associated_token_account(
                &accounts.caller,
                cea_ata,
                &accounts.cea_authority,
                &accounts.pc20_mint,
                &accounts.system_program,
                &accounts.token_program,
                &accounts.associated_token_program,
                &accounts.rent,
            )?;
            let parsed_ata = parse_token_account(cea_ata)?;
            require!(
                parsed_ata.owner == *accounts.cea_authority.key
                    && parsed_ata.mint == *accounts.pc20_mint.key,
                GatewayError::InvalidAccount
            );
            let cea_ata_lamports_paid = if cea_ata_created {
                Rent::get()?
                    .minimum_balance(SPL_TOKEN_ACCOUNT_LEN)
                    .saturating_sub(cea_ata_lamports_before)
            } else {
                0
            };
        (
            false,
            0,
            cea_ata_created,
            cea_ata_lamports_paid,
            cea_ata.clone(),
        )
    } else {
            let recipient_ata = accounts
                .recipient_ata
                .as_ref()
                .ok_or(error!(GatewayError::InvalidAccount))?;
            let recipient_ata_lamports_before = recipient_ata.lamports();
            let recipient_ata_created = ensure_associated_token_account(
                &accounts.caller,
                recipient_ata,
                &accounts.recipient,
                &accounts.pc20_mint,
                &accounts.system_program,
                &accounts.token_program,
                &accounts.associated_token_program,
                &accounts.rent,
            )?;
            let parsed_ata = parse_token_account(recipient_ata)?;
            require!(
                parsed_ata.owner == *accounts.recipient.key
                    && parsed_ata.mint == *accounts.pc20_mint.key,
                GatewayError::InvalidAccount
            );
            let recipient_ata_lamports_paid = if recipient_ata_created {
                Rent::get()?
                    .minimum_balance(SPL_TOKEN_ACCOUNT_LEN)
                    .saturating_sub(recipient_ata_lamports_before)
            } else {
                0
            };
        (
            recipient_ata_created,
            recipient_ata_lamports_paid,
            false,
            0,
            recipient_ata.clone(),
        )
    };

    let mint_bump_bytes = [mint_bump];
    let mint_seeds = [
        PC20_MINT_SEED,
        params.source_asset.as_ref(),
        &mint_bump_bytes[..],
    ];
    pda_mint_to(
        &accounts.pc20_mint,
        &mint_destination,
        &accounts.pc20_mint,
        params.amount,
        &mint_seeds,
    )?;

    if let Some(payload) = decoded_payload.as_ref() {
        dispatch_pc20_payload(&accounts, payload, params.push_account, cea_bump)?;
    }

    let (gas_used, gas_to_refund) = settle_pc20_finalize_gas(
        &accounts,
        params.gas_fee,
        mint_lamports_paid,
        pc20_state_lamports_paid,
        recipient_ata_lamports_paid,
        cea_ata_lamports_paid,
        store_upload_fee_lamports,
        store_refund_recipient,
    )?;

    emit!(UniversalTxFinalized {
        sub_tx_id: params.sub_tx_id,
        universal_tx_id: params.universal_tx_id,
        gas_fee: params.gas_fee,
        gas_used,
        gas_to_refund,
        ata_created: recipient_ata_created || cea_ata_created,
        push_account: params.push_account,
        target: *accounts.destination_program.key,
        token: *accounts.pc20_mint.key,
        amount: params.amount,
        payload: params.ix_data,
    });

    Ok(())
}

fn create_pc20_mint<'info>(
    caller: &AccountInfo<'info>,
    pc20_mint: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    rent: &AccountInfo<'info>,
    decimals: u8,
    source_asset: &[u8; 20],
    mint_bump: u8,
) -> Result<u64> {
    let mint_rent = Rent::get()?.minimum_balance(SPL_MINT_ACCOUNT_LEN);
    let mint_bump_bytes = [mint_bump];
    let mint_seeds = [PC20_MINT_SEED, source_asset.as_ref(), &mint_bump_bytes[..]];
    let lamports_paid = create_pda_account(
        pc20_mint,
        caller,
        system_program,
        &spl_token::ID,
        SPL_MINT_ACCOUNT_LEN,
        mint_rent.max(1),
        &mint_seeds,
        || error!(GatewayError::InvalidPc20Mint),
    )?;

    let init_mint_ix = spl_token::instruction::initialize_mint(
        &spl_token::ID,
        pc20_mint.key,
        pc20_mint.key,
        None,
        decimals,
    )?;
    invoke(&init_mint_ix, &[pc20_mint.clone(), rent.clone()])?;

    Ok(lamports_paid)
}

fn create_or_validate_pc20_state<'info>(
    program_id: &Pubkey,
    caller: &AccountInfo<'info>,
    pc20_mint: &AccountInfo<'info>,
    pc20_state: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    source_asset: [u8; 20],
    decimals: u8,
) -> Result<(bool, u64)> {
    let mint_key = *pc20_mint.key;
    let (expected_state, state_bump) =
        Pubkey::find_program_address(&[PC20_STATE_SEED, mint_key.as_ref()], program_id);
    require!(
        pc20_state.key() == expected_state,
        GatewayError::InvalidAccount
    );

    if pc20_state.data_is_empty() {
        let state_rent = Rent::get()?.minimum_balance(Pc20State::LEN);
        let state_bump_bytes = [state_bump];
        let state_seeds = [PC20_STATE_SEED, mint_key.as_ref(), &state_bump_bytes[..]];
        let lamports_paid = create_pda_account(
            pc20_state,
            caller,
            system_program,
            program_id,
            Pc20State::LEN,
            state_rent.max(1),
            &state_seeds,
            || error!(GatewayError::InvalidAccount),
        )?;

        let state = Pc20State {
            source_asset,
            wrapped_mint: mint_key,
            decimals,
            bump: state_bump,
        };
        state.try_serialize(&mut &mut pc20_state.try_borrow_mut_data()?[..])?;
        return Ok((true, lamports_paid));
    }

    require!(pc20_state.owner == program_id, GatewayError::InvalidAccount);
    let state = Pc20State::try_deserialize(&mut &pc20_state.try_borrow_data()?[..])?;
    require!(
        state.source_asset == source_asset,
        GatewayError::InvalidAccount
    );
    require!(state.wrapped_mint == mint_key, GatewayError::InvalidAccount);
    require!(state.bump == state_bump, GatewayError::InvalidAccount);
    Ok((false, 0))
}

pub fn validate_pc20_state(
    program_id: &Pubkey,
    pc20_state: &Account<Pc20State>,
    mint: Pubkey,
) -> Result<[u8; 20]> {
    validate_pc20_state_fields(program_id, &pc20_state.key(), pc20_state, mint)
}

pub fn validate_pc20_state_fields(
    program_id: &Pubkey,
    pc20_state_key: &Pubkey,
    pc20_state: &Pc20State,
    mint: Pubkey,
) -> Result<[u8; 20]> {
    let (expected_state, state_bump) =
        Pubkey::find_program_address(&[PC20_STATE_SEED, mint.as_ref()], program_id);
    require!(
        *pc20_state_key == expected_state,
        GatewayError::InvalidAccount
    );
    require!(
        pc20_state.wrapped_mint == mint,
        GatewayError::InvalidAccount
    );
    require!(pc20_state.bump == state_bump, GatewayError::InvalidAccount);

    let (expected_mint, _) = Pubkey::find_program_address(
        &[PC20_MINT_SEED, pc20_state.source_asset.as_ref()],
        program_id,
    );
    require!(expected_mint == mint, GatewayError::InvalidPc20Mint);
    Ok(pc20_state.source_asset)
}

pub fn is_pc20_burn_account_shape<'info>(
    program_id: &Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
    mint: Pubkey,
) -> bool {
    if mint == Pubkey::default() || remaining_accounts.len() != 2 {
        return false;
    }
    let pc20_state = &remaining_accounts[0];
    let pc20_mint = &remaining_accounts[1];
    if pc20_mint.key() != mint || pc20_state.owner != program_id || pc20_state.data_is_empty() {
        return false;
    }
    let Ok(state_data) = pc20_state.try_borrow_data() else {
        return false;
    };
    let Ok(state) = Pc20State::try_deserialize(&mut &state_data[..]) else {
        return false;
    };
    validate_pc20_state_fields(program_id, pc20_state.key, &state, mint).is_ok()
}

pub fn is_pc20_remint_account_shape<'info>(
    program_id: &Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
    mint: Pubkey,
) -> bool {
    if remaining_accounts.len() != 5 {
        return false;
    }
    is_pc20_burn_account_shape(program_id, &remaining_accounts[..2], mint)
}

pub fn pc20_prefixed_payload(source_asset: [u8; 20], payload: &[u8]) -> Vec<u8> {
    let mut prefixed = Vec::with_capacity(PC20_SELECTOR.len() + 32 + payload.len());
    prefixed.extend_from_slice(&PC20_SELECTOR);
    prefixed.extend_from_slice(&[0u8; 12]);
    prefixed.extend_from_slice(&source_asset);
    prefixed.extend_from_slice(payload);
    prefixed
}

fn validate_pc20_mint(
    mint_info: &AccountInfo,
    expected_mint: Pubkey,
    expected_decimals: u8,
) -> Result<()> {
    let mint_state = validate_pc20_mint_authority(mint_info, expected_mint)?;
    require!(
        mint_state.decimals == expected_decimals,
        GatewayError::InvalidPc20Mint
    );
    Ok(())
}

pub fn validate_pc20_mint_authority(
    mint_info: &AccountInfo,
    expected_mint: Pubkey,
) -> Result<spl_token::state::Mint> {
    require!(
        mint_info.owner == &spl_token::ID,
        GatewayError::InvalidPc20Mint
    );
    let mint_data = mint_info.try_borrow_data()?;
    let mint_state = spl_token::state::Mint::unpack(&mint_data)
        .map_err(|_| error!(GatewayError::InvalidPc20Mint))?;
    let mint_authority = match mint_state.mint_authority {
        spl_token::solana_program::program_option::COption::Some(authority) => authority,
        _ => return err!(GatewayError::InvalidPc20Mint),
    };
    require!(
        mint_authority == expected_mint,
        GatewayError::InvalidPc20Mint
    );
    require!(
        mint_state.freeze_authority.is_none(),
        GatewayError::InvalidPc20Mint
    );
    Ok(mint_state)
}

fn decode_execute_payload(user_data: &[u8]) -> Result<DecodedExecutePayload> {
    let mut offset = 0usize;
    let accounts_len = read_u32_be(user_data, &mut offset)? as usize;
    // Bound before allocation: each entry needs at least 33 bytes (pubkey + writable), and the
    // buffer must still contain the ix header (u32 ix_len + u8 instruction_id + 32-byte target).
    require!(
        accounts_len
            .checked_mul(33)
            .and_then(|n| n.checked_add(offset + 4 + 1 + 32))
            .map(|n| n <= user_data.len())
            .unwrap_or(false),
        GatewayError::InvalidInput
    );
    let mut accounts = Vec::with_capacity(accounts_len);
    for _ in 0..accounts_len {
        let pubkey = Pubkey::new_from_array(read_fixed::<32>(user_data, &mut offset)?);
        let writable = read_u8(user_data, &mut offset)? == 1;
        accounts.push(GatewayAccountMeta {
            pubkey,
            is_writable: writable,
        });
    }

    let ix_len = read_u32_be(user_data, &mut offset)? as usize;
    let ix_data = read_vec(user_data, &mut offset, ix_len)?;
    let instruction_id = read_u8(user_data, &mut offset)?;
    let target_program = Pubkey::new_from_array(read_fixed::<32>(user_data, &mut offset)?);

    require!(offset == user_data.len(), GatewayError::InvalidInput);

    Ok(DecodedExecutePayload {
        accounts,
        ix_data,
        instruction_id,
        target_program,
    })
}

fn read_u32_be(buf: &[u8], offset: &mut usize) -> Result<u32> {
    let bytes = read_fixed::<4>(buf, offset)?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_u8(buf: &[u8], offset: &mut usize) -> Result<u8> {
    require!(*offset < buf.len(), GatewayError::InvalidInput);
    let value = buf[*offset];
    *offset += 1;
    Ok(value)
}

fn read_fixed<const N: usize>(buf: &[u8], offset: &mut usize) -> Result<[u8; N]> {
    require!(*offset + N <= buf.len(), GatewayError::InvalidInput);
    let mut out = [0u8; N];
    out.copy_from_slice(&buf[*offset..*offset + N]);
    *offset += N;
    Ok(out)
}

fn read_vec(buf: &[u8], offset: &mut usize, len: usize) -> Result<Vec<u8>> {
    require!(*offset + len <= buf.len(), GatewayError::InvalidInput);
    let out = buf[*offset..*offset + len].to_vec();
    *offset += len;
    Ok(out)
}

fn build_and_validate_pc20_finalize_tss(
    tss_pda: &mut Account<crate::state::TssPda>,
    universal_tx_id: [u8; 32],
    sub_tx_id: [u8; 32],
    source_asset: [u8; 20],
    push_account: [u8; 20],
    recipient: Pubkey,
    name: &str,
    symbol: &str,
    decimals: u8,
    gas_fee: u64,
    amount: u64,
    payload: Option<&[u8]>,
    deadline: i64,
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
) -> Result<()> {
    let name_buf = serialize_string(name);
    let symbol_buf = serialize_string(symbol);
    let decimals_buf = [decimals];
    let gas_fee_buf = encode_u64_be(gas_fee);
    let recipient_bytes = recipient.to_bytes();

    if let Some(user_data) = payload {
        let user_data_buf = serialize_ix_data(user_data);
        let additional: [&[u8]; 10] = [
            &sub_tx_id,
            &universal_tx_id,
            &push_account,
            &source_asset,
            &recipient_bytes,
            &name_buf,
            &symbol_buf,
            &decimals_buf,
            &gas_fee_buf,
            &user_data_buf,
        ];
        validate_message(
            tss_pda,
            PC20_FINALIZE_INSTRUCTION_ID,
            Some(amount),
            deadline,
            &additional,
            message_hash,
            signature,
            recovery_id,
        )
    } else {
        let additional: [&[u8]; 9] = [
            &sub_tx_id,
            &universal_tx_id,
            &push_account,
            &source_asset,
            &recipient_bytes,
            &name_buf,
            &symbol_buf,
            &decimals_buf,
            &gas_fee_buf,
        ];
        validate_message(
            tss_pda,
            PC20_FINALIZE_INSTRUCTION_ID,
            Some(amount),
            deadline,
            &additional,
            message_hash,
            signature,
            recovery_id,
        )
    }
}

fn dispatch_pc20_payload<'a, 'info>(
    accounts: &Pc20FinalizeAccountSet<'a, 'info>,
    payload: &DecodedExecutePayload,
    push_account: [u8; 20],
    cea_bump: u8,
) -> Result<()> {
    let cea_bump_bytes = [cea_bump];
    let cea_seeds = [CEA_SEED, push_account.as_ref(), &cea_bump_bytes[..]];
    invoke_signed_gateway_instruction(
        payload.target_program,
        &payload.accounts,
        &payload.ix_data,
        *accounts.cea_authority.key,
        accounts.remaining_accounts,
        &cea_seeds,
    )
}

fn settle_pc20_finalize_gas<'a, 'info>(
    accounts: &Pc20FinalizeAccountSet<'a, 'info>,
    gas_fee: u64,
    mint_lamports_paid: u64,
    pc20_state_lamports_paid: u64,
    recipient_ata_lamports_paid: u64,
    cea_ata_lamports_paid: u64,
    store_upload_fee_lamports: u64,
    store_refund_recipient: Option<&AccountInfo<'info>>,
) -> Result<(u64, u64)> {
    let mut gas_used = SIGNATURE_FEE_LAMPORTS + Rent::get()?.minimum_balance(ExecutedSubTx::LEN);
    gas_used = gas_used
        .checked_add(mint_lamports_paid)
        .and_then(|n| n.checked_add(pc20_state_lamports_paid))
        .and_then(|n| n.checked_add(recipient_ata_lamports_paid))
        .and_then(|n| n.checked_add(cea_ata_lamports_paid))
        .and_then(|n| n.checked_add(store_upload_fee_lamports))
        .ok_or(error!(GatewayError::InvalidAmount))?;
    require!(gas_fee >= gas_used, GatewayError::InsufficientGasBudget);

    let relayer_gas = gas_used
        .checked_sub(store_upload_fee_lamports)
        .ok_or(error!(GatewayError::InvalidAmount))?;
    transfer_gas_fee_to_caller(
        &accounts.vault_sol,
        &accounts.caller,
        &accounts.system_program,
        relayer_gas,
        accounts.vault_bump,
    )?;

    if let Some(refund_recipient) = store_refund_recipient {
        transfer_gas_fee_to_caller(
            &accounts.vault_sol,
            refund_recipient,
            &accounts.system_program,
            store_upload_fee_lamports,
            accounts.vault_bump,
        )?;
    }

    Ok((gas_used, gas_fee - gas_used))
}

pub fn is_send_pc20_universal_tx_ix(ix_data: &[u8]) -> bool {
    if ix_data.len() < 8 {
        return false;
    }
    let expected = solana_hash(b"global:send_pc20_universal_tx").to_bytes();
    ix_data[..8] == expected[..8]
}

pub fn is_send_universal_tx_ix(ix_data: &[u8]) -> bool {
    if ix_data.len() < 8 {
        return false;
    }
    let expected = solana_hash(b"global:send_universal_tx").to_bytes();
    ix_data[..8] == expected[..8]
}

pub fn is_pc20_burn_ix(ix_data: &[u8]) -> bool {
    is_send_pc20_universal_tx_ix(ix_data) || is_send_universal_tx_ix(ix_data)
}

struct Pc20CeaBurnAccounts<'info> {
    source_asset: [u8; 20],
    pc20_mint: AccountInfo<'info>,
    cea_ata: AccountInfo<'info>,
}

fn parse_pc20_cea_burn_accounts<'info>(
    program_id: &Pubkey,
    cea_authority: &AccountInfo<'info>,
    remaining_accounts: &[AccountInfo<'info>],
    source_asset: Option<[u8; 20]>,
    wrapped_mint: Option<Pubkey>,
) -> Result<Pc20CeaBurnAccounts<'info>> {
    let (source_asset, pc20_mint, cea_ata, token_program) = if let Some(source_asset) = source_asset
    {
        require!(
            remaining_accounts.len() == 3,
            GatewayError::AccountListLengthMismatch
        );
        (
            source_asset,
            remaining_accounts[0].clone(),
            remaining_accounts[1].clone(),
            remaining_accounts[2].clone(),
        )
    } else {
        require!(
            remaining_accounts.len() == 4,
            GatewayError::AccountListLengthMismatch
        );
        let pc20_state_info = remaining_accounts[0].clone();
        let pc20_mint = remaining_accounts[1].clone();
        let mint_key = wrapped_mint.ok_or(error!(GatewayError::InvalidMint))?;
        require!(pc20_mint.key() == mint_key, GatewayError::InvalidMint);

        require!(
            pc20_state_info.owner == program_id,
            GatewayError::InvalidAccount
        );
        let state = Pc20State::try_deserialize(&mut &pc20_state_info.try_borrow_data()?[..])?;
        let source_asset =
            validate_pc20_state_fields(program_id, pc20_state_info.key, &state, mint_key)?;
        (
            source_asset,
            pc20_mint,
            remaining_accounts[2].clone(),
            remaining_accounts[3].clone(),
        )
    };

    require!(
        pc20_mint.is_writable && cea_ata.is_writable,
        GatewayError::AccountWritableFlagMismatch
    );
    require!(
        !pc20_mint.is_signer && !cea_ata.is_signer && !token_program.is_signer,
        GatewayError::UnexpectedOuterSigner
    );
    require!(
        token_program.key() == spl_token::ID,
        GatewayError::InvalidAccount
    );
    require!(token_program.executable, GatewayError::InvalidProgram);

    let (expected_mint, _) =
        Pubkey::find_program_address(&[PC20_MINT_SEED, source_asset.as_ref()], program_id);
    require!(
        pc20_mint.key() == expected_mint,
        GatewayError::InvalidPc20Mint
    );
    validate_pc20_mint_authority(&pc20_mint, expected_mint)?;

    let expected_cea_ata = spl_associated_token_account::get_associated_token_address(
        cea_authority.key,
        pc20_mint.key,
    );
    require!(
        cea_ata.key() == expected_cea_ata,
        GatewayError::InvalidAccount
    );
    let parsed_cea_ata = parse_token_account(&cea_ata)?;
    require!(
        parsed_cea_ata.owner == *cea_authority.key && parsed_cea_ata.mint == *pc20_mint.key,
        GatewayError::InvalidAccount
    );

    Ok(Pc20CeaBurnAccounts {
        source_asset,
        pc20_mint,
        cea_ata,
    })
}
