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
   Risk: a target invoked via `finalize_universal_tx` receives the CEA as a CPI signer and could plant persistent authority mutations (`spl_token::Approve`, `spl_token::SetAuthority(AccountOwner)`, `spl_token::SetAuthority(CloseAccount)`, `system_instruction::assign`) that survive the tx and drain funds bridged into the CEA afterwards or brick every future finalize.  
   Control: `dispatch_finalize_action` runs post-CPI invariants (F-2026-18980). CEA account must remain System-owned and empty; CEA ATA `owner` and `close_authority` must be unchanged from the pre-CPI snapshot; any delegate change on the CEA ATA is bounded so that a new delegate or an increased allowance cannot exceed the amount staged this tx. Prior legitimate delegations survive across later unrelated executes; on the current-mint ATA `spl_token::Revoke` is allowed, while on bystander CEA-owned ATAs (passed in `remaining_accounts`) delegate identity and allowance must be strictly unchanged.  
   Residual: in-call spending of pre-existing CEA lamports or token balance during the same CPI is not sandboxed. Consistent with the CEA-as-wallet model: the user chose the target and the signed payload made accounts writable.

15. **Recipient ATA rent farming (accepted risk)**  
   Risk: on SPL withdraw, if the recipient's ATA does not exist, the gateway creates it via CPI with the caller (relayer) as rent-payer. An attacker can drive many small withdrawals to fresh recipient wallets, forcing the relayer to sponsor ATA rent each time.  
   Control: none currently. Deliberately deferred. Rationale: ATA auto-create mirrors the CEA ATA path and preserves first-withdraw UX to fresh wallets. Mitigation candidates (recipient-pays via amount deduction; billing on Push Chain L1) are tracked as protocol changes for a future revision.  
   Residual: relayer sponsors ATA rent (~0.002 SOL per new `(recipient, mint)`); recoverable only by the recipient closing the ATA.

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
