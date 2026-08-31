# Withdraw & Execute (Outbound)

**Functions:** `finalize_universal_tx` / `finalize_universal_tx_with_ix_data_ref`
**Direction:** Push Chain → Solana
**Authorization:** TSS ECDSA secp256k1 signature

Single entrypoint for withdraw/execute outbound operations, routed by `instruction_id`. For execute payloads too large to fit inline (> ~900 bytes), use the ref-finalize route — see `6-TX-SIZE-REF-ROUTE.md`.

| instruction_id | Mode | Action |
|---|---|---|
| 1 | Withdraw | Vault → CEA → Recipient |
| 2 | Execute | Vault → CEA → CPI to target program |

---

## TSS Message Format

```
PREFIX = b"PUSH_CHAIN_SVM"
message = PREFIX || instruction_id (1 byte) || chain_id || deadline (8 bytes i64 BE) || amount (8 bytes u64 BE) || additional_data
hash = keccak256(message)
```

`deadline` is a Unix timestamp (seconds). The program rejects execution if `Clock::unix_timestamp > deadline`.

### Withdraw (id=1) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | push_account[20] | token[32] | gas_fee_be[8] | recipient[32]
```

### Execute (id=2) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | push_account[20] | token[32] | gas_fee_be[8] | target_program[32] | accounts_buf | ix_data_buf
```

**accounts_buf:** `[count (4 bytes BE)][pubkey (32 bytes)][is_writable (1 byte)]...`
**ix_data_buf:** `[length (4 bytes BE)][data bytes...]`

---

## Execution Flow

1. Validate params and account presence (SOL vs SPL paths)
2. Verify TSS signature — recover Ethereum address, compare to `TssPda.tss_eth_address`
3. Create `ExecutedSubTx` PDA (replay protection — init fails if `sub_tx_id` reused)
4. `Vault → CEA`: transfer `amount`
5. Compute `gas_used = signature_fee + executed_sub_tx_rent (+ cea_ata_rent if ATA was created)` and require `gas_fee >= gas_used`
6. `Vault → Caller`: transfer `gas_used` (actual UV reimbursement)
7. Mode-specific action (see below)
8. Emit `UniversalTxFinalized` (all finalized paths, including CEA self-withdraw) with `gas_fee`, `gas_used`, `gas_to_refund`, `ata_created`

---

## Withdraw Mode

Transfers funds from CEA to the recipient. If `recipient == cea_authority`, funds stay in CEA (no second transfer). SPL: `recipient_ata` is auto-created via CPI if missing (caller pays rent, mirroring the CEA ATA flow). Post-create, mint and owner are validated against the signed recipient wallet. When the recipient ATA is created, its rent is folded into `gas_used` and reimbursed to the caller in the same tx (see `THREAT_MODEL.md` entry 15); the `UniversalTxFinalized` event exposes a `recipient_ata_created` flag for off-chain reconciliation.

---

## Execute Mode

Builds a CPI instruction with CEA as signer via `invoke_signed`. Validation rules for `remaining_accounts`:
- Pubkeys must match the signed `accounts_buf` exactly
- Writability is one-way validated: if TSS signed an account as writable, the actual account must also be writable; the reverse is not enforced (actual writable while signed read-only is allowed)
- No account may have `is_signer = true` — CEA gains signer authority only via `invoke_signed`


### CEA Self-Withdraw (target == gateway)

When `destination_program == gateway_program_id`, the execute path triggers a special CEA → UEA withdrawal instead of a CPI. The `ix_data` must be:

```
[discriminator: 8 bytes]  // keccak256("global:send_universal_tx_to_uea")[..8]
[borsh-encoded args]
```

Args (Borsh):
```rust
{
  token: Pubkey,    // Pubkey::default() for SOL, mint for SPL
  amount: u64,      // can be 0 only when payload is non-empty
  payload: Vec<u8>, // empty/non-empty controls tx_type with amount
  revert_recipient: Pubkey, // must be non-zero
}
```

Valid combinations:
- `amount > 0, payload empty` → `Funds`
- `amount > 0, payload non-empty` → `FundsAndPayload`
- `amount = 0, payload non-empty` → `GasAndPayload` (payload-only CEA route)
- `amount = 0, payload empty` → rejected with `InvalidInput`

The recipient UEA address comes from the `push_account` parameter, not from `ix_data`.
This path emits:
- `UniversalTx` with `from_cea: true` using inner decoded args (`token`, `amount`, `payload`)
- `UniversalTxFinalized` from parent finalize flow using outer execute fields (`amount`, signed `gas_fee`, full `ix_data`) plus accounting fields (`gas_used`, `gas_to_refund`, `ata_created`)

---

## SPL vs SOL Account Requirements

| Account | SOL route | SPL route |
|---------|-----------|-----------|
| `vault_ata` | None | Required (canonical vault ATA for mint) |
| `cea_ata` | None | Required (auto-created if missing) |
| `mint` | None | Required |
| `recipient_ata` | None | Required (withdraw mode; auto-created if missing) |

---

## Key Security Properties

- **Replay protection:** `sub_tx_id` uniqueness enforced via PDA init — each ID can execute exactly once
- **CEA isolation:** `CEA(sender_A) != CEA(sender_B)` — cross-user CPI is impossible
- **No outer signers:** `remaining_accounts` entries with `is_signer = true` are rejected
- **Vault integrity:** only `gas_used` leaves vault as UV reimbursement; `amount` moves vault → CEA → target, never directly to the UV

---

## Ref-Finalize Route (Large Payloads)

When `ix_data` is too large to fit in a single transaction alongside the finalize accounts, use the two-step ref route:

1. Call `store_execute_ix_data(sub_tx_id, keccak256(ix_data), ix_data)` — stores bytes on-chain.
2. Call `finalize_universal_tx_with_ix_data_ref` with `ix_data_hash` instead of raw `ix_data`.

TSS signs the same message format (raw `ix_data` bytes, not the hash). The program loads, verifies, and uses the stored bytes identically to the direct path.

Gas accounting difference: `gas_used` is `base_finalize_gas + 5000` (extra 5000 to reimburse the store UV's transaction fee).

See `6-TX-SIZE-REF-ROUTE.md` for complete details, gas accounting, multi-UV model, and close policy.

---

## Key Errors

| Error | Cause |
|-------|-------|
| `TssAuthFailed` | Signature invalid or TSS address mismatch |
| `MessageHashMismatch` | Message reconstruction does not match provided hash |
| account init failure | `sub_tx_id` reused — `ExecutedSubTx` PDA already exists, init constraint rejects the tx |
| `UnexpectedOuterSigner` | `remaining_accounts` entry has `is_signer = true` |
| `AccountPubkeyMismatch` | Account in `remaining_accounts` doesn't match signed payload |
| `InvalidProgram` | Target program not executable |
| `InsufficientGasBudget` | `gas_fee < gas_used` — on-chain guard in `settle_relayer_gas_cost` |
| `Paused` | Gateway is paused |
