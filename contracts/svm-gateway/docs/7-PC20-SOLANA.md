# PC20 on Solana - Architecture

This document defines the Solana destination architecture for PC20 after the EVM 3rd-iteration change.

The important change is not "PC20 exists on Solana." That part was already clear. The important change is that the Push-side and EVM-side architecture no longer treat PC20 as a parallel outbound lane with separate public entrypoints. PC20 is now tunneled through the existing outbound surface with a selector-prefixed payload, and the Solana design should mirror that semantic model without forcing an EVM-style structure onto SVM.

---

## Alignment With EVM 3rd Iteration

Compared with the earlier PC20 draft, the 3rd iteration changes the architecture in four material ways:

1. Push-side export is no longer a separate `exportPC20()` public flow. It is now a PC20 branch inside `UniversalGatewayPC.sendUniversalTxOutbound()`.
2. The source event is no longer `PC20ExportInitiated`. It is the existing `UniversalTxOutbound` event, and PC20 is detected by the `PC_20_SELECTOR` prefix in `payload`.
3. Destination metadata is now carried inside the outbound payload. TSS no longer needs to fetch the token metadata as a separate off-chain step for settlement construction.
4. On EVM, the Vault no longer exposes a separate public `finalizePC20Export()` entrypoint. PC20 is routed internally through the existing `finalizeUniversalTx()` surface after selector detection.

For Solana, the first three changes should be mirrored exactly. The fourth should be mirrored semantically, not structurally: Solana should reuse the same Push-side event and relayer semantics, but it does not need to overload the current SVM `finalize_universal_tx` instruction if that makes the account model worse.

### What Did Not Change in Core

No additional Push core-contract delta was identified for the 3rd iteration.

The available core source already contains the PC20-specific fee interface and first-export overhead model:

- `pc20DeploymentGasOverhead`
- `getPC20ExportGasAndFees(destChainNamespace, gasLimit, pc20Token)`
- `updatePC20DeploymentGasOverhead(...)`

The gateway PR continues to consume that same core interface. So the architecture update is gateway-side and relayer-side, not a new core-contract redesign.

---

## Core Invariant

For every Push-native token:

```text
locked_on_push == total_wrapped_supply_on_all_destinations
```

For the Solana leg specifically:

```text
locked_on_push >= wrapped_supply_on_solana
```

This invariant is enforced by:

- locking originals on Push in `VaultPC20`,
- minting only through a TSS-authorized Solana finalization path,
- burning wrapped supply on Solana before Push-side unlock,
- replay protection on both sides,
- reminting on Solana if the Push-side unlock fails after a burn.

---

## Actors

| Actor | Role |
|-------|------|
| User | Initiates export on Push, receives wrapped mint on Solana, or burns wrapped supply on Solana for return |
| UniversalGatewayPC | Push-side outbound entrypoint (`sendUniversalTxOutbound`) |
| UniversalCore | Push-side fee quote source for `getPC20ExportGasAndFees()` |
| VaultPC20 | Push-side custody vault for locked originals |
| TSS | Observes source events, signs destination settlement, signs recovery flows |
| UV / relayer | Builds Solana transactions, submits them, fronts rent and runtime fees, and is reimbursed from the signed gas budget |
| SVM Gateway Program | Solana-side PC20 mint, burn, execution, and recovery authority |

---

## Push-Side Architecture (3rd Iteration Model)

### Components

| Component | Responsibility |
|-----------|----------------|
| `UniversalGatewayPC.sendUniversalTxOutbound()` | unified outbound entrypoint for PRC20 and PC20 |
| `UniversalOutboundTxRequest` | unchanged outbound request struct |
| `UniversalCore.getPC20ExportGasAndFees()` | quotes Solana destination gas budget |
| `VaultPC20` | records locks, unlocks on return, reverts failed exports |
| `UniversalTxOutbound` | canonical source event for Push -> Solana PC20 export |

### PC20 Discriminator

PC20 is identified by:

```text
PC_20_SELECTOR = 0x50433230
```

The selector is carried at the beginning of the outbound payload.

### Push Payload Format

The 3rd-iteration Push payload is:

```text
payload =
  abi.encodePacked(
    PC_20_SELECTOR,
    abi.encode(destChainNamespace, name, symbol, decimals)
  )
  ++ userData
```

Where:

- `destChainNamespace` is the destination chain identifier used for fee quoting and event routing,
- `name`, `symbol`, `decimals` are the wrapped-token metadata for first export,
- `userData` is opaque destination-specific payload.

For Solana destinations, `userData` should carry the existing SVM execute payload format already described in the integration guide, not a new PC20-specific CPI format.

### Push Request Shape

PC20 now uses the existing outbound request shape:

```solidity
struct UniversalOutboundTxRequest {
    bytes recipient;
    address token;
    uint256 amount;
    uint256 gasLimit;
    uint256 gasPrice;
    uint256 maxPCForGas;
    bytes payload;
    address revertRecipient;
}
```

For the PC20 branch:

- `recipient` stays VM-agnostic and carries the Solana destination wallet bytes,
- `token` is the Push-native source asset,
- `amount` must be non-zero,
- `payload` must start with `PC_20_SELECTOR`,
- `gasPrice` override is not supported for the PC20 path,
- `txType` emitted on Push is always `FUNDS_AND_PAYLOAD`.

### Push Export Flow

1. User calls `sendUniversalTxOutbound(req)` on Push Chain.
2. Gateway validates shared fields (`token`, `revertRecipient`) and detects PC20 by checking `payload[:4] == PC_20_SELECTOR`.
3. Gateway confirms the token supports the PC20 interface by calling `IPC20(token).pc20Metadata()`.
4. Gateway decodes `destChainNamespace` from the selector-prefixed payload.
5. Gateway calls `UniversalCore.getPC20ExportGasAndFees(destChainNamespace, gasLimit, token)`.
6. Gateway transfers the source token into `VaultPC20` and calls `recordLock(token, amount)`.
7. Gateway collects protocol fee, performs the gas swap, and refunds any capped excess exactly the same way the current SVM gas model expects on the source side.
8. Gateway increments the shared nonce and computes `subTxId`.
9. Gateway emits `UniversalTxOutbound`, with:
   - `chainNamespace = destChainNamespace`
   - `txType = FUNDS_AND_PAYLOAD`
   - `payload = PC20 selector + metadata + optional Solana userData`
10. TSS and UV route from this event to Solana settlement.

### Push Failure Recovery

If the Solana settlement fails after export initiation, TSS calls:

- `VaultPC20.revertExport(subTxId, token, amount, revertRecipient)`

That returns the original Push-native asset to the Push-side revert recipient and restores the invariant.

---

## Solana Design Rule

The target is outcome parity with the EVM 3rd-iteration PC20 model, not structural parity.

That means:

- preserve the same Push-side entrypoint and source event,
- preserve the same lock -> mint -> burn -> unlock / revert lifecycle,
- preserve the same replay and gas-budget semantics,
- preserve the same selector-based PC20 identification,
- but use Solana-native accounts, PDAs, and token authority models where the EVM structure is just an implementation detail.

Applied to Solana, that means:

- no factory contract if deterministic PDA mint derivation gives the same canonical mapping,
- no registry account if `source_asset -> wrapped_mint` can be derived directly,
- no "program-is-authority" shortcut when Solana requires PDA signing,
- no forced reuse of the current `finalize_universal_tx` instruction if its account graph is the wrong shape for mint-first settlement.

---

## Recommended SVM Settlement Surface

EVM 3rd iteration routes PC20 through the existing `Vault.finalizeUniversalTx()` function after selector detection.

Solana should not copy that exact structure.

### Why Not Reuse `finalize_universal_tx` Directly

The current SVM finalize path is explicitly a vault-withdraw / vault-execute path:

- `finalize_universal_tx` only supports `instruction_id = 1` (withdraw) and `2` (execute),
- its account graph is centered on `vault_sol`, `vault_ata`, `cea_authority`, `destination_program`, and optional recipient ATA accounts,
- its validation assumes the asset source is the existing Solana vault path, not a first-time mint creation path.

That is appropriate for current PRC20/SOL/SPL settlement. It is not the cleanest shape for PC20 wrapped-mint creation.

### Recommendation

Keep semantic unification at the Push event and relayer layer, but use a dedicated PC20 instruction family on Solana:

- `finalize_pc20_export`
- `send_pc20_universal_tx`
- `finalize_universal_tx` self-call carrying `send_pc20_universal_tx` payload for CEA-held wrapped supply
- `revert_pc20_burn`

This gives the same result as EVM 3rd iteration while keeping the Solana account constraints explicit and easier to audit.

---

## Solana Representation of the EVM 3rd-Iteration Pieces

| EVM / Push 3rd-iteration piece | Solana equivalent |
| --- | --- |
| `PC_20_SELECTOR` in Push payload | same selector in `UniversalTxOutbound.payload`, used by relayer to route to the SVM PC20 path |
| `UniversalTxOutbound` source event | same source event; no separate Push-side PC20 export event |
| EVM Vault internal PC20 branch inside `finalizeUniversalTx()` | dedicated Solana PC20 finalize instructions |
| EVM CEA calling `sendPC20UniversalTx()` | SVM `finalize_universal_tx` self-call with `send_pc20_universal_tx` discriminator and PC20 burn accounts in `remaining_accounts` |
| `PC20Factory.getWrapper(sourceAsset)` | deterministic PDA derivation of `Pc20Mint` from `source_asset` |
| `PC20Wrapper` | wrapped SPL mint |
| factory mint/burn authority | mint PDA signer controlled via `invoke_signed` |
| factory mapping | deterministic mint address, optionally augmented by small per-token PDA state |

---

## Solana Accounts and PDAs

### Existing accounts reused

| Account | Seeds | Purpose |
|---------|-------|---------|
| `Config` | `["config"]` | existing gateway config and gas-accounting config |
| `Vault` | `["vault"]` | existing lamport pool used by the current SVM gas reimbursement model |
| `TssPda` | `["final_tss_pda"]` | verifies the TSS Ethereum address used to authorize settlement |
| `CEA` PDA | `["push_identity", push_account_20]` | per-Push-account execution identity |
| `ExecutedSubTx` | `["executed_sub_tx", sub_tx_id]` | replay protection for finalize and revert |
| `StoredIxData` | `["stored_ix_data", sub_tx_id, ix_data_hash]` | existing stored-by-reference route for oversized execution payloads |

### New required PC20 accounts

| Account | Seeds | Purpose |
|---------|-------|---------|
| `Pc20Mint` | `["pc20_mint", source_asset_20]` | canonical wrapped SPL mint for one Push-native source asset |
| `Pc20MintAta` | standard ATA derivation | recipient ATA or CEA ATA for the wrapped mint |

### Optional per-token state

A separate registry is not required if the only mapping needed is:

```text
source_asset -> wrapped_mint
```

because the program can derive the canonical mint directly from `source_asset`.

If mutable per-token state is needed later, add a small PDA such as:

| Account | Seeds | Purpose |
|---------|-------|---------|

Recommended rule:

- do not add a registry just to mimic EVM's `sourceToWrapper` mapping,
- add `Pc20State` only when the program needs mutable data that cannot be derived from the mint PDA, metadata PDA, or source asset.

### Mint Authority Model

The gateway program itself is not a signer. On Solana, signer authority for CPIs comes from PDAs used with `invoke_signed`.

For PC20, the recommended default is:

- derive the wrapped mint as `Pc20Mint = PDA("pc20_mint", source_asset_20)`,
- set the mint's authority to that same PDA,
- sign minting and reminting CPIs with the mint PDA seeds.

This is the cleanest Solana-native pattern and is explicitly supported by the Anchor PDA-mint-authority model.

A separate authority PDA is optional, not required.

Use a separate authority PDA only if the design later needs:

- authority rotation independent of the mint identity,
- separate mint authority vs freeze or metadata authority,
- multiple signer roles per wrapped token,
- or mutable per-token control state that should itself be the signer.

For v1 PC20, the default should be:

- mint PDA as mint authority,
- no separate registry,
- no separate mint-authority PDA,
- freeze authority set only if the product explicitly wants freeze semantics.

---

## Instruction Surface

### 1. `finalize_pc20_export`

TSS-authorized settlement for Push -> Solana export.

Responsibilities:

- verify TSS signature,
- create replay marker,
- derive the canonical `Pc20Mint` from `source_asset`,
- create and initialize the mint on first export,
- optionally create Metaplex metadata on first export,
- create recipient or CEA ATA when missing,
- mint wrapped supply,
- optionally execute Solana userData through the existing CEA execution model,
- reimburse the relayer from the signed gas budget,
- emit a finalized event.

### 2. `send_pc20_universal_tx`

User-initiated Solana -> Push burn path.

Responsibilities:

- validate the canonical wrapped mint for the declared `source_asset`,
- burn wrapped supply from the user's ATA,
- emit the Solana-side PC20 burn event that validators map to `VaultPC20.unlock()` on Push.

### 3. `finalize_universal_tx` self-call with `send_pc20_universal_tx` payload

CEA-initiated Solana -> Push burn path for wrapped supply held in the CEA ATA after payload-based flows.

Responsibilities:

- verify the normal TSS execute signature for `finalize_universal_tx`,
- require native payload-only staging (`amount = 0`, no generic SPL mint accounts),
- decode the existing `send_pc20_universal_tx` discriminator and arguments from `ix_data`,
- validate the canonical PC20 mint PDA, CEA ATA, and SPL Token program from `remaining_accounts`,
- burn wrapped supply from the CEA ATA using PDA authority,
- emit the same burn event semantics as the user path.

### 4. `revert_pc20_burn`

TSS-authorized recovery path for a Solana burn when the Push-side unlock fails.

Responsibilities:

- use a new `revert_sub_tx_id`,
- replay-protect the remint instruction independently of the original burn,
- remint the same wrapped amount on Solana,
- mint back to the declared Solana-side revert recipient,
- replay-protect the remint via its own `sub_tx_id` (`ExecutedSubTx` PDA).

This mirrors EVM's wrapper-burn recovery: the remint is not bound on-chain to the
original burn. Like EVM, it is a fresh TSS-authorized remint to the declared revert
recipient; preventing a double remint is a TSS-orchestration responsibility, exactly
as on EVM.

---

## Finalize Architecture: Push -> Solana

### Source Event

The canonical source event is the Push-side `UniversalTxOutbound` event.

The relayer determines that the event is PC20 when:

```text
payload[0..4] == PC_20_SELECTOR
```

There is no separate Push-side `PC20ExportInitiated` event in the 3rd iteration.

### Metadata Resolution

For Solana settlement, metadata is taken from the event payload, not fetched separately from the Push token contract.

The relayer must:

1. confirm the selector prefix,
2. decode `destChainNamespace`, `name`, `symbol`, `decimals` from the metadata envelope,
3. strip that envelope,
4. treat the remaining bytes as Solana-specific `userData`.

For Solana payload execution, that `userData` should be interpreted as the existing SVM execute payload format already used by the current outbound execution path.

### Signed Inputs

The signed settlement payload should minimally bind:

- `sub_tx_id`
- `universal_tx_id`
- `push_account`
- `source_asset`
- destination Solana recipient
- `amount`
- `name`
- `symbol`
- `decimals`
- `gas_fee`
- `deadline`

If Solana userData is present, the signed payload should also bind:

- the destination program,
- ordered account metas,
- writable flags,
- raw `ix_data` bytes or the stored `ix_data_hash` reference.

This mirrors the current SVM execution model, which already signs the destination program and payload bytes for execute flows.

### Flow Without Solana userData

1. UV observes `UniversalTxOutbound` on Push Chain and detects `PC_20_SELECTOR`.
2. UV/TSS decode metadata and build the Solana finalize transaction.
3. Solana gateway verifies the TSS signature through `TssPda`.
4. Gateway creates `ExecutedSubTx` for replay protection.
5. Gateway derives `Pc20Mint` from `source_asset`.
6. If the mint does not exist:
   - create `Pc20Mint`,
   - initialize it with the mint PDA as mint authority,
   - optionally create Metaplex metadata,
7. Gateway derives the recipient ATA for `Pc20Mint`.
8. If the recipient ATA is missing, create it.
9. Gateway mints `amount` of wrapped supply to the recipient ATA.
10. Gateway computes and reimburses the relayer using the signed gas budget.
11. Gateway emits `Pc20ExportFinalized`.

### Flow With Solana userData

