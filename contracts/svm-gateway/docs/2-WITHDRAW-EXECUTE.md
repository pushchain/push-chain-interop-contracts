# Withdraw & Execute (Outbound)

**Function:** `finalize_universal_tx`
**Direction:** Push Chain → Solana
**Authorization:** TSS ECDSA secp256k1 signature

Single entrypoint for withdraw/execute outbound operations, routed by `instruction_id`.

| instruction_id | Mode | Action |
|---|---|---|
| 1 | Withdraw | Vault → CEA → Recipient |
| 2 | Execute | Vault → CEA → CPI to target program |

---

## TSS Message Format

```
PREFIX = b"PUSH_CHAIN_SVM"
message = PREFIX || instruction_id (1 byte) || chain_id || amount (8 bytes BE) || additional_data
hash = keccak256(message)
```

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
5. `Vault → Caller`: transfer `gas_fee` (UV reimbursement)
6. Mode-specific action (see below)
7. Emit `UniversalTxFinalized` (all finalized paths, including CEA self-withdraw) with `gas_fee`

---

## Withdraw Mode

Transfers funds from CEA to the recipient. If `recipient == cea_authority`, funds stay in CEA (no second transfer). SPL: requires `recipient_ata` to exist.

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
- `UniversalTxFinalized` from parent finalize flow using outer execute fields (`amount`, `gas_fee`, full `ix_data`)

---

## SPL vs SOL Account Requirements

| Account | SOL route | SPL route |
|---------|-----------|-----------|
| `vault_ata` | None | Required (canonical vault ATA for mint) |
| `cea_ata` | None | Required (auto-created if missing) |
| `mint` | None | Required |
| `recipient_ata` | None | Required (withdraw mode) |

---

## Key Security Properties

- **Replay protection:** `sub_tx_id` uniqueness enforced via PDA init — each ID can execute exactly once
- **CEA isolation:** `CEA(sender_A) != CEA(sender_B)` — cross-user CPI is impossible
- **No outer signers:** `remaining_accounts` entries with `is_signer = true` are rejected
- **Vault integrity:** only `gas_fee` leaves vault as UV reimbursement; `amount` moves vault → CEA → target, never directly to the UV

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
| `Paused` | Gateway is paused |
