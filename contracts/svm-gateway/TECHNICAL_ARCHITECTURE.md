# Push Solana Gateway - Technical Architecture

## Current Deployment

**Program ID:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`  
**Network:** Solana Devnet  
**Legacy Locker:** `3zrWaMknHTRQpZSxY4BvQxw9TStSXiHcmcp3NMPTFkke`

## Overview

This document provides comprehensive technical details about all Program Derived Addresses (PDAs) and Associated Token Accounts (ATAs) used in the Push Solana Gateway program, including when and how they are created, used, and managed.

## Program Derived Addresses (PDAs)

### 1. Config PDA
- **Purpose**: Stores global gateway configuration and state
- **Seeds**: `[CONFIG_SEED]` where `CONFIG_SEED = b"config"`
- **Bump**: Stored in the Config account for deterministic derivation
- **Data Structure**: `Config` account containing:
  - `admin`: Admin public key
  - `tss_address`: TSS public key for verification
  - `pauser`: Pauser public key
  - `min_cap_universal_tx_usd`: Minimum USD cap for gas transactions (8 decimals)
  - `max_cap_universal_tx_usd`: Maximum USD cap for gas transactions (8 decimals)
  - `paused`: Boolean pause state
  - `bump`: Config PDA bump
  - `vault_bump`: Bump seed for vault PDA derivation
  - `pyth_price_feed`: Pyth price feed account for SOL/USD
  - `pyth_confidence_threshold`: Price confidence validation threshold
- **Usage**: 
  - Authority checks for admin functions
  - Pause state validation
  - USD cap enforcement
  - Vault PDA derivation

### 2. Vault PDA
- **Purpose**: Holds native SOL funds for the gateway
- **Seeds**: `[VAULT_SEED]` where `VAULT_SEED = b"vault"`
- **Bump**: Derived from `config.vault_bump`
- **Data**: No data stored (unchecked account)
- **Usage**:
  - Receives native SOL from deposits
  - Authority for SPL token vault ATAs
  - Source for SOL withdrawals
- **Authority**: Used as signer for SPL token transfers from vault ATAs

### 3. Whitelist PDA
- **Purpose**: Manages whitelisted SPL tokens
- **Seeds**: `[WHITELIST_SEED]` where `WHITELIST_SEED = b"whitelist"`
- **Bump**: Stored in the TokenWhitelist account
- **Data Structure**: `TokenWhitelist` account containing:
  - `tokens`: Vector of whitelisted token mint addresses
- **Usage**:
  - Token whitelist validation
  - Admin token management functions

### 4. TSS PDA  
- **Purpose**: Manages Threshold Signature Scheme (TSS) state for ECDSA verification
- **Seeds**: `[TSS_SEED]` where `TSS_SEED = b"tss"`
- **Bump**: Stored in the TssPda account
- **Data Structure**: `TssPda` account containing:
  - `tss_eth_address`: 20-byte Ethereum address for signature verification
  - `chain_id`: Chain ID for message domain separation
  - `nonce`: Replay protection counter
  - `authority`: Authority that can update TSS parameters
- **Usage**:
  - ECDSA secp256k1 signature verification for withdrawals
  - Nonce-based replay attack prevention  
  - Canonical message reconstruction and validation

## Associated Token Accounts (ATAs)

### 1. User Token ATA
- **Purpose**: User's token account for SPL tokens
- **Owner**: User's wallet public key
- **Mint**: SPL token mint address
- **Creation**: Created by users when they want to hold SPL tokens
- **Usage**:
  - Source for SPL token deposits (`send_funds`, `send_tx_with_funds`)
  - Destination for SPL token withdrawals (if user is recipient)

### 2. Vault Token ATA
- **Purpose**: Gateway's token account for each whitelisted SPL token
- **Owner**: Vault PDA (not user wallet)
- **Mint**: SPL token mint address
- **Creation**: 
  - **When**: Created by client applications before making SPL deposits
  - **How**: Using `spl::get_or_create_associated_token_account` with vault PDA as owner
  - **Authority**: Vault PDA (for transfers out)
  - **Note**: Program does NOT create this ATA - it must exist before calling deposit functions
- **Usage**:
  - Destination for SPL token deposits
  - Source for SPL token withdrawals
  - Authority: Vault PDA signs transfers from this account

### 3. Admin Token ATA
- **Purpose**: Admin's token account for receiving withdrawn SPL tokens
- **Owner**: Admin wallet public key
- **Mint**: SPL token mint address
- **Creation**: 
  - **When**: Created by client applications before making TSS withdrawals
  - **How**: Using `spl::get_or_create_associated_token_account` with admin as owner
  - **Note**: Program does NOT create this ATA - it must exist before calling withdrawal functions
- **Usage**:
  - Destination for admin SPL token withdrawals via TSS

## ATA Creation Rules

### When ATAs Are Created

1. **User Token ATA**:
   - Created by users externally when they want to hold SPL tokens
   - Not created by the gateway program
   - Required for users to receive SPL tokens

2. **Vault Token ATA**:
   - Created by client applications before making SPL deposits
   - NOT created by the gateway program
   - Must exist before calling `send_funds` or `send_tx_with_funds`
   - One per whitelisted SPL token
   - Created using vault PDA as owner

3. **Admin Token ATA**:
   - Created by client applications before making TSS withdrawals
   - NOT created by the gateway program
   - Must exist before calling `withdraw_spl_token_tss`
   - Created using admin wallet as owner

### When ATAs Are NOT Created

1. **Native SOL**: No ATA needed (uses regular accounts)
2. **By the program**: The gateway program never creates ATAs - they must be created by clients
3. **Non-whitelisted tokens**: ATAs not needed for unwhitelisted tokens

## Account Relationships

```
Config PDA (authority)
├── Vault PDA (SOL holder, SPL ATA authority)
│   └── Vault Token ATA (per SPL token)
├── Whitelist PDA (token management)
└── TSS PDA (withdrawal verification)

