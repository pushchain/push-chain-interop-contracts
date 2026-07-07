use crate::errors::GatewayError;
use crate::instructions::tss::validate_message;
use crate::state::{
    Config, ExecutedSubTx, FeeVault, GatewayAccountMeta, Pc20BurnReverted, Pc20ExportFinalized,
    Pc20UniversalTx, CEA_SEED, CONFIG_SEED, EXECUTED_SUB_TX_SEED, FEE_VAULT_SEED, PC20_MINT_SEED,
    TSS_SEED, VAULT_SEED,
};
use crate::utils::{
    create_pda_account, encode_u64_be, ensure_associated_token_account,
    invoke_signed_gateway_instruction, parse_token_account, pda_burn, pda_mint_to,
    reimburse_relayer_from_fee_vault, serialize_ix_data, serialize_string, spl_burn,
    transfer_gas_fee_to_caller, validate_remaining_accounts,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{hash::hash as solana_hash, program::invoke, program_pack::Pack};
use anchor_spl::associated_token::{spl_associated_token_account, AssociatedToken};
use anchor_spl::token::{spl_token, Mint, Token, TokenAccount};

const SIGNATURE_FEE_LAMPORTS: u64 = 5_000;
const SPL_TOKEN_ACCOUNT_LEN: usize = 165;
const SPL_MINT_ACCOUNT_LEN: usize = spl_token::state::Mint::LEN;
const PC20_FINALIZE_INSTRUCTION_ID: u8 = 5;
const PC20_BURN_REVERT_INSTRUCTION_ID: u8 = 6;

struct DecodedExecutePayload {
    accounts: Vec<GatewayAccountMeta>,
    ix_data: Vec<u8>,
    instruction_id: u8,
    target_program: Pubkey,
}

#[derive(Accounts)]
#[instruction(
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    source_asset: [u8; 20],
    amount: u64,
    push_account: [u8; 20]
)]
pub struct FinalizePc20Export<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
    )]
    pub config: Account<'info, Config>,

    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault_sol: SystemAccount<'info>,

    /// CHECK: Canonical wrapped mint PDA for the Push-native source asset.
    #[account(
        mut,
        seeds = [PC20_MINT_SEED, source_asset.as_ref()],
        bump
    )]
    pub pc20_mint: UncheckedAccount<'info>,

    /// CHECK: Final recipient wallet for direct mints.
    pub recipient: UncheckedAccount<'info>,

    /// CHECK: Recipient ATA for direct mints.
    #[account(mut)]
    pub recipient_ata: UncheckedAccount<'info>,

    /// CHECK: Canonical Solana identity derived from the Push account.
    #[account(
        seeds = [CEA_SEED, push_account.as_ref()],
        bump
    )]
    pub cea_authority: UncheckedAccount<'info>,

    /// CHECK: CEA ATA used for payload execution flows.
    #[account(mut)]
    pub cea_ata: UncheckedAccount<'info>,

    #[account(mut, seeds = [TSS_SEED], bump = tss_pda.bump)]
    pub tss_pda: Account<'info, crate::state::TssPda>,

    #[account(
        init,
        payer = caller,
        space = ExecutedSubTx::LEN,
        seeds = [EXECUTED_SUB_TX_SEED, sub_tx_id.as_ref()],
        bump
    )]
    pub executed_sub_tx: Account<'info, ExecutedSubTx>,

    pub system_program: Program<'info, System>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub rent: Sysvar<'info, Rent>,

    /// CHECK: Destination program for payload execution. Pass SystemProgram when user_data is empty.
    pub destination_program: UncheckedAccount<'info>,
}

