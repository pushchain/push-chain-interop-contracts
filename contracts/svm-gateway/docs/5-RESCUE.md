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
4. `Vault → Recipient` (amount). On the legacy SPL path the gateway auto-creates the recipient's canonical ATA if it does not yet exist (caller pays rent; folded into `gas_used`).
5. Compute measured `gas_used = SIGNATURE_FEE + ExecutedSubTx rent + recipient_ata_rent (0 unless just created)` and require `gas_fee >= gas_used`.
6. Emit `FundsRescued` with the measured `gas_used`.
7. `FeeVault → Caller` (`gas_used`, UV reimbursement).

The funds transfer comes from the bridge `Vault`. The UV reimbursement comes from `FeeVault` — not from `Vault`. This preserves the 1:1 bridge invariant. The signed `gas_fee` is a ceiling, not the payment amount; the on-chain program measures actual cost and reimburses that. If `FeeVault` cannot cover `gas_used` the tx fails with `InsufficientFeePool`; if `gas_fee < gas_used` it fails with `InsufficientGasBudget` before any lamports move.

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
| `recipient_token_account` | None | Required — canonical ATA for `(recipient, mint)`; auto-created if missing |
| `token_mint` | None | Required |
| `token_program` | None | Required |
| `associated_token_program` | Ignored | Required (used to create recipient ATA if missing) |
| `rent` | Ignored | Required (used to create recipient ATA if missing) |

For SOL, pass `token_vault`, `recipient_token_account`, `token_mint`, `token_program` as `null`. `associated_token_program` and `rent` are only consumed on the legacy SPL path; on native they are ignored (Anchor JS may auto-populate).

**Cross-account constraints (SPL):**
- `token_vault` must be the canonical ATA for `(vault, token_mint)`
- `token_vault.mint == token_mint.key()`
- `recipient_token_account` must be `get_associated_token_address(recipient, token_mint)` (address check happens before the create CPI)
- After the create-if-missing step, on-chain re-parses the account and requires `mint == token_mint.key()` and `owner == recipient.key()`

The `recipient` account in the TSS message is the wallet pubkey (owner), not the ATA. If the canonical ATA does not exist on-chain, the gateway creates it with `caller` (relayer) as rent-payer; rent is folded into measured `gas_used` and reimbursed atomically from `FeeVault`. The Push-side signer must size `gas_fee` to cover ATA rent when the ATA does not yet exist — otherwise `InsufficientGasBudget` trips and no state changes.

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
| `InvalidRecipient` | Recipient is zero address; or (SPL) post-create ATA owner doesn't match recipient |
| `InvalidAccount` | SPL accounts missing/inconsistent; or passed `recipient_token_account` is not the canonical ATA for `(recipient, mint)` |
| `InvalidMint` | ATA mint does not match `token_mint` |
| `InsufficientGasBudget` | Signed `gas_fee` is less than the measured `gas_used` |
| `InsufficientFeePool` | `FeeVault` cannot cover `gas_used` above rent-exempt minimum |
| `Paused` | Gateway is paused |
