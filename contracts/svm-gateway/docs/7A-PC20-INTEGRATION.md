# PC20 on Solana - Integration Guide

This guide is the client/relayer checklist for SVM PC20. For design rationale,
see `docs/7-PC20-SOLANA.md`.

## Constants

| Name | Value |
| --- | --- |
| PC20 selector | ASCII `PC20`, bytes `0x50433230` |
| PC20 mint PDA | `["pc20_mint", source_asset_20]` |
| PC20 state PDA | `["pc20_state", pc20_mint]` |
| CEA PDA | `["push_identity", push_account_20]` |
| TSS PDA | `["final_tss_pda"]` |

For burn events, `abi_encode_address(source_asset)` means Solidity-compatible
`abi.encode(address)`: 12 leading zero bytes followed by the 20-byte source
asset. Do not encode the raw 20-byte source asset directly in event payloads.

## Direct Burn: `send_universal_tx`

Use this for Solana -> Push direct user burns. There is no public
PC20-specific burn instruction.

Normal accounts:

| Account | Value |
| --- | --- |
| `config` | config PDA |
| `vault` | vault PDA |
| `fee_vault` | fee vault PDA |
| `user_token_account` | caller ATA for `pc20_mint` |
| `gateway_token_account` | `null` |
| `user` | caller signer |
| `price_update` | same account required by generic IDL |
| `rate_limit_config` | same account required by generic IDL |
| `token_rate_limit` | same account required by generic IDL |
| `token_program` | SPL Token program |
| `system_program` | System program |

Remaining accounts, in order:

```text
[pc20_state, pc20_mint]
```

Request requirements:

- `req.token = pc20_mint`
- `req.amount > 0`
- `req.recipient != 0x0000000000000000000000000000000000000000`
- `req.revert_recipient != Pubkey::default()`
- `native_amount >= fee_vault.inbound_fee_lamports`

The event surface is generic `UniversalTx` with:

```text
payload = "PC20" || abi_encode_address(source_asset) || req.payload
tx_type = FundsAndPayload
from_cea = false
signature_data = req.signature_data
```

If `native_amount` is greater than the inbound fee, the post-fee native excess
is routed as a second normal native `Funds` `UniversalTx`, matching EVM
`_routePC20Tx(nativeValue > 0)`.

PC20 burn amount handling:

```text
amount > 0 => FundsAndPayload
amount = 0 => InvalidAmount
```

## CEA Burn: `finalize_universal_tx` Self-Route

Use this when PC20 is held by the CEA and Push routes execution back into the
Solana gateway.

Outer `finalize_universal_tx` requirements:

| Field | Value |
| --- | --- |
| `instruction_id` | `2` |
| `destination_program` | universal gateway program id |
| `amount` | `0` |
| `mint` / `token_program` typed SPL accounts | `null` on the outer finalize account list |
| `recipient` / `recipient_ata` | `null` |
| `ix_data` | encoded inner `send_universal_tx(req, 0)` |

Remaining accounts for the canonical generic inner payload:

```text
[pc20_state, pc20_mint, cea_ata, token_program]
```

The old inner `send_pc20_universal_tx` payload discriminator is accepted only
inside the CEA self-route for compatibility. If used there, its remaining
accounts are:

```text
[pc20_mint, cea_ata, token_program]
```

CEA burn does not pay the inbound fee. It is paid through the outer
`finalize_universal_tx` gas model. The inner request must set
`req.recipient == push_account` from the outer finalize call. The canonical event
is generic `UniversalTx` with
`payload = "PC20" || abi_encode_address(source_asset) || req.payload`.

## Push -> Solana Export: `finalize_universal_tx`

Use this for Push-native asset export to Solana.

Instruction arguments:

| Field | Value |
| --- | --- |
| `instruction_id` | `5` |
| `amount` | wrapped amount to mint |
| `push_account` | Push account bytes |
| `writable_flags` | empty bytes |
| `ix_data` | `"PC20" || borsh(source_asset, name, symbol, decimals, user_data)` |
| `gas_fee` / `deadline` / signature fields | same TSS fields as other finalize routes |

Successful export emits the existing generic `UniversalTxFinalized`; there is no
PC20-specific export event.

Typed accounts (`.accountsPartial({...})`):

