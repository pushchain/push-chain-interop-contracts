# Operations Runbook

Admin and operator reference for the Universal Gateway program.

All CLI commands assume you are in `contracts/svm-gateway/`.

---

## Bootstrap / Initialize

One-time setup. Run once per deployment.

```bash
# Deploy program
anchor deploy --provider.cluster devnet
```

There is currently no standalone `config:init` CLI command. Bootstrap is done by calling the on-chain `initialize(...)` instruction from an Anchor client.

`initialize(...)` is gated to the program's current upgrade authority. The caller must pass the gateway program account and its `ProgramData` account, and the signing authority must match `program_data.upgrade_authority_address`.

Working references:
- `app/gateway-test.ts` — devnet bootstrap example
- `tests/helpers/test-setup.ts` — test bootstrap flow

After `initialize(...)` succeeds, configure the remaining state with the CLI commands below.

Accounts created by the bootstrap flow:
- `Config` PDA
- `Vault` PDA
- `FeeVault` PDA (created lazily when `set_inbound_fee` is first called)
- `RateLimitConfig` PDA (created lazily when any rate-limit config command is first called: `set_block_usd_cap` or `update_epoch_duration`)

---

## TSS Configuration

Every authority-bearing `config-cli` command supports both:
- direct EOA execution with the role keypair flag for that command
- Squads vault proposal mode via `--multisig <multisig-pda> --member-keypair <member.json>`

This is per-role. Admin, operator, and pauser can each independently be EOA or Squads.

### Initialize TSS state

```bash
npm run config:tss-init -- --admin-keypair <admin-keypair.json> --eth 0x<40-hex-address> --chain-id <chain-id-string>

# Squads admin flow
npm run config:tss-init -- --multisig <admin-multisig-pda> --member-keypair <member.json> --eth 0x<40-hex-address> --chain-id <chain-id-string>
# then approve + execute the emitted tx index
```

### Update TSS address

```bash
npm run config:tss-update -- --operator-keypair <operator-keypair.json> --eth 0x<40-hex-address> --chain-id <chain-id-string>

# Squads operator flow
npm run config:tss-update -- --multisig <operator-multisig-pda> --member-keypair <member.json> --eth 0x<40-hex-address> --chain-id <chain-id-string>
# then approve + execute the emitted tx index
```

Only the current operator can update TSS. The TSS address is stored in `TssPda` and is used for ECDSA signature verification on all outbound transactions.

---

## Authority Rotation

### Propose admin and/or pauser

```bash
npm run config:authority-propose -- --admin-keypair <admin-keypair.json> --new-admin <new-admin-pubkey>
npm run config:authority-propose -- --admin-keypair <admin-keypair.json> --new-pauser <new-pauser-pubkey>
npm run config:authority-propose -- --admin-keypair <admin-keypair.json> --new-admin <new-admin-pubkey> --new-pauser <new-pauser-pubkey>
```

This only records a pending authority. The current admin and pauser remain active until the proposed authority accepts.
Proposing the same role again overwrites the previous pending proposal.

### Accept pending admin

```bash
npm run config:authority-accept-admin -- --keypair <path-to-new-admin-keypair.json>

# Squads pending admin flow
npm run config:authority-accept-admin -- --multisig <new-admin-multisig-pda> --member-keypair <member.json>
# then approve + execute the emitted tx index
```

The proposed admin keypair is both the signer and the fee payer for this transaction.

### Accept pending pauser

```bash
npm run config:authority-accept-pauser -- --keypair <path-to-new-pauser-keypair.json>

# Squads pending pauser flow
npm run config:authority-accept-pauser -- --multisig <new-pauser-multisig-pda> --member-keypair <member.json>
# then approve + execute the emitted tx index
```

The proposed pauser keypair is both the signer and the fee payer for this transaction.

### Set operator (admin-only, immediate)

```bash
npm run config:operator-set -- --admin-keypair <admin-keypair.json> --new-operator <new-operator-pubkey>

# Squads admin flow
npm run config:operator-set -- --multisig <admin-multisig-pda> --member-keypair <member.json> --new-operator <new-operator-pubkey>
# then approve + execute the emitted tx index
```

Operator rotation is currently one-step (no pending accept). This is intentional because the deployed `Config` layout has no extra slot for `pending_operator` without migration.

