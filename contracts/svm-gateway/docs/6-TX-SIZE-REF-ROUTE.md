# TX-Size Ref-Finalize Route

## Why it exists

Solana enforces a 1232-byte hard limit on legacy transactions. `finalize_universal_tx` passes `ix_data` as a direct instruction argument. For execute payloads above roughly 900 bytes, the transaction exceeds the limit and Solana rejects it before the program runs.

The ref route solves this by splitting finalization into two transactions:

1. **Store** — UV uploads `ix_data` to a PDA in a separate transaction.
2. **Ref-finalize** — UV calls `finalize_universal_tx_with_ix_data_ref`, which loads `ix_data` from the PDA and executes the same finalize logic as the direct route.

The on-chain behavior after loading is identical. TSS signs the same message format. No protocol-level changes.

---

## New Instructions

| Instruction | Auth | Description |
|---|---|---|
| `store_execute_ix_data` | Any signer (permissionless) | Store raw `ix_data` on-chain under a content-addressed PDA |
| `finalize_universal_tx_with_ix_data_ref` | TSS signature | Same as `finalize_universal_tx` but reads `ix_data` from a `StoredIxData` PDA |
| `close_stored_ix_data` | Policy-gated (see below) | Close the stored PDA and return rent to `store_refund_recipient` |

---

## StoredIxData Account

```
PDA seeds: [b"stored_ix_data", sub_tx_id[32], keccak256(ix_data)[32]]
```

| Field | Type | Description |
|---|---|---|
| `bump` | `u8` | Canonical PDA bump |
| `sub_tx_id` | `[u8; 32]` | Stored explicitly so orphaned PDAs can be rediscovered via `getProgramAccounts` and closed without local UV state |
| `store_refund_recipient` | `Pubkey` | The caller of `store_execute_ix_data`; receives gas reimbursement at finalize and rent at close |
| `ix_data` | `Vec<u8>` | Raw instruction data bytes |

The PDA is content-addressed: the hash of `ix_data` is part of the seeds. A `StoredIxData` account at a given address certifies that its stored bytes hash to the hash used in its seeds.

---

## Step 1 — `store_execute_ix_data`

**Accounts:** `caller` (mut signer), `stored_ix_data` (init, payer = caller), `system_program`

**Args:** `sub_tx_id: [u8; 32]`, `ix_data_hash: [u8; 32]`, `ix_data: Vec<u8>`

**Validations:**
- `ix_data` must be non-empty (`EmptyIxData`)
- `keccak256(ix_data) == ix_data_hash` (`InvalidIxDataHash`)

**Effect:** creates `StoredIxData` PDA; sets `store_refund_recipient = caller.key()`.

`store_execute_ix_data` is permissionless. Any account can store for any `sub_tx_id`. Security comes from the PDA being content-addressed and TSS signing over the actual `ix_data` bytes — a stored payload with wrong content will fail TSS verification at finalize time.

---

## Step 2 — `finalize_universal_tx_with_ix_data_ref`

**Instruction signature:**
```
instruction_id: u8,
sub_tx_id: [u8; 32],
universal_tx_id: [u8; 32],
amount: u64,
push_account: [u8; 20],
ix_data_hash: [u8; 32],  ← hash, not raw bytes
writable_flags: Vec<u8>,
gas_fee: u64,
signature: [u8; 64],
recovery_id: u8,
message_hash: [u8; 32],
```

**Account struct:** same `FinalizeUniversalTx` struct as the direct route. `stored_ix_data` and `store_refund_recipient` are optional accounts that become required on this path.

**Pre-finalize checks (in lib.rs, before calling the shared core):**

1. Load `stored_ix_data` and `store_refund_recipient` from accounts (both must be `Some`).
2. Compute `keccak256(stored_ix_data.ix_data)` and require it equals `ix_data_hash` arg.
3. Require `store_refund_recipient.key() == stored_ix_data.store_refund_recipient` (prevents reimbursement redirection).
4. Derive expected PDA from `(sub_tx_id, computed_hash)` and require the account key matches.

After these checks, calls `finalize_universal_tx_common` with:
- loaded `ix_data` (not the arg)
- `store_upload_fee_lamports = SIGNATURE_FEE_LAMPORTS (5000)`
- `store_refund_recipient = Some(refund_recipient account info)`

**TSS message format:** identical to direct execute route — TSS signs over the raw `ix_data` bytes, not the hash.

---

## Gas Accounting

### Direct finalize

```
gas_used  = SIGNATURE_FEE (5000) + executed_sub_tx_rent [+ cea_ata_rent if ATA created]
gas_to_refund = gas_fee - gas_used  (stays in vault, returned to user on Push Chain)
```

Vault pays `gas_used` to `caller` (the UV that submitted finalize).

### Ref-finalize

```
base_finalize_gas = SIGNATURE_FEE (5000) + executed_sub_tx_rent [+ cea_ata_rent]
gas_used  = base_finalize_gas + 5000
gas_to_refund = gas_fee - gas_used
```

