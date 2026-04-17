# Threat Model — Push Chain Universal Gateway

## 1. System Overview

The Push Chain Universal Gateway is a two-chain bridging system that routes funds and execution payloads between external EVM chains (Ethereum, Base, Arbitrum, etc.) and Push Chain. On the EVM side, `UniversalGateway` accepts inbound deposits from users and `Vault` holds token custody for outbound releases; on the Push Chain side, `UniversalGatewayPC` burns PRC20 tokens to initiate outbound flows and `VaultPC` accumulates protocol fees. An off-chain Threshold Signature Scheme (TSS) authority bridges events between the two chains: it observes on-chain events and triggers the corresponding on-chain execution on the destination chain. Users never interact with TSS directly — they interact with gateway contracts, and TSS acts as the trusted relay.

---

## 2. Scope & Exclusions

**In scope:**
- `src/UniversalGateway.sol`
- `src/Vault.sol`
- `src/UniversalGatewayPC.sol`
- `src/VaultPC.sol`

**Out of scope:**
- `src/testnetV0/` — testnet-only contracts, not production
- All test mocks and forge test helpers
- CEA and CEAFactory implementation contracts (external dependencies; trusted at their interfaces)
- OpenZeppelin library internals

**Commit/version reference:** *(insert commit hash at time of audit)*

---

## 3. Trust Boundaries & Actor Definitions

| Actor | Type | Trust Level | Capabilities |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | EOA / Multisig | Highest | Config changes, role assignment across all contracts |
| TSS (Threshold Sig Authority) | Off-chain multi-party | High | Finalise, revert, and rescue funds; relay between chains |
| `PAUSER_ROLE` | EOA / Multisig | Medium | Emergency pause / unpause only |
| `VAULT_ROLE` | Smart contract (Vault) | Medium | Call `revertUniversalTx()` and `rescueFunds()` on Gateway |
| `MANAGER_ROLE` | EOA / Multisig (VaultPC) | Medium | Withdraw collected protocol fees from VaultPC |
| CEA (Chain Execution Account) | Smart contract | Low-Medium | `sendUniversalTxFromCEA()` only; identity verified via CEAFactory |
| Public User | EOA / contract | Untrusted | `sendUniversalTx()`, `sendUniversalTxOutbound()`, `rescueFundsOnSourceChain()` |
| Chainlink Oracle | External protocol | Trusted-external | ETH/USD price feed, L2 sequencer uptime |
| Uniswap V3 | External protocol | Trusted-external | Token → native ETH swaps on EVM side |
| UniversalCore | Push Chain contract | Trusted-external | Gas quotes, exactOutputSingle swaps, refund of unused PC |

**Trust boundary summary:**

```
[ Public User ] ──→ [ UniversalGateway ] ──(deposit)──→ [ TSS address ]
                              │                                   │
                     (VAULT_ROLE only)                   (off-chain relay)
                              ↓                                   ↓
                           [ Vault ] ←──(TSS_ROLE)────→ [ finalizeUniversalTx ]
                              │
                   (CEAFactory + ICEA)
                              ↓
                    [ CEA per user UEA ]

[ Public User ] ──→ [ UniversalGatewayPC ] ──(gas swap)──→ [ UniversalCore ]
                              │                                      │
                      (burn PRC20)                         (refund unused PC)
                              ↓                                      │
                          [ VaultPC ] ←──(protocol fee)─────────────┘
```

---

## 4. UniversalGateway

**What this contract does:** Inbound entry point on external EVM chains. Accepts native ETH and ERC-20 tokens from users, enforces a dual-layer rate limit system (per-block USD caps for instant routes; per-token epoch limits for standard routes), forwards native ETH deposits directly to the TSS address, coordinates ERC-20 custody with Vault, and handles refund and rescue flows back to users. It also serves as the canonical token support registry consulted by Vault.

### Access Control Table