After acceptance:
- `Config.admin` or `Config.pauser` is updated
- the corresponding pending field is cleared
- the old authority immediately loses access

After `accept_admin`, update the admin keypair used by the CLI before running any further admin commands. The default admin CLI path still reads `./upgrade-keypair.json`.

Use `npm run config:show` to inspect current and pending authorities before and after acceptance.

---

## USD Caps (GAS route)

Caps are in Pyth 8-decimal USD format: `1_00000000` = $1.00

```bash
npm run config:caps-set -- --admin-keypair <admin-keypair.json> --min 100000000 --max 1000000000

# Squads admin flow
npm run config:caps-set -- --multisig <admin-multisig-pda> --member-keypair <member.json> --min 100000000 --max 1000000000
# then approve + execute the emitted tx index

# Example: $1 min, $10 max
# min = 100000000, max = 1000000000
```

Caps apply only to the instant GAS / GAS_AND_PAYLOAD routes. FUNDS routes are governed by token rate limits instead.

---

## Inbound Fee

Flat fee charged per `send_universal_tx` call, paid in SOL by the depositor. Collected into `FeeVault` to fund UV reimbursements for automated reverts and rescues.

```bash
# Set fee (in lamports); this also creates FeeVault if needed
npm run config:fee-init -- --admin-keypair <admin-keypair.json> --fee <lamports>
npm run config:fee-init -- --multisig <admin-multisig-pda> --member-keypair <member.json> --fee <lamports>
# Example: disable fee
npm run config:fee-init -- --admin-keypair <admin-keypair.json> --fee 0

# Withdraw accumulated surplus from FeeVault to a treasury address (admin-only)
npm run config:fee-withdraw -- --admin-keypair <admin-keypair.json> --amount <lamports> --recipient <pubkey>
```

The inbound fee is deducted from `native_amount` before routing. It goes to `FeeVault`, not `Vault`, preserving the 1:1 bridge invariant.
The fee is capped on-chain at `2_000_000` lamports (`0.002 SOL`). Only txs that are reverted on Push Chain consume from `FeeVault` — surplus from successful txs accumulates and can be swept via `withdraw_inbound_fees`.

---

## Oracle (Pyth)

The Pyth price feed is used to convert SOL amounts to USD for GAS route cap enforcement.

```bash
npm run config:pyth-set-feed -- --admin-keypair <admin-keypair.json> --feed <pyth-price-feed-pubkey>
npm run config:pyth-set-feed -- --multisig <admin-multisig-pda> --member-keypair <member.json> --feed <pyth-price-feed-pubkey>

# Optional: set confidence threshold
npm run config:pyth-set-conf -- --admin-keypair <admin-keypair.json> --threshold <u64>
npm run config:pyth-set-conf -- --multisig <admin-multisig-pda> --member-keypair <member.json> --threshold <u64>

# Set price staleness window (seconds); default 60 at initialization
npm run config:pyth-set-max-age -- --admin-keypair <admin-keypair.json> --seconds 60
npm run config:pyth-set-max-age -- --multisig <admin-multisig-pda> --member-keypair <member.json> --seconds 60
```

The program does not enforce a fixed feed — the admin can update it at any time via `set_pyth_price_feed`.
Inbound gas-route pricing enforces staleness (`get_price_no_older_than` using `config.pyth_max_age_seconds`) and optionally enforces confidence (`pyth_confidence_threshold > 0`).

Recommended staleness window: 60–90 seconds. Values above a few minutes defeat the purpose of the freshness check. The `get_sol_price` view function is not enforcement — it always uses a 1-hour window for display.

---

## Rate Limiting

### Block USD cap (instant route)

Per-slot USD budget for GAS route deposits. 0 disables.

```bash
npm run config:rate-set-block-usd-cap -- --admin-keypair <admin-keypair.json> --cap <u128-8-decimal-usd>
npm run config:rate-set-block-usd-cap -- --multisig <admin-multisig-pda> --member-keypair <member.json> --cap <u128-8-decimal-usd>
```

### Epoch duration

Controls the period for token-based epoch rate limits.

```bash
npm run config:rate-set-epoch -- --admin-keypair <admin-keypair.json> --seconds 86400
npm run config:rate-set-epoch -- --multisig <admin-multisig-pda> --member-keypair <member.json> --seconds 86400
```

