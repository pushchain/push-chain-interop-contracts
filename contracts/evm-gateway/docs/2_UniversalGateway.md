# UniversalGateway — Overview & Architecture

The **UniversalGateway** is the canonical inbound entry point that allows users on external chains to interact with **Push Chain** in a unified, deterministic way. It abstracts away chain-specific complexity and provides a single interface to deposit gas, bridge funds, and execute arbitrary payloads on Push Chain through a user's **Universal Execution Account (UEA)**.

Instead of forcing users or SDKs to explicitly specify transaction intent, the UniversalGateway **infers intent automatically** based on the structure of the request (presence of payload, funds, and native value). This design removes ambiguity, reduces user error, and enforces protocol safety by construction.

UniversalGateway supports both **instant, low-value actions** (like gas top-ups and small payload executions) and **high-value fund transfers** that require stronger security guarantees. Internally, each request is classified into a well-defined transaction type and routed through the appropriate execution path with strict rate limits and validation.

In short, UniversalGateway is the bridge between external chains and Push Chain's execution layer—simple on the outside, highly structured and secure on the inside.

---

## 1. Transaction Types

UniversalGateway **infers `TX_TYPE` internally** using a fixed decision matrix derived from four signals:

- **hasPayload** → `payload.length > 0`
- **hasFunds** → `amount > 0`
- **fundsIsNative** → `token == address(0)`
- **hasNativeValue** → `nativeValue > 0` (ETH sent directly, or ETH produced by a token swap)

### Inference Table

| TX_TYPE                                               | hasPayload | hasFunds | fundsIsNative | hasNativeValue                  |
| ----------------------------------------------------- | ---------- | -------- | ------------- | ------------------------------- |
| **TX_TYPE.GAS**                                       | NO         | NO       | not-needed    | YES                             |
| **TX_TYPE.GAS_AND_PAYLOAD**                           | YES        | NO       | not-needed    | YES or NO *(NO = payload-only)* |
| **TX_TYPE.FUNDS (Native)**                            | NO         | YES      | YES           | YES                             |
| **TX_TYPE.FUNDS (ERC-20)**                            | NO         | YES      | NO            | any                             |
| **TX_TYPE.FUNDS_AND_PAYLOAD (No batching)**           | YES        | YES      | NO            | any                             |
| **TX_TYPE.FUNDS_AND_PAYLOAD (Native + Gas batching)** | YES        | YES      | YES           | YES                             |

Any other combination reverts with `Errors.InvalidInput`.

Implementation: `_fetchTxType` (`UniversalGateway.sol:891-941`).

### Key Design Notes

- **GAS vs FUNDS is unambiguous** — GAS routes always have `amount == 0`. FUNDS routes always have `amount > 0`.
- **Payload-only execution is supported** — users may execute payloads with zero gas value if their UEA is already funded.
- **Batching is implicit** — if both funds and native value are present, the gateway automatically batches gas and funds internally with no extra user input.

---

## 2. `sendUniversalTx` — Entry Points

Once `TX_TYPE` is inferred, it determines the internal routing and validation path. Three public entry points feed into this routing:

### 2.1 `sendUniversalTx(UniversalTxRequest)`

The primary entry point for any EOA or contract on the source chain. Accepts native ETH via `msg.value`.

1. Blocked for CEAs — reverts `InvalidInput` if `isCEA(msg.sender)` is true (`UniversalGateway.sol:311`).
2. Calls `_fetchTxType(req, msg.value)` to infer TX_TYPE.
3. Calls `_routeUniversalTx(req, msg.value, fromCEA=false)`.

### 2.2 `sendUniversalTx(UniversalTokenTxRequest)`

Variant that accepts gas payment in an ERC-20 token (e.g. USDC). Also blocked for CEAs.

Extra step before routing: calls `_swapToNative(gasToken, gasAmount, amountOutMinETH, deadline)` — swaps the ERC-20 to ETH via Uniswap v3 (or WETH fast-path). The resulting `ethOut` becomes `nativeValue` passed into `_fetchTxType` and routing. After that, processing is identical to 2.1.

Key validations: `gasToken != address(0)`, `gasAmount > 0`, `amountOutMinETH > 0`.

### 2.3 `sendUniversalTxFromCEA(UniversalTxRequest)`

Dedicated entry point for CEA contracts calling back into the gateway to bridge funds or payloads toward Push Chain.

Before routing, performs four checks (`UniversalGateway.sol:352-364`):
1. `ceaFactory != address(0)` — factory must be configured.
2. `ICEAFactory(ceaFactory).isCEA(msg.sender)` — caller must be a deployed CEA.
3. `mappedUEA = ICEAFactory.getUEAForCEA(msg.sender)` — must not be `address(0)`.
4. `req.recipient == mappedUEA` — anti-spoof: prevents crediting arbitrary UEAs.

Then calls `_routeUniversalTx(req, msg.value, fromCEA=true)`. All four TX_TYPEs are supported on this path. Protocol fee is skipped (`fromCEA=true`) because the fee was already paid on Push Chain.

