# CEA — Chain Executor Account

A per-user PDA that acts as the persistent on-chain identity for a Push Chain user on Solana. It is the signing authority for CPI calls made on behalf of that user.

**Derivation:** `[b"push_identity", push_account[20], bump]`

The same Push Chain address always maps to the same CEA pubkey. CEA has no private key — only the gateway can make it sign via `invoke_signed`. It is created by the Solana runtime on the first `Vault → CEA` transfer; no explicit init is needed.

---

## Role in Execute Flow

When `finalize_universal_tx` runs in execute mode:

1. Funds move `Vault → CEA`
2. Gateway builds a CPI instruction with CEA as the signer
3. `invoke_signed(&ix, accounts, &[cea_seeds])` — target program sees CEA as the caller

Target programs can use CEA as an authority (e.g., token account owner, stake authority). Because CEA is deterministic and gateway-controlled, programs can trust it as a stable per-user identity.

---

## CEA → UEA Withdrawal

When `destination_program == gateway_program_id` in execute mode, the flow routes to a special self-withdraw handler instead of an external CPI.

```
finalize_universal_tx (instruction_id=2, target=gateway)
  → Vault → CEA (amount)
  → Vault → Caller (gas_used, UV reimbursement)
  → CEA → Vault (withdraw_amount)   [skipped when amount == 0]
  → emit UniversalTx (from_cea=true)
  → emit UniversalTxFinalized
```

The `UniversalTx` event is picked up by Push Chain Universal Validators (UVs) to credit the user's UEA.
`UniversalTx` uses inner decoded values from `send_universal_tx_to_uea` args (`amount`, `payload`, `revert_recipient`).
`UniversalTxFinalized` uses outer `finalize_universal_tx` values (`amount`, signed `gas_fee`, full `ix_data`) and includes `gas_used`, `gas_to_refund`, and `ata_created`.

`from_cea` is always `true` on this path. This differs from EVM where FUNDS-only CEA withdrawals emit `from_cea=false` — an artifact of EVM routing that does not apply to SVM, where the gateway always knows it is handling a CEA withdrawal.

### TX_TYPE in CEA → UEA

| `amount` | `payload` | `tx_type` emitted |
|----------|-----------|-------------------|
| `> 0` | empty | `Funds` |
| `> 0` | non-empty | `FundsAndPayload` |
| `0` | non-empty | `GasAndPayload` — payload-only, no funds transferred |
| `0` | empty | **invalid** — reverts with `InvalidInput` |

When `amount == 0`, no balance check, rate limit check, or transfer occurs. Only the event is emitted.

This path consumes the token's epoch rate limit only when `amount > 0` (same as a standard inbound FUNDS deposit).

---

## Security Properties

- `CEA(sender_A) != CEA(sender_B)` — cross-user CPI is structurally impossible
- No account in `remaining_accounts` may have `is_signer = true` — CEA gains signer authority only via `invoke_signed`, never via outer transaction signature
- CEA only signs when TSS has authorized the transaction; the gateway validates the TSS signature before `invoke_signed` is called
