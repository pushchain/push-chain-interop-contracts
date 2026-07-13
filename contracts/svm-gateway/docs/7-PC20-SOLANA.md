# PC20 on Solana - Architecture

This document defines the Solana-side PC20 architecture after the EVM
3rd-iteration PC20 changes.

PC20 enables Push-native assets to be represented on Solana as canonical wrapped
SPL mints. The Solana gateway should match the EVM protocol outcome, but should
not copy EVM contract structure when Solana PDAs, account validation, and SPL
Token authority rules give a cleaner implementation.

This is an SVM architecture reference, not a full Push-side or relayer runbook.

---

## Core Invariant

For every Push-native PC20 source asset:

```text
locked_on_push == total_wrapped_supply_on_all_destinations
```

For the Solana leg:

```text
locked_on_push >= wrapped_supply_on_solana
```

The invariant is maintained by Push-side locks, TSS-authorized Solana minting,
Solana burns before Push unlock, burn-revert remints, and replay protection on
TSS finalize/revert instructions.

---

## EVM/SVM Parity

Latest local EVM comparison point: `origin/pc20-3rd-iteration` at
`51e937ad48a07dd80a97d95af2466c87e8e7bafc`.

| Flow / property | EVM 3rd iteration | SVM PC20 | Result |
| --- | --- | --- | --- |
| Source event | `sendUniversalTxOutbound()` emits `UniversalTxOutbound` with `PC_20_SELECTOR` payload | relayer consumes the same event and calls SVM PC20 finalize | same source event |
| Export settlement | `Vault.finalizeUniversalTx()` detects PC20 and calls `_finalizePC20Export()` | `finalize_pc20_export` | same lock -> mint outcome |
| Wrapper identity | `PC20Factory` maps `sourceAsset` to wrapper contract | SPL mint PDA derived from `["pc20_mint", source_asset]` | same canonical mapping |
| First-export metadata | wrapper deploy sets metadata; later exports reuse wrapper | first mint creation fixes SPL decimals; name/symbol are signed but not stored | same first-wrapper semantics |
| User burn | `sendPC20UniversalTx()` burns from caller wrapper balance | `send_pc20_universal_tx` burns from caller-owned ATA | same user-authorized burn |
| CEA burn | CEA multicall invokes `sendPC20UniversalTx()` | `finalize_universal_tx` self-routes a `send_pc20_universal_tx` payload and burns from CEA ATA | same Push-routed CEA burn outcome |
| Export revert | Push-side `VaultPC20.revertExport()` | same Push-side recovery; SVM finalize is atomic | same recovery domain |
| Burn revert | `revertPC20Burn()` calls `PC20Factory.revertMint()` | `revert_pc20_burn` remints via PDA mint authority | same failed-unlock recovery |
| Burn-revert binding | new revert `subTxId`; no on-chain binding to original burn | new revert `sub_tx_id`; `original_burn_sub_tx_id` is signed/emitted only | same TSS-orchestrated model |
| TSS freshness | role-gated EVM call | ECDSA TSS signature plus signed `deadline` | SVM is stricter |

---

## Intentional SVM Differences

### No Factory Contract

EVM needs `PC20Factory` because wrappers are contracts. Solana does not.

SVM uses:

```text
Pc20Mint = PDA("pc20_mint", source_asset_20)
```

This gives the same canonical `source_asset -> wrapper` mapping without a factory
or registry account.

### No Registry in v1

No separate `Pc20State` is required in the current implementation. A per-token
state PDA should only be added later if the program needs mutable data that cannot
be derived from the mint PDA, token metadata, or source asset.

### Dedicated Export Instruction

EVM can branch inside `Vault.finalizeUniversalTx()` because accounts are runtime
addresses in calldata. Solana account sets are part of the instruction ABI, so a
dedicated `finalize_pc20_export` keeps mint, ATA, token-program, and replay
accounts explicit under Anchor validation.

### CEA Burn Uses Existing Finalize Surface

EVM CEA burn is:

```text
Vault.finalizeUniversalTx -> CEA.executeUniversalTx -> sendPC20UniversalTx
```

SVM cannot implement that as a gateway-to-gateway CPI. The gateway instead detects
the self-route inside `finalize_universal_tx` and dispatches in-process.

The route is:

```text
finalize_universal_tx
  instruction_id = 2
  destination_program = universal_gateway
  amount = 0
  native path only
  ix_data discriminator = send_pc20_universal_tx
  remaining_accounts = [pc20_mint, cea_ata, token_program]
```

