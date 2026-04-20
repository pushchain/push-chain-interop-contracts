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
| `Config.admin` | High | Update config, oracle feed, rate limits, authorities, bounded protocol fee |
| `Config.pauser` | Medium | Pause/unpause gateway |
| TSS | High | Authorize all outbound releases with signatures |
| UV | Untrusted for content | Submit txs and pay gas only |
| Public user | Untrusted | Call inbound deposit only |
| Pyth price account | Trusted-external | SOL/USD used for inbound gas-route caps |

**Boundary summary:**
- UV cannot change signed outbound content without failing signature validation.
- `Vault` stores bridge funds; `FeeVault` stores protocol fees and revert/rescue reimbursements.
- Replay protection is on-chain via `ExecutedSubTx` PDA (`sub_tx_id` uniqueness).

---

## 4. Universal Gateway Program

### Access Control

| Authority | Protected Surface |
|---|---|
| `Config.admin` | all `set_*` admin setters, `propose_authorities`, `set_protocol_fee`, `init_tss`, `update_tss` |
| `Config.pending_admin` | `accept_admin` |
| `Config.pending_pauser` | `accept_pauser` |
| `Config.pauser` or `Config.admin` | `pause`, `unpause` |
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

12. **Protocol fee misconfiguration**  
   Risk: admin sets an excessive inbound fee and griefs users.  
   Control: `set_protocol_fee` is hard-capped at `2_000_000` lamports (`0.002 SOL`).

10. **Pause griefing**  
   Risk: pauser halts flows.  
   Control: admin can unpause directly; keep admin/pauser as separate keys.

11. **Wrong `token_rate_limit` account passed**  
   Risk: bypass token caps using another token's state account.  
   Control: account must be program-owned `TokenRateLimit` and internal `token_mint` must match expected mint.

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
