# Testnet Upgrade Plan
---

## Overview


This is a detailed document, an authoritative step-by-step execution plan for upgrading the Push Chain
gateway systems on EVM Testnet Chains ( <chain_name>, Base, BSC and Arbitrum ) testnet. It covers:

1. Fresh Deployment of Vault
2. Upgrade the live UniversalGatewayV0 proxy (Upgrade 1 — with `moveFunds_temp`)`
3. Register Vault and CEAFactory on the upgraded gateway
4. Migrate USDT held in Gateway → Vault via `moveFunds_temp`
5. Upgrade the proxy again (Upgrade 2 — clean, no `moveFunds_temp`)
6. Etherscan verification of both implementations

---

**Note:**
- These pre-flight checklist and all other commands here are applicable before every upgrade we do on any EVM Chain.
- The RPC URL configuration should be updated based on WHICH chain we are upgrading on.
- For instance, if we are upgrading for Binance Smart Chain testnet, we must use BSC_TESTNET_RPC_URL instead of "RPC_URL".
- When executing, I will clearly specify which CHAIN ( testnet ) I want this whole instructon to be executed on, you will include all the commands for the same specified chain accordingly.

## Key Addresses (<chain_name>, <chain_ID)

| Name                     | Address                                      |
| ------------------------ | -------------------------------------------- |
| UniversalGatewayV0 Proxy | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |
| Vault Proxy (deployed ✅) | `To be depoloyed `                           |
| Vault Implementation     | `To be depoloyed `                           |
| CEAFactory               | `0xf882C49A3E3d90640bFbAAf992a04c0712A9Af5C` |
| USDT Token Address       | `0xBC14F348BC9667be46b35Edc9B68653d86013DC5` |
| Deployer (KEY)           | `0x6dD2cA20ec82E819541EB43e1925DbE46a441970` |

---

## Pre-flight Checklist

Run these before starting. All must pass.

```bash
source .env

# 1. Confirm deployer key resolves to expected address
cast wallet address --private-key $KEY
# Expected: "DEPLOYER_WALLET"

# 2. Confirm ETH balance (need gas for ~4 broadcast transactions)
cast balance "DEPLOYER_WALLET" --rpc-url $"RPC_URL" --ether

# 3. Confirm gateway proxy exists
cast code <UniversalGatewayV0_Proxy> --rpc-url $"RPC_URL" | head -c 10

# 4. Confirm vault proxy exists
cast code 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294 --rpc-url $"RPC_URL" | head -c 10

# 5. Check current USDT balance in Gateway (record this — it's what we will migrate)
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  <UniversalGatewayV0_Proxy> \
  --rpc-url $"RPC_URL"
# Note: this is the amount that must land in Vault after Phase 5

# 6. Check current USDT balance in Vault (should be 0 before migration)
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294 \
  --rpc-url $"RPC_URL"

# 7. Confirm current gateway tssAddress (must survive both upgrades unchanged)
cast call <UniversalGatewayV0_Proxy> \
  "tssAddress()(address)" \
  --rpc-url $"RPC_URL"

# 8. Build passes cleanly
forge build
```



**NOTE: Quick Instructions for accurate task tracking from Phase 3 onwards**
- add a new file in docs/ called Test_Upgrade_Logs.md
- after every phase ( phase 3 onwards ) include briefl logs in this new file to accurately provide info of:
  -  what was done in the given phase
  -  did it succeedded/failed
  -  what was the outcome?
-
---

## Phase 1 — Vault Deployment

- Vault Proxy:          ``
- Vault Implementation: ``
- Script used:          `script/vault/deployVault.s.sol`

Note: verify that Vault Deployment goes correctly. Update the addresses in docs/address/<chain_name.md> file.

**2nd Phase: **
Verify that tssAddress of freshly deployed VAULT is 0x05d7386fb3d7cb00e0cfac5af3b2eff6bf37c5f1.
---

## Phase 2 — UniversalGatewayV0 Code Preparation for Upgrade [COMPLETE ✅]

- The latest version of Contract to be used for Upgrade is in src/UniversalGatewayV0.sol
- Ensure the contract compiles with no errors.
- Addition of `moveFunds_temp`

**Context on moveFunds_temp()**
1. Current UniversalGatewayV0 on the respective chain might have some ERC20 tokens like USDT.
2. Since we will now have Vault contract on the same chain, we must first move all tokens from UniversalGateway to Vault.
3. To do this, in the first upgrade we must also add moveFunds_temp() which allows OWNER to call and move funds from Gateway to Vault that we deploy.


### Details on Upgrade:
Our upgrade will be a 3 step process:
1. Upgrade 1st: Upgrade the current Gateway first, with src/UniversalGatewayV0.sol + `moveFunds_temp` in it.
2. Initiate `moveFunds_temp` to move tokens from Gateway to Vault.
3. Upgrade 2nd: To remove `moveFunds_temp` and let everything be as is.
---

---
## Phase 3 — Upgrade 1st: Deploy Implementation with `moveFunds_temp`


**Brief overview of scripts**

### `script/gatewayV0/` scripts (all created)
| Script                            | Purpose                                                              |
| --------------------------------- | -------------------------------------------------------------------- |
| `upgradeGatewayV0_upgrade1.s.sol` | Upgrade 1: deploy new impl (with `moveFunds_temp`) and upgrade proxy |
| `setVault.s.sol`                  | Call `setVault()` + `setCEAFactory()` on upgraded gateway            |
| `moveFunds.s.sol`                 | Call `moveFunds_temp()` to migrate USDT from Gateway to Vault        |
| `upgradeGatewayV0_upgrade2.s.sol` | Upgrade 2: deploy clean impl (no `moveFunds_temp`), upgrade proxy    |


#### Detailed instructions

**Script:** `script/gatewayV0/upgradeGatewayV0_upgrade1.s.sol:UpgradeGatewayV0_1`

```bash
source .env
forge script script/gatewayV0/upgradeGatewayV0_upgrade1.s.sol:UpgradeGatewayV0_1 \
  --rpc-url $"RPC_URL" \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Reads ProxyAdmin address from EIP-1967 admin slot of the proxy
