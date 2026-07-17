# PC20 on Solana - Architecture

This document describes the Solana-side PC20 architecture after aligning with the
EVM PC20 route changes from gateway PR #130 and PR #131.

PC20 represents Push-native assets as wrapped SPL mints on Solana. The goal is
EVM-equivalent protocol behavior while preserving Solana account validation,
PDA authority, and SPL Token rules.

---

## Core Invariant

For every Push-native PC20 source asset:

```text
locked_on_push >= wrapped_supply_on_solana
```

The Solana leg maintains this by:

- minting only through TSS-authorized exports, reverts, and rescues,
- burning wrapped SPL supply before Push-side unlock/execution,
- replay-protecting TSS finalize/revert/rescue instructions with `ExecutedSubTx`,
- validating the canonical mint and reverse lookup state before every generic
  PC20 burn/remint route.

---

## EVM/SVM Parity

Latest local EVM comparison points:

- `origin/pr-130` / `origin/cea-pc20-consistency-fix` (`b8550f7`): direct/CEA PC20 burn merged into regular universal tx route.
- `origin/rescue-for-pc20` (`a3aaa91`): PC20 revert/rescue merged into regular revert/rescue route.
- `origin/pc20-3rd-iteration` (`e08eaf0`): 3rd-iteration PC20 interface base.

| Flow | EVM | SVM |
| --- | --- | --- |
| Export | `Vault.finalizeUniversalTx()` detects PC20 export | `finalize_universal_tx()` detects `PC20`-prefixed `ix_data` |
| Mint identity | `PC20Factory` maps source asset to wrapper contract | `Pc20Mint = PDA("pc20_mint", source_asset)` |
| Reverse lookup | wrapper exposes `SOURCE_ASSET()` | `Pc20State = PDA("pc20_state", wrapped_mint)` stores `source_asset`, `wrapped_mint`, `decimals` |
| Direct burn | `sendUniversalTx(req)` branches to `_routePC20Tx()` | `send_universal_tx(req, native_amount)` branches when PC20 remaining accounts are supplied |
| CEA burn | `sendUniversalTxFromCEA(req)` / CEA route burns PC20 without inbound fee and requires `req.recipient` to equal the mapped UEA | outer `finalize_universal_tx` self-routes inner generic `send_universal_tx(req, 0)`, requires `req.recipient == push_account`, and burns from CEA ATA when `amount > 0` |
| Burn revert | `revertUniversalTx()` PC20 branch calls `PC20Factory.revertMint()` | `revert_universal_tx()` PC20 branch remints via PDA mint authority |
| Rescue | `rescueFunds()` PC20 branch calls `PC20Factory.revertMint()` | `rescue_funds()` PC20 branch remints via PDA mint authority |
| Events | generic universal events carry `PC_20_SELECTOR || abi.encode(sourceAsset) || payload` | generic universal events carry `PC20 || abi_encode_address(source_asset) || payload` |
| CEA fee | CEA PC20 burn skips inbound fee | CEA PC20 burn skips inbound fee; direct user burn pays the regular inbound fee |

All primary PC20 lifecycle routes now use the generic gateway entrypoints. SVM
still needs PC20-specific `remaining_accounts` because a first export may create
an uninitialized mint/state/ATA, which cannot be modeled as the existing typed
SPL accounts without changing the public IDL account structs.

---

## Accounts and PDAs

| Account | Seeds / derivation | Purpose |
| --- | --- | --- |
| `Config` | `["config"]` | pause flag, vault bump, price feed, chain config |
| `Vault` / `vault_sol` | `["vault"]` | lamport pool used for Push-routed destination reimbursement |
| `FeeVault` | `["fee_vault"]` | inbound fee pool and revert/rescue reimbursement source |
| `TssPda` | `["final_tss_pda"]` | TSS Ethereum address and signature state |
| `CEA` PDA | `["push_identity", push_account_20]` | Push-account execution identity on Solana |
| `ExecutedSubTx` | `["executed_sub_tx", sub_tx_id]` | replay protection for TSS-routed instructions |
| `Pc20Mint` | `["pc20_mint", source_asset_20]` | canonical wrapped SPL mint |
| `Pc20State` | `["pc20_state", pc20_mint]` | reverse lookup equivalent of EVM `SOURCE_ASSET()` |
| Recipient / CEA ATA | standard ATA derivation | SPL token account for wrapped PC20 balances |

Mint authority model:

- `Pc20Mint` is also the mint authority.
- Mint/remint CPIs sign with `["pc20_mint", source_asset, bump]`.
- Freeze authority must be unset.
- A separate mint-authority PDA is not used.

---

## Instruction Surface

### `finalize_universal_tx` PC20 export branch

TSS-authorized Push -> Solana export.

Route selection:

```text
instruction_id = 5
ix_data = "PC20" || borsh(source_asset, name, symbol, decimals, user_data)
writable_flags = empty
```

Primary behavior:

- validates the TSS-signed `sub_tx_id`, `universal_tx_id`, `source_asset`,
  `push_account`, `recipient`, metadata fields, `amount`, `gas_fee`, optional
  `user_data`, and `deadline`,
- creates or validates `Pc20Mint`,
- creates or validates `Pc20State`,
- mints to recipient ATA for direct export,
- mints to CEA ATA and dispatches `user_data` for CEA export,
- reimburses relayer from `vault_sol`,
- emits the existing generic `UniversalTxFinalized`.

`Pc20State` is required because generic Solana burn/revert/rescue routes receive
only the wrapped mint as `req.token` / `token_mint`. Unlike EVM wrappers, SPL
mints cannot expose a `SOURCE_ASSET()` function.

Metadata note: metadata fields are part of the signed export payload. On first
mint, `decimals` is enforced by SPL mint initialization. For later exports of an
existing mint, the program validates the canonical source/mint/state mapping and
mint authority; it does not store or enforce mutable `name`/`symbol` metadata on
Solana.

### `send_universal_tx` PC20 branch

Primary direct Solana -> Push burn route.

Route selection:

```text
if remaining_accounts = [pc20_state, pc20_mint]:
  validate req.token == pc20_mint
  require req.amount > 0
  require native_amount >= inbound_fee_lamports
  require gateway_token_account = null
  validate pc20_state PDA and source_asset mapping
  validate canonical PC20 mint authority
  validate caller-owned ATA and burn caller ATA balance
  emit UniversalTx(payload = "PC20" || abi_encode_address(source_asset) || req.payload)
  if native_amount_after_fee > 0:
    emit and route a second native Funds UniversalTx
else:
  use normal native/SPL routing
```

PC20 burn tx type matches EVM:

```text
amount > 0 => FundsAndPayload
amount = 0 => InvalidAmount
```

Fee behavior:

- direct PC20 burn pays the same `inbound_fee_lamports` as regular
  `send_universal_tx`; native lamports above the fee are routed as a second
  native `Funds` transfer, matching EVM `_routePC20Tx(nativeValue > 0)`,
- CEA PC20 burn does not pay this fee because it is already inside a
  Push-routed finalize gas model.

There is no public PC20-specific direct burn instruction; direct burns route
through `send_universal_tx` with `[pc20_state, pc20_mint]` supplied as remaining
accounts.

### CEA PC20 burn through `finalize_universal_tx`

CEA-held wrapped supply is burned through the existing TSS-routed finalize path.

Outer requirements:

```text
instruction_id = 2
destination_program = universal_gateway
amount = 0
native path only
ix_data discriminator = send_universal_tx
remaining_accounts = [pc20_state, pc20_mint, cea_ata, token_program]
```

The handler parses the inner generic `send_universal_tx(req, 0)`, validates
`Pc20State`, requires `req.recipient == push_account`, validates the CEA ATA
and burns via CEA PDA signer seeds, and emits:

- generic `UniversalTx` with
  `payload = "PC20" || abi_encode_address(source_asset) || req.payload`.

The old inner `send_pc20_universal_tx` payload discriminator is still accepted
inside the CEA self-route for compatibility, but it is not a public SVM
instruction. That legacy inner payload uses
`remaining_accounts = [pc20_mint, cea_ata, token_program]`; the
generic inner payload uses `[pc20_state, pc20_mint, cea_ata, token_program]`
so the program can resolve the source asset without a PC20-specific public IDL
instruction.

### `revert_universal_tx` PC20 branch

TSS-authorized remint when Push-side unlock/execution fails after a Solana burn.

Route selection:

```text
if remaining_accounts = [pc20_state, pc20_mint, recipient_ata, associated_token_program, rent]:
  token_mint must be the wrapped PC20 mint
  token_vault and recipient_token_account must be absent
  token_program must be present
  pc20_mint must equal token_mint and be writable
  recipient_ata must be writable
  validate Pc20State and mint authority
  create recipient ATA when missing
  remint amount to recipient ATA
else:
  use normal native/SPL revert logic
```

This uses the existing generic revert entrypoint and `instruction_id = 3`, but
PC20 mode is domain-separated in the signed additional data:

```text
sub_tx_id || universal_tx_id || pc20_mint || recipient || gas_fee || revert_msg_hash || "PC20" || source_asset
```

The generic `revert_universal_tx` IDL account list is unchanged; PC20-only
accounts are supplied through `remaining_accounts` to avoid breaking normal
SOL/SPL callers.

There is no public PC20-specific revert instruction; remints route through the
generic `revert_universal_tx` branch.

### `rescue_funds` PC20 branch

TSS-authorized emergency remint through the generic rescue route.

