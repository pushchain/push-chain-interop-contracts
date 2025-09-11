# Solana Universal Gateway

Production-ready Solana program for cross-chain asset bridging to Push Chain. Mirrors Ethereum Universal Gateway functionality with complete Pyth oracle integration.

## Program Details

**Program ID:** `9nokRuXvtKyT32vvEQ1gkM3o8HzNooStpCuKuYD8BoX5`  
**Network:** Solana Devnet  
**Pyth Oracle:** SOL/USD feed `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE`

## Core Functions

### Deposit Functions
1. **`send_tx_with_gas`** - Native SOL gas deposits with USD caps ($1-$10)
2. **`send_funds`** - SPL token bridging (whitelisted tokens only)
3. **`send_funds_native`** - Native SOL bridging (high value, no caps)
4. **`send_tx_with_funds`** - Combined SPL tokens + gas with payload execution

### Admin Functions
- **`initialize`** - Deploy gateway with admin, TSS, caps configuration
- **`pause/unpause`** - Emergency controls
- **`set_caps_usd`** - Update USD caps (8 decimal precision)
- **`whitelist_token/remove_token`** - Manage supported SPL tokens
- **`withdraw_funds/withdraw_spl_token`** - TSS-only fund extraction

## Account Structure

### PDAs
- **Config:** `[b"config"]` - Gateway state, caps, authorities
- **Vault:** `[b"vault"]` - Native SOL storage
- **Whitelist:** `[b"whitelist"]` - SPL token registry
- **Token Vaults:** Program ATAs for each whitelisted SPL token

### Required Accounts
- Functions with USD caps require `priceUpdate` (Pyth price feed)
- SPL functions require user/gateway token accounts and token program
- Admin functions require `admin` or `tss` authority

## Events
- **`TxWithGas`** - Gas deposits (maps to Ethereum event)
- **`TxWithFunds`** - Token/native bridging (maps to Ethereum event)
- **`WithdrawFunds`** - TSS withdrawals
- **`CapsUpdated`** - Admin cap changes

## Integration Guide

### 1. Initialize Gateway
```typescript
await program.methods
  .initialize(adminPubkey, pauserPubkey, tssPubkey, minCapUsd, maxCapUsd, pythFeedId)
  .accounts({ config: configPda, vault: vaultPda, admin: adminPubkey })
  .rpc();
```

### 2. Whitelist SPL Token
```typescript
await program.methods
  .whitelistToken(tokenMint)
  .accounts({ whitelist: whitelistPda, admin: adminPubkey })
  .rpc();
```

### 3. Gas Deposit (with USD caps)
```typescript
await program.methods
  .sendTxWithGas(payload, revertSettings, amount)
  .accounts({
    config: configPda, vault: vaultPda, user: userPubkey,
    priceUpdate: pythPriceAccount, systemProgram: SystemProgram.programId
  })
  .rpc();
```

### 4. SPL Token Bridge
```typescript
await program.methods
  .sendFunds(recipient, tokenMint, amount, revertSettings)
  .accounts({
    config: configPda, vault: vaultPda, user: userPubkey,
    tokenWhitelist: whitelistPda, userTokenAccount, gatewayTokenAccount,
    bridgeToken: tokenMint, tokenProgram: TOKEN_PROGRAM_ID
  })
  .rpc();
```

## Security Features

- **Pause functionality** - Emergency stop for all user functions
- **USD caps** - Real-time Pyth oracle price validation (gas functions only)
- **Whitelist enforcement** - Only approved SPL tokens accepted
- **Authority separation** - Admin, pauser, TSS roles with distinct permissions
- **Balance validation** - Comprehensive user fund checks before operations
- **PDA-based vaults** - Secure custody using program-derived addresses

## Testing

Run comprehensive test suite:
```bash
cd app && ts-node gateway-test.ts
```

## Development

**Build:** `anchor build`  
**Deploy:** `solana program deploy --program-id <PROGRAM_ID> target/deploy/pushsolanagateway.so`  
**Test:** Uses devnet SPL tokens and Pyth price feeds

For integration support, ensure your client:
1. Handles both native SOL and SPL token account contexts
2. Includes Pyth price update accounts for gas functions
3. Manages token whitelisting before bridging operations
4. Implements proper error handling for cap violations