# SVM Gateway — Program Upgrade Runbook

---

## 0. Quick Reference

Copy-paste commands for every common task. Replace `<CAPS>` placeholders with real values.
Full context for each command is in the numbered sections below.

```bash
# ── Inspect ────────────────────────────────────────────────────────────────

# Show multisig state (threshold, timelock, members, latest tx index)
npx ts-node app/squads-upgrade.ts --mode show \
  --multisig <MULTISIG_PDA> --rpc <RPC_URL>

# Show a specific proposal + timelock countdown
npx ts-node app/squads-upgrade.ts --mode show \
  --multisig <MULTISIG_PDA> --rpc <RPC_URL> \
  --tx-index <N>

# Show program upgrade authority and last deployed slot
solana program show <PROGRAM_ID> --url <RPC_URL>

# ── Build ──────────────────────────────────────────────────────────────────

anchor build                          # devnet
anchor build --verifiable             # mainnet (Anchor < 0.32)

# ── Buffer ─────────────────────────────────────────────────────────────────

# Write new binary to a buffer (payer pays rent ~3–4 SOL for a 617 KB program)
solana program write-buffer target/deploy/universal_gateway.so \
  --keypair ./upgrade-keypair.json \
  --url <RPC_URL> \
  --with-compute-unit-price 10000
# → outputs: Buffer: <BUFFER_ADDRESS>

# Lock buffer to Vault PDA (do this immediately after write-buffer)
solana program set-buffer-authority <BUFFER_ADDRESS> \
  --new-buffer-authority <VAULT_PDA> \
  --keypair ./upgrade-keypair.json \
  --url <RPC_URL>

# Verify buffer authority is the Vault PDA
solana program show <BUFFER_ADDRESS> --url <RPC_URL>

# Close orphaned buffers (reclaim rent after a failed or cancelled upgrade)
solana program close --buffers \
  --keypair ./upgrade-keypair.json \
  --url <RPC_URL>

# ── Upgrade: mainnet ───────────────────────────────────────────────────────

# Step 1: Propose (run from proposer's machine, stops after creating proposal)
npx ts-node app/squads-upgrade.ts --mode propose \
  --multisig    <MULTISIG_PDA> \
  --program     <PROGRAM_ID> \
  --program-data <PROGRAM_DATA> \
  --buffer      <BUFFER_ADDRESS> \
  --keypair     ./upgrade-keypair.json \
  --rpc         <RPC_URL> \
  --priority-fee 10000
# → prints tx index and buffer-verify commands for approvers

# Step 2a: Each approver independently verifies the buffer hash
solana-verify get-buffer-hash -u <RPC_URL> <BUFFER_ADDRESS>
solana-verify get-executable-hash target/deploy/universal_gateway.so
# Hashes must match — then approve via Squads UI or own key

# Step 2a-alt: Approve a proposal from the command line (one invocation per member key)
npx ts-node app/squads-upgrade.ts --mode approve \
  --tx-index <N> \
  --multisig <MULTISIG_PDA> \
  --keypair  <member-keypair.json> \
  --rpc      <RPC_URL>
# Run once per signing key until threshold is reached

# Step 2b: Check proposal status + timelock countdown before executing
npx ts-node app/squads-upgrade.ts --mode show \
  --multisig <MULTISIG_PDA> --rpc <RPC_URL> --tx-index <N>

# Step 3: Execute (after threshold approvals + timelock window)
npx ts-node app/squads-upgrade.ts --mode execute \
  --tx-index    <N> \
  --multisig    <MULTISIG_PDA> \
  --program     <PROGRAM_ID> \
  --program-data <PROGRAM_DATA> \
  --buffer      <BUFFER_ADDRESS> \
  --keypair     ./upgrade-keypair.json \
  --rpc         <RPC_URL> \
  --priority-fee 10000

# Step 4: Verify upgrade landed
# Check 1 — slot advanced + authority unchanged
solana program show <PROGRAM_ID> --url <RPC_URL>

# Check 2 — binary hash matches local build (required for mainnet)
solana-verify get-executable-hash target/deploy/universal_gateway.so
solana-verify get-program-hash <PROGRAM_ID> --url <RPC_URL>
# Must match exactly

# ── Upgrade: devnet automated (testing only) ───────────────────────────────

npx ts-node app/squads-upgrade.ts --mode all \
  --buffer <BUFFER_ADDRESS>

# ── Timelock ───────────────────────────────────────────────────────────────

# Propose a timelock change (goes through member vote)
npx ts-node app/squads-upgrade.ts --mode set-timelock \
  --timelock-seconds <N> \
  --multisig <MULTISIG_PDA> \
  --keypair  ./upgrade-keypair.json \
  --rpc      <RPC_URL>
# → prints tx index

# Execute the approved timelock change (after members approve + current lock expires)
npx ts-node app/squads-upgrade.ts --mode execute-config \
  --tx-index <N> \
  --multisig <MULTISIG_PDA> \
  --keypair  ./upgrade-keypair.json \
  --rpc      <RPC_URL>

# Devnet: full set-timelock in one shot
npx ts-node app/squads-upgrade.ts --mode all-setlock \
  --timelock-seconds 60

# ── Initial setup (one-time) ───────────────────────────────────────────────

# Derive Vault PDA for a multisig (use SDK output, never compute manually)
npx ts-node app/squads-upgrade.ts --mode show \
  --multisig <MULTISIG_PDA> --rpc <RPC_URL>
# → prints "Vault PDA: <address>"

# Transfer upgrade authority from hot key to Vault PDA
solana program set-upgrade-authority <PROGRAM_ID> \
  --new-upgrade-authority <VAULT_PDA> \
  --skip-new-upgrade-authority-signer-check \
  --keypair ./upgrade-keypair.json \
  --url <RPC_URL>

# Verify authority transferred
solana program show <PROGRAM_ID> --url <RPC_URL>
# → "Authority" must show Vault PDA

# ── Emergency ──────────────────────────────────────────────────────────────

# Pause the gateway immediately (Config.pauser, no multisig needed)
npm run config:pause -- --keypair <pauser-keypair.json>

# Rotate TSS key (Phase 1: Config.admin via config multisig)
npm run config:tss-update -- --keypair <admin-keypair.json> --new-tss <NEW_TSS_PUBKEY>

# Check current config roles
npm run config:show
```