2. Verifies caller is ProxyAdmin owner
3. Records current (old) implementation address
4. Deploys new `UniversalGatewayV0` implementation (includes `moveFunds_temp`)
5. Calls `ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` — no re-initialization
6. Verifies: `tssAddress` unchanged, `VAULT` is `address(0)` (not yet set), new impl active

**Record the implementation address** from the script output — needed for Etherscan verification.

**Post-upgrade verification:**
```bash
# tssAddress must be unchanged
cast call <UniversalGatewayV0_Proxy> \
  "tssAddress()(address)" --rpc-url $"RPC_URL"

# VAULT must be address(0) — not yet registered
cast call <UniversalGatewayV0_Proxy> \
  "VAULT()(address)" --rpc-url $"RPC_URL"
# Expected: 0x0000000000000000000000000000000000000000

# Version should be 2.0.0
cast call <UniversalGatewayV0_Proxy> \
  "version()(string)" --rpc-url $"RPC_URL"
# Expected: "2.0.0"
```

---

## Phase 4 — Register Vault and CEAFactory

Note: setVault is now setVault
**Script:** `script/gatewayV0/setVault.s.sol:setVault`

```bash
forge script script/gatewayV0/setVault.s.sol:setVault\
  --rpc-url $"RPC_URL" \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Verifies Vault and CEAFactory contracts exist on-chain
2. Calls `gateway.setVault(0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294)`
   - Sets `VAULT` storage variable
   - Grants `VAULT_ROLE` to the Vault contract
3. Calls `gateway.setCEAFactory(0xE86655567d3682c0f141d0F924b9946999DC3381)`
   - Sets `ceaFactory` storage variable
4. Verifies both addresses are set and `VAULT_ROLE` is granted

**Post-registration verification:**
```bash
cast call <UniversalGatewayV0_Proxy> \
  "VAULT()(address)" --rpc-url $"RPC_URL"
# Expected: 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294

cast call <UniversalGatewayV0_Proxy> \
  "ceaFactory()(address)" --rpc-url $"RPC_URL"
# Expected: 0xE86655567d3682c0f141d0F924b9946999DC3381
```

5. Also verify that TSS of GatewayV0 is 0x05d7386fb3d7cb00e0cfac5af3b2eff6bf37c5f1.
---

## Phase 5 — Migrate USDT: Gateway → Vault

**Script:** `script/gatewayV0/moveFunds.s.sol:MoveFunds`

> **Prerequisites:** Phase 3 and Phase 4 must be complete. VAULT must be set on gateway.

```bash
forge script script/gatewayV0/moveFunds.s.sol:MoveFunds \
  --rpc-url $"RPC_URL" \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Validates gateway, vault, and USDT addresses are configured correctly
2. Checks that `VAULT` is registered on the gateway (fails fast if not)
3. Records USDT balances before (both gateway and vault)
4. Requires `gatewayBalance > 0` (fails if nothing to migrate)
5. Calls `gateway.moveFunds_temp()` — transfers all USDT from Gateway to Vault
6. Records balances after
7. Asserts: gateway balance == 0, vault balance increased by exact migrated amount

**Post-migration verification (must both pass before continuing):**
```bash
# Gateway USDT must be 0
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  <UniversalGatewayV0_Proxy> \
  --rpc-url $"RPC_URL"
# Expected: 0

# Vault USDT must equal the amount recorded in pre-flight step 5
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294 \
  --rpc-url $"RPC_URL"
# Expected: [amount from pre-flight]
```

**DO NOT proceed to Phase 6 unless both checks above pass.**

---

## Phase 6 — Remove `moveFunds_temp` from Source

This is a manual edit — no script involved.

1. Open `src/UniversalGatewayV0.sol`
2. Remove the entire `moveFunds_temp()` function (the block under `// UG_4: TEMPORARY MIGRATION`)
3. Rebuild:
   ```bash
   forge build
   # Must complete with no errors
   ```
4. Run full test suite:
   ```bash
   forge test -vv
   # Expected: all tests pass
   ```