| Role | Constant | Assigned To | Protected Functions |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | OZ default | Admin multisig | `pause()`, `unpause()`, `setTSS()`, `setVault()` (whenPaused), `setCapsUSD()`, `setBlockUsdCap()`, `setUniswapV3Config()`, `setTokenLimitThresholds()`, `setEthUsdFeed()`, `setChainlinkStalePeriod()`, `setL2SequencerFeed()`, `setL2SequencerGracePeriodSec()`, `setCEAFactory()`, `setProtocolFee()`, `updateEpochDuration()`, `setDefaultSwapDeadline()`, `setV3FeeOrder()` |
| `TSS_ROLE` | `keccak256("TSS_ROLE")` | TSS address | Receives native ETH via `_handleDeposits()` (direct transfer target) |
| `VAULT_ROLE` | `keccak256("VAULT_ROLE")` | Vault contract | `revertUniversalTx()`, `rescueFunds()` |
| CEA identity check | via CEAFactory | CEA contracts only | `sendUniversalTxFromCEA()` |
| *(none)* | — | Public | `sendUniversalTx()`, `sendUniversalTx(token,...)`, `checkUSDCaps()`, `getEthUsdPrice()`, `isSupportedToken()`, `currentTokenUsage()` |

### External Dependencies

| Dependency | Interface | Trust Assumption | Risk if Compromised |
|---|---|---|---|
| Chainlink ETH/USD feed | `AggregatorV3Interface` | Returns fresh, correct ETH/USD price | Manipulated price bypasses USD rate limits (both min and max caps) |
| Chainlink L2 sequencer feed | `AggregatorV3Interface` | Accurately reflects sequencer uptime | False "UP" signal allows deposits during sequencer downtime |
| Uniswap V3 router | `ISwapRouterV3` | Executes swaps honestly within deadline | Malicious router drains token approvals granted by the gateway |
| Uniswap V3 factory | `IUniswapV3Factory` | Returns correct pool addresses | Fake pool routes user swap to attacker-controlled contract |
| CEAFactory | `ICEAFactory` | `isCEA()` and `getPushAccountForCEA()` are accurate | CEA spoofing; arbitrary recipient injected via `sendUniversalTxFromCEA` |
| TSS_ADDRESS | EOA / multisig | Controlled by honest TSS committee | Compromised TSS receives and retains all deposited native ETH |
| Vault (VAULT_ROLE) | `IVault` | Calls `revertUniversalTx`/`rescueFunds` correctly | Malicious vault with VAULT_ROLE drains gateway ERC-20 balances |

### Threat Scenarios

1. **Oracle price manipulation** — An attacker exploits a stale or manipulated Chainlink ETH/USD price to either bypass the minimum USD cap (depositing near-zero value) or, during a flash price spike, exceed the maximum USD cap. Mitigated by: `chainlinkStalePeriod` staleness check, L2 sequencer uptime validation, positive price assertion, and `answeredInRound >= roundId` check. Residual risk: if `ethUsdFeed == address(0)` (not yet configured), all instant-route deposits revert.

2. **Rate limit exhaustion / griefing** — A well-funded attacker sends maximum-value instant-route transactions in a single block to exhaust `BLOCK_USD_CAP`, denying service to other users for that block. The cap resets per block but a sustained attacker can repeat this every block. No per-user sub-limit exists. Mitigated by: both block cap and epoch cap are enforced; economic cost of sustained attack scales with the cap value.

3. **CEA impersonation on `sendUniversalTxFromCEA`** — An attacker deploys a contract and calls `sendUniversalTxFromCEA()` claiming to be a CEA to bypass deposit limits or spoof a recipient. Mitigated by: `_isCallerCEA()` queries `CEAFactory.isCEA(msg.sender)` and reverts with `Unauthorized` if false. Residual risk: if `CEA_FACTORY` is `address(0)`, all calls revert (safe but unavailable).

4. **Recipient anti-spoof bypass via CEA path** — A legitimate CEA caller sets `req.recipient` to an arbitrary Push Chain address (not its mapped UEA). Mitigated by: `sendUniversalTxFromCEA()` validates `req.recipient == CEAFactory.getPushAccountForCEA(msg.sender)` and reverts if mismatched. Residual risk: CEAFactory returning a wrong UEA mapping (factory compromise, see §3).

5. **Replay of revert / rescue `subTxId`** — TSS replays the same `subTxId` for `revertUniversalTx()` or `rescueFunds()` to double-pay users or drain the gateway. Mitigated by: `isExecuted[subTxId]` mapping; reverts with `PayloadExecuted` on any repeated call.

6. **Admin role compromise** — A compromised admin key updates TSS address, oracle feeds, Uniswap router, Vault address, or CEAFactory within a single transaction, redirecting all fund flows. Mitigated by: `setVault()` requires `whenPaused`; `setTSS()` atomically revokes the old TSS role. Residual risk: no timelock on most admin setter functions; single-key admin is critical. Recommend multisig + timelock.