---

## 1. Authority Model

The gateway has two independent trust layers. They use different signers and must be secured separately. Transferring upgrade authority to a multisig does **not** automatically change any `Config` field — each must be explicitly rotated.

Full design rationale: `docs/SVM-Access-Control-PoC.md`.

### Layer 0 — Program bytecode (BPFLoaderUpgradeable)

Controls who can replace the on-chain binary. Stored in the ProgramData account.

**Holder: Governance multisig — Squads Vault PDA (index 0)**

This is the highest-trust layer. A holder can replace the entire program with arbitrary code, bypassing all in-program access control. Requires the strongest signer threshold and hardware wallets.

### Layer 1 — In-program Config authorities

Controls who can call privileged instructions. Stored in the `Config` PDA. Four distinct roles, each with a separate recommended holder.

| Role               | Instruction surface (Phase 2 design)                    | Current Phase 1 surface                        | Recommended holder                         | Notes                                                        |
| ------------------ | ------------------------------------------------------- | ---------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------ |
| `Config.admin`     | USD caps, oracle feed, protocol fee, authority rotation | **+ `unpause()`, `tss_update()`**              | Config multisig (separate from governance) | Economic + protocol parameters. In Phase 1 admin also owns operator surface until operator role is implemented. |
| `Config.operator`  | `unpause()`, `tss_update()`                             | **Does not exist — field not in Config yet**   | Ops multisig                               | **Not yet implemented — Phase 2. Do not treat as in-effect during an incident.** |
| `Config.pauser`    | `pause()` only — no unpause                             | Same                                           | Guardian multisig                          | Emergency stop; must be fast. Always active. |
| TSS key (`TssPda`) | Authorizes all outbound fund releases via ECDSA         | Same                                           | TSS service hot wallet                     | Non-human; rotated by **Config.admin** in Phase 1 |

> ⚠️ **Phase 1 incident note:** If you need to pause or rotate TSS right now, the signer is **Config.admin** — not a dedicated operator. There is no `Config.operator` field in the live program. Anyone consulting this table during an incident should check the current phase before deciding who to call.

**Critical distinctions:**

- The governance multisig (upgrade authority) and the config multisig (Config.admin) are **different signers with different members and thresholds**. A single multisig holding both powers creates a concentration risk — a quorum can drain the vault AND hide the evidence by upgrading the program.
- `Config.pauser` has no `unpause()` power. Unpause is an operator action (intentional — avoids a guardian key being used to resume operations after an incident without proper review).
- In Phase 1 (current), `Config.admin` still controls unpause and TSS rotation. The operator role does not exist yet in the program.

### Rollout Phases (from SVM-Access-Control-PoC.md)

