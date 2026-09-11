# Revert (Outbound Recovery)

**Function:** `revert_universal_tx` (unified SOL + SPL)
**Direction:** Vault → Recipient
**Authorization:** TSS ECDSA secp256k1 signature

Returns deposited funds to the user when a Push Chain transaction fails.

---

## Flow

1. Verify TSS signature
2. Create `ExecutedSubTx` PDA (replay protection)
3. `Vault → Recipient` (amount). On the legacy SPL path the gateway auto-creates the recipient's canonical ATA if it does not yet exist (caller pays rent; folded into the measured `gas_used`).
4. Compute measured `gas_used = SIGNATURE_FEE + ExecutedSubTx rent + recipient_ata_rent (0 unless just created)` and require `gas_fee >= gas_used`.
5. Emit `RevertUniversalTx`.
6. `FeeVault → Caller` (`gas_used`, UV reimbursement); emit `InboundFeeReimbursed { sub_tx_id, relayer, amount_lamports: gas_used }`.

The funds transfer comes from the bridge `Vault`. The UV reimbursement comes from `FeeVault` — not from `Vault`. Revert is SVM-inbound-fee funded (the user paid the inbound fee into `FeeVault` when depositing), so `FeeVault` is the correct source. The signed `gas_fee` is a ceiling, not the payment amount; the on-chain program measures actual cost and reimburses that. If `FeeVault` cannot cover `gas_used` the tx fails with `InsufficientFeePool`; if `gas_fee < gas_used` it fails with `InsufficientGasBudget` before any lamports move.

The measured `gas_used` is visible off-chain via `InboundFeeReimbursed.amount_lamports` — no schema change to `RevertUniversalTx` was required.

---

## TSS Message Format

```
PREFIX = b"PUSH_CHAIN_SVM"
message = PREFIX || instruction_id (1 byte) || chain_id || deadline (8 bytes i64 BE) || amount (8 bytes u64 BE) || additional_data
hash = keccak256(message)
```

`deadline` is a Unix timestamp (seconds). The program rejects execution if `Clock::unix_timestamp > deadline`.

### SOL Revert (instruction_id=3) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | recipient[32] | gas_fee (8 BE) | keccak256(revert_msg)[32]
```

### SPL Revert (instruction_id=3) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | mint[32] | recipient[32] | gas_fee (8 BE) | keccak256(revert_msg)[32]
```

---

## Recipient Validation

The `recipient` must match the flat `revert_recipient: Pubkey` from the original deposit. This value was included in the `UniversalTx` event emitted at deposit time. TSS reads it from chain state to construct the revert.
`revert_msg` is also authenticated via its keccak256 hash in the TSS-signed message, so emitted revert metadata cannot be altered by the relayer.

`recipient` must not be `Pubkey::default()`.

---

## Key Errors

| Error | Cause |
|-------|-------|
| `TssAuthFailed` | Signature invalid or TSS address mismatch |
| `MessageHashMismatch` | Message reconstruction mismatch |
| account init failure | `sub_tx_id` reused — `ExecutedSubTx` PDA already exists |
| `InvalidRecipient` | Recipient is zero address; or doesn't match original `revert_recipient`; or (SPL) post-create ATA owner doesn't match `revert_recipient` |
| `InvalidMint` | Recipient ATA mint doesn't match `token_mint` |
| `InvalidAccount` | Legacy SPL: passed `recipient_token_account` is not the canonical ATA for `(recipient, mint)`; or a required optional slot is missing |
| `InsufficientGasBudget` | Signed `gas_fee` is less than the measured `gas_used` |
| `InsufficientFeePool` | `FeeVault` cannot cover `gas_used` above rent-exempt minimum |
| `Paused` | Gateway is paused |