1. UV observes `UniversalTxOutbound` and detects `PC_20_SELECTOR`.
2. UV/TSS decode metadata and extract Solana `userData` from the payload tail.
3. Solana gateway verifies the TSS signature through `TssPda`.
4. Gateway creates `ExecutedSubTx`.
5. Gateway derives `Pc20Mint` from `source_asset`.
6. If first export, create mint and optional metadata as above.
7. Gateway derives the `CEA` PDA from `push_account`.
8. Gateway derives the `CEA` ATA for `Pc20Mint`.
9. If the CEA ATA is missing, create it.
10. Gateway mints `amount` of wrapped supply to the CEA ATA.
11. Gateway executes the Solana payload through `invoke_signed` using the existing CEA model.
12. Gateway computes and reimburses the relayer using the signed gas budget.
13. Gateway emits `Pc20ExportFinalized`.

### Large Solana userData

The current implementation expects Solana `userData` bytes to fit in the direct `finalize_pc20_export` transaction.

If this becomes too large later, add an explicit stored-by-reference PC20 finalize route that:

1. stores the Solana execution bytes in `StoredIxData`,
2. loads those bytes before TSS verification,
3. charges the same extra stored-route surcharge already used by the current SVM ref-finalize path.

The selector-prefixed Push payload format does not change. Only the Solana execution bytes are offloaded to the existing stored-by-reference route.

### Metadata Reuse After First Export

After the canonical Solana mint already exists:

- the finalize path should not mutate the mint identity,
- metadata should be treated as first-export initialization data, not an update authority,
- the current implementation fixes `decimals` at first mint creation and does not
  persist any metadata commitment; later exports for the same `source_asset` mint
  into the existing canonical mint without re-checking `name`/`symbol`/`decimals`,
- this matches EVM, where later metadata is ignored once the wrapper is
  deployed; it is safe as long as PC20 metadata is immutable per source asset.

---

## Burn Architecture: Solana -> Push

### Burn Request Shape

The Solana burn path should carry the same logical fields as the EVM `PC20BurnRequest`, adapted to SVM types:

- canonical `source_asset`
- `amount`
- Push recipient bytes
- optional Push payload
- Solana revert recipient

### User Path

1. User calls `send_pc20_universal_tx`.
2. Gateway derives the canonical `Pc20Mint` PDA from `source_asset`.
3. Gateway validates that the supplied mint matches the derived canonical mint.
4. Gateway burns wrapped supply from the user's ATA.
5. Gateway emits `Pc20UniversalTx` containing:
   - `sub_tx_id`
   - `source_asset`
   - `wrapped_mint`
   - `amount`
   - Push recipient bytes
   - optional Push payload
   - Solana revert recipient
   - `from_cea = false`
6. TSS observes the event.
7. Push-side TSS calls `VaultPC20.unlock(subTxId, token, amount, recipient)`.

### CEA Path

1. Push-side execution finalizes on Solana with `destination_program = universal_gateway`.
2. The `ix_data` discriminator is `send_pc20_universal_tx`.
3. The outer finalize route is payload-only: `amount = 0`, `mint = None`, and no generic SPL staging accounts are supplied.
4. TSS signs the normal SVM execute message, including the PC20 burn accounts in `remaining_accounts`.
5. Gateway validates the PC20 mint PDA, CEA ATA, and SPL Token program.
6. Gateway burns wrapped supply from the CEA ATA using CEA PDA authority.
7. Gateway emits the same `Pc20UniversalTx` semantics with `from_cea = true`.
8. TSS observes the event and unlocks on Push.

### Burn Failure Recovery

If Push-side unlock fails after a Solana burn:

1. TSS allocates a new `revert_sub_tx_id`.
2. TSS calls `revert_pc20_burn` on Solana.
3. Gateway replay-checks the revert using the new subTx ID.
4. Gateway remints the wrapped amount to the Solana revert recipient.
5. Wrapped supply is restored and the original Push lock remains intact.

The revert must not reuse the original burn `sub_tx_id`, because replay protection is keyed by transaction ID.
The revert is a thin remint to the declared revert recipient, replay-protected by
its own `sub_tx_id`, mirroring EVM's re-mint-via-export recovery.

---