| Phase   | What changes                                                                   | Status                          |
| ------- | ------------------------------------------------------------------------------ | ------------------------------- |
| Phase 1 | Move upgrade authority from hot key to governance multisig                     | **Complete — devnet verified**  |
| Phase 2 | Add `operator` role in-program; split unpause + TSS rotation out of admin      | Pending implementation          |
| Phase 3 | Ceremony: verify all roles held by correct signers, no personal keys remaining | Pending                         |

---

## 2. Devnet Configuration (as of 2026-05-05)

| Item                      | Value                                                                      |
| ------------------------- | -------------------------------------------------------------------------- |
| Gateway program (dummy)   | `DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp`                            |
| Gateway ProgramData       | `AXVQcbZHGnY9au7reU7VMH3vSjPS575eTTC2abyJupH6`                            |
| Upgrade authority         | `G8tT59UomYEAjSjjn3ACDbpY2tZB51fjPzPHETLRLq7e` ✓ Vault PDA               |
| Squads Multisig           | `HJKFqvANP2HvDT3hRApJaFU7jMdj6cQcwmB5At4ZXyWz`                            |
| **Vault PDA (index 0)**   | `G8tT59UomYEAjSjjn3ACDbpY2tZB51fjPzPHETLRLq7e`                            |
| Multisig threshold        | 2-of-3                                                                     |
| **Time-lock**             | **60 seconds** (set 2026-05-05; upgrade to 24h before mainnet)             |
| Member 1                  | `BesWssuCiGE3EqeGRFamuouvAxJDUCdWH6NPHpAFPMBa` — `upgrade-keypair.json`  |
| Member 2                  | `2EEYH6e1PtCdWzZaag9buJmDDS79gvrm1aQm9yEcgWdR` — `clean-user-keypair.json`|
| Member 3                  | `jf4RQSJhZHU4z79GMzgdDMxaH1Mfk4SUNL4X3dBUhqy` — keypair not in repo      |
| Upgrade script            | `app/squads-upgrade.ts`                                                    |

The dummy gateway has completed two Squads-multisig upgrades on devnet (tx indices 3 and 5). Upgrade authority is the Vault PDA throughout.

---

## 3. Critical: How to Derive the Vault PDA

**Never compute the Vault PDA manually.** Always use the SDK.

```typescript
import * as multisig from "@sqds/multisig";
import { PublicKey } from "@solana/web3.js";

const [vaultPda] = multisig.getVaultPda({
  multisigPda: new PublicKey("<MULTISIG_PDA>"),
  index: 0,
});
console.log(vaultPda.toBase58());
```

**Why:** The actual seeds are `[b"multisig", multisigPda, b"vault", u8_index]`. Manual derivation that omits `b"vault"` or uses `u64` instead of `u8` for the index produces a different address that no program controls — setting this as upgrade authority permanently locks the program. This happened during devnet testing (on the test-counter program, not the gateway).

Always verify by running the derivation with the SDK before any authority transfer. The script (`app/squads-upgrade.ts`) derives and prints the Vault PDA at startup for every mode.

---

## 4. Initial Setup (One-Time, Per Deployment)

Steps performed once at deployment. For the gateway they must be done in order.

### 4.1 Create governance multisig

```bash
# Use Squads UI at app.squads.so, or the @sqds/multisig SDK.
# Record the multisig PDA and Vault PDA (index 0) before proceeding.
# Derive Vault PDA:
npx ts-node app/squads-upgrade.ts --mode show --multisig <MULTISIG_PDA>
```

Recommended mainnet configuration: 5 members, threshold 3, hardware wallets, different jurisdictions. See Section 10.

### 4.2 Deploy program

```bash
solana program deploy target/deploy/universal_gateway.so \
  --program-id target/deploy/universal_gateway-keypair.json \
  --keypair ./upgrade-keypair.json \
  --url mainnet-beta \
  --with-compute-unit-price 10000
```

### 4.3 Verify ProgramData address

```bash
solana program show <PROGRAM_ID> --url mainnet-beta
# Record "ProgramData Address" — this value does not change between upgrades
```

### 4.4 Transfer upgrade authority to Vault PDA

```bash
solana program set-upgrade-authority <PROGRAM_ID> \
  --new-upgrade-authority <VAULT_PDA> \
  --skip-new-upgrade-authority-signer-check \
  --keypair ./upgrade-keypair.json \
  --url mainnet-beta
```

`--skip-new-upgrade-authority-signer-check` is required when the new authority is a PDA (it cannot cosign the transfer transaction). Omitting it causes a signature verification error.

### 4.5 Verify

```bash
solana program show <PROGRAM_ID> --url mainnet-beta
# "Authority" field must show the Vault PDA address — stop if it shows anything else
```

