# PC20 on Solana - Integration Guide

This guide is the client/relayer checklist for SVM PC20. For design rationale,
see `docs/7-PC20-SOLANA.md`.

## Constants

| Name | Value |
| --- | --- |
| PC20 selector | ASCII `PC20`, bytes `0x50433230` |
| PRC20 selector | ASCII `PRC2`, bytes `0x50524332` |
| PC20 mint PDA | `["pc20_mint", source_asset_20]` |
| PC20 state PDA | `["pc20_state", pc20_mint]` |
| CEA PDA | `["push_identity", push_account_20]` |
| TSS PDA | `["final_tss_pda"]` |

Burn events use the same payload shape as current EVM PC20:

```text
"PC20" || user_payload
```

## Cross-Chain SDK Model

SDKs should expose PC20 through the same universal transaction surface as EVM.
The Solana program keeps the existing generic gateway instructions and selects
PC20 by signed instruction id, selector bytes, and `remaining_accounts`.

### Push -> Solana export

The Push-side UGPC/Core flow initiates the export. For a Solana destination, the
validator translates the Push-side PC20 export data into the existing finalize
surface:

```text
instruction_id = 5
ix_data = "PC20" || source_asset_20 || abi.encode(dest_chain_namespace, name, symbol, decimals) || raw_user_data
remaining_accounts = [pc20_state, pc20_mint, ...payload_accounts]
```

Submit this through `finalize_universal_tx_with_ix_data_ref` when the ABI
metadata payload makes the direct transaction exceed Solana's transaction-size
limit. This is the existing audit-main-fixes large-payload route, not a PC20
entrypoint. It adds `SIGNATURE_FEE_LAMPORTS` to measured `gas_used`.

Encoding rules:

- `source_asset` is the 20-byte Push/EVM-side source asset identifier.
- `dest_chain_namespace` is decoded and discarded, matching EVM Vault behavior.
- `recipient` is the Solana recipient wallet in the typed account list.
- `push_account` is the 20-byte Push account used to derive the Solana CEA PDA.
- `raw_user_data` is empty for export-only minting, or a Solana instruction payload
  executed by the CEA after the wrapped amount is minted to the CEA ATA.
- `pc20_mint = PDA("pc20_mint", source_asset)` and
  `pc20_state = PDA("pc20_state", pc20_mint)`.

EVM carries PC20 `sourceAsset` in the existing `Vault.finalizeUniversalTx`
`token` argument. SVM has no equivalent 20-byte token argument in its existing
`finalize_universal_tx` interface, so `source_asset_20` is intentionally carried
inside PC20 `ix_data` rather than adding a new instruction argument.

The TSS signed message is not reused from a normal finalize route. PC20 export
uses the existing `finalize_universal_tx` function with instruction id `5` and
the PC20 additional-data layout listed below.

### Solana -> Push burn

For a direct user burn, the SDK calls the existing `send_universal_tx` method.
It must pass `req.token = pc20_mint`, the caller's PC20 ATA as
`user_token_account`, `gateway_token_account = null`, and positional
`remaining_accounts = [pc20_state, pc20_mint]`.

For CEA-held PC20, validators use the existing Push-routed
`finalize_universal_tx` self-route. The inner payload is the generic
`send_universal_tx(req, 0)` discriminator plus accounts listed in the CEA burn
section below.

Off-chain decoders identify PC20 burns the same way as EVM: read the generic
`UniversalTx` event and check `payload` starts with `PC20`.

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
| `token_rate_limit` | `null` for pure PC20 burn; native-SOL rate-limit PDA if `native_amount` exceeds the inbound fee and the excess is routed as native `Funds` |
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
payload = "PC20" || req.payload
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

Remaining accounts:

```text
[pc20_state, pc20_mint, cea_ata, token_program]
```

CEA burn does not pay the inbound fee. It is paid through the outer
`finalize_universal_tx` gas model. The inner request must set
`req.recipient == push_account` from the outer finalize call. The canonical event
is generic `UniversalTx` with
`payload = "PC20" || req.payload`; this PC20 self-route does not emit
`UniversalTxFinalized`.

## Push -> Solana Export: `finalize_universal_tx`

Use this for Push-native asset export to Solana.

Instruction arguments:

| Field | Value |
| --- | --- |
| `instruction_id` | `5` |
| `amount` | wrapped amount to mint |
| `push_account` | Push account bytes |
| `writable_flags` | empty bytes |
| `ix_data` | `"PC20" || source_asset_20 || abi.encode(dest_chain_namespace, name, symbol, decimals) || raw_user_data` |
| `gas_fee` / `deadline` / signature fields | same TSS fields as other finalize routes |