Set to `0` to disable epoch-based rate limiting entirely.

### Token rate limits (FUNDS route)

Each SPL token that can be bridged must be whitelisted with an epoch threshold.

```bash
# Whitelist a token
npm run token:whitelist -- --mint <mint-pubkey-or-symbol> --threshold <token-natural-units>
npm run token:whitelist -- --mint <mint-pubkey-or-symbol> --threshold <token-natural-units> --trusted-mint-authority --trusted-freeze-authority

# List whitelisted tokens
npm run token:list
```

The threshold is the maximum amount of that token that can be deposited in one epoch. Native SOL also has a rate limit entry (use `Pubkey::default()` as the mint when deriving the PDA).
For SPL tokens, a non-zero threshold now requires explicit acknowledgment if the mint retains `mint_authority` and/or `freeze_authority`. Pass only the flags that match the issuer controls you are intentionally accepting.

---

## Pause / Unpause

Use for emergencies. All inbound and outbound operations revert when paused.

```bash
npm run config:pause -- --pauser-keypair <pauser-keypair.json>
npm run config:unpause -- --operator-keypair <operator-keypair.json>

# Squads flows
npm run config:pause -- --multisig <pauser-multisig-pda> --member-keypair <member.json>
npm run config:unpause -- --multisig <operator-multisig-pda> --member-keypair <member.json>
# then approve + execute the emitted tx index
```

Either the configured `pauser` or the current `admin` can call `pause`. Only the current `operator` can call `unpause`. Admin/operator/pauser can be the same or different keypairs.
While paused, inbound and outbound user flows stay blocked, but the admin can still update configuration and rate-limit parameters to remediate an incident before unpausing.

---

## Token Management

```bash
npm run token:create -- --name "Test Token" --symbol TST --decimals 6
npm run token:mint -- --mint <mint-pubkey-or-symbol> --recipient <wallet-pubkey> --amount <amount>
npm run token:list      # list all whitelisted tokens and their limits
```

---

## Upgrade / Redeploy

Anchor programs are upgradeable by default (upgrade authority is set to the deployer keypair). To upgrade the program in place:

```bash
anchor upgrade target/deploy/universal_gateway.so \
  --program-id <PROGRAM_ID> \
  --provider.wallet ./upgrade-keypair.json
```

There is no admin-only vault migration instruction in the current program. If a new program ID is required (e.g., breaking account layout change), fund migration must be handled out-of-band — the current program has no on-chain path for an admin to move vault funds to a new deployment.

---

## Verify Config State

```bash
npm run config:show
```

Shows current values for:
- Admin, pauser addresses
- Pending admin, pending pauser addresses
- USD caps
- Pyth feed
- Inbound fee
- Pause state
- Block USD cap, epoch duration

## Squads Proposal Lifecycle

When a command is run with `--multisig`, the CLI does not execute the gateway instruction directly. It creates a Squads vault transaction proposal and prints the transaction index.

```bash
npm run config:squads-show -- --multisig <multisig-pda> --tx-index <n>
npm run config:squads-approve -- --multisig <multisig-pda> --member-keypair <member.json> --tx-index <n>
npm run config:squads-execute -- --multisig <multisig-pda> --member-keypair <member.json> --tx-index <n>
```

---

## Common Issues

**Deposit rejected with `Paused`:** Gateway is paused. Call `unpause` from the operator address.

**Deposit rejected with `BelowMinCap` / `AboveMaxCap`:** `native_amount` (after inbound fee) is outside USD cap range. Adjust caps or deposit amount.

**Outbound rejected with `TssAuthFailed`:** TSS address mismatch or wrong message format. Verify `TssPda.tss_eth_address` matches the current TSS signer and message construction follows [2-WITHDRAW-EXECUTE.md](./2-WITHDRAW-EXECUTE.md).

**Outbound replay attempt fails:** `sub_tx_id` has already been finalized. The `ExecutedSubTx` PDA for this ID already exists, so the transaction is rejected during account initialization.

**SPL deposit fails with `InvalidAccount`:** on an SPL route, `user_token_account` and `gateway_token_account` must both be provided, and `gateway_token_account` must be the canonical vault ATA for the selected mint.