### 4.6 Set a time-lock (recommended before any upgrade)

See Section 5. A 24h timelock should be set before the first mainnet upgrade proposal. Do this while the multisig still has `timeLock = 0` so the change takes effect immediately:

```bash
# Propose + (manual member approvals) + execute-config
npx ts-node app/squads-upgrade.ts --mode set-timelock --timelock-seconds 86400 \
  --multisig <MULTISIG_PDA> --keypair <proposer-keypair.json> --rpc <RPC_URL>
```

### 4.7 Rotate in-program Config authorities (after initialize)

After the gateway is initialized, all in-program roles must be rotated away from bootstrap keys.

**Config.admin → Config multisig Vault PDA** (a separate multisig from the upgrade governance multisig):

```bash
# Step 1: propose the new admin (signed by current admin)
npm run config:authority-propose -- --new-admin <CONFIG_MULTISIG_VAULT_PDA>
```

Step 2 requires the proposed admin (the Vault PDA) to sign `accept_admin`. A Vault PDA can only sign via Squads `invoke_signed`, which means this **must be a vault transaction** on the config multisig — not a config transaction. Config transactions only execute Squads built-in actions (AddMember, SetTimeLock, etc.) and cannot CPI into external programs.

The acceptance flow: create a vault transaction on the config multisig whose inner instruction is `accept_admin` with `pending_admin = config multisig Vault PDA` → members approve → vault-transaction-execute → `Config.admin` is now the Vault PDA.

The standard upgrade script wraps `BPFLoaderUpgradeable::Upgrade`; a separate script or the Squads UI transaction builder is needed to wrap `accept_admin` as the inner instruction.

**Config.pauser → Guardian multisig or dedicated hot wallet:**

```bash
npm run config:authority-propose -- --new-pauser <GUARDIAN_PUBKEY>
# Accepted by the guardian keypair directly (it can sign normally)
npm run config:authority-accept-pauser -- --keypair <guardian-keypair.json>
```

**Do not rotate Config.admin to the same Vault PDA that holds upgrade authority.** If the same signer controls both, a compromised quorum can drain the vault and then upgrade the program to erase the evidence. These must remain distinct signers.

---

## 5. Time-Lock Management

The time-lock (`timeLock`) is a multisig-level setting (seconds) that applies to **all** transactions — vault transactions (upgrades) and config transactions (including changing the timelock itself). Once a proposal reaches the approval threshold, execution is blocked until `approved_timestamp + timeLock ≤ clock.unix_timestamp`.

**There is no bypass.** A pending timelock cannot be skipped for any transaction, including emergency upgrades. Plan accordingly: do not set a 30-day timelock on a multisig that may need emergency security patches.

### View current timelock

```bash
npx ts-node app/squads-upgrade.ts --mode show --multisig <MULTISIG_PDA>
```

### Propose a timelock change

```bash
npx ts-node app/squads-upgrade.ts --mode set-timelock \
  --timelock-seconds <N> \
  --multisig <MULTISIG_PDA> \
  --keypair <proposer-keypair.json> \
  --rpc <RPC_URL>
# Output: transaction index to use in execute-config
```

Then members approve via Squads UI or the `proposalApprove` instruction. The change itself is subject to the current timelock (e.g., if the current lock is 24h, the config tx must also wait 24h after approval before execution).

### Execute timelock change

```bash
npx ts-node app/squads-upgrade.ts --mode execute-config \
  --tx-index <N> \
  --multisig <MULTISIG_PDA> \
  --keypair <executor-keypair.json> \
  --rpc <RPC_URL>
```

The command aborts with a precise "executable at" timestamp if the lock has not cleared. Re-run after the window passes.

### Recommended timelock values

| Network  | Value    | Rationale                                                    |
| -------- | -------- | ------------------------------------------------------------ |
| Devnet   | 60s      | Fast iteration; still proves the flow works end-to-end       |
| Testnet  | 1h       | Catches accidental executions; short enough for rapid testing |
| Mainnet  | 24h–72h  | Gives community and watchers time to detect malicious upgrades |

---

## 6. Upgrade Flow (Every Upgrade)

### Step 1 — Build

```bash
anchor build
```

For mainnet, use a verifiable build:

```bash
anchor build --verifiable   # Anchor < 0.32 (current: 0.31.1)
```

### Step 2 — Write new binary to a buffer

```bash
solana program write-buffer target/deploy/universal_gateway.so \
  --keypair ./upgrade-keypair.json \
  --url mainnet-beta \
  --with-compute-unit-price 10000
# Output: Buffer: <BUFFER_ADDRESS>
```