7. **Uniswap sandwich attack on `_swapToNative`** — When `deadline == 0`, the gateway defaults to `block.timestamp + defaultSwapDeadlineSec` at execution time. A transaction held in the mempool always receives a fresh deadline, making sandwich attacks viable during the hold period. Mitigated by: `amountOutMinETH` slippage bound enforced by caller; callers should pass an explicit deadline.

8. **Non-standard ERC-20 transfer semantics** — Supported tokens with fee-on-transfer behaviour cause revert/rescue flows to receive less than the expected `amount`, potentially locking funds in the gateway. Tokens that revert on zero-transfer can deadlock protocol fee collection. See `docs/SECURITY_ANALYSIS_v1.md` for full analysis.

9. **Protocol fee DoS via non-payable TSS** — If `INBOUND_FEE > 0` and `TSS_ADDRESS` is a contract that reverts on ETH receive, every `_collectProtocolFee()` call fails, blocking all deposits. Same risk applies to `_handleDeposits()` for native ETH. Mitigated by: TSS address should be a plain EOA or a contract with a payable fallback.

10. **Storage layout corruption on upgrade** — The gateway uses an upgradeable proxy pattern (`Initializable`). Adding state variables in the wrong position during an implementation upgrade corrupts existing storage slots silently, potentially overwriting balances, roles, or configuration. Admin must follow OpenZeppelin upgrade-safe storage extension patterns (append-only, no gaps moved).

---

## 5. Vault

**What this contract does:** Token custody contract deployed on external EVM chains. Holds ERC-20 tokens deposited via `UniversalGateway`. TSS calls `finalizeUniversalTx()` to deploy or reuse a CEA, fund it with tokens, and execute a multicall payload on the user's behalf. TSS also calls `revertUniversalTxToken()` and `rescueFunds()` to return tokens to users through the Gateway's refund path.

### Access Control Table

| Role | Constant | Assigned To | Protected Functions |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | OZ default | Admin multisig | `setGateway()`, `setTSS()`, `setCEAFactory()` |
| `TSS_ROLE` | `keccak256("TSS_ROLE")` | TSS address | `finalizeUniversalTx()`, `revertUniversalTxToken()`, `rescueFunds()` |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | Pauser address | `pause()`, `unpause()` |

### External Dependencies

| Dependency | Interface | Trust Assumption | Risk if Compromised |
|---|---|---|---|
| UniversalGateway | `IUniversalGateway` | `isSupportedToken()` is correct; accepts `revertUniversalTx`/`rescueFunds` calls | Malicious gateway (with `VAULT_ROLE`) can refuse refunds or drain Vault ERC-20 via those calls |
| CEAFactory | `ICEAFactory` | `getCEAForPushAccount()` returns the correct CEA; `deployCEA()` is safe | Wrong CEA address receives user funds; malicious factory redirects all custody |
| ICEA (per-user) | `ICEA` | `executeUniversalTx()` executes the payload faithfully and does not reenter | CEA multicall payload reenters Vault or Gateway before state is finalised |
| TSS (off-chain) | EOA / multisig | Calls `finalizeUniversalTx` with correct params matching the user's request | Compromised TSS redirects funds to the wrong CEA or suppresses all finalisations |

### Threat Scenarios

1. **TSS key compromise** — `TSS_ROLE` can call `finalizeUniversalTx()` to direct any supported token held in the Vault to an attacker-controlled CEA, then execute a multicall payload to extract those tokens to an arbitrary address. All Vault token custody is at risk. Mitigated by: TSS is a threshold scheme (multiple parties required); `whenNotPaused` enables emergency stop by PAUSER_ROLE.

2. **CEA reentrancy via multicall payload** — During `_finalizeUniversalTx()`, tokens are transferred to the CEA and then `CEA.executeUniversalTx()` is called. A malicious or compromised CEA multicall payload could reenter `Vault.finalizeUniversalTx()` before the first call completes. Mitigated by: `nonReentrant` modifier on `finalizeUniversalTx()`.

3. **CEAFactory address replaced with attacker-controlled factory** — Admin updates `CEA_FACTORY` to a malicious contract. `finalizeUniversalTx()` calls `getCEAForPushAccount()`, receives an attacker-controlled address, and sends tokens there. Mitigated by: requires `DEFAULT_ADMIN_ROLE`. Residual risk: no timelock; single-block attack if admin is compromised.