Route selection matches `revert_universal_tx`: when the five PC20
`remaining_accounts` are supplied, the handler validates the PC20 mint/state pair
and remints to the remaining recipient ATA instead of transferring from a vault
ATA. The generic `rescue_funds` IDL account list is unchanged for normal SOL/SPL
rescue callers.

This uses the existing generic rescue entrypoint and `instruction_id = 4`, but
PC20 mode is domain-separated in the signed additional data:

```text
sub_tx_id || universal_tx_id || pc20_mint || recipient || gas_fee || "PC20" || source_asset
```

---

## Fee and Gas Model

| Route | Fee / reimbursement behavior |
| --- | --- |
| Direct `send_universal_tx` PC20 burn | caller pays `inbound_fee_lamports` to `FeeVault` before burn |
| CEA PC20 burn via `finalize_universal_tx` | no inbound fee; relayer reimbursement follows outer finalize gas model |
| `finalize_universal_tx` PC20 export | relayer reimbursed from `vault_sol` for measured signature/rent components actually paid |
| generic PC20 `revert_universal_tx` | relayer reimbursed from `fee_vault` for measured signature/replay/ATA rent, capped by signed `gas_fee` |
| generic PC20 `rescue_funds` | relayer reimbursed from `fee_vault` for measured signature/replay/ATA rent, capped by signed `gas_fee` |

PC20 export still uses measured gas accounting:

```text
signature_fee
+ executed_sub_tx_rent
+ wrapped_mint_rent_if_created
+ pc20_state_rent_if_created
+ recipient_ata_rent_if_created
+ cea_ata_rent_if_created
```

The signed gas budget must cover any expected mint/state/ATA creation rent.
If a PDA/ATA was prefunded, reimbursement uses only the missing lamports paid by
the relayer, not the full rent constant.

---

## Events

Primary indexer surface:

- PC20 export emits existing generic `UniversalTxFinalized` with the PC20 export
  `ix_data` as `payload`.
- Direct PC20 burn emits generic `UniversalTx` with
  `payload = "PC20" || abi_encode_address(source_asset) || payload`
  and `from_cea = false`.
- Direct PC20 burn with native lamports above the inbound fee also emits the
  existing native `Funds` `UniversalTx` for the extra native amount.
- CEA PC20 burn emits generic `UniversalTx` with
  `payload = "PC20" || abi_encode_address(source_asset) || payload`
  and `from_cea = true`.
- PC20 revert through generic route emits existing `RevertUniversalTx`.
- PC20 rescue through generic route emits existing `FundsRescued`.

The selector bytes are ASCII `PC20` (`0x50433230`). For burn events the selector
is followed by Solidity-compatible `abi.encode(address sourceAsset)`: a 32-byte
word with 12 leading zero bytes and the 20-byte source asset.

---

## Security Properties

- Mint/remint requires TSS authorization except direct/CEA burns, which only burn
  already-owned wrapped supply.
- TSS messages include `deadline`.
- Generic PC20 revert/rescue signatures include `"PC20" || source_asset` so the
  same TSS signature cannot be switched between normal SPL transfer and PC20
  remint by changing `remaining_accounts`.
- TSS-routed routes create `ExecutedSubTx` replay markers.
- `Pc20State` prevents a generic `req.token` mint from being treated as a PC20
  wrapper without a canonical `source_asset` mapping.
- Wrapped mint PDA derivation ties `source_asset` to `pc20_mint`.
- Mint authority must equal the mint PDA and freeze authority must be unset.
- ATAs are validated after lazy creation.
- Direct burn validates caller-owned ATA before burning.
- CEA burn validates the CEA ATA and burns only through CEA PDA signer seeds.
- Generic PC20 revert/rescue reject vault token accounts to avoid accidentally
  treating vault-held SPL funds as mintable PC20 supply.

---

## Compatibility Notes

The CEA self-route decoder still accepts the old inner
`send_pc20_universal_tx` payload discriminator for compatibility while the
EVM-parity route
moves to generic `finalize_universal_tx`, `send_universal_tx`,
`revert_universal_tx`, and `rescue_funds`.
Relayers/indexers should treat the generic events as the only canonical PC20
event surface.

Client-level account tables and signed-data byte layouts are in
`docs/7A-PC20-INTEGRATION.md`.

---

## References

Local code:

- `programs/universal-gateway/src/instructions/pc20.rs`
- `programs/universal-gateway/src/instructions/deposit.rs`
- `programs/universal-gateway/src/instructions/execute.rs`
- `programs/universal-gateway/src/instructions/revert.rs`
- `programs/universal-gateway/src/instructions/rescue.rs`
- `programs/universal-gateway/src/state.rs`

EVM comparison:

- gateway PR #130: generic PC20 burn route
- gateway PR #131: generic PC20 revert/rescue route