Any funded keypair can pay for the buffer upload. The buffer authority starts as the payer's key.

### Step 3 — Lock the buffer to the Vault PDA

```bash
solana program set-buffer-authority <BUFFER_ADDRESS> \
  --new-buffer-authority <VAULT_PDA> \
  --keypair ./upgrade-keypair.json \
  --url mainnet-beta
```

**This step is security-critical.** Without it, a compromised deployer key could swap the buffer contents after the multisig approved but before execution. After this step, only the Squads program (acting as the Vault PDA) can use or close the buffer.

Verify:

```bash
solana program show <BUFFER_ADDRESS> --url mainnet-beta
# "Authority" must show the Vault PDA — not a personal key
```

### Step 4 — Propose the upgrade

Pass the buffer address and all config values on the command line — no file editing needed:

```bash
npx ts-node app/squads-upgrade.ts --mode propose \
  --multisig  <MULTISIG_PDA> \
  --program   <PROGRAM_ID> \
  --program-data <PROGRAM_DATA_ADDRESS> \
  --buffer    <BUFFER_ADDRESS> \
  --keypair   <proposer-keypair.json> \
  --rpc       <RPC_URL> \
  --priority-fee 10000
```

The script prints:
- The transaction index (needed for `--mode execute`)
- The exact `solana-verify` commands each approver must run to verify the buffer hash
- The exact `--mode execute` command to run after approvals

### Step 5 — Independent approvals (each approver, separately)

Each approver who needs to vote:

1. Independently builds the program from source on their own machine
2. Verifies buffer hash matches their local build (commands printed by `--mode propose`):
   ```bash
   solana-verify get-buffer-hash -u <RPC_URL> <BUFFER_ADDRESS>
   solana-verify get-executable-hash target/deploy/universal_gateway.so
   # Must match exactly
   ```
3. Approves via the Squads UI (`app.squads.so`) or their own key invocation

**Do not approve from the same machine that proposed.** The point is independent review.

### Step 6 — Check status (optional)

After approvals, inspect the proposal state and timelock countdown:

```bash
npx ts-node app/squads-upgrade.ts --mode show \
  --tx-index <N> \
  --multisig <MULTISIG_PDA>
```

Output example:
```
Proposal tx 5:
  Status:    Approved
  Approved:  2 / 2 required
  Timelock:  NOT YET EXPIRED — executable at 2026-05-06 14:00:00 UTC (in 22h 41m)
```

### Step 7 — Execute (after threshold + timelock)

```bash
npx ts-node app/squads-upgrade.ts --mode execute \
  --tx-index  <N> \
  --multisig  <MULTISIG_PDA> \
  --program   <PROGRAM_ID> \
  --program-data <PROGRAM_DATA_ADDRESS> \
  --buffer    <BUFFER_ADDRESS> \
  --keypair   <executor-keypair.json> \
  --rpc       <RPC_URL> \
  --priority-fee 10000
```

The script checks the timelock before submitting. If the lock has not cleared, it aborts with a precise timestamp. Re-run after the window passes.

### Step 8 — Verify

Three checks are required. The third is mandatory for mainnet — slot advancing only proves *an* upgrade happened, not that the *intended* binary was deployed.

**Check 1 — Slot advanced** (proves the upgrade instruction executed):

```bash
solana program show <PROGRAM_ID> --url <RPC_URL>
# "Last Deployed In Slot" must be higher than before execution
# "Authority" must still show the Vault PDA — not a personal key
```

If the slot did not advance, `confirmTransaction` still returned success because it only confirms the outer Squads transaction landed. Look up the execution signature with:

```bash
solana confirm <EXECUTION_SIG> --url <RPC_URL> -v
# Read the log messages for the inner BPFLoaderUpgradeable error
```

**Check 2 — Authority unchanged** (proves upgrade authority was not transferred away):

Confirmed by the same `solana program show` output above — `Authority` field must show the Vault PDA.

**Check 3 — Binary hash match** (required for mainnet — proves the deployed binary is exactly the intended build):

```bash
# Hash of your local build:
solana-verify get-executable-hash target/deploy/universal_gateway.so

# Hash of the on-chain program:
solana-verify get-program-hash <PROGRAM_ID> --url <RPC_URL>

# These must match exactly.
```

> ⚠️ A log marker inside `initialize` (or any `#[account(init, ...)]` instruction) is **not** a valid upgrade marker. Anchor validates account constraints before the function body runs, so on an already-initialized deployment the function body is never reached. Use hash verification instead.

### Step 9 — Clean up buffers

