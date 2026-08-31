# SVM Gateway — Overview

The SVM gateway is a single Anchor program deployed on Solana. It is the Solana-side half of the Push Chain bridge, mirroring the role of `UniversalGateway.sol` on EVM chains. It accepts inbound deposits from Solana users, locks funds in a PDA-controlled vault, and processes outbound release instructions authorized by TSS.

For Push Chain / UEA / universal transaction concepts shared with EVM, see the EVM docs (`1_PUSH_CHAIN.md`, `2_UniversalGateway.md`). This doc covers only what is specific to the Solana program.

---

## Actors

| Actor | Role |
|-------|------|
| **User** | Sends inbound transactions via `send_universal_tx`; their Solana wallet is the signer |
| **Universal Validator (UV)** | Watches Push Chain events, builds and submits outbound Solana transactions as `caller`, and reads `UniversalTx` events emitted by this program to credit users' UEAs |
| **TSS** | Multi-party signer network; authorizes outbound operations by producing ECDSA secp256k1 signatures |

---

## Key Accounts

The program uses PDAs for all protocol state. No external signers or owner keys control funds.

| Account | Seeds | What it holds |
|---------|-------|---------------|
| `Config` | `["config"]` | Admin/operator/pauser pubkeys, pending admin/pauser pubkeys, USD caps, Pyth oracle config (operator reuses legacy `tss_address` storage slot for layout compatibility) |
| `Vault` | `["vault"]` | Native SOL bridge balance; also the authority for all SPL vault ATAs |
| `FeeVault` | `["fee_vault"]` | Inbound fees and UV gas reimbursement pool |
| `TssPda` | `["final_tss_pda"]` | Active TSS Ethereum address (`tss_eth_address`), `chain_id` — this is the account verified against on every outbound call |
| `CEA` | `["push_identity", push_account[20]]` | Per-user signing authority; no private key — gateway signs via `invoke_signed` |
| `ExecutedSubTx` | `["executed_sub_tx", sub_tx_id[32]]` | Replay protection; existence = executed |
| `RateLimitConfig` | `["rate_limit_config"]` | Block USD cap, epoch duration |
| `TokenRateLimit` | `["rate_limit", mint]` | Per-token epoch usage |
| `StoredIxData` | `["stored_ix_data", sub_tx_id[32], keccak256(ix_data)[32]]` | Temporary store for large `ix_data` used by the ref-finalize route |

**Vault vs FeeVault separation:** `Vault` holds only user-deposited bridge funds, keeping it 1:1 backed. `FeeVault` holds inbound fees and funds UV reimbursement for `revert_universal_tx` and `rescue_funds`. `finalize_universal_tx` reimburses only `gas_used` from `Vault`; any signed surplus (`gas_to_refund = gas_fee - gas_used`) remains in `Vault` and is refunded to the user on Push Chain using the `UniversalTxFinalized` event. The inbound fee is hard-capped at `2_000_000` lamports (`0.002 SOL`). Only reverted txs consume from `FeeVault`; accumulated surplus from successful txs is recoverable by admin via `withdraw_inbound_fees`.

**CEA vs EVM:** On EVM, CEA is a deployed contract per user. On SVM, CEA is a system-owned PDA. No deployment step is needed — the Solana runtime creates it on first lamport transfer.

