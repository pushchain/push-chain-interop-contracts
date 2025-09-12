# Solana Universal Gateway

Production-ready Solana program for cross-chain asset bridging to Push Chain. Mirrors Ethereum Universal Gateway functionality with complete Pyth oracle integration.

## Program Details

**Program ID:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`  
**Network:** Solana Devnet  
**Pyth Oracle:** SOL/USD feed `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE`  
**Legacy Locker:** `3zrWaMknHTRQpZSxY4BvQxw9TStSXiHcmcp3NMPTFkke` (compatible)

## Core Functions

### Deposit Functions
1. **`send_tx_with_gas`** - Native SOL gas deposits with USD caps ($1-$10)
2. **`send_funds`** - SPL token bridging (whitelisted tokens only)
3. **`send_funds_native`** - Native SOL bridging (high value, no caps)
4. **`send_tx_with_funds`** - Combined SPL tokens + gas with payload execution

### Admin & TSS Functions
- **`initialize`** - Deploy gateway with admin/pauser/caps and set Pyth feed
- **`pause/unpause`** - Emergency controls
- **`set_caps_usd`** - Update USD caps (8 decimal precision)
- **`whitelist_token/remove_token`** - Manage supported SPL tokens
- **`init_tss` / `update_tss` / `reset_nonce`** - Configure Ethereum TSS address, chain id, and nonce
- **`withdraw_tss` / `withdraw_spl_token_tss`** - TSS-verified withdrawals (ECDSA secp256k1)

## Account Structure

### PDAs
- **Config:** `[b"config"]` - Gateway state, caps, authorities
- **Vault:** `[b"vault"]` - Native SOL storage
- **Whitelist:** `[b"whitelist"]` - SPL token registry
- **Token Vaults:** Program ATAs for each whitelisted SPL token
 - **TSS:** `[b"tss"]` - TSS ETH address (20 bytes), chain id, nonce, authority

### Required Accounts
- Functions with USD caps require `priceUpdate` (Pyth price feed)
- SPL functions require user/gateway token accounts and token program
- Admin functions require `admin` or `pauser` authority; TSS functions require TSS ECDSA verification

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

### 5. TSS Configuration & Verified Withdrawals
```typescript
// init TSS
await program.methods
  .initTss(Array.from(Buffer.from("ebf0cfc34e07ed03c05615394e2292b387b63f12", "hex")), new anchor.BN(1))
  .accounts({ tssPda, authority: admin, systemProgram: SystemProgram.programId })
  .rpc();

// build message hash = keccak256(prefix|instruction_id|chain_id|nonce|amount|recipient)
// sign with ECDSA (secp256k1) using ETH private key; normalize recovery id to 0/1

await program.methods
  .withdrawTss(new anchor.BN(amount), signature, recoveryId, messageHash, new anchor.BN(nonce))
  .accounts({ config, vault, tssPda, recipient, systemProgram: SystemProgram.programId })
  .rpc();
```

## Security Features

- **Pause functionality** - Emergency stop for all user functions
- **USD caps** - Real-time Pyth oracle price validation (gas functions only)
- **Whitelist enforcement** - Only approved SPL tokens accepted
- **Authority separation** - Admin, pauser, TSS roles with distinct permissions
- **TSS verification** - Nonce check, canonical message hash, ECDSA secp256k1 recovery to ETH address
- **Balance validation** - Comprehensive user fund checks before operations
- **PDA-based vaults** - Secure custody using program-derived addresses

## Testing

Run comprehensive test suite:
```bash
cd app && ts-node gateway-test.ts
```

## Development

**Build:** `anchor build`  
**Deploy:** `anchor deploy --program-name pushsolanagateway`  
**Test:** Uses devnet SPL tokens and Pyth price feeds  
**Current Deployment:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`

For integration support, ensure your client:
1. Handles both native SOL and SPL token account contexts
2. Includes Pyth price update accounts for gas functions
3. Manages token whitelisting before bridging operations
4. Implements proper error handling for cap violations