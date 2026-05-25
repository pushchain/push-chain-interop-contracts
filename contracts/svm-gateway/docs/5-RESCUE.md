# Rescue (Emergency Fund Recovery)

**Function:** `rescue_funds`
**Direction:** Vault → Recipient
**Authorization:** TSS ECDSA secp256k1 signature
**instruction_id:** 4 (both SOL and SPL)

Emergency release of locked funds when normal outbound paths (withdraw/execute/revert) cannot be used. Authorized exclusively by TSS. Replay-protected via `sub_tx_id`.

---

## When to Use

Rescue is for funds that are permanently locked — e.g., the original deposit's `revert_recipient` is invalid or the associated outbound transaction can never be finalized. TSS initiates rescue off-chain; it is not triggered by user request.

Rescue is distinct from revert:
- **Revert (3):** standard recovery of a failed Push Chain transaction; uses same `revert_recipient` as original deposit
- **Rescue (4):** TSS-authorized emergency release to any recipient; used when normal recovery paths are unavailable

---

## Flow

1. Validate account presence (SOL vs SPL paths)
2. Verify TSS signature — recover Ethereum address, compare to `TssPda.tss_eth_address`
3. Create `ExecutedSubTx` PDA (replay protection — init fails if `sub_tx_id` reused)
4. `Vault → Recipient` (amount)
5. Emit `FundsRescued`
6. `FeeVault → Caller` (gas_fee, UV reimbursement)

The funds transfer comes from the bridge `Vault`. The UV reimbursement comes from `FeeVault` — not from `Vault`. This preserves the 1:1 bridge invariant. If `FeeVault` has insufficient balance, reimbursement fails with `InsufficientFeePool`.

---

## TSS Message Format

```
PREFIX = b"PUSH_CHAIN_SVM"
message = PREFIX || instruction_id (1 byte) || chain_id || deadline (8 bytes i64 BE) || amount (8 bytes u64 BE) || additional_data
hash = keccak256(message)
```

`deadline` is a Unix timestamp (seconds). The program rejects execution if `Clock::unix_timestamp > deadline`.

### SOL Rescue (instruction_id=4) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | recipient[32] | gas_fee (8 BE)
```

### SPL Rescue (instruction_id=4) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | mint[32] | recipient[32] | gas_fee (8 BE)
```

**Reference:** `buildRescueAdditionalData()` in `tests/helpers/tss.ts`

---

## Account Requirements

| Account | SOL route | SPL route |
|---------|-----------|-----------|
| `config` | Required | Required |
| `vault` | Required | Required |
| `fee_vault` | Required | Required |
| `tss_pda` | Required | Required |
| `recipient` | Required | Required (wallet, not ATA) |
| `executed_sub_tx` | Required (created) | Required (created) |
| `caller` | Required (signer) | Required (signer) |
| `system_program` | Required | Required |
| `token_vault` | None | Required (vault ATA for mint) |
| `recipient_token_account` | None | Required (must exist) |
| `token_mint` | None | Required |
| `token_program` | None | Required |

For SOL, pass `token_vault`, `recipient_token_account`, `token_mint`, `token_program` as `null`.

**Cross-account constraints (SPL):**
- `token_vault` must be the canonical ATA for `(vault, token_mint)`
- `token_vault.mint == token_mint.key()`
- `recipient_token_account.mint == token_mint.key()`
- `recipient_token_account.owner == recipient.key()`

The `recipient` account in the TSS message is the wallet pubkey (owner), not the ATA. The recipient ATA must already exist — rescue does not create it.

---

## Replay Protection

`ExecutedSubTx` PDA seeded by `["executed_sub_tx", sub_tx_id]` is created on execution. Anchor's `init` constraint causes a second call with the same `sub_tx_id` to fail at account creation — the same mechanism used by withdraw, execute, and revert.

---

## Events

### `FundsRescued`
```rust
FundsRescued {
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    token: Pubkey,          // Pubkey::default() for SOL, mint for SPL
    amount: u64,
    revert_instruction: RevertInstructions {
        revert_recipient: Pubkey,  // recipient
        revert_msg: Vec<u8>,       // always empty for rescue
    },
}
```

### `InboundFeeReimbursed`
Emitted after UV gas reimbursement from `FeeVault`.

---

## Key Errors

| Error | Cause |
|-------|-------|
| `TssAuthFailed` | Signature invalid or TSS address mismatch |
| `MessageHashMismatch` | Message reconstruction does not match provided hash |
| account init failure | `sub_tx_id` reused — `ExecutedSubTx` PDA already exists |
| `InvalidAmount` | `amount == 0` |
| `InvalidRecipient` | Recipient is zero address |
| `InvalidAccount` | SPL accounts missing or inconsistent (null/non-null mismatch) |
| `InvalidMint` | ATA mint does not match `token_mint` |
| `InsufficientFeePool` | `FeeVault` balance < `gas_fee` |
| `Paused` | Gateway is paused |