> **Note on Etherscan verification:** If you intend to verify Impl1 on Etherscan (Phase 8),
> do it **before** this step, or save a copy of the pre-removal source file. Once
> `moveFunds_temp` is removed, you cannot regenerate the Impl1 bytecode without restoring it.

---

## Phase 7 — Upgrade 2: Deploy Clean Implementation

**Script:** `script/gatewayV0/upgradeGatewayV0_upgrade2.s.sol:UpgradeGatewayV0_2`

> **Prerequisites:** Phase 6 must be complete (`moveFunds_temp` removed from source).
> The script pre-condition check verifies gateway USDT balance == 0 before proceeding.

```bash
forge script script/gatewayV0/upgradeGatewayV0_upgrade2.s.sol:UpgradeGatewayV0_2 \
  --rpc-url $"RPC_URL" \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Validates: proxy exists, caller is ProxyAdmin owner
2. Pre-condition checks: `VAULT` is set, `ceaFactory` is set, gateway USDT balance == 0
3. Records old (Upgrade 1) implementation address
4. Deploys new clean `UniversalGatewayV0` implementation (no `moveFunds_temp`)
5. Calls `ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` — no re-initialization
6. Verifies: implementation changed, `tssAddress` intact, `VAULT` and `ceaFactory` intact

**Record the new implementation address** from the script output — needed for Etherscan verification.

**Post-upgrade verification:**
```bash
# Confirm moveFunds_temp is gone (call must revert)
cast call <UniversalGatewayV0_Proxy> \
  "moveFunds_temp()" --rpc-url $"RPC_URL"
# Expected: revert

# Confirm all critical state preserved
cast call <UniversalGatewayV0_Proxy> \
  "tssAddress()(address)" --rpc-url $"RPC_URL"

cast call <UniversalGatewayV0_Proxy> \
  "VAULT()(address)" --rpc-url $"RPC_URL"
# Expected: 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294

cast call <UniversalGatewayV0_Proxy> \
  "ceaFactory()(address)" --rpc-url $"RPC_URL"
# Expected: 0xE86655567d3682c0f141d0F924b9946999DC3381
```

---

## Phase 8 — Etherscan Verification

Verify both implementation contracts so the proxy shows verified source on Etherscan.
Substitute `<IMPL1_ADDR>` and `<IMPL2_ADDR>` from the script outputs in Phases 3 and 7.

### Implementation 1 (with `moveFunds_temp`)

> Verify this using the source **before** removing `moveFunds_temp` (Phase 6).

```bash
forge verify-contract --chain <chain_name> \
  --constructor-args $(cast abi-encode "constructor()") \
  <IMPL1_ADDR> \
  src/UniversalGatewayV0.sol:UniversalGatewayV0 \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Implementation 2 (clean, no `moveFunds_temp`)

> Verify this using the source **after** removing `moveFunds_temp` (Phase 6).

```bash
forge verify-contract --chain <chain_name> \
  --constructor-args $(cast abi-encode "constructor()") \
  <IMPL2_ADDR> \
  src/UniversalGatewayV0.sol:UniversalGatewayV0 \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

---

## Full Execution Sequence (Summary)

```
Phase 1    Vault deployed
Phase 2    Code changes implemented, scripts created,
Phase 3  Run upgradeGatewayV0_upgrade1.s.sol  -->  record IMPL1_ADDR
Phase 4  Run setVault.s.sol and setCEAFactory -->  sets VAULT + ceaFactory
Phase 5  Run moveFunds.s.sol                  -->  USDT migrated to Vault
         Verify: gateway USDT == 0, vault USDT == migrated amount
Phase 6  Manual: remove moveFunds_temp() from source, forge build, forge test
Phase 7  Run upgradeGatewayV0_upgrade2.s.sol  -->  record IMPL2_ADDR

```

---

## Invariants That Must Hold Throughout

| Invariant                                  | Verification Command                                                                     |
| ------------------------------------------ | ---------------------------------------------------------------------------------------- |
| tssAddress unchanged across both upgrades | `cast call <proxy> "tssAddress()(address)"`                                             |
| minCapUniversalTxUsd preserved         | `cast call <proxy> "minCapUniversalTxUsd()(uint256)"`                                |
| maxCapUniversalTxUsd preserved         | `cast call <proxy> "maxCapUniversalTxUsd()(uint256)"`                                |
| blockUsdCap preserved                    | `cast call <proxy> "blockUsdCap()(uint256)"`                                           |
| epochDurationSec preserved                 | `cast call <proxy> "epochDurationSec()(uint256)"`                                        |
| VAULT_ROLE granted to Vault                | `cast call <proxy> "hasRole(bytes32,address)(bool)" $(cast keccak "VAULT_ROLE") <VAULT>` |
| Gateway USDT balance == 0 after Phase 5    | `cast call <USDT> "balanceOf(address)(uint256)" <GATEWAY>`                               |
| Vault USDT balance == migrated amount      | `cast call <USDT> "balanceOf(address)(uint256)" <VAULT>`                                 |
| moveFunds_temp() reverts after Phase 7     | `cast call <proxy> "moveFunds_temp()"` — must revert                                     |

---