#[derive(Accounts)]
#[instruction(_sub_tx_id: [u8; 32], source_asset: [u8; 20])]
pub struct SendPc20UniversalTx<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
    )]
    pub config: Account<'info, Config>,

    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        mut,
        seeds = [PC20_MINT_SEED, source_asset.as_ref()],
        bump
    )]
    pub pc20_mint: Account<'info, Mint>,

    #[account(
        mut,
        constraint = user_ata.owner == caller.key() @ GatewayError::InvalidOwner,
        constraint = user_ata.mint == pc20_mint.key() @ GatewayError::InvalidMint,
    )]
    pub user_ata: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(
    sub_tx_id: [u8; 32],
    original_burn_sub_tx_id: [u8; 32],
    source_asset: [u8; 20]
)]
pub struct RevertPc20Burn<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
    )]
    pub config: Account<'info, Config>,

    #[account(mut, seeds = [FEE_VAULT_SEED], bump = fee_vault.bump)]
    pub fee_vault: Account<'info, FeeVault>,

    #[account(mut, seeds = [TSS_SEED], bump = tss_pda.bump)]
    pub tss_pda: Account<'info, crate::state::TssPda>,

    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        mut,
        seeds = [PC20_MINT_SEED, source_asset.as_ref()],
        bump
    )]
    pub pc20_mint: Account<'info, Mint>,

    /// CHECK: Solana wallet that receives the reminted wrapped supply.
    pub revert_recipient: UncheckedAccount<'info>,

    /// CHECK: ATA for the revert recipient. Created lazily when missing.
    #[account(mut)]
    pub recipient_ata: UncheckedAccount<'info>,

    #[account(
        init,
        payer = caller,
        space = ExecutedSubTx::LEN,
        seeds = [EXECUTED_SUB_TX_SEED, sub_tx_id.as_ref()],
        bump
    )]
    pub executed_sub_tx: Account<'info, ExecutedSubTx>,

    pub system_program: Program<'info, System>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub rent: Sysvar<'info, Rent>,
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

