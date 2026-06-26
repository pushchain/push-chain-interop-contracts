# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Push Chain Gateway Contracts** — A monorepo containing bidirectional bridge gateway implementations between Push Chain and external blockchain ecosystems:

- **EVM Gateway** (`contracts/evm-gateway/`) — Solidity contracts for Ethereum and EVM-compatible chains
- **SVM Gateway** (`contracts/svm-gateway/`) — Anchor programs for Solana

Both gateways implement the same protocol: inbound bridging (external chain → Push Chain), outbound bridging (Push Chain → external chain via TSS signatures), automatic TX_TYPE inference, dual rate limiting, fee abstraction, and cross-chain payload execution.

## Build & Test

### EVM Gateway (Foundry)

```bash
cd contracts/evm-gateway

forge build                                                    # Build
forge test -vv                                                 # All tests
forge test --match-path test/gateway/1_adminActions.t.sol -vv  # Single file
forge test --match-test testFunctionName -vv                   # Single test
forge test -vvvv                                               # Max trace
forge coverage --ir-minimum                                    # Coverage
forge test --gas-report                                        # Gas report

# Deploy (requires .env with SEPOLIA_RPC_URL and KEY)
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

Foundry profiles: `default` (1000 fuzz), `ci` (2000 fuzz), `coverage`, `debug` (optimizer off), `gas`, `fork`.

### SVM Gateway (Anchor)

```bash
cd contracts/svm-gateway

npm install                                          # Install deps
anchor build                                         # Build programs
anchor test                                          # All tests (or: npm test)
TEST_FILE=tests/execute.test.ts anchor test          # Single file
npm run test:execute                                 # Convenience scripts available:
# test:withdraw, test:admin, test:rate-limit, test:universal-tx,
# test:rescue, test:cea-to-uea, test:execute-heavy
npm run typecheck                                    # TypeScript type check
```

**CLI tools** (run from `contracts/svm-gateway/`):
- Token: `npm run token:{create,mint,whitelist,remove-whitelist,list}`
- Config: `npm run config:{show,tss-init,tss-update,authority-set,pause,unpause,fee-init,caps-set,pyth-set-feed,pyth-set-conf,rate-set-block-usd-cap,rate-set-epoch,rate-set-token}`

## Architecture

### Transaction Type System

TX_TYPE is **automatically inferred** from request structure — users never specify it.

| TX_TYPE | Route | Inferred when | Rate Limiting |
|---------|-------|---------------|---------------|
| `GAS` | Instant | No funds, no payload, has native value | USD caps (min/max) + block cap |
| `GAS_AND_PAYLOAD` | Instant | No funds, has payload | USD caps (min/max) + block cap |
| `FUNDS` | Standard | Has funds, no payload | Per-token epoch limits |
| `FUNDS_AND_PAYLOAD` | Standard | Has funds, has payload | Per-token epoch limits |

**Inference logic**: `hasFunds` and `hasPayload` determine the type. If neither is true and no native value, the tx reverts. See `_fetchTxType()` in both `UniversalGateway.sol` and the SVM `deposit.rs`.

### Rate Limiting (Dual System)

- **Instant route** (GAS, GAS_AND_PAYLOAD): Per-tx USD caps + per-block USD budget. Oracle-priced (Chainlink on EVM, Pyth on SVM).
- **Standard route** (FUNDS, FUNDS_AND_PAYLOAD): Per-token epoch-based limits. Usage resets on epoch rollover.

### Cross-Chain Flow

**Inbound** (External → Push Chain): User deposits via gateway → funds locked in Vault → `UniversalTx` event → relayers credit UEA on Push Chain.

**Outbound** (Push Chain → External): User initiates on Push Chain → TSS signs (ECDSA secp256k1) → relayer submits to external chain → gateway validates signature → funds released from Vault → `UniversalTxExecuted` event.

### Outbound Instruction IDs (SVM)

| ID | Operation | Description |
|----|-----------|-------------|
| `1` | Withdraw | Vault → CEA → Recipient |
| `2` | Execute | Vault → CEA → Target Program (CPI) |
| `3` | Revert | Unified SOL + SPL revert |
| `4` | Rescue | Emergency fund release (no replay guard) |

SVM entrypoint: `finalize_universal_tx` (withdraw/execute) and separate `revert_universal_tx` / `rescue_funds` instructions.

**TX-size ref route** (execute only): when `ix_data` exceeds ~900 bytes, use the two-step ref route:
1. `store_execute_ix_data(sub_tx_id, keccak256(ix_data), ix_data)` — uploads bytes to a `StoredIxData` PDA.
2. `finalize_universal_tx_with_ix_data_ref(...)` — loads `ix_data` from the PDA, same TSS message format and execution logic as `finalize_universal_tx`. Gas cost is `base_finalize_gas + 5000` (extra 5000 reimburses the store UV).
3. `close_stored_ix_data()` — no args; only needed on failure/abort path (finalize auto-closes on success). Recovers PDA rent to `store_refund_recipient`. Supports orphan recovery via `getProgramAccounts` — `sub_tx_id` is stored inside the PDA so no local UV state is required.

See `contracts/svm-gateway/docs/6-TX-SIZE-REF-ROUTE.md` for full details.

### Outbound (EVM)

EVM uses `Vault.finalizeUniversalTx()` as the main outbound entrypoint. All operations route through deterministic CEA (Chain Execution Account) contracts deployed per user via CREATE2. The CEA executes multicall payloads (`Multicall[]` struct). Separate functions: `revertUniversalTx()`, `rescueFunds()`.

## EVM Architecture

**Core contracts:**
- `UniversalGateway.sol` — Main inbound gateway (current version)
- `UniversalGatewayPC.sol` — Push Chain side (outbound: burn + swap + emit)
- `Vault.sol` — External chain fund custody, TSS-controlled outbound via CEA
- `VaultPC.sol` — Push Chain side vault

**Key patterns:**
- Upgradeable proxy (TransparentUpgradeableProxy, OpenZeppelin)
- Roles: `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, `TSS_ROLE`
- Reentrancy guards on all deposit/withdraw paths
- Chainlink ETH/USD oracle with staleness + L2 sequencer checks
- Uniswap v3 for ERC-20 → native gas swaps
- Solidity 0.8.26, `via_ir=true`, optimizer runs: 99999