Authorization is the outer TSS-signed `finalize_universal_tx` message. Burn
authority is the CEA PDA signer derived from `push_account`.

---

## Accounts and PDAs

| Account | Seeds / derivation | Purpose |
| --- | --- | --- |
| `Config` | `["config"]` | existing gateway config, pause flag, gas settings |
| `Vault` / `vault_sol` | `["vault"]` | lamport pool used by Push-routed destination reimbursement |
| `FeeVault` | `["fee_vault"]` | inbound fee pool used by burn-revert reimbursement |
| `TssPda` | `["final_tss_pda"]` | stores TSS Ethereum address for signature verification |
| `CEA` PDA | `["push_identity", push_account_20]` | Push-account execution identity on Solana |
| `ExecutedSubTx` | `["executed_sub_tx", sub_tx_id]` | replay protection for finalize and revert |
| `StoredIxData` | `["stored_ix_data", sub_tx_id, ix_data_hash]` | existing oversized-payload route; not PC20-specific |
| `Pc20Mint` | `["pc20_mint", source_asset_20]` | canonical wrapped SPL mint |
| Recipient / CEA ATA | standard ATA derivation | token account for wrapped SPL balances |

Mint authority model:

- `Pc20Mint` is also the mint authority.
- Minting/reminting signs CPIs with the mint PDA seeds.
- Freeze authority is unset.
- A separate mint-authority PDA is not needed for v1.

---

## Instruction Surface

### `finalize_pc20_export`

TSS-authorized Push -> Solana export.

Primary data: `sub_tx_id`, `universal_tx_id`, `source_asset`, `amount`,
`push_account`, Solana `recipient`, `name`, `symbol`, `decimals`, optional
`user_data`, `gas_fee`, `deadline`, and TSS signature fields.

Key guarantees:

- rejects zero amount, zero source asset, paused config, and default recipient,
- requires `ctx.accounts.recipient.key() == recipient`,
- creates `ExecutedSubTx` for replay protection,
- creates the canonical mint PDA if missing, using dust-safe PDA creation,
- initializes new mint decimals from the signed payload,
- validates existing mint authority and unset freeze authority,
- signs and verifies TSS payload with `deadline`,
- mints to recipient ATA when `user_data` is empty,
- mints to CEA ATA and dispatches CEA payload when `user_data` is present,
- validates ATA owner and mint after lazy ATA creation,
- reimburses relayer from `vault_sol`,
- emits `Pc20ExportFinalized`.

Signed fields include `sub_tx_id`, `universal_tx_id`, `push_account`,
`source_asset`, `recipient`, `name`, `symbol`, `decimals`, `gas_fee`, `amount`,
`deadline`, and `user_data` when present.

