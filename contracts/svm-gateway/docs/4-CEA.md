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

## Post-CPI Invariants (F-2026-18980)

After `invoke_signed` in `dispatch_finalize_action`, the gateway re-reads CEA-side state and rejects any transaction whose CPI target left persistent authority mutations that could drain funds bridged into the CEA later.

Five checks run on the external-CPI branch of the execute path:

| # | Check | Blocks |
|---|-------|--------|
| 1 | CEA account is System-owned and empty (`cea.owner == system_program::ID && cea.data_is_empty()`) | `system_instruction::assign` bricking every future finalize |
| 2 | CEA ATA `owner` unchanged from pre-CPI snapshot | `spl_token::SetAuthority(AccountOwner)` seizing the ATA |
| 3 | CEA ATA `close_authority` unchanged | `spl_token::SetAuthority(CloseAccount)` griefing rent |
| 4 | Post-CPI **coverage rule** on the current-mint ATA: `delegated_amount <= amount` — any surviving allowance must be backed by the surviving balance | `spl_token::Approve` + owner-authority drain leaving a live allowance over a zero balance (auditor retest G2/G3) |
| 5 | Post-CPI **new-canonical-ATA scan**: any CEA-owned SPL token account that appeared during the CPI at a canonical ATA address for a mint present in `remaining_accounts` must have zero delegate, zero allowance, and zero close_authority | Target creating the future canonical CEA ATA for a mint whose ATA didn't yet exist and planting a delegate that later staging would fund (auditor retest G1) |

Additional guard on the current-mint ATA: the delegate-identity swap check from pre-CPI still applies — a swap from an *active* prior delegate (non-`None`, non-zero allowance) to a different party is rejected, so a target can't divert an existing user allowance to itself under the coverage rule.

On bystander CEA-owned ATAs (accounts in `remaining_accounts` unrelated to the staged mint), delegate identity and allowance must be strictly unchanged — `Revoke` on a bystander reverts, since the CPI target has no legitimate reason to touch delegations on accounts unrelated to the current mint.

In-call spending of accounts the signed payload made writable (including pre-existing CEA lamports and CEA ATA balance) is not sandboxed by these invariants. Consistent with the CEA-as-wallet model: the user chose the target and made accounts writable via the TSS-signed payload; the gateway prevents persistent poisoning of the CEA identity but not the target's use of authority granted for the current call.

### Trade-off from the coverage rule (Option B)

The coverage rule blocks any execute whose end state leaves `delegated_amount > amount` on the current-mint ATA — including the legitimate case of a user having a pre-existing delegate for `N` tokens and a target spending part of that balance as owner. The user must revoke or reduce the delegate before spending. The trade-off intentionally favours structural safety over a niche wallet convenience: SPL delegates are rare in mainstream Solana DeFi, and the unsafe "live allowance over unbacked balance" state has no legitimate Solana pattern.

---

## Security Properties

- `CEA(sender_A) != CEA(sender_B)` — cross-user CPI is structurally impossible
- No account in `remaining_accounts` may have `is_signer = true` — CEA gains signer authority only via `invoke_signed`, never via outer transaction signature
- CEA only signs when TSS has authorized the transaction; the gateway validates the TSS signature before `invoke_signed` is called
- Post-CPI invariants prevent execute targets from installing persistent state on the CEA or its ATA (see above)