User Wallet
├── User Token ATA (per SPL token)
└── Admin Token ATA (for withdrawals)
```

## Function-Specific Account Usage

### Deposit Functions

1. **`send_tx_with_gas`**:
   - Uses: Config PDA, Vault PDA, User wallet
   - Creates: None
   - Transfers: Native SOL to vault

2. **`send_funds`** (SPL only):
   - Uses: Config PDA, Whitelist PDA, User Token ATA, Vault Token ATA
   - Creates: None (ATAs must exist)
   - Transfers: SPL tokens from user to vault

3. **`send_funds_native`**:
   - Uses: Config PDA, Vault PDA, User wallet
   - Creates: None
   - Transfers: Native SOL to vault

4. **`send_tx_with_funds`**:
   - Uses: Config PDA, Whitelist PDA, User Token ATA, Vault Token ATA, Vault PDA
   - Creates: None (ATAs must exist)
   - Transfers: SPL tokens + native SOL

### Withdrawal Functions

1. **`withdraw_tss`** (SOL):
   - Uses: Config PDA, Vault PDA, TSS PDA, Recipient wallet
   - Creates: None
   - Transfers: Native SOL from vault to recipient

2. **`withdraw_spl_token_tss`** (SPL):
   - Uses: Config PDA, Whitelist PDA, Vault PDA, Vault Token ATA, TSS PDA, Recipient Token ATA
   - Creates: None (ATAs must exist)
   - Transfers: SPL tokens from vault to recipient

### Admin Functions

1. **`initialize`**:
   - Creates: Config PDA, Vault PDA, Whitelist PDA
   - Initializes: All global state

2. **`init_tss`**:
   - Creates: TSS PDA
   - Initializes: TSS state with ETH address and chain ID

3. **`whitelist_token`**:
   - Uses: Config PDA, Whitelist PDA
   - Updates: Token whitelist

4. **`remove_token_from_whitelist`**:
   - Uses: Config PDA, Whitelist PDA
   - Updates: Token whitelist

## Security Considerations

### PDA Security
- All PDAs use deterministic seeds
- Bump seeds are stored in accounts for verification
- Authority checks prevent unauthorized access

### ATA Security
- Vault ATAs are owned by vault PDA (not user wallets)
- Only vault PDA can authorize transfers from vault ATAs
- User ATAs are owned by user wallets
- Admin ATAs are owned by admin wallet

### Authority Hierarchy
```
Admin Wallet (highest authority)
├── Config PDA (gateway authority)
├── Vault PDA (fund authority)
├── Whitelist PDA (token authority)
└── TSS PDA (withdrawal authority)
```

## Error Handling

### Common ATA Errors
- **Account not found**: ATA doesn't exist (create it)
- **Owner mismatch**: Wrong owner for ATA
- **Insufficient funds**: Not enough tokens in ATA

### Common PDA Errors
- **Seeds constraint violated**: Wrong PDA derivation
- **Authority mismatch**: Unauthorized access attempt
- **Account not initialized**: PDA account doesn't exist

## Best Practices

1. **Create ATAs before calling program functions** - the program expects them to exist
2. **Use proper authority** for each operation
3. **Validate PDA derivations** in account constraints
4. **Handle non-existent accounts** gracefully
5. **Use deterministic seeds** for all PDAs
6. **Store bump seeds** in accounts for verification
7. **Client applications must create all required ATAs** before interacting with the program

## Example Usage Patterns

### Creating Vault ATA (Client-side)
```typescript
// Create vault ATA before calling deposit functions
const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
    connection,
    userKeypair,
    tokenMint,
    vaultPda,  // vault PDA as owner
    true  // allowOwnerOffCurve
);
```

### Using Vault PDA as Authority
```rust
let seeds: &[&[u8]] = &[VAULT_SEED, &[config.vault_bump]];
let cpi_accounts = Transfer {
    from: vault_ata.to_account_info(),
    to: recipient_ata.to_account_info(),
    authority: vault_pda.to_account_info(),
};
let cpi_ctx = CpiContext::new_with_signer(token_program, cpi_accounts, &[seeds]);
```

