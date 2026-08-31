# Threat Model — SVM Universal Gateway

## 1. System Overview

The SVM gateway is a single Anchor program on Solana that:
- accepts inbound deposits (`send_universal_tx`)
- releases outbound funds (`finalize_universal_tx`)
- handles outbound recovery (`revert_universal_tx`, `rescue_funds`)

Outbound calls are authorized by TSS ECDSA signatures (`secp256k1`).  
Universal Validators (UVs) submit transactions, but outbound-critical values are signature-bound.

---

## 2. Scope & Exclusions

**In scope:**
- `programs/universal-gateway/src/`

**Out of scope:**
- `programs/test-counter/`
- TypeScript scripts/tests
- UV/TSS off-chain infrastructure
- Solana/SPL/System/ATA runtime internals

**Commit/version reference:** *(insert commit hash at time of audit)*

---

## 3. Trust Boundaries & Actors

| Actor | Trust Level | Capability |
|---|---|---|
| `Config.admin` | High | Update config, oracle feed, rate limits, authorities, bounded inbound fee |
| `Config.operator` | High | Unpause gateway, rotate TSS signer |
| `Config.pauser` | Medium | Pause gateway |
| TSS | High | Authorize all outbound releases with signatures |
| UV | Untrusted for content | Submit txs and pay gas only |
| Public user | Untrusted | Call inbound deposit only |
| Pyth price account | Trusted-external | SOL/USD used for inbound gas-route caps |

**Boundary summary:**
- UV cannot change signed outbound content without failing signature validation.
- `Vault` stores bridge funds and funds Push-paid finalize/rescue gas reimbursement; `FeeVault` stores inbound fees and funds SVM-originated revert reimbursement.
- Replay protection is on-chain via `ExecutedSubTx` PDA (`sub_tx_id` uniqueness).

---

## 4. Universal Gateway Program

### Access Control

| Authority | Protected Surface |
|---|---|
| `Config.admin` | all `set_*` admin setters, `propose_authorities`, `set_inbound_fee`, `withdraw_inbound_fees`, `init_tss`, `set_operator` |
| `Config.operator` | `unpause`, `update_tss` |
| `Config.pending_admin` | `accept_admin` |
| `Config.pending_pauser` | `accept_pauser` |
| `Config.pauser` or `Config.admin` | `pause` |
| TSS signature (`TssPda.tss_eth_address`) | `finalize_universal_tx`, `revert_universal_tx`, `rescue_funds` |
| Public | `send_universal_tx` |

### External Dependencies

| Dependency | Usage | If compromised |
|---|---|---|
| Pyth `PriceUpdateV2` | inbound SOL/USD conversion | cap enforcement can be distorted |
| SPL Token Program | token transfers | transfer semantics could break |
| Associated Token Program | ATA creation in finalize SPL paths | SPL finalize path can fail |
| System Program | SOL transfers | SOL transfer paths can fail |

### Threat Scenarios

1. **TSS compromise**  
   Risk: arbitrary outbound releases.  
   Control: threshold TSS + pause path + TSS rotation (`update_tss`).  
   Residual: no timelock; high-impact if TSS + admin both compromised.

2. **Admin compromise**  
   Risk: malicious config/oracle/TSS updates.  
   Control: separate pauser can stop user flows.  
   Residual: most setters are immediate (no timelock).

3. **Authority handover typo / wrong recipient key**  
   Risk: one-step transfer can permanently assign control to an unusable pubkey.  
   Control: authority changes are proposal + acceptance; current authority remains active until the proposed key accepts.

4. **Outbound replay (`sub_tx_id`)**  
   Risk: duplicate release for same outbound request.  
   Control: `ExecutedSubTx` PDA is created with `init`; reuse fails.

5. **Message tampering by UV**  
   Risk: UV mutates recipient/amount/accounts/gas fields.  
   Control: program reconstructs message hash and verifies recovered TSS address.

6. **Execute account privilege escalation**  
   Risk: injected signer or mismatched account list in `remaining_accounts`.  
   Control: signer entries rejected; account metas validated against signed payload.

7. **Oracle account substitution / staleness**  
   Risk: bad price used for inbound gas-route caps.  
   Control: `price_update.key() == config.pyth_price_feed` + feed-id check + positive price + staleness check (`get_price_no_older_than` using `config.pyth_max_age_seconds`) + confidence threshold (`config.pyth_confidence_threshold`).  
   Residual: admin can set the staleness window too loose; recommended value is 60–90 seconds.

8. **Inbound SPL account spoofing**  
   Risk: user supplies fake source/destination token accounts.  
   Control: `user_token_account` owner/mint checks plus canonical ATA enforcement on `gateway_token_account` for `(vault, token)`.

9. **Reimbursement pool depletion**
   Risk: revert fails if `FeeVault` lacks inbound-fee surplus; rescue/finalize fail if `Vault` lacks lamports for measured gas reimbursement.
   Control: `FeeVault` reimbursement checks available lamports above rent and fails safely (`InsufficientFeePool`); `Vault` reimbursement fails atomically if bridge lamports are insufficient.

12. **Inbound fee misconfiguration**  
   Risk: admin sets an excessive inbound fee and griefs users.  
   Control: `set_inbound_fee` is hard-capped at `2_000_000` lamports (`0.002 SOL`).

13. **FeeVault surplus locked**  
   Risk: inbound fees from successful txs accumulate with no exit path.  
   Control: `withdraw_inbound_fees` (admin-only) allows sweeping surplus above rent-exemption to a treasury address.

10. **Pause griefing**  
   Risk: pauser halts flows.  
   Control: pauser can halt flows, but only operator can unpause; admin can still update configuration/rate-limit parameters while paused; keep admin/operator/pauser as separate keys.