Current v1 signs `name`, `symbol`, and `decimals`, but only SPL mint `decimals`
are stored on-chain. Metaplex metadata is not created by the current program.
On re-export of an existing `source_asset`, the program validates the canonical
mint's authority and unset freeze authority only; `name`/`symbol`/`decimals` are
not re-checked against the first-export values (matches EVM's factory model).

#### `user_data` binary encoding

When present, `user_data` is the concatenation (big-endian lengths):

```
[u32 BE accounts_len]
  ( [32 bytes pubkey] [u8 is_writable] ) * accounts_len
[u32 BE ix_data_len]
[ix_data_len bytes ix_data]
[u8 instruction_id]
[32 bytes target_program]
```

The Solana-side handler validates `target_program == destination_program`,
`instruction_id == 2`, and that `remaining_accounts` matches the signed
`accounts` list (pubkey + writable flag).

### `send_pc20_universal_tx`

User-initiated Solana -> Push burn.

Primary data: `sub_tx_id`, `source_asset`, `amount`, Push `recipient`, Push
`payload`, and Solana `revert_recipient`.

Key guarantees:

- caller must sign,
- caller ATA must be owned by caller,
- caller ATA mint must equal canonical `Pc20Mint`,
- burns wrapped SPL supply from caller ATA,
- collects a flat `inbound_fee_lamports` from caller into `FeeVault` (mirrors
  EVM `sendPC20UniversalTx` `_collectInboundFee`; skipped when `inbound_fee_lamports == 0`),
- emits `Pc20UniversalTx` with `from_cea = false` and `fee_collected = amount taken`.

This instruction has no TSS signature and no relayer reimbursement. The Solana
caller pays the transaction cost plus the `inbound_fee`.

There is no SVM replay marker on the direct burn: `sub_tx_id` uniqueness is a
Push-side concern, and a repeat call actually burns tokens again (event-only
signal to Push).

### CEA PC20 Burn via `finalize_universal_tx`

CEA-held wrapped supply is burned through the existing TSS-routed finalize path,
not through a separate public CEA-burn instruction.

Outer finalize requirements: `instruction_id = 2`,
`destination_program == program_id`, `amount = 0`, native path only, `ix_data`
starts with the `send_pc20_universal_tx` discriminator, and remaining accounts
are exactly writable `Pc20Mint`, writable CEA ATA, readonly SPL Token program,
writable `FeeVault`, readonly System program.

Key guarantees:

- TSS signature and deadline are verified by `finalize_universal_tx`,
- `sub_tx_id` inside `ix_data` must equal the outer finalize `sub_tx_id`,
- CEA ATA is validated against the canonical mint and CEA authority,
- burn uses CEA PDA signer seeds,
- inbound fee is transferred from the CEA PDA to `FeeVault` (CEA-signed
  `system_program::transfer`), mirroring EVM `sendPC20UniversalTx`
  `_collectInboundFee`. CEA must hold `>= inbound_fee_lamports` SOL or the
  burn reverts with `InsufficientInboundFee`; no-op when the fee is 0.
- emits `Pc20UniversalTx` with `from_cea = true` and real `fee_collected`,
- outer-finalize gas is still reimbursed from `vault_sol`.

### `revert_pc20_burn`

TSS-authorized Solana remint when Push-side unlock fails after a Solana burn.

Primary data: new revert `sub_tx_id`, `original_burn_sub_tx_id`,
`source_asset`, `amount`, Solana `revert_recipient`, `gas_fee`, `deadline`, and
TSS signature fields.

Key guarantees:

- creates `ExecutedSubTx` for replay protection on the revert `sub_tx_id`,
- requires `ctx.accounts.revert_recipient.key() == revert_recipient`,
- verifies TSS signature with deadline,
- validates canonical mint authority and unset freeze authority,
- creates revert recipient ATA when missing,
- validates ATA owner and mint,
- remints wrapped SPL supply to the revert recipient ATA,
- reimburses relayer from `fee_vault`,
- emits `Pc20BurnReverted`.

`original_burn_sub_tx_id` is signed and emitted for indexers and audit trails. It
is not an on-chain burn-marker check. This matches EVM's `revertPC20Burn()`
model, where the new revert `subTxId` is replay-protected but not cryptographically
bound on-chain to the original burn.

---

## Fee Model

PC20 uses the same source-quoted lamport budget model as the rest of the SVM
gateway:

```text
quoted_budget = gasPrice * gasLimit
```

On Solana, this value is a signed lamport budget, not literal EVM gas.

Gas reimbursement (operational) and inbound fee (revenue) are separate:

| Route | Relayer gas | Inbound fee |
| --- | --- | --- |
| `finalize_pc20_export` | `vault_sol` | none |
| CEA PC20 burn via `finalize_universal_tx` | `vault_sol` | CEA PDA pays |
| User `send_pc20_universal_tx` burn | caller pays tx cost | caller pays |
| `revert_pc20_burn` | `fee_vault` | none |

Gas is `vault_sol` for Push-routed finalizations (paired with source-side
`swapAndBurnGas`) and `fee_vault` for burn revert (no paired Push-side burn).
Inbound fee is charged on every PC20 burn — direct or CEA — mirroring EVM
`sendPC20UniversalTx._collectInboundFee`.

Current PC20 gas-used components:

```text
signature_fee
+ executed_sub_tx_rent
+ wrapped_mint_rent_if_created
+ recipient_ata_rent_if_created
+ cea_ata_rent_if_created
```

For `revert_pc20_burn`, current components are:

```text
signature_fee
+ executed_sub_tx_rent
+ recipient_ata_rent_if_created
```

Rules: require `gas_fee >= gas_used`, reimburse only `gas_used`, emit
`gas_to_refund = gas_fee - gas_used` where applicable, and require callers to
increase `gasLimit` when expecting mint or ATA creation rent beyond the base path.

Metaplex metadata is not enabled in v1. If it is added later, metadata rent must
be added to the signed gas budget.

---

## Relayer Requirements

Push -> Solana export: listen to `UniversalTxOutbound`, detect
`PC_20_SELECTOR`, decode the metadata envelope, pass remaining bytes as SVM
`user_data`, and build `finalize_pc20_export`.

Solana -> Push burn: index `Pc20UniversalTx` and map `source_asset`, `amount`,
recipient, payload, and `from_cea` to Push-side unlock/execution handling.

CEA PC20 burn: build a payload-only `finalize_universal_tx` to the gateway
program itself, keep generic SPL staging accounts absent, and pass
`[pc20_mint, cea_ata, token_program]` in `remaining_accounts`.

Burn revert: when Push-side unlock fails, allocate a new revert `sub_tx_id`,
include the original burn subTx ID in the signed SVM revert message, and call
`revert_pc20_burn`.

---

## Events

Canonical event layouts live in
`programs/universal-gateway/src/state.rs`.

PC20 events:

| Event | Purpose |
| --- | --- |
| `Pc20ExportFinalized` | Push -> Solana export settled and wrapped supply minted |
| `Pc20UniversalTx` | Solana wrapped supply burned for Push-side unlock/execution |
| `Pc20BurnReverted` | failed Push-side unlock reminted on Solana |

Push-side source event:

- `UniversalTxOutbound`, distinguished as PC20 by `PC_20_SELECTOR` in payload.

---

## Security Properties

- Only TSS-authorized PC20 finalize and burn-revert paths can mint wrapped supply.
- TSS signatures include signed `deadline`.
- Finalize and burn-revert paths are replay-protected by `ExecutedSubTx`.
- Signed recipient pubkeys are bound to supplied Solana accounts.
- ATAs are validated by expected owner and mint after lazy creation.
- Canonical wrapped mint is derived from `source_asset`; no registry spoofing path.
- Mint/remint authority is PDA-controlled.
- Freeze authority must be unset.
- Existing mint validation prevents replacing the canonical PDA with a malformed
  SPL account.
- Destination excess gas budget is not paid to the relayer; only `gas_used` is
  reimbursed.
- CEA PC20 burn is authorized by the outer TSS finalize message and CEA PDA seeds.
- There is no burn-marker account; burn-revert trust matches latest EVM and relies
  on TSS not signing duplicate revert subTx IDs for the same failed burn.

---

## Not in v1

- No Metaplex metadata account creation.
- No `Pc20State` or registry PDA.
- No separate mint-authority PDA.
- No stored-by-reference PC20 export finalize route; direct `user_data` is used.
- No on-chain burn marker tying revert to the original burn.

These are future extensions, not current architecture requirements.

---

## Post-Audit Integration Notes

This branch is based on the audit-main-fixes SVM shape:

- TSS PDA seed is `final_tss_pda`.
- PC20 TSS messages include `deadline`.
- fee naming follows `inbound_fee`.
- `StoredIxData` remains available for the generic finalize route.
- recipient account binding is enforced in PC20 finalize and burn revert.
- burn-revert parity follows EVM's dedicated `revertPC20Burn()` /
  `PC20Factory.revertMint()` path.

---

## References

### Local code references

- Program entrypoints: `programs/universal-gateway/src/lib.rs`
- PC20 instruction implementation: `programs/universal-gateway/src/instructions/pc20.rs`
- CEA self-route dispatch: `programs/universal-gateway/src/instructions/execute.rs`
- Event structs and PDA seeds: `programs/universal-gateway/src/state.rs`
- Shared ATA/PDA helpers: `programs/universal-gateway/src/utils/transfers.rs`

### EVM / Push references

- [PC20 3rd-iteration PR #128](https://github.com/pushchain/push-chain-gateway-contracts/pull/128/changes#top)
- [3rd-iteration `UniversalGateway.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-3rd-iteration/contracts/evm-gateway/src/UniversalGateway.sol)
- [3rd-iteration `Vault.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-3rd-iteration/contracts/evm-gateway/src/Vault.sol)
- [3rd-iteration `PC20Factory.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-3rd-iteration/contracts/evm-gateway/src/PC20Factory.sol)
- [2nd-iteration `UniversalCore.sol`](https://raw.githubusercontent.com/pushchain/push-chain-core-contracts/pc20-2nd-iteration/src/UniversalCore.sol)

### Solana / Anchor references

- [Program Derived Addresses](https://solana.com/docs/core/pda)
- [Cross Program Invocation](https://solana.com/docs/core/cpi)
- [Create a Token Mint](https://solana.com/docs/tokens/basics/create-mint)
- [Anchor PDA mint authority example](https://www.anchor-lang.com/docs/tokens/basics/mint-tokens)