4. **Gateway address replaced with malicious contract** — Admin updates `gateway` to an attacker-controlled contract. Vault calls `gateway.revertUniversalTx()` or `gateway.rescueFunds()`, transferring tokens to the fake gateway which retains them. Mitigated by: requires `DEFAULT_ADMIN_ROLE`. Residual risk: no timelock.

5. **Token delist blocking revert path** — Admin removes a token from the Gateway's supported list after a user has deposited but before TSS processes the revert. `_enforceSupported()` in `revertUniversalTxToken()` and `rescueFunds()` reverts, permanently blocking TSS from returning user funds for that token. Mitigation: operational process must verify no pending reverts exist before delisting a token.

6. **Insufficient Vault balance on finalisation** — The Vault holds fewer tokens than `amount` specified in `finalizeUniversalTx()` (e.g. due to accounting error or manual sweep). The `balanceOf >= amount` check reverts, blocking all finalisations for that token until balance is restored. TSS must ensure the Vault is funded before submitting finalisation transactions.

7. **Native ETH msg.value mismatch** — For native finalisations, `_validateParams()` enforces `msg.value == amount`. Any discrepancy reverts immediately. The exact `amount` is forwarded to the CEA via `{value: amount}`. No ETH remains stranded in the Vault.

8. **CEA deployment failure** — `deployCEA()` on the factory reverts (factory paused, CREATE2 address collision, or factory bug). The entire `finalizeUniversalTx()` reverts. No funds are lost (state is rolled back) but the transaction is blocked until the factory issue is resolved. TSS must re-attempt after the factory is fixed.

9. **Double-finalisation replay** — TSS submits the same `subTxId` twice for `finalizeUniversalTx()`. The Vault does not maintain a `subTxId` executed mapping for finalisations (Gateway tracks it only for revert/rescue). A second call with the same parameters would succeed if the Vault has sufficient balance, effectively executing the user's payload twice. Mitigated by: TSS off-chain deduplication. No on-chain guard for finalisation replay exists in the Vault.

10. **Pause griefing by PAUSER_ROLE** — A compromised or malicious PAUSER_ROLE holder pauses the Vault indefinitely, blocking all finalisations, reverts, and rescues. There is no on-chain forced unpause path. Mitigated by: `DEFAULT_ADMIN_ROLE` can revoke and reassign `PAUSER_ROLE`, then unpause.

---

## 6. UniversalGatewayPC

**What this contract does:** Outbound gateway deployed on Push Chain. Users call `sendUniversalTxOutbound()` to burn PRC20 tokens and emit an event that TSS relays to the origin chain, triggering fund release from Vault. Gas fees are paid in native PC, converted to gas tokens via `UniversalCore.swapAndBurnGas()` (exactOutputSingle), with unused PC refunded directly to the caller. The contract infers TX_TYPE automatically from the request structure.

### Access Control Table

| Role | Constant | Assigned To | Protected Functions |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | OZ default | Admin multisig | `setVaultPC()` (requires `whenNotPaused`), role management |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | Pauser address | `pause()`, `unpause()` |
| *(none)* | — | Public | `sendUniversalTxOutbound()`, `rescueFundsOnSourceChain()` |

### External Dependencies

| Dependency | Interface | Trust Assumption | Risk if Compromised |
|---|---|---|---|
| UniversalCore | `IUniversalCore` | Returns accurate gas quotes; `swapAndBurnGas()` executes and refunds correctly | Inflated fee quotes drain excess user PC; swap failure blocks all outbound transactions |
| VaultPC | `IVaultPC` | Accepts native PC transfers (payable) | If VaultPC reverts on receive, every outbound transaction fails |
| PRC20 token | `IPRC20` | `burn()` destroys tokens correctly; `transferFrom()` respects approval | Burn failure with false return leaves tokens in UGPC with no on-chain recovery; fake burn enables double-spend |
| TSS (off-chain) | Off-chain relay | Monitors `UniversalTxOutbound` event and executes on source chain | TSS ignoring an event destroys user tokens with no corresponding origin-chain release |

### Threat Scenarios

1. **TSS event censorship / liveness failure** — A user burns PRC20 tokens and the `UniversalTxOutbound` event is emitted on-chain, but TSS never relays it to the origin chain. The user's tokens are permanently destroyed with no corresponding fund release. Mitigated by: TSS is a threshold committee; the event is on-chain and independently verifiable; off-chain monitoring and alerting. No on-chain recovery mechanism exists once tokens are burned.