11. **Wrong `token_rate_limit` account passed**  
   Risk: bypass token caps using another token's state account.  
   Control: account must be program-owned `TokenRateLimit` and internal `token_mint` must match expected mint.

13. **Whitelisting a centralized SPL mint without explicit acknowledgment**  
   Risk: issuer retains `mint_authority` and/or `freeze_authority`, affecting collateral assumptions or freezing vault flows.  
   Control: `set_token_rate_limit` requires explicit acknowledgment flags for retained mint and freeze authorities before a non-zero threshold can be set.

14. **PC20 emergency rescue minting**
   Risk: PC20 rescue mints wrapped supply on Solana instead of transferring from a token vault. A bad TSS rescue signature can create uncollateralized wrapped supply unless the matching Push-side ledger action has already happened.
   Control: PC20 rescue remains TSS-authorized, domain-separated with `"PC20" || source_asset`, and replay-protected by `ExecutedSubTx`; off-chain TSS policy must require Push-side confirmation before signing rescue.

15. **PC20 CEA burn self-route interpretation**
   Risk: `finalize_universal_tx` with `destination_program = gateway` can treat an inner generic `send_universal_tx` discriminator as a PC20 CEA burn when the signed remaining accounts match the PC20 account shape.
   Control: TSS signs the destination program, inner instruction data, account list, and writable flags; signer policy must explicitly classify `target = gateway`, inner `send_universal_tx`, `outer amount = 0`, and PC20 remaining accounts as PC20 burn intent.

16. **Malicious execute target installing persistent state on CEA**  
   Risk: a target invoked via `finalize_universal_tx` receives the CEA as a CPI signer and could plant persistent authority mutations (`spl_token::Approve`, `spl_token::SetAuthority(AccountOwner)`, `spl_token::SetAuthority(CloseAccount)`, `system_instruction::assign`) that survive the tx and drain funds bridged into the CEA afterwards or brick every future finalize.  
   Control: `dispatch_finalize_action` runs post-CPI invariants (F-2026-18980). CEA account must remain System-owned and empty; CEA ATA `owner` and `close_authority` must be unchanged from the pre-CPI snapshot; any delegate change on the CEA ATA is bounded so that a new delegate or an increased allowance cannot exceed the amount staged this tx. Prior legitimate delegations survive across later unrelated executes; on the current-mint ATA `spl_token::Revoke` is allowed, while on bystander CEA-owned ATAs (passed in `remaining_accounts`) delegate identity and allowance must be strictly unchanged.  
   Residual: in-call spending of pre-existing CEA lamports or token balance during the same CPI is not sandboxed. Consistent with the CEA-as-wallet model: the user chose the target and the signed payload made accounts writable.

17. **Recipient ATA rent leakage on SPL withdraw**  
   Risk: on SPL withdraw the gateway auto-creates the recipient ATA with the caller (relayer) as rent-payer. If that rent is not folded into `gas_used`, an attacker can drive many small withdrawals to fresh recipient wallets and force the relayer to sponsor ATA rent (~0.002 SOL per new `(recipient, mint)`) unreimbursed.  
   Control: `internal_withdraw` returns a `recipient_ata_created` flag; `dispatch_finalize_action` propagates it; `settle_relayer_gas_cost` (called after dispatch) includes the ATA rent in `gas_used` alongside the CEA ATA rent, so the caller is reimbursed atomically. The `UniversalTxFinalized` event exposes `recipient_ata_created` for off-chain reconciliation. Push Chain still bears the cost via the signed `gas_fee` cap, so signing policy on the Push side must bound withdrawal frequency to fresh recipients to bound net protocol cost.  
   Residual: Push-side gas budget still absorbs the ATA rent when the recipient is fresh; that's a signing-policy concern, not a relayer-farming vector.

18. **Event forgery via co-executed program logs (F-2026-18198)**  
   Risk: with `emit!`, an event lands in the shared program-log stream as `Program data: <base64>`. A parser that regexes log lines cannot cryptographically bind the emitting program, so any co-executed program in the same transaction can log a byte-identical string and forge a `UniversalTx` event, triggering a spurious mint on the Push Chain L1 that the UV credits to the attacker.  
   Control: every event is emitted via `emit_cpi!` (self-CPI to the program's `event_authority` PDA). The event bytes live in `meta.innerInstructions` under our program's id — only our program can produce them. UVs parse events from inner instructions, not from `Program data:` log lines, and validate the emitting program id.  
   Residual: parser correctness. If a UV falls back to log parsing, forgery becomes possible again; this is enforced off-chain in the UV codebase.

---

## 5. Cross-Program / Operational Risks

1. **Off-chain liveness failure (UV/TSS)**  
   Deposits can remain uncredited or outbound burns can remain unreleased without off-chain action.

2. **Non-standard SPL tokens**  
   Fee-on-transfer/rebasing tokens can break 1:1 accounting assumptions; allowlist should stay strict.

3. **Upgradeable program operational risk**  
   Upgrade authority compromise or unsafe upgrade process can override all controls.

4. **Fee model drift across paths**
   `finalize_universal_tx` and `rescue_funds` gas reimbursement use `Vault` for Push-paid destination gas; `revert_universal_tx` uses `FeeVault` for SVM-originated inbound-fee-funded recovery.
   This direction-aware split must stay intentional and explicitly monitored in ops/runbooks.

---

## 6. Deferred / Non-Goals

- Pyth max-age (`pyth_max_age_seconds`) is admin-configurable. Default is 60 seconds at initialization.
- No user-driven timeout recovery path if off-chain relay never executes.
- No automatic `FeeVault` replenishment; operational top-up is required.