For production validators, prefer `finalize_universal_tx_with_ix_data_ref` for
PC20 exports unless the fully serialized direct transaction has been measured
under Solana's size limit. The signed fields are the same; the ref route stores
the exact `ix_data`, passes its hash to finalize, and reimburses the existing
5,000 lamport store upload fee through SVM gas accounting.

Successful export emits the generic `UniversalTxFinalized` event, matching the
latest EVM PC20 export route.

Common EVM/SVM fields:

```text
sub_tx_id
universal_tx_id
push_account
wrapper_address / wrapperAddress
recipient (EVM) / target (SVM)
token
amount
payload / data
```

For PC20 export, EVM sets `wrapperAddress = wrapper`, `token = sourceAsset`,
and `data = userData`. SVM sets `wrapper_address = wrapped_mint`,
`token = 12 zero bytes || source_asset`, `target = recipient`, and
`payload = user_data`.

SVM-only finalize accounting fields:

```text
gas_fee
gas_used
gas_to_refund
ata_created
```

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
| `cea_ata` | CEA ATA for the wrapped PC20 mint |

Positional remaining accounts (`.remainingAccounts([...])`):

| Index | Account | Value |
| --- | --- | --- |
| `0` | `pc20_state` | `["pc20_state", pc20_mint]` |
| `1` | `pc20_mint` | `["pc20_mint", source_asset]` |
| `2+` | payload accounts | only when `user_data` is non-empty; must match signed payload account order |

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

The relayer gas budget must cover signature fee, `ExecutedSubTx` rent, any
missing mint/state/CEA ATA lamports that the relayer actually pays, and the
5,000 lamport store upload fee when using finalize-by-reference. Prefunded
accounts reduce reimbursed rent.

TSS/validator note: PC20 export uses the existing `finalize_universal_tx`
function, but it is signed with instruction id `5`. Normal finalize routes keep
their existing instruction ids and signed-data layouts.

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

**Reimbursement source (applies to ALL rescue token types, not just PC20):**
`rescue_funds` reimburses the UV from the bridge `vault`, **not** `fee_vault`.
Rescue is Push-initiated — `UniversalGatewayPC.rescueFundsOnSourceChain` burns the
destination gas token on Push via `UniversalCore.swapAndBurnGas`, so the matching
backing must be released from `vault` to stay 1:1. The UV is reimbursed the
**measured** `gas_used` (signature fee + `ExecutedSubTx` rent, plus recipient-ATA
rent only when the PC20 remint path creates it); the signed `gas_fee` is a **cap**.
The `FundsRescued` event now carries `gas_used`, and the Push side refunds
`gas_fee - gas_used`. The `fee_vault` account stays in the IDL account list for
compatibility but is unused by rescue. (Revert is unchanged: `fee_vault`-funded.)

Normal accounts match PC20 revert except there is no `revert_instruction`
argument. The remaining accounts are the same:

```text
[pc20_state, pc20_mint, recipient_ata, associated_token_program, rent]
```

TSS additional data (unchanged — `gas_fee` is still the only signed gas field, now
interpreted as a cap):

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
`rescue_funds` interface has no `RevertInstructions` argument. It adds a
`gas_used` field (IDL-breaking layout change — regenerate types).

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
- For pure PC20 burns, pass `token_rate_limit = null`. If the same call sends
  native value above the configured inbound fee, the excess becomes a normal
  native `Funds` leg and the SDK must pass the native-SOL token-rate-limit PDA.
- `revert_universal_tx` and `rescue_funds` become PC20 remints only when
  `remaining_accounts` exactly match
  `[pc20_state, pc20_mint, recipient_ata, associated_token_program, rent]` for
  `token_mint`; otherwise legacy SPL/native behavior is preserved.

This is a fail-closed client behavior change: clients that previously appended
unused extra accounts to generic calls must stop doing that.

PC20 burn detection in `send_universal_tx` is based on the two PC20 remaining
accounts, not on `instruction_id` because direct burns do not pass an
instruction id. SDKs/relayers must include `[pc20_state, pc20_mint]` for PC20
burns. Do not configure canonical PC20 mints as normal SPL outbound assets
unless routing them through the legacy SPL path is explicitly intended.

Push Core note: current PC20 Core tracks destination wrappers as `bytes32`.
Register Solana wrapped mints as raw 32-byte mint PDA values; do not coerce them
into 20-byte EVM addresses.

## Devnet Dummy Program

The top-to-bottom devnet PC20 section in `app/gateway-test.ts` is dummy-only.
The dummy program id must remain:

```text
DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp
```

Running the script against main/non-dummy skips the PC20 section.