2. **UniversalCore gas price manipulation** — A compromised or upgraded `UniversalCore` returns an inflated `gasFee`. The user overpays in native PC; `swapAndBurnGas()` refunds the excess but an inflated fee could effectively price out users. Mitigated by: UGPC validates `gasFee + protocolFee != 0`; users can inspect `gasPriceByChainNamespace()` before submitting.

3. **PRC20 burn returning false (non-standard token)** — If the PRC20 token's `burn()` returns `false` instead of reverting, UGPC checks the return value and reverts with `TokenBurnFailed`. However, `transferFrom()` has already moved tokens to UGPC before the burn call. Tokens are now held in UGPC with no on-chain withdrawal function for regular users. Mitigated by: the check exists and the transaction reverts, rolling back state. Residual risk: if `transferFrom` uses a non-reverting pattern and the `burn` check is missed, tokens could be permanently stranded.

4. **Malicious VaultPC blocking protocol fee delivery** — Admin updates `VAULT_PC` to a contract that reverts on native ETH receive. All `sendUniversalTxOutbound()` calls fail when attempting to forward `protocolFee`. Mitigated by: `setVaultPC()` requires `whenNotPaused`; admin compromise is the prerequisite.

5. **Empty transaction gas waste prevention** — `_fetchTxType()` reverts with `InvalidInput` when both `req.amount == 0` and `req.payload.length == 0`. Gas-only spam is impossible because gas fees are charged for all transaction types including payload-only requests.

6. **`subTxId` uniqueness and nonce exhaustion** — `subTxId` is derived from `keccak256(sender, recipient, token, amount, payloadHash, chainNamespace, nonce)` using a global, ever-incrementing nonce. Collision is computationally infeasible. The nonce is `uint256`; overflow would require more transactions than are practically possible. Residual risk: global (not per-user) nonce means TSS sees all transactions sequenced together; rapid sequential transactions from the same user could be reordered.

7. **Insufficient `msg.value` for protocol fee** — If `msg.value < protocolFee + gasFee`, the transaction reverts with `InvalidInput`. No partial state changes occur.

8. **`rescueFundsOnSourceChain` spam** — Any caller can invoke `rescueFundsOnSourceChain()` with an arbitrary `universalTxId` and `prc20` address, emitting a `RescueFundsOnSourceChain` event. This creates TSS noise but has no on-chain fund impact. The caller still pays the gas fee (native PC) for each call, making sustained spam economically costly.

9. **Upgrade storage slot collision** — Same risk as UniversalGateway: upgradeable proxy pattern requires append-only, gap-preserving storage layout discipline across implementation upgrades.

---

## 7. VaultPC

**What this contract does:** Simple fee custody vault deployed on Push Chain. Accumulates native PC and PRC20 protocol fees forwarded by `UniversalGatewayPC`. `MANAGER_ROLE` holders withdraw collected fees. Has no complex logic — primary threat surface is access control and the unrestricted `receive()` function.

### Access Control Table

| Role | Constant | Assigned To | Protected Functions |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | OZ default | Admin multisig | `grantRole()`, `revokeRole()`, role management |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | Pauser address | `pause()`, `unpause()` |
| `MANAGER_ROLE` | `keccak256("MANAGER_ROLE")` | Fee manager | `withdraw()`, `withdrawToken()` |
| *(none)* | — | Public | `receive()` — accepts any native PC from any sender |

### External Dependencies

| Dependency | Interface | Trust Assumption | Risk if Compromised |
|---|---|---|---|
| IERC20 tokens (via SafeERC20) | `SafeERC20` | `safeTransfer` executes correctly | Fee-on-transfer tokens reduce actual received amount vs expected |
| `MANAGER_ROLE` holder | EOA / multisig | Withdraws only to legitimate recipients | Compromised manager drains all accumulated fees |
| UniversalGatewayPC | Caller via `receive()` | Sends only legitimate protocol fee amounts | No sender check — any address can deposit native PC |

### Threat Scenarios

1. **MANAGER_ROLE key compromise** — A compromised manager calls `withdraw()` or `withdrawToken()` to drain all accumulated fees to an attacker-controlled address. No per-withdrawal limit or time delay exists. Mitigated by: `nonReentrant` and `whenNotPaused` on withdrawal functions. Recommendation: manager should be a multisig, not a single EOA.