**Types are split across three files:** `Types.sol` (shared), `TypesUG.sol` (gateway-specific), `TypesUGPC.sol` (Push Chain gateway-specific).

**Test organization** (numbered files in `test/gateway/`):
- `1_` admin, `2-3_` deposits, `4_` GAS type, `5-8_` FUNDS cases, `9_` TX_TYPE inference
- `10_` withdrawals, `12-13_` rate limits, `14_` gatewayPC, `15_` CEA inbound
- `16_` protocol fees, `17_` rescue funds
- All tests inherit from `BaseTest.t.sol` (setup, mocks, helpers)
- Fork tests: `3_sendUniversalTx_token_fork.t.sol`
- Vault tests: `test/vault/` (Vault.t.sol, VaultPC.t.sol, VaultWithdrawal.t.sol, VaultRescueFunds.t.sol)

See `contracts/evm-gateway/CLAUDE.md` for detailed EVM-specific guidance including Vault/CEA architecture, CEA inbound route, and UGPC outbound flow.

## SVM Architecture

**Core program:** `universal-gateway` (Anchor 0.31.1)

**Source layout** (`programs/universal-gateway/src/`):
- `lib.rs` — Program entrypoints
- `state.rs` — Account structures and PDA definitions
- `errors.rs` — Custom error codes
- `instructions/` — `deposit.rs`, `withdraw.rs`, `execute.rs`, `revert.rs`, `rescue.rs`, `admin.rs`, `initialize.rs`, `tss.rs`
- `utils/` — `encoding.rs`, `pricing.rs`, `rate_limit.rs`, `transfers.rs`, `validation.rs`

**PDAs and seeds:**
```
config           → b"config"
vault            → b"vault"             (SOL vault, authority only)
tsspda_v2        → b"tsspda_v2"         (TSS address, chain_id, nonce)
rate_limit_config → b"rate_limit_config"
rate_limit       → b"rate_limit"        (per-token epoch state)
executed_sub_tx  → b"executed_sub_tx"   (replay protection, existence check)
push_identity    → b"push_identity"     (CEA per-user signing authority)
stored_ix_data   → b"stored_ix_data"    (sub_tx_id[32], keccak256(ix_data)[32]) — tx-size ref route
```

**Key patterns:**
- PDA-based (no external signers for protocol operations)
- TSS via ECDSA secp256k1 recovery (`tss.rs`)
- CEA provides persistent CPI signing authority per user
- Replay protection via `ExecutedTx` PDA existence
- Pyth price feeds for USD valuation

**Test files** (`tests/`):
- `execute.test.ts` — CPI execution (largest suite)
- `withdraw.test.ts`, `universal-tx.test.ts`, `rate-limit.test.ts`, `admin.test.ts`
- `rescue.test.ts`, `cea-to-uea.test.ts`, `execute-heavy.test.ts`
- Helpers: `tests/helpers/` (`tss.ts`, `test-setup.ts`, `token-mint.ts`, `price-feed.ts`)
- Shared state: `tests/shared-state.ts`
- Payload encoding: `app/execute-payload.ts`

**TSS message format:** `keccak256("PUSH_CHAIN_SVM" || instruction_id || chain_id || amount || additional_data)` — replay protection is via `ExecutedSubTx` PDA, not a nonce.

**Test files also include:**
- `tx-size-ref.test.ts` — ref-finalize route (store + finalize-by-reference)

See `contracts/svm-gateway/docs/` for detailed architecture, flows, threat model, and runbook.

## Build Issues & Solutions (SVM)

1. **`spl-associated-token-account` dependency** — Direct dependency causes `#[global_allocator]` conflict. Use `anchor_spl::associated_token::spl_associated_token_account` re-export instead. Requires `anchor-spl` with `features = ["associated_token"]`.

2. **Rent sysvar import** — `rent::ID` doesn't resolve. Use `anchor_lang::solana_program::sysvar::rent as rent_sysvar` then `rent_sysvar::ID`.

3. **Manual ATA creation** — `init_if_needed` incompatible with `Option<Account>` pattern. Use manual CPI via `spl_associated_token_account::instruction::create_associated_token_account`.

## Security Model

- **TSS signatures** are the sole authorization for all outbound transactions
- **Replay protection**: Nonces (EVM) or ExecutedTx PDAs (SVM)
- **Pausable** for emergency stops on both chains
- **Rate limiting** on both instant and standard routes
- **Oracle staleness checks**: Chainlink (EVM), Pyth (SVM)
- **Reentrancy guards** on all EVM deposit/withdraw paths
- **CEA isolation**: Only CEA can sign for a user's cross-chain identity

## Version Information

- **EVM:** Solidity 0.8.26, Foundry, EVM target: shanghai
- **SVM:** Anchor 0.31.1, Solana 1.18+, Rust 1.75+
- **Node:** 20+ (SVM tests and CLIs)