Vault pays:
- `base_finalize_gas` → `caller` (the UV that submitted ref-finalize)
- `5000` → `store_refund_recipient` (the UV that paid for the store transaction)

The 5000 reimbursement compensates the store UV for their Solana transaction signature fee. Rent paid during store is recovered separately at close time.

**UGPC gas_fee sizing:** For the ref route to succeed, `gas_fee` must be at least `base_finalize_gas + 5000`. `base_finalize_gas` is dynamic: `5000 + executed_sub_tx_rent [+ cea_ata_rent if SPL ATA created]`. The UGPC should compute this dynamically and add at least 5000 on top when using the ref route.

---

## Step 3 — Auto-close on finalize success

`finalize_universal_tx_with_ix_data_ref` automatically closes the `StoredIxData` PDA on success. Rent is returned to `store_refund_recipient` in the same transaction. No separate cleanup step is needed.

## `close_stored_ix_data` — Rent Recovery Before Finalize Succeeds

Used in two cases where the PDA was not auto-closed (because finalize never succeeded):

1. **Finalize failed** — store succeeded, ref-finalize was submitted but reverted. PDA is still open; `store_refund_recipient` calls close to recover rent.
2. **Abort** — UV decides finalize will never be submitted (e.g. invalid payload discovered). `store_refund_recipient` closes to recover rent immediately.

Only `store_refund_recipient` can close in both cases, since `ExecutedSubTx` does not exist yet.

**Close policy:**

| State | Who can trigger close |
|---|---|
| `ExecutedSubTx` does not exist (finalize not yet succeeded or failed) | Only `store_refund_recipient` |
| `ExecutedSubTx` exists and PDA is still open (direct finalize used instead of ref) | Anyone |

The second row covers the edge case where a `StoredIxData` PDA was created but direct `finalize_universal_tx` was used for the same `sub_tx_id` instead of the ref route — the PDA was never auto-closed, but the `ExecutedSubTx` exists, so anyone can clean it up.

**Error:** `StoredIxDataNotClosable` if caller is not `store_refund_recipient` and `ExecutedSubTx` does not exist.

---

## Failed-Path Economics

There is no on-chain reimbursement for failed transactions. The UV absorbs transaction fees on all failure paths. Rent is always recoverable:

- **Store succeeds, finalize fails** — `ExecutedSubTx` was never created. `store_refund_recipient` calls `close_stored_ix_data` to recover PDA rent.
- **Store succeeds, finalize never submitted** — same as above.
- **Store fails** — no PDA was created, no rent to recover.
- **Finalize succeeds** — PDA is auto-closed, rent already returned in the same transaction.

---

## Multi-UV Model

The UV that stores and the UV that finalizes can differ:

- **Store UV** (`store_refund_recipient`): pays the store transaction fee; receives 5,000 lamport reimbursement at finalize and rent at close.
- **Finalize UV** (`caller`): pays the finalize transaction fee; receives `base_finalize_gas` at finalize.

If the same UV does both, it simply receives both reimbursements.

---

## When to Use Which Route

The trigger is the **total finalize transaction size**, not ix_data size alone. The 1232-byte limit is consumed by account keys, instruction args, blockhash, and signatures together. With many remaining accounts, the ix_data budget in direct finalize shrinks proportionally.

| Scenario | Route |
|---|---|
| Serialized finalize tx ≤ 1232 bytes | Direct `finalize_universal_tx` |
| Serialized finalize tx > 1232 bytes | Store + `finalize_universal_tx_with_ix_data_ref` |

The UV should try to serialize the full `finalize_universal_tx` transaction and use the ref route if it would exceed 1232 bytes.

**Store instruction hard limit:** `store_execute_ix_data` has a fixed overhead of ~311 bytes (3 accounts + discriminator + sub_tx_id + ix_data_hash), leaving ~921 bytes for ix_data. If ix_data itself exceeds ~921 bytes, the store transaction also fails — neither route works. In that case versioned transactions with Address Lookup Tables are required.

---

## Replay Protection

Same as the direct route: `ExecutedSubTx` PDA seeded by `sub_tx_id`. If the direct route is called first for a given `sub_tx_id`, ref-finalize cannot be used for the same ID (init constraint fails). If ref-finalize succeeds first, close policy allows anyone to close the stored PDA.

---

## Key Errors

| Error | Cause |
|---|---|
| `EmptyIxData` | `ix_data` is zero-length in `store_execute_ix_data` |
| `InvalidIxDataHash` | `keccak256(ix_data)` does not match provided hash |
| `InvalidAccount` | `store_refund_recipient` does not match stored field, or wrong `executed_sub_tx` key |
| `StoredIxDataNotClosable` | Pre-success close attempted by non-refund-recipient |
| `InsufficientGasBudget` | `gas_fee < base_finalize_gas + 5000` |
| All errors from `finalize_universal_tx` | Propagated unchanged after `ix_data` is loaded |