pub fn finalize_pc20_export(
    ctx: Context<FinalizePc20Export>,
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
    gas_fee: u64,
    deadline: i64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(source_asset != [0u8; 20], GatewayError::ZeroAddress);

    let mint_created = ctx.accounts.pc20_mint.to_account_info().data_is_empty();
    if mint_created {
        create_pc20_mint(&ctx, decimals, &source_asset)?;
        validate_pc20_mint(
            &ctx.accounts.pc20_mint.to_account_info(),
            ctx.accounts.pc20_mint.key(),
            decimals,
        )?;
    } else {
        validate_pc20_mint_authority(
            &ctx.accounts.pc20_mint.to_account_info(),
            ctx.accounts.pc20_mint.key(),
        )?;
    }

    let decoded_payload = if user_data.is_empty() {
        None
    } else {
        let payload = decode_execute_payload(&user_data)?;
        require!(
            payload.instruction_id == 2,
            GatewayError::InvalidInstruction
        );
        require!(
            payload.target_program == ctx.accounts.destination_program.key(),
            GatewayError::InvalidProgram
        );
        require!(
            ctx.accounts.destination_program.executable,
            GatewayError::InvalidProgram
        );
        validate_remaining_accounts(&payload.accounts, ctx.remaining_accounts)?;
        Some(payload)
    };

    build_and_validate_pc20_finalize_tss(
        &mut ctx.accounts.tss_pda,
        universal_tx_id,
        sub_tx_id,
        source_asset,
        push_account,
        recipient,
        &name,
        &symbol,
        decimals,
        gas_fee,
        amount,
        if user_data.is_empty() {
            None
        } else {
            Some(user_data.as_slice())
        },
        deadline,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    let (recipient_ata_created, cea_ata_created, mint_destination) = if decoded_payload.is_some() {
        let cea_ata_created = ensure_associated_token_account(
            &ctx.accounts.caller.to_account_info(),
            &ctx.accounts.cea_ata.to_account_info(),
            &ctx.accounts.cea_authority.to_account_info(),
            &ctx.accounts.pc20_mint.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            &ctx.accounts.token_program.to_account_info(),
            &ctx.accounts.associated_token_program.to_account_info(),
            &ctx.accounts.rent.to_account_info(),
        )?;
        let parsed_ata = parse_token_account(&ctx.accounts.cea_ata.to_account_info())?;
        require!(
            parsed_ata.owner == ctx.accounts.cea_authority.key()
                && parsed_ata.mint == ctx.accounts.pc20_mint.key(),
            GatewayError::InvalidAccount
        );
        (
            false,
            cea_ata_created,
            ctx.accounts.cea_ata.to_account_info(),
        )
    } else {
        let recipient_ata_created = ensure_associated_token_account(
            &ctx.accounts.caller.to_account_info(),
            &ctx.accounts.recipient_ata.to_account_info(),
            &ctx.accounts.recipient.to_account_info(),
            &ctx.accounts.pc20_mint.to_account_info(),
            &ctx.accounts.system_program.to_account_info(),
            &ctx.accounts.token_program.to_account_info(),
            &ctx.accounts.associated_token_program.to_account_info(),
            &ctx.accounts.rent.to_account_info(),
        )?;
        let parsed_ata = parse_token_account(&ctx.accounts.recipient_ata.to_account_info())?;
        require!(
            parsed_ata.owner == ctx.accounts.recipient.key()
                && parsed_ata.mint == ctx.accounts.pc20_mint.key(),
            GatewayError::InvalidAccount
        );
        (
            recipient_ata_created,
            false,
            ctx.accounts.recipient_ata.to_account_info(),
        )
    };

    let mint_bump = [ctx.bumps.pc20_mint];
    let mint_seeds = [PC20_MINT_SEED, source_asset.as_ref(), &mint_bump[..]];
    pda_mint_to(
        &ctx.accounts.pc20_mint.to_account_info(),
        &mint_destination,
        &ctx.accounts.pc20_mint.to_account_info(),
        amount,
        &mint_seeds,
    )?;

    if let Some(payload) = decoded_payload.as_ref() {
        dispatch_pc20_payload(&ctx, payload, push_account)?;
    }

    let (gas_used, gas_to_refund) = settle_pc20_finalize_gas(
        &ctx,
        gas_fee,
        mint_created,
        recipient_ata_created,
        cea_ata_created,
    )?;

    emit!(Pc20ExportFinalized {
        sub_tx_id,
        universal_tx_id,
        push_account,
        source_asset,
        wrapped_mint: ctx.accounts.pc20_mint.key(),
        recipient,
        amount,
        gas_fee,
        gas_used,
        gas_to_refund,
        mint_created,
        recipient_ata_created,
        cea_ata_created,
        payload_executed: decoded_payload.is_some(),
    });

    Ok(())
}

pub fn send_pc20_universal_tx(
    ctx: Context<SendPc20UniversalTx>,
    sub_tx_id: [u8; 32],
    source_asset: [u8; 20],
    amount: u64,
    recipient: [u8; 20],
    payload: Vec<u8>,
    revert_recipient: Pubkey,
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(source_asset != [0u8; 20], GatewayError::ZeroAddress);
    require!(recipient != [0u8; 20], GatewayError::InvalidRecipient);
    require!(
        revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    spl_burn(
        &ctx.accounts.pc20_mint.to_account_info(),
        &ctx.accounts.user_ata.to_account_info(),
        &ctx.accounts.caller.to_account_info(),
        amount,
    )?;

    emit!(Pc20UniversalTx {
        sub_tx_id,
        sender: ctx.accounts.caller.key(),
        push_account: [0u8; 20],
        source_asset,
        wrapped_mint: ctx.accounts.pc20_mint.key(),
        amount,
        recipient,
        payload,
        revert_recipient,
        from_cea: false,
    });

    Ok(())
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
    require!(
        is_send_pc20_universal_tx_ix(ix_data),
        GatewayError::InvalidInput
    );

    let args = SendPc20UniversalTxArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;
    require!(args.sub_tx_id == sub_tx_id, GatewayError::InvalidInput);
    require!(args.amount > 0, GatewayError::InvalidAmount);
    require!(args.source_asset != [0u8; 20], GatewayError::ZeroAddress);
    require!(push_account != [0u8; 20], GatewayError::ZeroAddress);
    require!(args.recipient != [0u8; 20], GatewayError::InvalidRecipient);
    require!(
        args.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    let route_accounts = parse_pc20_cea_burn_accounts(
        program_id,
        cea_authority,
        remaining_accounts,
        args.source_asset,
    )?;

    pda_burn(
        &route_accounts.pc20_mint,
        &route_accounts.cea_ata,
        cea_authority,
        args.amount,
        cea_seeds,
    )?;

    emit!(Pc20UniversalTx {
        sub_tx_id,
        sender: *cea_authority.key,
        push_account,
        source_asset: args.source_asset,
        wrapped_mint: *route_accounts.pc20_mint.key,
        amount: args.amount,
        recipient: args.recipient,
        payload: args.payload,
        revert_recipient: args.revert_recipient,
        from_cea: true,
    });

    Ok(())
}

pub fn revert_pc20_burn(
    ctx: Context<RevertPc20Burn>,
    sub_tx_id: [u8; 32],
    original_burn_sub_tx_id: [u8; 32],
    source_asset: [u8; 20],
    amount: u64,
    revert_recipient: Pubkey,
    gas_fee: u64,
    deadline: i64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(source_asset != [0u8; 20], GatewayError::ZeroAddress);
    require!(
        revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.revert_recipient.key() == revert_recipient,
        GatewayError::InvalidRecipient
    );

    let gas_fee_buf = encode_u64_be(gas_fee);
    let recipient_bytes = revert_recipient.to_bytes();
    let additional: [&[u8]; 5] = [
        &sub_tx_id,
        &original_burn_sub_tx_id,
        &source_asset,
        &recipient_bytes,
        &gas_fee_buf,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        PC20_BURN_REVERT_INSTRUCTION_ID,
        Some(amount),
        deadline,
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    validate_pc20_mint_authority(
        &ctx.accounts.pc20_mint.to_account_info(),
        ctx.accounts.pc20_mint.key(),
    )?;

    let recipient_ata_created = ensure_associated_token_account(
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.recipient_ata.to_account_info(),
        &ctx.accounts.revert_recipient.to_account_info(),
        &ctx.accounts.pc20_mint.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        &ctx.accounts.token_program.to_account_info(),
        &ctx.accounts.associated_token_program.to_account_info(),
        &ctx.accounts.rent.to_account_info(),
    )?;
    let parsed_ata = parse_token_account(&ctx.accounts.recipient_ata.to_account_info())?;
    require!(
        parsed_ata.owner == revert_recipient && parsed_ata.mint == ctx.accounts.pc20_mint.key(),
        GatewayError::InvalidAccount
    );

    let mint_bump = [ctx.bumps.pc20_mint];
    let mint_seeds = [PC20_MINT_SEED, source_asset.as_ref(), &mint_bump[..]];
    pda_mint_to(
        &ctx.accounts.pc20_mint.to_account_info(),
        &ctx.accounts.recipient_ata.to_account_info(),
        &ctx.accounts.pc20_mint.to_account_info(),
        amount,
        &mint_seeds,
    )?;

    let gas_used = settle_pc20_revert_gas(&ctx, sub_tx_id, gas_fee, recipient_ata_created)?;

    emit!(Pc20BurnReverted {
        sub_tx_id,
        original_burn_sub_tx_id,
        source_asset,
        wrapped_mint: ctx.accounts.pc20_mint.key(),
        amount,
        revert_recipient,
        gas_fee,
        gas_used,
        recipient_ata_created,
    });

    Ok(())
}

fn create_pc20_mint<'info>(
    ctx: &Context<FinalizePc20Export<'info>>,
    decimals: u8,
    source_asset: &[u8; 20],
) -> Result<()> {
    let mint_rent = Rent::get()?.minimum_balance(SPL_MINT_ACCOUNT_LEN);
    let mint_bump = [ctx.bumps.pc20_mint];
    let mint_seeds = [PC20_MINT_SEED, source_asset.as_ref(), &mint_bump[..]];
    let mint_info = ctx.accounts.pc20_mint.to_account_info();
    create_pda_account(
        &mint_info,
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        &spl_token::ID,
        SPL_MINT_ACCOUNT_LEN,
        mint_rent.max(1),
        &mint_seeds,
        || error!(GatewayError::InvalidPc20Mint),
    )?;

    let init_mint_ix = spl_token::instruction::initialize_mint(
        &spl_token::ID,
        &ctx.accounts.pc20_mint.key(),
        &ctx.accounts.pc20_mint.key(),
        None,
        decimals,
    )?;
    invoke(
        &init_mint_ix,
        &[
            ctx.accounts.pc20_mint.to_account_info(),
            ctx.accounts.rent.to_account_info(),
        ],
    )?;

    Ok(())
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

fn validate_pc20_mint_authority(
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

fn dispatch_pc20_payload(
    ctx: &Context<FinalizePc20Export>,
    payload: &DecodedExecutePayload,
    push_account: [u8; 20],
) -> Result<()> {
    let cea_bump = [ctx.bumps.cea_authority];
    let cea_seeds = [CEA_SEED, push_account.as_ref(), &cea_bump[..]];
    invoke_signed_gateway_instruction(
        payload.target_program,
        &payload.accounts,
        &payload.ix_data,
        ctx.accounts.cea_authority.key(),
        ctx.remaining_accounts,
        &cea_seeds,
    )
}

fn settle_pc20_finalize_gas(
    ctx: &Context<FinalizePc20Export>,
    gas_fee: u64,
    mint_created: bool,
    recipient_ata_created: bool,
    cea_ata_created: bool,
) -> Result<(u64, u64)> {
    let mut gas_used = SIGNATURE_FEE_LAMPORTS + Rent::get()?.minimum_balance(ExecutedSubTx::LEN);
    if mint_created {
        gas_used = gas_used
            .checked_add(Rent::get()?.minimum_balance(SPL_MINT_ACCOUNT_LEN))
            .ok_or(error!(GatewayError::InvalidAmount))?;
    }
    if recipient_ata_created {
        gas_used = gas_used
            .checked_add(Rent::get()?.minimum_balance(SPL_TOKEN_ACCOUNT_LEN))
            .ok_or(error!(GatewayError::InvalidAmount))?;
    }
    if cea_ata_created {
        gas_used = gas_used
            .checked_add(Rent::get()?.minimum_balance(SPL_TOKEN_ACCOUNT_LEN))
            .ok_or(error!(GatewayError::InvalidAmount))?;
    }
    require!(gas_fee >= gas_used, GatewayError::InsufficientGasBudget);

    transfer_gas_fee_to_caller(
        &ctx.accounts.vault_sol.to_account_info(),
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        gas_used,
        ctx.accounts.config.vault_bump,
    )?;

    Ok((gas_used, gas_fee - gas_used))
}

fn settle_pc20_revert_gas(
    ctx: &Context<RevertPc20Burn>,
    sub_tx_id: [u8; 32],
    gas_fee: u64,
    recipient_ata_created: bool,
) -> Result<u64> {
    let mut gas_used = SIGNATURE_FEE_LAMPORTS + Rent::get()?.minimum_balance(ExecutedSubTx::LEN);
    if recipient_ata_created {
        gas_used = gas_used
            .checked_add(Rent::get()?.minimum_balance(SPL_TOKEN_ACCOUNT_LEN))
            .ok_or(error!(GatewayError::InvalidAmount))?;
    }
    require!(gas_fee >= gas_used, GatewayError::InsufficientGasBudget);
    reimburse_relayer_from_fee_vault(
        &ctx.accounts.fee_vault,
        &ctx.accounts.caller.to_account_info(),
        sub_tx_id,
        gas_used,
    )?;
    Ok(gas_used)
}

pub fn is_send_pc20_universal_tx_ix(ix_data: &[u8]) -> bool {
    if ix_data.len() < 8 {
        return false;
    }
    let expected = solana_hash(b"global:send_pc20_universal_tx").to_bytes();
    ix_data[..8] == expected[..8]
}

struct Pc20CeaBurnAccounts<'info> {
    pc20_mint: AccountInfo<'info>,
    cea_ata: AccountInfo<'info>,
}

fn parse_pc20_cea_burn_accounts<'info>(
    program_id: &Pubkey,
    cea_authority: &AccountInfo<'info>,
    remaining_accounts: &[AccountInfo<'info>],
    source_asset: [u8; 20],
) -> Result<Pc20CeaBurnAccounts<'info>> {
    require!(
        remaining_accounts.len() == 3,
        GatewayError::AccountListLengthMismatch
    );

    let pc20_mint = remaining_accounts[0].clone();
    let cea_ata = remaining_accounts[1].clone();
    let token_program = remaining_accounts[2].clone();

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

    Ok(Pc20CeaBurnAccounts { pc20_mint, cea_ata })
}