2. **Unrestricted `receive()` — fee inflation** — Any EOA or contract can send arbitrary native PC to VaultPC via `receive()`. This inflates the stored balance but does not enable theft; the manager would withdraw more than expected protocol fees. This could obscure accounting or be used to trigger withdrawal limit checks if any are added in future.

3. **Reentrancy on native `withdraw()`** — `withdraw()` sends native PC via a low-level `call{value}()`. If the recipient `to` is a malicious contract with a reentrancy fallback, it could reenter `withdraw()` before the first call completes. Mitigated by: `nonReentrant` modifier on `withdraw()`.

4. **Fee-on-transfer token withdrawal discrepancy** — `withdrawToken()` validates `balanceOf(this) >= amount` then calls `safeTransfer(to, amount)`. For a fee-on-transfer token, the recipient receives `amount - fee` while the Vault's balance decreases by `amount`. The invariant check passes but the actual output is less than expected. No on-chain loss (total fee leaves the Vault) but accounting is inaccurate.

5. **Pause griefing** — `PAUSER_ROLE` pauses VaultPC, blocking all fee withdrawals. Incoming native PC via `receive()` continues to accumulate (the `receive()` function is not paused). Fees are inaccessible until the contract is unpaused. Mitigated by: `DEFAULT_ADMIN_ROLE` can reassign `PAUSER_ROLE` and then unpause.

6. **Zero amount withdrawal** — Both `withdraw()` and `withdrawToken()` revert on `amount == 0` via `Errors.InvalidAmount`. No gas-wasting no-op calls succeed.

7. **Upgrade storage slot collision** — Same upgradeable proxy risk as other contracts in the system.

---

## 8. Cross-Contract Threat Scenarios

These scenarios span multiple contracts and cannot be mitigated by any single contract in isolation.

1. **Admin compromise cascade** — A single compromised `DEFAULT_ADMIN_ROLE` key can update TSS address, Vault address, Gateway address, CEAFactory, and VaultPC within seconds. With no timelock on most admin functions, an attacker can redirect all inbound and outbound fund flows in a single block across all four contracts. Recommendation: use a multisig with a time-locked governance contract for all admin operations across all deployments.

2. **TSS compromise — full system takeover** — The TSS authority is the single most powerful actor in the system. A compromised TSS can simultaneously: drain all ERC-20 tokens from Vault via `finalizeUniversalTx()`; receive all native ETH deposits from Gateway's `_handleDeposits()`; suppress all `UniversalTxOutbound` event relays, trapping users' burned tokens. The threshold scheme distributes this risk but the aggregate TSS capability is total.

3. **Event-driven off-chain / on-chain synchronisation gap** — The entire system depends on TSS observing on-chain events and executing the corresponding on-chain action on the destination chain. A sustained network partition, TSS downtime, censored block range, or RPC failure can leave transactions in permanent limbo: ERC-20 tokens locked in Vault (inbound path) or PRC20 tokens burned on Push Chain (outbound path) with no on-chain timeout or dispute resolution mechanism. There is no on-chain timeout after which a user can self-recover.

4. **Token delist race condition** — If admin removes a token from Gateway's supported list while a user's inbound transaction is mid-flight (deposited at Gateway, not yet finalised at Vault), both the Vault's `_enforceSupported()` and Gateway's `rescueFunds()` will revert on that token, permanently trapping user funds with no on-chain recovery path. Operational procedure must guarantee no pending inbound transactions exist before any token is delisted.

5. **Upgradeable proxy initialiser attack** — If any implementation contract is deployed without immediately calling `_disableInitializers()` in its constructor (or without being initialised via the proxy), an attacker can call `initialize()` directly on the bare implementation contract and claim admin control of the implementation. This does not affect the proxy's storage but could be used to emit confusing events or to execute delegatecall attacks if the implementation's admin then upgrades the proxy. All implementation constructors must call `_disableInitializers()`.

6. **Protocol fee token / native mismatch on outbound** — `UniversalGatewayPC` forwards `protocolFee` in native PC to `VaultPC`, and `gasFee` is consumed by `UniversalCore`. If `protocolFee` is set to zero and `VaultPC` expects non-zero deposits for accounting, the fee accumulation model breaks silently. Conversely, if `gasFee` calculation underestimates the required swap input, `swapAndBurnGas()` reverts and blocks all outbound transactions until the fee is corrected.