Once the upgrade is verified, the old buffer account has been closed (its lamports went to the spill address during upgrade). Close any orphaned buffers from earlier failed attempts:

```bash
solana program close --buffers \
  --keypair ./upgrade-keypair.json \
  --url mainnet-beta
```

---

## 7. Devnet Automated Flow (Testing Only)

These modes run the full propose → approve × 2 → [wait for timelock] → execute sequence in one invocation. They are blocked unless the parsed `--rpc` hostname is exactly one of: `api.devnet.solana.com`, `localhost`, `127.0.0.1`.

### Full upgrade

```bash
npx ts-node app/squads-upgrade.ts --mode all \
  --buffer <BUFFER_ADDRESS>
# Uses defaults for multisig, program, program-data, and keypairs
```

### Full set-timelock

```bash
npx ts-node app/squads-upgrade.ts --mode all-setlock \
  --timelock-seconds 60
```

If the multisig already has a timelock set, `--mode all-setlock` will call `execute-config` which internally waits for the existing lock to clear.

---

## 8. squads-upgrade.ts — Complete Mode Reference

The script lives at `app/squads-upgrade.ts`. It uses `@sqds/multisig` v2.1.4 directly because `squads-multisig-cli` v0.1.7 has a serialization bug that causes vault transaction creation to fail.

### CLI flags

| Flag              | Default (devnet)                                | Description                                        |
| ----------------- | ----------------------------------------------- | -------------------------------------------------- |
| `--mode`          | `propose`                                       | One of the modes below                             |
| `--rpc`           | `https://api.devnet.solana.com`                 | RPC endpoint                                       |
| `--multisig`      | devnet test multisig                            | Squads multisig PDA address                        |
| `--program`       | devnet test gateway                             | Program to upgrade                                 |
| `--program-data`  | devnet test program data                        | ProgramData account (from `solana program show`)   |
| `--buffer`        | last devnet buffer                              | Buffer account containing the new binary           |
| `--keypair`       | `./upgrade-keypair.json`                        | Proposer / executor keypair                        |
| `--keypair2`      | `./clean-user-keypair.json`                     | Second keypair (devnet `all` modes only)           |
| `--priority-fee`  | `0`                                             | Compute unit price in microlamports (mainnet: 10000+) |
| `--tx-index`      | —                                               | Transaction index (required for execute modes)     |
| `--timelock-seconds` | —                                            | Timelock duration in seconds (required for set-timelock) |

### Modes

| Mode            | Description                                                                                   |
| --------------- | --------------------------------------------------------------------------------------------- |
| `show`          | Print multisig state (threshold, timelock, members, latest tx index). Add `--tx-index N` to also show proposal status + timelock countdown. |
| `propose`       | Create vault transaction + proposal. Stops. Prints tx index and buffer-verify commands.       |
| `approve`       | Approve a proposal with the loaded keypair. Run once per member key. Requires `--tx-index`.   |
| `execute`       | Check timelock, then execute the vault transaction (upgrade). Requires `--tx-index`.          |
| `set-timelock`  | Create config transaction + proposal to change the timelock. Stops. Prints tx index.          |
| `execute-config`| Check timelock, then execute an approved config transaction. Requires `--tx-index`.           |
| `all`           | Devnet only. Full upgrade: propose → approve × 2 → [wait timelock] → execute.                |
| `all-setlock`   | Devnet only. Full set-timelock: propose → approve × 2 → execute-config.                      |

### Upgrade instruction accounts

- ProgramData (writable)
- Program account (writable)
- Buffer (writable)
- Spill address — receives buffer rent when upgrade executes (set to member 1)
- Rent sysvar, Clock sysvar
- Vault PDA as signer (Squads signs for it via `invoke_signed`)

---

## 9. Security Threats and Mitigations

### T1 — Compromised upgrade-keypair.json

**Risk:** Anyone with this file can write buffers and create upgrade proposals. They cannot execute without a second approval (threshold ≥ 2), but they can flood the proposal queue with malicious proposals.

**Mitigation:** Keep `upgrade-keypair.json` off CI servers. On mainnet, use a dedicated proposer keypair with only Proposer permission (bitmask 1) rather than the full-permissions key (bitmask 7). The Squads permission model allows this.

### T2 — Buffer swap between upload and lock

**Risk:** If Step 3 (buffer authority transfer) is skipped or delayed, the deployer could replace the buffer contents after the multisig has reviewed and approved, deploying different code than what was approved.

**Mitigation:** Steps 2 and 3 must be executed atomically — transfer buffer authority **immediately** after write-buffer returns. Never leave a buffer under a personal key for longer than a few seconds. Every approver must verify the buffer hash matches their local build before signing.