**Event transport (`emit_cpi`):** every event this program emits (`UniversalTx`, `UniversalTxFinalized`, `RevertUniversalTx`, `FundsRescued`, `InboundFeeCollected`, `InboundFeeReimbursed`, and admin config-change events) is emitted via Anchor's `emit_cpi!` macro, not `emit!`. The event bytes land in the transaction's inner instructions (as a self-CPI to the program's `event_authority` PDA), not in program logs. Off-chain consumers (Universal Validators) MUST parse events from `getTransaction(...).meta.innerInstructions` rather than regexing `Program data:` lines — a plain log parser is vulnerable to forgery by any co-executed program in the same transaction. See [F-2026-18198 mitigation](THREAT_MODEL.md).

---

## Instruction Surface

| Function | Direction | Auth | Description |
|----------|-----------|------|-------------|
| `send_universal_tx` | Inbound | User signature | Deposit SOL or SPL tokens; infers TX_TYPE automatically |
| `finalize_universal_tx` | Outbound | TSS signature | Withdraw (id=1) or Execute (id=2) — single entrypoint |
| `store_execute_ix_data` | Outbound (prep) | Any signer | Store large `ix_data` on-chain before ref-finalize |
| `finalize_universal_tx_with_ix_data_ref` | Outbound | TSS signature | Same as `finalize_universal_tx` but loads `ix_data` from a stored PDA (for payloads > ~900 bytes) |
| `close_stored_ix_data` | Outbound (cleanup) | Policy-gated | Close `StoredIxData` PDA and recover rent |
| `revert_universal_tx` | Outbound | TSS signature | Return funds to original depositor (id=3) |
| `rescue_funds` | Outbound | TSS signature | Emergency release to any recipient (id=4) |
| `initialize` | Admin | Upgrade authority signature | One-time program setup |
| `set_*` | Admin | Admin signature | Config, oracle, and rate-limit updates (allowed even while paused) |
| `propose_authorities` | Admin | Admin signature | Propose new admin and/or pauser (two-step handover) |
| `accept_admin` | Admin | Pending admin signature | Accept a proposed admin handover |
| `accept_pauser` | Admin | Pending pauser signature | Accept a proposed pauser handover |

---

## Inbound: TX_TYPE Routing

`send_universal_tx` never takes an explicit `TX_TYPE`. The program infers it from the fee-adjusted native amount:
`adjusted_native_amount = native_amount - inbound_fee_lamports`.

| TX_TYPE | req.amount | req.payload | adjusted_native_amount |
|---------|------------|-------------|------------------------|
| `Gas` | 0 | empty | > 0 |
| `GasAndPayload` | 0 | non-empty | any |
| `Funds` (SOL) | > 0 | empty | == req.amount |
| `Funds` (SPL) | > 0 | empty | 0 |
| `FundsAndPayload` (SOL) | > 0 | non-empty | >= req.amount |
| `FundsAndPayload` (SPL) | > 0 | non-empty | any |

Gas route (`Gas`, `GasAndPayload`): instant, USD caps enforced via Pyth, per-slot budget.
Funds route (`Funds`, `FundsAndPayload`): standard, epoch-based per-token rate limit.

See `1-DEPOSIT.md` for full routing logic.

---

## Outbound: All Cases

All outbound operations are TSS-authorized. The UV submits the transaction; TSS provides the signature.

### Withdraw (instruction_id=1)

```
Vault → CEA → Recipient
```

**SOL:** lamports transferred directly to recipient wallet.
**SPL:** tokens transferred from vault ATA → recipient ATA (auto-created if missing; caller pays rent).
**Special case:** if `recipient == CEA`, the second transfer is skipped (funds stay in CEA).

Emits: `UniversalTxFinalized`

See `2-WITHDRAW-EXECUTE.md`.

---

### Execute (instruction_id=2)

```
Vault → CEA → CPI to target program
```

CEA receives funds, then the gateway calls the target program with CEA as the signer via `invoke_signed`. Target program sees `msg.sender == CEA`. `remaining_accounts` must match signed pubkeys/order exactly; writability is validated one-way (`signed writable => actual writable`).

**CEA self-withdraw:** when `destination_program == gateway_program_id`, the execute path routes to a CEA→UEA flow instead of an external CPI. Emits both `UniversalTx` (`from_cea: true`) and `UniversalTxFinalized`.

Emits: `UniversalTxFinalized` (and `UniversalTx` for CEA self-withdraw)

See `2-WITHDRAW-EXECUTE.md` and `4-CEA.md`.

---

### Revert (instruction_id=3)

```
Vault → Recipient (original depositor)
```

Returns funds when the Push Chain transaction failed. Recipient must match the `revert_recipient` from the original deposit. Gas reimbursement comes from FeeVault, not Vault.

Emits: `RevertUniversalTx`

See `3-REVERT.md`.

---

### Rescue (instruction_id=4)

```
Vault → Any recipient (TSS-designated)
```

Emergency release when normal recovery paths are unavailable. TSS designates the recipient directly. Replay-protected via `ExecutedSubTx` PDA.

Emits: `FundsRescued`

See `5-RESCUE.md`.

---

## Authorization Model

**Inbound:** user's Solana wallet signature. No TSS involvement.

**Outbound (all):** TSS ECDSA secp256k1 signature. The program reconstructs the message, hashes it with keccak256, recovers the Ethereum address from the signature, and compares it to `TssPda.tss_eth_address`. No `onlyRole` or key-based auth — the signature is the only gate.

**Admin:** config changes require the current admin pubkey to sign. `pause` can be called by either the configured pauser or the admin; `unpause` is operator-only. Authority handover is two-step for admin/pauser: the current admin proposes and the proposed key accepts. Operator is admin-set in one step (no extra pending slot in current layout). These are Solana `Pubkey` fields stored in `Config`, not Ethereum addresses.

---

## What Differs from EVM

| Aspect | EVM | SVM |
|--------|-----|-----|
| CEA | Deployed contract (CREATE2) | PDA (no deployment, system-owned) |
| Vault | Separate contract | PDA (system account) |
| Outbound auth | `onlyRole(TSS_ROLE)` | ECDSA signature verification on-chain |
| Replay protection | `mapping(bytes32 => bool) isExecuted` | `ExecutedSubTx` PDA existence |
| CPI execution | `target.call{value:}(data)` | `invoke_signed` with CEA seeds |
| SPL accounts | ERC-20 via `transferFrom` | Optional ATA accounts passed explicitly |
| Fee separation | Bundled in msg.value | Vault vs FeeVault split (SVM-specific) |
