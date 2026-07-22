# Revert (Outbound Recovery)

**Function:** `revert_universal_tx` (unified SOL + SPL)
**Direction:** Vault → Recipient
**Authorization:** TSS ECDSA secp256k1 signature

Returns deposited funds to the user when a Push Chain transaction fails.

---

## Flow

1. Verify TSS signature
2. Create `ExecutedSubTx` PDA (replay protection)
3. `Vault → Recipient` (amount)
4. Emit `RevertUniversalTx` (now includes `gas_used` = the amount actually reimbursed)
5. `FeeVault → Caller` (UV reimbursement)

The funds transfer comes from the bridge `Vault`. The UV reimbursement comes from `FeeVault` — not from `Vault`. Revert is SVM-inbound-fee funded (the user paid the inbound fee into `FeeVault` when depositing), so this is the correct source and is **unchanged** from audit-main-fixes: the reimbursed amount is the full signed `gas_fee` for the legacy native/SPL/PRC20 paths, and the measured cost for the PC20 remint path. If `FeeVault` has insufficient balance, the reimbursement fails with `InsufficientFeePool`.

> Contrast with `rescue_funds`, which is Push-initiated (gas burned on Push via `swapAndBurnGas`) and therefore reimburses from `Vault`, not `FeeVault`. See `5-RESCUE.md`.

The event now carries `gas_used` (the reimbursed amount) — an IDL-breaking layout addition; regenerate types. It is emitted after the funds transfer but before the UV reimbursement.

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
| `InvalidRecipient` | Recipient is zero address; or doesn't match original `revert_recipient`; or (SPL) recipient ATA owner doesn't match `revert_recipient` |
| `InvalidMint` | Recipient ATA mint doesn't match `token_mint` |
| `Paused` | Gateway is paused |