### T3 — Wrong Vault PDA as upgrade authority

**Risk:** If the Vault PDA is computed incorrectly (wrong seeds, wrong multisig address) and set as the upgrade authority, the program is permanently unupgradeable. There is no recovery.

**Mitigation:** Always derive via `multisig.getVaultPda()`. Verify the derived address appears in `solana program show` output before proceeding. Cross-check against the multisig transaction logs from creation to confirm the multisig address itself is correct (CLI truncated the multisig address in the creation output during testing — always verify from the creation transaction, not the CLI output).

### T4 — Execution tx confirmed but inner instruction failed

**Risk:** `connection.confirmTransaction(sig)` only confirms the transaction landed on chain. It does not check whether the instruction succeeded. A Squads `VaultTransaction` can be confirmed (outer tx) while the inner upgrade instruction failed, leaving the program unchanged with no obvious error surfaced.

**Mitigation:** After every execution run the three post-upgrade checks from Step 8: slot advanced, authority unchanged, binary hash matches local build. Slot advancing only proves *an* upgrade executed — not that the *intended* binary was deployed. Hash verification is the only way to confirm the correct binary is live. If the slot did not advance, look up the execution signature with `solana confirm <SIG> --url mainnet-beta -v` and read the log messages. The script uses `skipPreflight: true` on the execute transaction — this is intentional (allows submission when simulation would reject due to missing account metadata) but means preflight errors are suppressed.

### T5 — TSS key compromise

**Risk:** TSS key signs all outbound fund releases. A compromised TSS key can drain the `Vault` PDA. This is independent of the upgrade authority.

**Mitigation (Phase 1 — current):** TSS rotation is gated to `Config.admin`. Compromised TSS → config multisig proposes `tss-update`. If funds are draining actively → guardian calls `pause` immediately (does not require multisig).

**Mitigation (Phase 2 — after operator role is added):** TSS rotation moves to `Config.operator`. The ops multisig can rotate the TSS key without involving the config multisig.

The pauser must always be capable of pausing faster than a TSS drain completes.

### T6 — Proposal with wrong buffer

**Risk:** A member creates a proposal pointing to a buffer containing malicious code, then socially engineers other members into approving.

**Mitigation:** Every approver must independently verify:
```bash
solana-verify get-buffer-hash -u <RPC_URL> <BUFFER_ADDRESS>
solana-verify get-executable-hash target/deploy/universal_gateway.so
# Must match exactly
```
No approval based on trust alone. Hardware wallets (Ledger) for all mainnet multisig members.

### T7 — Single-slot window during upgrade

**Risk:** Between when the upgrade transaction executes and when the new bytecode activates (next slot, ~400ms), the old code handles in-flight transactions.

**Mitigation:** For the gateway, this window is safe — account state changes atomically within each transaction and the upgrade does not modify stored account layouts. Only an account schema change would require special handling during this window.

### T8 — Urgent upgrade blocked by timelock

**Risk:** A critical security patch is needed but the multisig has a 72h timelock, making it impossible to deploy in a timely manner.

**Mitigation:** Design the timelock duration with incident response time in mind. A 24h timelock is strong for community visibility but still allows same-day response to critical issues discovered in the morning. For any vulnerability that allows active fund drain, the correct first response is `Config.pauser` calling `pause()` — this does not require an upgrade and does not require multisig. Only the upgrade itself is gated by the timelock.

---

## 10. Known Traps (Discovered During Testing)

| Trap                                     | What happened                                                                                                                        | Prevention                                                                                       |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `squads-multisig-cli` vault creation bug | `initiate-program-upgrade` in v0.1.7 fails with "Failed to serialize or deserialize account data"                                    | Use `app/squads-upgrade.ts` (TypeScript SDK) instead                                             |
| CLI truncates multisig address in output | The creation output showed a truncated address vs the actual address                                                                  | Always verify multisig address from the creation transaction signature, not from CLI output text |
| Manual Vault PDA derivation              | Missing `b"vault"` seed component produced a different address that no program controls                                              | Never derive manually; always use `multisig.getVaultPda()`                                       |
| Confirm ≠ success                        | `connection.confirmTransaction()` returned success even when the inner BPFLoaderUpgradeable upgrade failed                           | Always check `solana program show` after execution; read tx logs if slot did not advance         |
| `display-vault` CLI panics               | `squads-multisig-cli display-vault` panics with `WrongSize` when given the truncated address                                         | Use `--mode show` in the upgrade script, or look up the multisig creation tx directly            |
| Wrong keypair for write-buffer           | `solana program write-buffer` failed with insufficient funds because it defaulted to the wrong keypair (id.json, not upgrade-keypair.json) | Always pass `--keypair ./upgrade-keypair.json` explicitly to every `solana program` command      |
| `set-buffer-authority --skip-new-...`    | `--skip-new-upgrade-authority-signer-check` is valid for `set-upgrade-authority` but not for `set-buffer-authority`                  | For buffers, omit the flag — `set-buffer-authority` does not require the new authority to cosign |