**Why `fromCEA=true` matters on the gas leg**: In FUNDS_AND_PAYLOAD Cases 2.2/2.3, the gas leg emits a separate `UniversalTx` event with a `recipient` field. On the normal path the gas and FUNDS_AND_PAYLOAD legs emit `address(0)` (Push Chain derives the UEA from `msg.sender`). Note: the FUNDS path is different — it emits `req.recipient` as-is on both normal and CEA paths. On the CEA path, `msg.sender` is the CEA address — if `recipient` were `address(0)`, Push Chain would deploy a new UEA for the CEA's address rather than crediting BOB's UEA. The fix: `gasLegRecipient = fromCEA ? req.recipient : address(0)`.

---

## 3. Rate Limits and Block Confirmation Model

UniversalGateway enforces two distinct rate-limit systems, aligned with different security and confirmation requirements.

### 3.1 Block Confirmation Model

| Route    | TX_TYPEs                     | Confirmations | Rationale                              |
| -------- | ---------------------------- | ------------- | -------------------------------------- |
| Instant  | `GAS`, `GAS_AND_PAYLOAD`     | Low           | Frequent, low-value; fast UX           |
| Standard | `FUNDS`, `FUNDS_AND_PAYLOAD` | High          | High-value; stronger finality required |

### 3.2 Instant Route — Per-Transaction USD Caps

**Function**: `checkUSDCaps(amount)` (`UniversalGateway.sol:722-726`)

Converts the native amount to USD using the Chainlink ETH/USD oracle, then enforces:
- `usdValue >= minCapUniversalTxUsd` — floor to prevent dust spam.
- `usdValue <= maxCapUniversalTxUsd` — ceiling to bound instant-route exposure.

**Skipped when `nativeValue == 0`** (payload-only `GAS_AND_PAYLOAD` transactions skip all USD cap checks).

### 3.3 Instant Route — Per-Block USD Cap

**Function**: `_checkBlockUSDCap(amountWei)` (`UniversalGateway.sol:749-767`)

Enforces a rolling USD budget per block number:
- On each new block, `_consumedUSDinBlock` resets to 0.
- Each GAS/GAS_AND_PAYLOAD transaction with `nativeValue > 0` adds its USD value to `_consumedUSDinBlock`.
- If the cumulative block spend exceeds `blockUsdCap`, the transaction reverts `BlockCapLimitExceeded`.
- **Disabled when `blockUsdCap == 0`** (early exit at line 751).

### 3.4 Standard Route — Per-Token Epoch Rate Limit

**Function**: `_consumeRateLimit(token, amount)` (`UniversalGateway.sol:774-794`)

Per-token epoch-based quota:
- Epoch boundary: `block.timestamp / epochDurationSec`. When a new epoch starts, `EpochUsage.used` resets to 0.
- Each FUNDS/FUNDS_AND_PAYLOAD transaction deducts `amount` from the current epoch's quota.
- If `used + amount > tokenToLimitThreshold[token]`, reverts `RateLimitExceeded`.
- Token must be in the allowlist (`tokenToLimitThreshold[token] != 0`); otherwise reverts `NotSupported`.

---

## 4. Inbound Fees

Every inbound transaction (except CEA self-calls) pays a flat protocol fee in native token before routing begins.

| Property                  | Value                                                             |
| ------------------------- | ----------------------------------------------------------------- |
| State variable            | `inboundFee` (uint256, wei). Default: 0 (disabled).               |
| Admin setter              | `setInboundFee(uint256)` — `DEFAULT_ADMIN_ROLE` only.             |
| Accumulator               | `totalProtocolFeesCollected` — running total, incremented per-tx. |
| Destination               | Forwarded to `tssAddress` via low-level call.                     |
| CEA path (`fromCEA=true`) | **Skipped** — fee is already paid on Push Chain.                  |
| Insufficient fee          | Reverts with `Errors.InsufficientProtocolFee()`.                  |

**Extraction**: `_collectProtocolFee(nativeValue)` is called inside `_routeUniversalTx` **before** any routing logic. All downstream functions receive the post-fee `nativeValue`.

**Fee mechanics (additive model)**: Users send `msg.value = desiredAmount + inboundFee`. After extraction, `nativeValue = msg.value - inboundFee`.

| TX_TYPE                           | `msg.value` required            | Post-fee `nativeValue` |
| --------------------------------- | ------------------------------- | ---------------------- |
| `GAS`                             | `gasTopUp + inboundFee`         | `gasTopUp`             |
| `GAS_AND_PAYLOAD` (with gas)      | `gasAmount + inboundFee`        | `gasAmount`            |
| `GAS_AND_PAYLOAD` (payload-only)  | `inboundFee` (or 0 if disabled) | 0                      |
| `FUNDS` (native)                  | `req.amount + inboundFee`       | `req.amount`           |
| `FUNDS` (ERC-20, no gas batching) | `inboundFee` (or 0 if disabled) | 0                      |
| `FUNDS` (ERC-20, gas batching)    | `gasTopUp + inboundFee`         | `gasTopUp`             |

> See [5_InboundTx_Flows.md](./5_InboundTx_Flows.md) for full flow diagrams showing fee extraction in context.