## Fee Model

PC20 on Solana uses the same destination budget mechanism already used by the current SVM outbound architecture.

### Reimbursement Source

The reimbursement source follows the direction of the transaction:

- Push -> Solana finalization (`finalize_pc20_export`) reimburses the relayer
  from `vault_sol`, because the source-side PC20 export quote burns gas on Push
  via `swapAndBurnGas`; the Solana vault unlock is the destination-side
  counterpart of that burn.
- Push-routed CEA PC20 burn via `finalize_universal_tx` also reimburses from
  `vault_sol`, because it is still a TSS-routed Push-origin finalize message.
- User-initiated Solana -> Push burn (`send_pc20_universal_tx`) does not
  reimburse from a protocol pool; the Solana caller pays the Solana transaction.
- Solana burn recovery (`revert_pc20_burn`) reimburses from `fee_vault`,
  because the original Solana -> Push burn failed before Push-side gas was
  burned, so there is no Push-side burn to pair with a `vault_sol` unlock.

### Budget Semantics

The Push-side quote remains:

```text
quoted_budget = gasPrice * gasLimit
```

For Solana, that value is interpreted as a signed lamport budget for the destination transaction, not as literal EVM gas accounting.

### Source-Side Quoting

Push still quotes PC20 through:

```text
UniversalCore.getPC20ExportGasAndFees(destChainNamespace, gasLimit, token)
```

The 3rd-iteration gateway still uses:

- `baseGasLimitByChainNamespace[destChainNamespace]`
- `pc20DeploymentGasOverhead[destChainNamespace]`
- protocol fee by token
- chain gas price

No special 3rd-iteration core redesign was identified beyond that existing model.

### Default Path

When the wrapped mint already exists and no new destination accounts need to be created:

- `gasLimit = 0` may be used on Push,
- the configured Solana base gas limit supplies the default budget.

### Dynamic Path

If any extra destination cost is expected, the caller should pass a higher `gasLimit`.

Examples:

- first export for a source asset,
- recipient ATA missing,
- CEA ATA missing,
- metadata creation enabled,
- stored-ix-data route used.

This matches the current SVM gas model already used by the Solana gateway: the source quote provides a signed lamport budget, and callers increase `gasLimit` when they expect account-creation rent beyond the base path.

### PC20 `gas_used` Components

The destination `gas_used` for Solana PC20 finalization is:

```text
signature_fee
+ executed_sub_tx_rent
+ recipient_ata_rent_if_created
+ cea_ata_rent_if_created
+ wrapped_mint_rent_if_created
+ metadata_rent_if_created
+ stored_ix_data_surcharge_if_ref_route
```

As with the existing SVM model:

- require `gas_fee >= gas_used`,
- reimburse only `gas_used`,
- keep `gas_to_refund = gas_fee - gas_used` for Push-side refund accounting.

### Role of `pc20DeploymentGasOverhead`

`pc20DeploymentGasOverhead` remains a valid coarse first-export premium for Solana because first export can require mint creation and optional metadata creation.

It is not sufficient by itself for all cases. Recipient-specific or route-specific account creation still requires dynamic `gasLimit` selection.

---

## Events

### Push-side source event

`UniversalTxOutbound`

Used as the canonical source event for Push -> Solana PC20 export.

The relayer distinguishes PC20 from PRC20 by checking the selector prefix in `payload`.

### Solana finalized event

Recommended event:

- `Pc20ExportFinalized`

Minimum fields:

- `sub_tx_id`
- `universal_tx_id`
- `push_account`
- `source_asset`
- `wrapped_mint`
- `amount`
- `gas_fee`
- `gas_used`
- `gas_to_refund`
- `mint_created`
- `recipient_ata_created`
- `cea_ata_created`

### Solana burn event

Recommended event:

- `Pc20UniversalTx`

Minimum fields:

- `sender`
- `source_asset`
- `wrapped_mint`
- `amount`
- Push recipient bytes
- Push payload
- Solana revert recipient
- `from_cea`

### Solana burn-revert event

Recommended event:

- `Pc20BurnReverted`

Minimum fields:

- `sub_tx_id`
- `source_asset`
- `wrapped_mint`
- `amount`
- Solana revert recipient

---