---

## 11. Multisig Member Management

All member and threshold changes go through a config transaction — the same vote-and-execute flow as a timelock change. The `--mode execute-config` command handles any approved config transaction regardless of what the action is.

### Add a member

```typescript
// In a script or ts-node session:
import * as multisig from "@sqds/multisig";
import { Connection, Keypair, PublicKey } from "@solana/web3.js";

const MULTISIG_PDA = new PublicKey("<MULTISIG_PDA>");
const connection = new Connection("<RPC_URL>", "confirmed");
const proposer = Keypair.fromSecretKey(/* load keypair */);

const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, MULTISIG_PDA);
const txIndex = BigInt(msState.transactionIndex.toString()) + 1n;

const ix = multisig.instructions.configTransactionCreate({
  multisigPda: MULTISIG_PDA,
  transactionIndex: txIndex,
  creator: proposer.publicKey,
  rentPayer: proposer.publicKey,
  actions: [{
    __kind: "AddMember",
    newMember: {
      key: new PublicKey("<NEW_MEMBER_PUBKEY>"),
      permissions: multisig.types.Permissions.all(), // or fromPermissions([...])
    },
  }],
});
// + proposalCreate, then sendAndConfirm
// Then members approve, then: --mode execute-config --tx-index N
```

### Change threshold

```typescript
actions: [{ __kind: "ChangeThreshold", newThreshold: 3 }]
// Same flow: configTransactionCreate → approve × N → execute-config
```

### Member key loss

If fewer than `threshold` members are available, the multisig is locked. No upgrade, no config change, no recovery. This is why threshold must be set with key-loss redundancy in mind.

For a 3-of-5 setup: losing 2 keys simultaneously locks the multisig. Keep encrypted key backups in geographically separate locations.

---

## 12. Mainnet Checklist

### Before first mainnet upgrade

- [ ] Create **governance multisig**: 5 members, threshold 3, hardware wallets, different jurisdictions
- [ ] Create **config multisig** (Config.admin): separate members, threshold 3
- [ ] Create **guardian wallet** (Config.pauser): prioritizes speed (can be 2-of-3 or single hot wallet)
- [ ] Derive all Vault PDAs via `multisig.getVaultPda()` — never manually
- [ ] Deploy gateway; set upgrade authority to governance Vault PDA from day one
- [ ] After `initialize`: rotate `Config.admin` to config multisig Vault PDA (not governance)
- [ ] Rotate `Config.pauser` to guardian signer
- [ ] Set timelock to ≥ 24h:
  ```bash
  npx ts-node app/squads-upgrade.ts --mode set-timelock --timelock-seconds 86400 \
    --multisig <GOVERNANCE_MULTISIG_PDA> --rpc <MAINNET_RPC>
  ```
- [ ] Verify with `solana program show`: upgrade authority = governance Vault PDA
- [ ] Verify with `npm run config:show`: admin ≠ upgrade authority ≠ pauser (all distinct)
- [ ] Build with `anchor build --verifiable`; publish binary hash

### Every upgrade

- [ ] Buffer authority transferred to Vault PDA before proposing
- [ ] Every approver independently verifies buffer hash against their local build
- [ ] `--mode show --tx-index N` checked before executing — timelock window visible
- [ ] After execution: `solana program show` confirms slot advanced and authority still shows Vault PDA
- [ ] Binary hash verified: `solana-verify get-program-hash` matches `solana-verify get-executable-hash` of local build
- [ ] Orphaned buffers closed: `solana program close --buffers --keypair ./upgrade-keypair.json --url mainnet-beta`

### Phase 2 — Operator role (when implemented in-program)

- [ ] Create **ops multisig** (Config.operator): members who respond to incidents
- [ ] Deploy Phase 2 upgrade (adds operator field) via governance multisig upgrade flow
- [ ] Set operator field to ops multisig Vault PDA via admin
- [ ] Verify operator controls unpause and TSS rotation; admin no longer does
- [ ] Run Phase 3 ceremony from SVM-Access-Control-PoC.md: all 4 roles distinct, no personal keys remaining
