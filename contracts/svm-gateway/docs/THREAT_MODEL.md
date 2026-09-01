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
- `Vault` stores bridge funds; `FeeVault` stores inbound fees and revert/rescue reimbursements.
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

9. **Fee vault depletion**  
   Risk: revert/rescue fail due to reimbursement shortfall.  
   Control: reimbursement checks available lamports above rent and fails safely (`InsufficientFeePool`).

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

14. **Malicious execute target installing persistent state on CEA**  
   Risk: a target invoked via `finalize_universal_tx` receives the CEA as a CPI signer and could plant persistent authority mutations that survive the tx and drain funds bridged into the CEA afterwards or brick every future finalize. Concrete vectors: (a) `system_instruction::assign` to reassign the CEA; (b) `spl_token::SetAuthority(AccountOwner|CloseAccount)` on the CEA ATA; (c) `spl_token::Approve` planting a delegate, then owner-authority transfer draining the balance in the same CPI to leave a live allowance over an empty balance that later staging refills (auditor retest gaps G2/G3); (d) creating the canonical CEA ATA for a mint whose ATA doesn't yet exist and planting a delegate that a later staging will fund (auditor retest gap G1).  
   Control: `dispatch_finalize_action` runs post-CPI invariants (F-2026-18980, hardened after auditor retest). CEA account must remain System-owned and empty. CEA ATA `owner` and `close_authority` must be unchanged from the pre-CPI snapshot. On the current-mint ATA the coverage rule enforces `delegated_amount <= amount` at end of CPI — any surviving allowance must be backed by the surviving balance. On bystander CEA-owned ATAs passed in `remaining_accounts`, delegate identity and allowance must be strictly unchanged. A post-CPI second scan flags any CEA-owned SPL account that appeared during the CPI at a canonical ATA address for a mint present in the tx: it must have zero delegate, zero allowance, and zero close_authority.  
   Residual: two-tx composition (TSS-signed tx A installs a legitimate delegate; TSS-signed tx B spends the balance as owner) can still reach the "allowance over empty balance" state. TSS signing policy must refuse the composition. In-call spending of pre-existing CEA lamports or token balance is not sandboxed by these invariants (CEA-as-wallet by design). The coverage rule also blocks a legit case where a user has a pre-existing delegate for N tokens and a target spends part of that balance as owner in the same CPI — the user must revoke or reduce the delegate first; this is an intentional trade-off (see `4-CEA.md`).

16. **Event forgery via co-executed program logs (F-2026-18198)**  
   Risk: with `emit!`, an event lands in the shared program-log stream as `Program data: <base64>`. A parser that regexes log lines cannot cryptographically bind the emitting program, so any co-executed program in the same transaction can log a byte-identical string and forge a `UniversalTx` event, triggering a spurious mint on the Push Chain L1 that the UV credits to the attacker.  
   Control: every event is emitted via `emit_cpi!` (self-CPI to the program's `event_authority` PDA). The event bytes live in `meta.innerInstructions` under our program's id — only our program can produce them. UVs parse events from inner instructions, not from `Program data:` log lines, and validate the emitting program id.  
   Residual: parser correctness. If a UV falls back to log parsing, forgery becomes possible again; this is enforced off-chain in the UV codebase.

15. **Recipient ATA rent leakage on SPL withdraw / revert / rescue**  
   Risk: on any SPL release path (withdraw, revert, rescue) the gateway auto-creates the recipient ATA when missing, with the caller (relayer) as rent-payer. If that rent is not folded into the on-chain reimbursement, an attacker (or a bad signing policy) can drive many small releases to fresh recipient wallets and force the relayer to sponsor ATA rent (~0.002 SOL per new `(recipient, mint)`) unreimbursed. Liveness: without auto-create, an SPL revert/rescue whose recipient doesn't yet have an ATA would revert hard and strand user funds in the vault.  
   Control (withdraw): `internal_withdraw` returns a `recipient_ata_created` flag; `dispatch_finalize_action` propagates it; `settle_relayer_gas_cost` folds the ATA rent into measured `gas_used` alongside the CEA ATA rent. The `UniversalTxFinalized` event exposes `recipient_ata_created`.  
   Control (revert, rescue): legacy SPL branch inlines the create-if-missing pattern before transfer; the ATA rent lamports paid are folded into a uniform measured `gas_used = SIGNATURE_FEE + ExecutedSubTx rent + recipient_ata_rent`. The signed `gas_fee` is a ceiling: `require!(gas_fee >= gas_used)`. Reimbursement source is `fee_vault` for both paths (SVM-inbound-fee funded). The measured amount is visible off-chain via `InboundFeeReimbursed.amount_lamports` (the FeeVault-outflow event that fires after each reimbursement).  
   Signing-policy contract (one rule, both paths): the Push-side signer must `getAccountInfo` on the canonical ATA(`recipient`, `mint`) before signing and size `gas_fee` to cover ATA rent when it does not exist on-chain. Otherwise the on-chain cap check trips (`InsufficientGasBudget`) and no lamports move.  
   Residual: FeeVault sustainability — every revert/rescue draws from FeeVault, and a fresh-ATA release costs roughly one full inbound-fee cap (~2.04M vs 2.0M max fee). Ops must monitor FeeVault and top up before campaigns of releases to fresh recipients.

---

## 5. Cross-Program / Operational Risks

1. **Off-chain liveness failure (UV/TSS)**  
   Deposits can remain uncredited or outbound burns can remain unreleased without off-chain action.

2. **Non-standard SPL tokens**  
   Fee-on-transfer/rebasing tokens can break 1:1 accounting assumptions; allowlist should stay strict.

3. **Upgradeable program operational risk**  
   Upgrade authority compromise or unsafe upgrade process can override all controls.

4. **Fee model drift across paths**  
   `finalize_universal_tx` gas reimbursement uses `Vault`; revert/rescue reimbursement uses `FeeVault`.  
   This must stay intentional and explicitly monitored in ops/runbooks.

---

## 6. Deferred / Non-Goals

- Pyth max-age (`pyth_max_age_seconds`) is admin-configurable. Default is 60 seconds at initialization.
- No user-driven timeout recovery path if off-chain relay never executes.
- No automatic `FeeVault` replenishment; operational top-up is required.