## Backend / Relayer Changes Required

### 1. Push Listener

The relayer must listen to `UniversalTxOutbound`, not a dedicated PC20 export event.

PC20 routing rule:

```text
payload[0..4] == PC_20_SELECTOR
```

### 2. Metadata Handling

The relayer must extract wrapped-token metadata from the selector-prefixed outbound payload and no longer depend on a separate metadata fetch step for settlement construction.

### 3. Solana Settlement Builder

For Solana destinations, the relayer must:

- strip the PC20 metadata envelope,
- keep the remaining Solana `userData`,
- convert that `userData` into the same target-program / account-meta / `ix_data` inputs already used by the current SVM execute path,
- choose direct finalize vs stored-ix-data finalize based on size.

### 4. Replay Tracking

PC20 replay domains are separate from the current PRC20 vault-withdraw path:

- Solana export finalize: `ExecutedSubTx`
- Solana burn revert: new `revert_sub_tx_id` plus `ExecutedSubTx`
- Push-side unlock / export revert: `VaultPC20` replay tracking

### 5. Core Awareness

No additional core-repo contract change was identified as necessary for 3rd iteration alignment. The relayer continues to rely on the existing Push quote path and deployment-overhead configuration.

---

## Security Properties

- Only TSS-authorized settlement can create wrapped supply on Solana.
- Every finalize and revert path is replay-protected.
- Only the canonical wrapped mint derived from `source_asset` can be burned.
- Wrapped supply can only be minted or reminted through PDA-controlled authority.
- Later finalizations cannot create a second canonical mint for the same `source_asset`.
- Destination-side excess gas budget is not paid out to the relayer; only `gas_used` is reimbursed.
- The Solana design avoids an unnecessary registry mapping by using deterministic PDA mint derivation.
- The Solana design avoids overloading the current vault-withdraw finalize path with mint-first settlement semantics.
- Payload execution remains bound to the current CEA model and signed account metas.

---

## References

### EVM 3rd-iteration sources

- [PC20 3rd-iteration PR #128](https://github.com/pushchain/push-chain-gateway-contracts/pull/128/changes#top)
- [PC20 3rd-iteration PR conversation](https://github.com/pushchain/push-chain-gateway-contracts/pull/128)

### Push gateway / core sources used for comparison

- [2nd-iteration `UniversalGatewayPC.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-2nd-iteration/contracts/evm-gateway/src/UniversalGatewayPC.sol)
- [2nd-iteration `Vault.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-2nd-iteration/contracts/evm-gateway/src/Vault.sol)
- [2nd-iteration `TypesUGPC.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-2nd-iteration/contracts/evm-gateway/src/libraries/TypesUGPC.sol)
- [2nd-iteration `TypesUG.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-2nd-iteration/contracts/evm-gateway/src/libraries/TypesUG.sol)
- [2nd-iteration `IUniversalGatewayPC.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-2nd-iteration/contracts/evm-gateway/src/interfaces/IUniversalGatewayPC.sol)
- [2nd-iteration `UniversalCore.sol`](https://raw.githubusercontent.com/pushchain/push-chain-core-contracts/pc20-2nd-iteration/src/UniversalCore.sol)
- [2nd-iteration `IUniversalCore.sol`](https://raw.githubusercontent.com/pushchain/push-chain-gateway-contracts/pc20-2nd-iteration/contracts/evm-gateway/src/interfaces/IUniversalCore.sol)

### Current SVM gateway sources

- [SVM Gateway Overview](./0-SVM-GATEWAY.md)
- [Integration Guide](../INTEGRATION_GUIDE.md)
- [Program entrypoints](../programs/universal-gateway/src/lib.rs)
- [Finalize account model and replay path](../programs/universal-gateway/src/instructions/execute.rs)
- [Program state and PDA seeds](../programs/universal-gateway/src/state.rs)

### Official Solana / Anchor docs

- [Program Derived Addresses](https://solana.com/docs/core/pda)
- [Cross Program Invocation](https://solana.com/docs/core/cpi)
- [Create a Token Mint](https://solana.com/docs/tokens/basics/create-mint)
- [Anchor PDA mint authority example](https://www.anchor-lang.com/docs/tokens/basics/mint-tokens)