| Account | Value |
| --- | --- |
| `caller` | relayer signer |
| `config` | config PDA |
| `vault_sol` | vault PDA |
| `cea_authority` | `["push_identity", push_account]` |
| `tss_pda` | TSS PDA |
| `executed_sub_tx` | `["executed_sub_tx", sub_tx_id]` |
| `system_program` | System program |
| `destination_program` | payload target, or System program when `user_data` is empty |
| `recipient` | final recipient wallet |
| `vault_ata` / `mint` / typed `recipient_ata` | `null` |
| `rate_limit_config` / `token_rate_limit` | `null` |
| `stored_ix_data` / `store_refund_recipient` | only set for stored-ix-data finalize-by-reference |
| `token_program` | SPL Token program |
| `associated_token_program` | Associated Token program |
| `rent` | Rent sysvar |
| `cea_ata` | CEA ATA for payload export; `null` for direct export |

Positional remaining accounts (`.remainingAccounts([...])`):

| Index | Account | Value |
| --- | --- | --- |
| `0` | `pc20_state` | `["pc20_state", pc20_mint]` |
| `1` | `pc20_mint` | `["pc20_mint", source_asset]` |
| `2` | `pc20_recipient_ata` | recipient ATA for direct export; omit for payload export |
| `2+` | payload accounts | only for payload export; must match signed payload account order |

TSS additional data:

```text
sub_tx_id
|| universal_tx_id
|| push_account
|| source_asset
|| recipient
|| len(name) || name
|| len(symbol) || symbol
|| decimals
|| gas_fee
[|| len(user_data) || user_data]
```

The relayer gas budget must cover signature fee, `ExecutedSubTx` rent, and any
missing mint/state/ATA lamports that the relayer actually pays. Prefunded
accounts reduce reimbursed rent.

## Burn Revert: `revert_universal_tx`

Use this when Push-side execution/unlock fails after a Solana PC20 burn.

Normal accounts:

| Account | Value |
| --- | --- |
| `config` | config PDA |
| `fee_vault` | fee vault PDA |
| `tss_pda` | TSS PDA |
| `vault` | vault PDA, present for generic IDL |
| `recipient` | revert recipient wallet |
| `token_vault` | `null` |
| `recipient_token_account` | `null` |
| `token_mint` | `pc20_mint` |
| `token_program` | SPL Token program |
| `caller` | relayer signer |
| `executed_sub_tx` | `["executed_sub_tx", sub_tx_id]` |
| `system_program` | System program |

Remaining accounts:

```text
[pc20_state, pc20_mint, recipient_ata, associated_token_program, rent]
```

TSS additional data:

```text
sub_tx_id
|| universal_tx_id
|| pc20_mint
|| recipient
|| gas_fee
|| keccak(revert_msg)
|| "PC20"
|| source_asset
```

The `"PC20" || source_asset` suffix is required. A normal SPL revert signature
for the same mint is rejected with `MessageHashMismatch`.

## Rescue: `rescue_funds`

Use this for emergency TSS-authorized PC20 remint.

**Operational warning:** PC20 rescue mints wrapped supply on Solana. Unlike a
normal SPL rescue, it does not transfer from a pre-funded token vault. TSS and
off-chain orchestration must only sign PC20 rescue after the matching Push-side
ledger action is confirmed.

Normal accounts match PC20 revert except there is no `revert_instruction`
argument. The remaining accounts are the same:

```text
[pc20_state, pc20_mint, recipient_ata, associated_token_program, rent]
```

TSS additional data:

```text
sub_tx_id
|| universal_tx_id
|| pc20_mint
|| recipient
|| gas_fee
|| "PC20"
|| source_asset
```

The `FundsRescued` event keeps `revert_msg = []` because the current SVM
`rescue_funds` interface has no `RevertInstructions` argument.

## Existing Route Compatibility

For normal SOL/SPL/PRC20 callers:

- Existing `finalize_universal_tx` and
  `finalize_universal_tx_with_ix_data_ref` named accounts are unchanged from
  `audit-main-fixes`. Legacy clients only need the regenerated IDL/types if they
  consume this branch; they do not pass PC20 null accounts.
- Keep `remaining_accounts` empty unless using the existing execute payload route.
- `send_universal_tx` becomes a PC20 burn only when `remaining_accounts` exactly
  match `[pc20_state, pc20_mint]` for `req.token`; unrelated remaining accounts
  stay on the legacy route.
- `revert_universal_tx` and `rescue_funds` become PC20 remints only when
  `remaining_accounts` exactly match
  `[pc20_state, pc20_mint, recipient_ata, associated_token_program, rent]` for
  `token_mint`; otherwise legacy SPL/native behavior is preserved.

This is a fail-closed client behavior change: clients that previously appended
unused extra accounts to generic calls must stop doing that.

## Devnet Dummy Program

The top-to-bottom devnet PC20 section in `app/gateway-test.ts` is dummy-only.
The dummy program id must remain:

```text
DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp
```

Running the script against main/non-dummy skips the PC20 section.
