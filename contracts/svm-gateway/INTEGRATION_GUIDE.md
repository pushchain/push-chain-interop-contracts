# Universal Gateway Backend Integration Guide

Technical guide for backend teams to implement the Universal Validator (UV) service that processes Push Chain events and executes transactions on Solana.

## 1. Execution Flow

### 1.1 High-Level Flow

```
User (EVM) → Push Chain → Event Emission → Backend Service → TSS Signing → Solana Execution
```

**Step-by-step:**
1. User calls `UniversalGatewayPC.sendUniversalTxOutbound()` on Push Chain
2. Push Chain burns tokens, emits `UniversalTxOutbound` event
3. Backend service watches events, extracts event data
4. Backend decodes payload (`instructionId`, `targetProgram`, `accounts`, `ixData`) and validates mode-specific rules
5. Backend builds mode-specific TSS message hash (format varies by instructionId), signs with ECDSA secp256k1
6. Backend constructs the appropriate Solana outbound instruction:
   - `finalize_universal_tx` for `instructionId` 1 (withdraw) or 2 (execute)
   - `revert_universal_tx` for `instructionId` 3
   - `rescue_funds` for `instructionId` 4
7. Backend submits transaction to Solana network
8. Gateway program verifies signature, then routes based on instructionId:
   - **Withdraw (1)**: `finalize_universal_tx` — vault→CEA→recipient (direct transfer)
   - **Execute (2)**: `finalize_universal_tx` — vault→CEA→CPI to target program (or CEA self-withdraw if target == gateway)
   - **Revert (3)**: `revert_universal_tx` — vault→recipient (unified SOL/SPL)
   - **Rescue (4)**: `rescue_funds` — vault→recipient (TSS-authorized emergency, separate function)
9. Events emitted:
   - Normal withdraw/execute: `UniversalTxFinalized`
   - CEA self-withdraw (execute with target == gateway): `UniversalTx` with `from_cea: true` **and** `UniversalTxFinalized`
   - Revert: `RevertUniversalTx`
   - Rescue: `FundsRescued`

### 1.2 Event Structure (Push Chain)

**Event**: `UniversalTxOutbound`
```solidity
event UniversalTxOutbound(
    address indexed push_account,        // EVM address (20 bytes)
    string chainId,                // Source chain ID
    address token,                 // PRC20 token address
    bytes target,                  // Target program/contract address (32 bytes for Solana)
    uint256 amount,                // Amount to withdraw
    address gasToken,              // Gas token address
    uint256 gasFee,                // Gas fee
    uint256 gasLimit,              // Gas limit (for EVM; not used on Solana)
    bytes payload,                 // Encoded payload (see section 2)
    uint256 inboundFee,            // Inbound fee
    address revertRecipient,       // Revert recipient address
    TX_TYPE txType                 // Transaction type
);
```

**Fields you need:**
- `push_account` → Convert to 20-byte array for `push_account` parameter
- `target` → 32-byte Solana program pubkey
- `amount` → u64 amount (reject if > u64::MAX, events are uint256)
- `gasFee` → u64 gas fee (reject if > u64::MAX, events are uint256)
- `revertRecipient` → For revert operations

**Missing fields (you must provide):**
- `universal_tx_id`: 32 bytes from source chain (EVM transaction hash)
- `sub_tx_id`: 32 bytes - **MUST be deterministic and stable across retries** (no random generation)
  - **Recommended**: Use source transaction hash or hash of event fields (e.g., `keccak256(event_tx_hash || log_index)`)
  - **Critical**: Same `sub_tx_id` must be used for all retry attempts of the same transaction

### 1.3 Unified Entrypoint Architecture

**Key Concept**: The gateway uses a **single unified function** `finalize_universal_tx` for both withdraw and execute operations.

**How it works**:
1. **instruction_id parameter** determines the operation mode:
   - `1` = Withdraw mode (vault→CEA→recipient, direct transfer)
   - `2` = Execute mode (vault→CEA→CPI to target program)

2. **No target parameter**: Target source is mode-specific:
   - Withdraw (1): Target derived from `recipient` account key
   - Execute (2): Canonical target comes from decoded payload `targetProgram`
     - **IMPORTANT**: `destination_program` account must match decoded `targetProgram`
     - The decoded payload is the canonical source of truth for execute destination
     - On-chain Rust validation remains unchanged (uses `destination_program` account for execution)

3. **Mode-specific account enforcement**:
   - `destination_program` is ALWAYS required (non-optional account)
     - Withdraw mode: Pass `SystemProgram.programId` (used as sentinel, target comes from recipient)
     - Execute mode: Pass target program pubkey (must match decoded payload's `targetProgram`, must be executable)
   - `recipient` is optional:
     - Withdraw mode: Must be provided (contains recipient pubkey)
     - Execute mode: Must be None/null

4. **Mode-specific validation**:

   | Rule | Withdraw (1) | Execute (2) |
   |------|-------------|-------------|
   | `recipient` | required | must be None |
   | `destination_program` | `SystemProgram.programId` (sentinel) | required, must be executable, must match decoded payload `targetProgram` |
   | `remaining_accounts` | must be empty | decoded accounts from payload |
   | `writable_flags` | must be empty | `ceil(accounts_count / 8)` bytes, MSB-first |
   | `ix_data` | must be empty | CPI instruction data from payload |
   | `amount` | must be > 0 | any (can be 0) |

5. **TSS message format**: Hash construction differs by instruction_id (see section 3.2)

**Benefits**:
- Reduces program size and complexity
- Shared validation logic
- Single transaction pattern for backend
- Easier maintenance and upgrades

---

## 2. Payload Encoding/Decoding

### 2.1 Payload Format (Solana Execute)

The `payload` field in Push Chain event contains encoded Solana execution data:

```
[accounts_count: 4 bytes (u32 big-endian)]
[account[0].pubkey: 32 bytes]
[account[0].is_writable: 1 byte (0 or 1)]
[account[1].pubkey: 32 bytes]
[account[1].is_writable: 1 byte]
... (repeat for all accounts)
[ix_data_length: 4 bytes (u32 big-endian)]
[ix_data: N bytes]
[instruction_id: 1 byte (u8)]
[target_program: 32 bytes] ← REQUIRED - canonical destination (source of truth)
```

**Total size**: `4 + (33 * accounts_count) + 4 + ix_data_length + 1 + 32`

**Instruction ID values**:
- `1` = Withdraw (SOL or SPL; vault→CEA→recipient)
- `2` = Execute (SOL or SPL; vault→CEA→CPI to target program)

**Target Program Field**:
- **REQUIRED** for all execute payloads
- Establishes the canonical destination for execution
- Must match the `destination_program` account passed to finalize_universal_tx
- TSS signature includes this value, preventing tampering

### 2.2 Decoding Payload

**Input**: `payload` bytes from event

**Output**:
- `accounts`: Array of `{ pubkey: 32 bytes, isWritable: bool }`
- `ixData`: Raw instruction data bytes
- `instructionId`: u8 (1 = withdraw, 2 = execute)
- `targetProgram`: 32-byte pubkey (canonical execute destination)

**Algorithm**:
1. Read first 4 bytes → `accounts_count` (u32 BE)
2. For each account (0 to accounts_count-1):
   - Read 32 bytes → `pubkey`
   - Read 1 byte → `is_writable` (0 = false, 1 = true)
3. Read next 4 bytes → `ix_data_length` (u32 BE)
4. Read `ix_data_length` bytes → `ix_data`
5. Read next 1 byte → `instruction_id` (u8)
6. Read next 32 bytes → `target_program` (canonical destination pubkey) - REQUIRED
   - **IMPORTANT**: This is the source of truth for the destination program
   - The `destination_program` account must match this value
   - Payload decoding will fail if this field is missing
7. Validate: total bytes consumed == payload length

### 2.3 Encoding Payload (For Testing/Validation)


**Algorithm**:
1. Write `accounts.length` as u32 BE (4 bytes)
2. For each account: write `pubkey` (32 bytes) + `is_writable` (1 byte)
3. Write `ixData.length` as u32 BE (4 bytes)
4. Write `ixData` bytes
5. Write `instructionId` as u8 (1 byte)
6. Write `targetProgram` as 32 bytes (canonical destination pubkey) - REQUIRED
   - **IMPORTANT**: This establishes the canonical destination for the execution
   - The TSS signature must include this same targetProgram value
   - On-chain validation will verify destination_program account matches this value
   - Encoding will fail if targetProgram is not provided

**Reference**: `contracts/svm-gateway/app/execute-payload.ts`

---

## 3. TSS Message Signing

### 3.1 Wire Format Specification

**CRITICAL**: All numeric fields use **big-endian (BE)** byte order. Any mismatch = `MessageHashMismatch`.

#### 3.1.1 Endianness and Width Table

| Field | Type | Width | Endianness | Notes |
|-------|------|-------|------------|-------|
| `accounts_count` | u32 | 4 bytes | BE | In payload and accounts_buf |
| `ix_data_length` | u32 | 4 bytes | BE | In payload and ix_data_buf |
| `amount` | u64 | 8 bytes | BE | From event (reject if > u64::MAX) |
| `gas_fee` | u64 | 8 bytes | BE | From event (reject if > u64::MAX) |


#### 3.1.2 Chain ID Encoding (CRITICAL)

**Format**: UTF-8 bytes of the `chain_id` string stored in TSS PDA account, **NO length prefix**, **NO trimming**.

**Steps**:
1. Read `tss_pda.chain_id` from on-chain TSS PDA account (it's a Rust `String`)
   - **Note**: This should match the event's `chainId` field (source chain identifier)
2. Convert to UTF-8 bytes: `chain_id_bytes = chain_id.encode('utf-8')` (Python) or `Buffer.from(chain_id, 'utf8')` (Node.js)
3. Concatenate directly into message hash buffer (no length prefix, no padding)

**Example**:
- On-chain value: `"EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"` (44 bytes UTF-8)
- Message hash includes: exactly these 44 bytes, nothing more, nothing less

**Reference Implementation**:
- Rust: `tss.chain_id.as_bytes()` (line 125 in `tss.rs`)
- TypeScript: `Buffer.from(chainId, 'utf8')` (line 59 in `tss.ts`)

**Common mistakes**:
- ❌ Adding length prefix (4 bytes u32)
- ❌ Trimming whitespace
- ❌ Converting to base58/base64
- ❌ Using different encoding (ASCII, Latin-1, etc.)

### 3.2 Message Hash Construction

**Prefix**: `"PUSH_CHAIN_SVM"` (14 bytes, UTF-8)

**Base fields** (always present, in this exact order):
1. `instruction_id`: 1 byte (unsigned integer)
   - `1` = Withdraw (SOL or SPL; unified, vault→CEA→recipient)
   - `2` = Execute (SOL or SPL; unified, vault→CEA→CPI)
   - `3` = Revert (SOL or SPL; unified)
   - `4` = Rescue (SOL or SPL; TSS-verified emergency release, replay-protected with `sub_tx_id`)
2. `chain_id`: UTF-8 bytes (see 3.1.2 above) - **NO length prefix**
3. `amount`: u64 BE (8 bytes) - present for all instructions

**Additional fields** (order-critical, depends on instruction):

**IMPORTANT**: Common fields come first in the same order for both modes, followed by mode-specific fields.

**Common Fields (same for Execute and Withdraw):**
```
sub_tx_id (32 bytes)           // First parameter in function signature
universal_tx_id (32 bytes) // Second parameter in function signature
push_account (20 bytes, EVM address)
token (32 bytes)           // Pubkey::default() for SOL, mint pubkey for SPL
gas_fee (u64 BE)
```

**For Execute (2, unified SOL+SPL):**
```
[common fields above]
target_program (32 bytes, pubkey)  // Execute-specific: target program for CPI
accounts_buf (see 3.3)             // Execute-specific: accounts for CPI
ix_data_buf (see 3.3)              // Execute-specific: instruction data
```

**For Withdraw (1, unified SOL+SPL):**
```
[common fields above]
target (32 bytes, recipient pubkey) // Withdraw-specific: recipient address
```
- **SOL**: `token` = `Pubkey::default()` (32 zero bytes), `target` = SOL recipient pubkey
- **SPL**: `token` = mint pubkey, `target` = recipient owner pubkey (recipient ATA derived on-chain)

**Rationale**: This ordering ensures consistency across modes and matches the function parameter order, making it easier to maintain and less error-prone.

**For Revert SOL (3):**
```
sub_tx_id (32 bytes)
universal_tx_id (32 bytes)
recipient_pubkey (32 bytes)
gas_fee (u64 BE)
```

**For Revert SPL (3):**
```
sub_tx_id (32 bytes)
universal_tx_id (32 bytes)
mint_pubkey (32 bytes)
recipient_pubkey (32 bytes)
gas_fee (u64 BE)
```

**For Rescue SOL (4):**
```
sub_tx_id (32 bytes)
universal_tx_id (32 bytes)
recipient_pubkey (32 bytes)
gas_fee (u64 BE)
```

**For Rescue SPL (4, with mint):**
```
sub_tx_id (32 bytes)
universal_tx_id (32 bytes)
mint_pubkey (32 bytes)
recipient_pubkey (32 bytes)
gas_fee (u64 BE)
```

**IMPORTANT**: All fields listed above (including `sub_tx_id`, `universal_tx_id`, `push_account`) **must** be included in the `additional` array when calling `signTssMessage()`. The helper function does **not** auto-inject these fields.

### 3.3 Accounts and Instruction Data Buffers (Execute Only)

**accounts_buf format:**
```
[accounts_count: 4 bytes (u32 BE)]
[account[0].pubkey: 32 bytes]
[account[0].is_writable: 1 byte (0 = false, 1 = true)]
[account[1].pubkey: 32 bytes]
[account[1].is_writable: 1 byte]
... (repeat for all accounts)
```

**ix_data_buf format:**
```
[ix_data_length: 4 bytes (u32 BE)]
[ix_data: N bytes (raw instruction data)]
```

**CRITICAL**: The accounts in `accounts_buf` MUST exactly match:
- The `writable_flags` parameter (bitpacked, 1 bit per account, MSB first)
- The `remaining_accounts` passed to Solana transaction
- Same order, same pubkeys, writable flags match bit positions

### 3.4 Writable Flags Bitpacking (Execute Only)

**Purpose**: Compress boolean writable flags into minimal bytes for transaction size optimization.

**Format**:
- **Size**: `ceil(accounts_count / 8)` bytes
- **Bit order**: MSB-first (most significant bit first)
- **Bit mapping**: Account `i` → bit `(7 - (i % 8))` of byte `floor(i / 8)`

**Algorithm**:
```python
# Python example
def accounts_to_writable_flags(accounts):
    flags_len = (len(accounts) + 7) // 8  # Ceiling division
    flags = bytearray(flags_len)
    for i, account in enumerate(accounts):
        byte_idx = i // 8
        bit_idx = 7 - (i % 8)  # MSB first
        if account.is_writable:
            flags[byte_idx] |= (1 << bit_idx)
    return bytes(flags)
```

**Decoding** (on-chain, for reference):
```rust
// Rust (from execute.rs line 420-424)
let byte_idx = i / 8;
let bit_idx = 7 - (i % 8); // MSB first
let is_writable = (writable_flags[byte_idx] >> bit_idx) & 1 == 1;
```

**Example**: 10 accounts with writable flags `[1, 0, 1, 0, 1, 1, 0, 0, 1, 0]`

```
Account index:  0  1  2  3  4  5  6  7  8  9
Writable:       1  0  1  0  1  1  0  0  1  0

Byte 0 (bits 7-0): accounts 0-7
  Bit 7 (account 0): 1 → 0b10000000
  Bit 6 (account 1): 0 → 0b00000000
  Bit 5 (account 2): 1 → 0b00100000
  Bit 4 (account 3): 0 → 0b00000000
  Bit 3 (account 4): 1 → 0b00001000
  Bit 2 (account 5): 1 → 0b00000100
  Bit 1 (account 6): 0 → 0b00000000
  Bit 0 (account 7): 0 → 0b00000000
  Result: 0b10101100 = 0xAC

Byte 1 (bits 7-0): accounts 8-9
  Bit 7 (account 8): 1 → 0b10000000
  Bit 6 (account 9): 0 → 0b00000000
  Bits 5-0: unused (0)
  Result: 0b10000000 = 0x80

Final: [0xAC, 0x80] (2 bytes)
```

**Verification**:
- Account 0: byte 0, bit 7 → `(0xAC >> 7) & 1 = 1` ✓
- Account 2: byte 0, bit 5 → `(0xAC >> 5) & 1 = 1` ✓
- Account 4: byte 0, bit 3 → `(0xAC >> 3) & 1 = 1` ✓
- Account 8: byte 1, bit 7 → `(0x80 >> 7) & 1 = 1` ✓

**Reference Implementation**:
- TypeScript: `accountsToWritableFlags()` in `contracts/svm-gateway/app/execute-payload.ts`
- Rust: Lines 420-424 in `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`

### 3.5 Signing Algorithm

1. Concatenate all segments in order: `PREFIX + instruction_id + chain_id + amount + additional_fields`
2. Compute Keccak-256 hash of concatenated bytes → `message_hash`
3. Sign `message_hash` with secp256k1 ECDSA (using TSS private key)
4. Extract:
   - `signature`: 64 bytes (r || s)
   - `recovery_id`: 0 or 1 (for public key recovery)

**Libraries**:
- Keccak-256: `js-sha3` or equivalent
- secp256k1: `@noble/secp256k1` or equivalent

**Reference Implementation**:
- File: `contracts/svm-gateway/tests/helpers/tss.ts`
- Functions: `signTssMessage()`, `buildExecuteAdditionalData()`, `buildWithdrawAdditionalData()`
- Test usage: `contracts/svm-gateway/tests/execute.test.ts` and `tests/withdraw.test.ts` (search for `signTssMessage`)
- **Note**: Use the `buildWithdrawAdditionalData()` or `buildExecuteAdditionalData()` helpers to construct the `additional` array with correct ordering (common fields first)

### 3.6 Getting TSS Chain ID

**Fetch from on-chain TSS PDA**:
- PDA seeds: `["final_tss_pda"]`
- Account contains: `{ tss_eth_address, chain_id, bump }`
- Read `chain_id` (Rust `String`)
- **CRITICAL**: Use `chain_id` exactly as stored (UTF-8 bytes, no modification)
  - This should match the event's `chainId` field (source chain identifier)

**Reference**: See `TssPda` struct in `contracts/svm-gateway/programs/universal-gateway/src/state.rs`

---

## 4. Solana Program Functions

### 4.1 Unified Withdraw & Execute Function

**Function**: `finalize_universal_tx`

This single entrypoint handles both withdraw (instruction_id=1) and execute (instruction_id=2) operations.

**Parameters**:
- `instruction_id`: u8 (`1` for withdraw, `2` for execute)
- `sub_tx_id`: [u8; 32] - deterministic transaction identifier
- `universal_tx_id`: [u8; 32] - source chain transaction hash
- `amount`: u64 - amount to transfer
- `push_account`: [u8; 20] - EVM address (Push Chain user)
- `writable_flags`: Vec<u8> - bitpacked writable flags (empty for withdraw, see 3.4 for execute)
- `ix_data`: Vec<u8> - CPI instruction data (empty for withdraw, from decoded payload for execute)
- `gas_fee`: u64 - total gas fee (includes UV reimbursement)
- `signature`: [u8; 64] - TSS signature
- `recovery_id`: u8 - signature recovery ID (0 or 1)
- `message_hash`: [u8; 32] - keccak256 hash of TSS message

**IMPORTANT - No `target` parameter**:
- **Withdraw (instruction_id=1)**: Target is derived from `recipient` account key
- **Execute (instruction_id=2)**: Canonical target comes from decoded payload `targetProgram`; `destination_program` must match it

**Required Accounts** (all cases):
- `caller`: UV keypair (signer, payer)
- `config`: PDA `["config"]`
- `vault_sol`: PDA `["vault"]` (uses config.vault_bump)
- `cea_authority`: PDA `["push_identity", push_account]`
- `tss_pda`: PDA `["final_tss_pda"]`
- `executed_sub_tx`: PDA `["executed_sub_tx", sub_tx_id]` (will be created)
- `system_program`: System program

**Mode-Specific Accounts**:
- `destination_program`: UncheckedAccount (ALWAYS REQUIRED, non-optional)
  - **Withdraw mode**: Pass `SystemProgram.programId` (sentinel value, actual target from recipient)
  - **Execute mode**: Pass decoded payload `targetProgram` (must be executable and match payload)
- `recipient`: Option<UncheckedAccount> - Mode-dependent (optional account)
  - **Withdraw mode**: Must be provided (mut)
  - **Execute mode**: Must be None

**SPL Optional Accounts** (all-or-none based on `mint` presence):
- `vault_ata`: Vault ATA for the mint (validated: owner == vault_sol, mint == mint)
- `cea_ata`: CEA ATA for the mint (created if missing; UV pays rent)
- `mint`: Token mint pubkey
- `token_program`: SPL Token program
- `rent`: Rent sysvar
- `associated_token_program`: Associated Token program
- `recipient_ata`: **Withdraw only** - Recipient ATA (must exist; derived from recipient + mint)

**New optional accounts** (added for ref-finalize route; pass `null` on all direct finalize calls):
- `stored_ix_data`: Option — `null` for direct route; `StoredIxData` PDA for ref route
- `store_refund_recipient`: Option — `null` for direct route; the account that called `store_execute_ix_data`

**Anchor client note**:
- For execute mode: pass `recipient: null`, `destinationProgram: targetProgramPubkey`
- For withdraw mode: pass `recipient: recipientPubkey`, `destinationProgram: SystemProgram.programId`
- `destination_program` is NEVER null/omitted (always required, use SystemProgram as sentinel for withdraw)
- Always pass `storedIxData: null, storeRefundRecipient: null` for direct finalize calls

**Remaining Accounts** (execute only):
- Pass decoded `accounts` from payload as `remaining_accounts`
- Each account: `{ pubkey, isWritable, isSigner: false }`
- Order must match the order in the decoded payload
- `writable_flags` is bitpacked: bit i corresponds to `remaining_accounts[i]`
- **Withdraw mode**: remaining_accounts must be empty

**Mode Enforcement Rules**:

| Rule | Withdraw (1) | Execute (2) |
|------|-------------|-------------|
| `recipient` | required | must be None |
| `destination_program` | SystemProgram.programId | required + executable |
| `remaining_accounts` | must be empty | required for CPI |
| `writable_flags` | must be empty | length = ceil(accounts/8) |
| `ix_data` | must be empty | CPI data |
| `amount` | must be > 0 | any (can be 0) |
| `recipient_ata` | SPL only | must be None |

**Reference**: See `FinalizeUniversalTx` struct in `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`

**CEA ATA Derivation**:
- Use standard ATA derivation: `[authority (CEA), token_program_id, mint]`
- Check if exists before transaction; if not, program will create it (UV pays rent)

### 4.2 Example: Execute Mode (instruction_id=2)

**Use case**: Execute a CPI to a target program with transferred funds

**Key requirements**:
- `instruction_id = 2`
- `destination_program`: Decoded payload `targetProgram` (must be executable and match payload)
- `recipient`: Must be None
- `remaining_accounts`: Decoded accounts from payload
- `writable_flags`: Bitpacked flags matching accounts
- `ix_data`: Instruction data from payload
- For SPL: include all SPL accounts (vault_ata, cea_ata, mint, etc.)

**Flow**: vault→CEA→CPI to destination_program

### 4.3 Example: Withdraw Mode (instruction_id=1)

**Use case**: Direct transfer to recipient without CPI

**Key requirements**:
- `instruction_id = 1`
- `recipient`: Must be provided (recipient pubkey)
- `destination_program`: SystemProgram.programId (sentinel value)
- `remaining_accounts`: Must be empty
- `writable_flags`: Must be empty
- `ix_data`: Must be empty
- `amount`: Must be > 0
- For SPL: include all SPL accounts including `recipient_ata`

**Flow**: vault→CEA→recipient (direct transfer)

### 4.4 Ref-Finalize Route (Large Execute Payloads)

When the serialized `finalize_universal_tx` transaction exceeds 1232 bytes (Solana legacy tx limit), use the two-step ref route instead. The store instruction can carry `ix_data` up to ~921 bytes; if `ix_data` itself exceeds that, versioned transactions with ALT are required.

**Step 1 — `store_execute_ix_data`**

```
Args: sub_tx_id [u8;32], ix_data_hash [u8;32] = keccak256(ix_data), ix_data Vec<u8>
Accounts: caller (mut signer), stored_ix_data (init PDA), system_program
```

Permissionless. PDA seeds: `["stored_ix_data", sub_tx_id, keccak256(ix_data)]`. `caller` becomes the `store_refund_recipient`.

**Step 2 — `finalize_universal_tx_with_ix_data_ref`**

Same args and accounts as `finalize_universal_tx` except:
- Pass `ix_data_hash [u8;32]` instead of raw `ix_data`
- Populate `stored_ix_data` and `store_refund_recipient` (not null)

TSS message format is identical — TSS signs over the raw `ix_data` bytes, not the hash.

**Step 3 — `close_stored_ix_data` (failure / abort path only)**

On the happy path, `finalize_universal_tx_with_ix_data_ref` auto-closes the `StoredIxData` PDA and returns rent to `store_refund_recipient` in the same transaction — no separate close needed.

`close_stored_ix_data` is only needed when finalize did not succeed:
- Finalize was submitted but failed (reverted) — PDA is still open.
- UV decides finalize will never be submitted (abort) — recover rent immediately.

In both cases only `store_refund_recipient` can close, since `ExecutedSubTx` does not exist yet.

```
Args: none
Accounts: caller (mut signer), stored_ix_data, store_refund_recipient (receives rent), executed_sub_tx (optional)
```

See [6-TX-SIZE-REF-ROUTE.md](./docs/6-TX-SIZE-REF-ROUTE.md) for full details.

---

### 4.5 Example: CEA Self-Withdraw (Execute to Gateway)

**Use case**: Execute path where `destination_program == gateway_program_id` routes to CEA→UEA withdrawal instead of normal CPI.

**Key requirements**:
- `instruction_id = 2`
- `destination_program`: gateway program ID
- `ix_data`: `send_universal_tx_to_uea` discriminator + Borsh args (`token`, `amount`, `payload`, `revert_recipient`)
- `amount`/`payload` combinations:
  - `amount > 0, payload empty` → `Funds`
  - `amount > 0, payload non-empty` → `FundsAndPayload`
  - `amount = 0, payload non-empty` → `GasAndPayload`
  - `amount = 0, payload empty` → rejected (`InvalidInput`)
- `revert_recipient` in args must be non-zero (`Pubkey::default()` is rejected)
- When `amount = 0`, no CEA→vault transfer and no rate-limit consumption happen on this inner route
- Emits `UniversalTx` with `from_cea: true` and `UniversalTxFinalized`
- Semantic split:
  - `UniversalTx.amount` / `UniversalTx.payload` come from inner decoded args
  - `UniversalTxFinalized.amount` / `UniversalTxFinalized.gasFee` / `UniversalTxFinalized.payload` come from outer finalize args (`amount`, `gas_fee`, full `ix_data`)

### 4.5 Revert Universal Transaction (Unified SOL/SPL)

**Function**: `revert_universal_tx`

**Parameters**:
- `sub_tx_id`: [u8; 32]
- `universal_tx_id`: [u8; 32]
- `amount`: u64
- `revert_instruction`: Struct `{ revert_recipient: Pubkey, revert_msg: Vec<u8> }`
- `gas_fee`: u64
- `signature`: [u8; 64]
- `recovery_id`: u8
- `message_hash`: [u8; 32]

**revert_instruction**:
- `revert_recipient`: Pubkey (32 bytes) - where to send reverted funds
- `revert_msg`: Vec<u8> - revert message (can be empty)

### 4.6 Revert Universal Transaction (SPL Token via unified function)

**Function**: `revert_universal_tx`

**Additional Required Accounts**: Same as SPL withdraw (token_vault, recipient_token_account, token_mint, token_program).  
For SOL path, pass these accounts as `null`.

---

## 5. PDA Derivation

All PDAs use `findProgramAddressSync` with gateway program ID.

**Gateway Program ID**: Deployed program address (check deployment)

**PDAs**:
- `config`: `["config"]`
- `vault`: `["vault"]` (bump stored in config)
- `tss_pda`: `["final_tss_pda"]`
- `cea_authority`: `["push_identity", push_account]` (push_account = 20-byte EVM address)
- `executed_sub_tx`: `["executed_sub_tx", sub_tx_id]` (sub_tx_id = 32 bytes)
- `rate_limit_config`: `["rate_limit_config"]`
- `token_rate_limit`: `["rate_limit", token_mint]`

**Note**: Token whitelist PDA is no longer used. Token support is determined by rate limit threshold > 0.

**Associated Token Accounts (ATAs)**:
- Standard ATA derivation: `[authority, token_program_id, mint]`
- Use `getAssociatedTokenAddress()` helper or derive manually

---

## 6. Fee Calculation

### 6.1 Gas Fee Components

`gas_fee` is UV reimbursement. There is no separate target-account top-up field.

**For SOL Execute**:
```text
gas_fee = executed_sub_tx_rent + compute_buffer
```

**For SPL Execute**:
```text
gas_fee = executed_sub_tx_rent + cea_ata_rent_if_created + compute_buffer
```

**Components**:
- `executed_sub_tx_rent`: get exact value via `getMinimumBalanceForRentExemption(8)`
- `cea_ata_rent_if_created`: get exact value via `getMinimumBalanceForRentExemption(165)` when CEA ATA does not already exist
- `compute_buffer`: operational buffer for tx fees / compute

**For Ref-Finalize (SOL Execute via stored ix_data)**:
```text
gas_fee = executed_sub_tx_rent + SIGNATURE_FEE (5000) + compute_buffer
```
The extra `5000` covers the store UV's transaction fee.

**On-chain transfer split (direct route)**:
- `amount` → CEA (if `amount > 0`)
- `gas_fee` → caller (UV reimbursement)

**On-chain transfer split (ref route)**:
- `amount` → CEA (if `amount > 0`)
- `base_finalize_gas` → caller (finalize UV)
- `5000` → `store_refund_recipient` (store UV)

---

## 7. Backend Implementation Steps

### 7.1 Event Listener

1. Connect to Push Chain RPC
2. Listen for `UniversalTxOutbound` events
3. Filter by `chainId` = Solana cluster identifier
4. Extract all event fields

### 7.2 Payload Decoding

1. Take `payload` bytes from event
2. Decode using algorithm in section 2.2
3. Extract fields:
   - `accounts[]`: Array of account metadata (pubkey + isWritable)
   - `ixData`: Instruction data for target program
   - `instructionId`: Operation mode (1=withdraw, 2=execute)
4. Validate:
   - Gateway allows `accounts_count == 0` and `ix_data_length == 0`, but target program may fail
   - For execute (instructionId=2): `accounts` and `ixData` contain CPI data

### 7.3 TSS Message Construction

1. Determine `instruction_id` from decoded payload:
   - `1` = Withdraw (unified SOL/SPL)
   - `2` = Execute (unified SOL/SPL)
2. Fetch TSS PDA from Solana:
   - Derive TSS PDA: `["final_tss_pda"]`
   - Read account: get `chain_id` (string)
3. Build message hash based on instruction_id (common fields first):
   - **Withdraw (1)**:
     `PREFIX | 0x01 | chain_id | deadline (i64 BE 8 bytes) | amount | sub_tx_id | universal_tx_id | push_account | token | gas_fee | target`
   - **Execute (2)**:
     `PREFIX | 0x02 | chain_id | deadline (i64 BE 8 bytes) | amount | sub_tx_id | universal_tx_id | push_account | token | gas_fee | target_program | accounts_buf | ix_data_buf`
   - **Revert (3)** and **Rescue (4)** include `deadline` in the same position.
   - `deadline` is the Unix timestamp (seconds) after which the program rejects the instruction with `SignatureExpired`. The program does not enforce a maximum deadline — TSS signer policy is responsible for capping the validity window (recommended: 24–48 hours from signing time).
4. For execute: build `accounts_buf` and `ix_data_buf` with length prefixes (section 3.3)

### 7.4 TSS Signing

1. Hash message with Keccak-256 → `message_hash`
2. Sign `message_hash` with TSS private key (secp256k1)
3. Extract `signature` (64 bytes) and `recovery_id` (0 or 1)
4. Verify: Recover public key from signature, verify matches TSS ETH address

### 7.5 Solana Transaction Construction

1. Derive all required PDAs (section 5)
2. Determine mode-specific accounts based on instruction_id:
   - **Withdraw (1)**: Set `recipient` account, `destination_program` = SystemProgram.programId, `remaining_accounts` = []
   - **Execute (2)**: Decode payload first, then set `destination_program = decoded.targetProgram`, `recipient` = None, `remaining_accounts` = decoded accounts
3. Build instruction using Anchor client or raw instruction:
   - Function: `finalize_universal_tx`
   - **IMPORTANT**: No `target` parameter - execute target comes from decoded payload `targetProgram`, and `destination_program` must match it
   - Accounts: Required accounts + mode-specific optional accounts + SPL accounts (if token) + remaining_accounts (if execute)
4. For execute mode: convert accounts to writable_flags (bitpacked, see section 3.4)
5. Add instruction to transaction
6. Set recent blockhash
7. Sign with UV keypair
8. Submit to Solana network

### 7.6 Error Handling

**Common errors**:
- `MessageHashMismatch`: TSS message construction incorrect (check field order)
- `ConstraintSeeds`: PDA derivation incorrect (check seeds)
- `InvalidAccount`: Accounts don't match (check order/flags)
- `InsufficientBalance`: Vault/CEA doesn't have enough funds
- `Paused`: Gateway is paused (check config)

**Retry logic**:
- Solana blockhash expired: Rebuild transaction with a new blockhash and resubmit — the TSS signature covers the gateway instruction, not the Solana transaction envelope, so the same signature remains valid until the `deadline` expires.
- `SignatureExpired` on `finalize_universal_tx` / `finalize_universal_tx_with_ix_data_ref`: The deadline has passed. Do NOT retry. Issue source-chain revert.
- `SignatureExpired` on `revert_universal_tx` or `rescue_funds`: TSS re-signs the same payload with a new deadline. No on-chain state cleanup is required — the `ExecutedSubTx` PDA is only written on success, so a rejected instruction leaves nothing to undo. Submit the new signature immediately.
- Account errors: Verify PDA derivation and account order

**CRITICAL — revert-after-deadline rule**:
A source-chain revert (refunding the user on Push) must only be issued when **both** conditions hold:
1. The `deadline` in the TSS-signed payload has elapsed (on-chain clock past `deadline`).
2. No `ExecutedSubTx` PDA exists for the `sub_tx_id` (confirming the finalize never succeeded).

Do not treat a transient Solana failure (CPI error, congestion, blockhash expiry) as terminal before the deadline. The signed payload remains executable on Solana until the deadline expires. Issuing a source-chain revert while the payload is still live risks double-spend: the user is refunded on Push and the transaction later executes on Solana.

### 7.7 Event Verification

1. After transaction confirmation, listen for Solana events:
   - **Normal execute/withdraw:** `UniversalTxFinalized` — field order: `sub_tx_id`, `universal_tx_id`, `gas_fee`, `push_account`, `target`, `token`, `amount`, `payload`. For withdraw, `target` = recipient, `payload` = empty.
   - **CEA self-withdraw (target == gateway):** emits both `UniversalTx` (`from_cea: true`) and `UniversalTxFinalized`
     - `UniversalTx.amount`/`payload` = inner decoded `send_universal_tx_to_uea` args
     - `UniversalTxFinalized.amount`/`gasFee`/`payload` = outer `finalize_universal_tx` args
   - **Revert:** `RevertUniversalTx` — field order: `sub_tx_id`, `universal_tx_id`, `revert_recipient`, `token`, `amount`, `revert_instruction`
2. Verify event fields match your transaction
3. Mark transaction as completed

**Important:** CEA→UEA path emits both events. It no longer suppresses `UniversalTxFinalized`.

---

## 8. Critical Implementation Rules

### 8.0 Unified Entrypoint Rules (NEW)

**CRITICAL - No target parameter**:
- The `finalize_universal_tx` function does **NOT** take a `target` parameter
- Target source by mode:
  - Withdraw (1): From `recipient` account key
  - Execute (2): From decoded payload `targetProgram`; `destination_program` must match it
- **Backend must pass correct accounts**: Passing wrong accounts will cause validation failure

**Mode-specific account enforcement**:
- `destination_program` is ALWAYS required (non-optional):
  - Withdraw mode: Pass `SystemProgram.programId` (sentinel, actual target from recipient)
  - Execute mode: Pass decoded payload `targetProgram` (must be executable and match payload)
- `recipient` is optional (mode-dependent):
  - Withdraw mode: Must be provided (contains recipient pubkey)
  - Execute mode: Must be None
- Violating this will cause on-chain constraint error

**instruction_id matching**:
- The `instruction_id` in the payload **must** match the `instruction_id` parameter passed to the function
- TSS message hash is built using the `instruction_id`, so any mismatch will cause signature verification failure

### 8.1 Account Consistency (Execute Mode Only)

**Requirements** (for execute mode, instruction_id=2):

**Pubkeys and Order:**
- MUST match exactly: Same pubkeys in same order between TSS message hash and `remaining_accounts`

**Writable Flags - One-Way Rule** (`utils/validation.rs`):
- If signed metadata (in `accounts_buf`) marks account as writable → actual account MUST be writable
- If signed metadata marks account as read-only → actual account CAN be writable OR read-only
- **NOT allowed:** Signed metadata says writable, but actual account is read-only
- **Allowed:** Actual account is writable, but signed metadata says read-only (CPI won't gain extra write privileges)

**For withdraw mode** (instruction_id=1):
- `remaining_accounts` must be empty
- `writable_flags` must be empty
- No account consistency check needed (no CPI)

**Why**: On-chain validates TSS signature against reconstructed message hash. Pubkey mismatch → hash mismatch → rejection. Writable validation ensures CPI safety.

### 8.2 Universal Transaction ID

- `universal_tx_id`: 32 bytes from source chain (EVM tx hash or similar)
- Include in: TSS message hash, function parameters, event emissions
- NOT stored on-chain (only emitted in events)

### 8.3 Target Program Funding Policy

- There is no dedicated target-account top-up field in execute payload or finalize args.
- If target CPI requires lamports/tokens in CEA, backend must ensure the bridged amount and flow cover that requirement.
- Payload contains only CPI routing data (`targetProgram`, `accounts`, `ixData`) and mode selector (`instructionId`).

### 8.4 Replay Protection

- Each transaction uses a unique `sub_tx_id` (32 bytes) — must be deterministic and stable across retries
- The `executed_sub_tx` PDA (seeded by `["executed_sub_tx", sub_tx_id]`) is created on first execution; Anchor's `init` constraint rejects reuse
- No global nonce — transactions can be submitted in any order without blocking each other

### 8.5 Transaction Size Limits

- Solana transaction limit: 1232 bytes
- Your payload: ~50-400 bytes typically
- If too large: split into multiple transactions (not supported yet)

---

## 9. Example Implementation Flow

### Execute Flow (instruction_id=2):

1. **Event received**: `UniversalTxOutbound` with `target`, `amount`, `payload`, `gasFee`, `push_account`
   - Verify `instructionId == 2` (execute mode)
2. **Decode payload**: extract `instructionId`, `targetProgram`, `accounts[]`, `ixData`
3. **Derive PDAs**: CEA authority, executed_sub_tx, config, vault, tss_pda
4. **Fetch TSS state**: Get `chain_id` from TSS PDA (`["final_tss_pda"]`)
5. **Build writable flags**: Convert `accounts[]` to bitpacked `writable_flags` (1 bit per account, MSB first)
6. **Build TSS message**:
   - Use `buildExecuteAdditionalData()` helper (see `tests/helpers/tss.ts`)
   - instruction_id = 2
   - **Common fields first**: sub_tx_id, universal_tx_id, push_account, token, gas_fee
   - `accounts_buf` = length-prefixed serialized accounts (u32 BE count + accounts with pubkeys + isWritable)
   - `ix_data_buf` = length-prefixed instruction data (u32 BE length + data)
   - `token` = `Pubkey::default()` for SOL, mint pubkey for SPL
7. **Sign**: Call `signTssMessage()` → Keccak-256 hash → secp256k1 sign → signature + recovery_id
8. **Build Solana transaction**:
   - Function: `finalize_universal_tx`
   - **IMPORTANT - No target parameter**: Execute target comes from decoded payload `targetProgram`
   - Accounts:
     - Required: `caller`, `config`, `vault_sol`, `cea_authority`, `tss_pda`, `executed_sub_tx`, `system_program`
     - Mode-specific: `destination_program` = decoded `targetProgram`, `recipient` = None
     - SPL (if token): `vault_ata`, `cea_ata`, `mint`, `token_program`, `rent`, `associated_token_program`
     - Remaining: decoded accounts from payload (same order, same isWritable flags)
9. **Submit**: Sign with UV keypair, send to Solana
10. **Verify**: Wait for event:
   - Normal execute: `UniversalTxFinalized` (includes sub_tx_id, universal_tx_id, gas_fee, push_account, target, token, amount, payload)
   - CEA self-withdraw (destinationProgram == gateway): both `UniversalTx` (`from_cea: true`) and `UniversalTxFinalized`

### Withdraw Flow (instruction_id=1):

1. **Event received**: `UniversalTxOutbound` with `payload` (or no payload for simple withdraw)
2. **Decode payload** (if present): Extract `instructionId`
   - Verify `instructionId == 1` (withdraw mode)
3. **Derive PDAs**: Same as execute (see section 5)
4. **Fetch TSS state**: Get `chain_id` from TSS PDA (`["final_tss_pda"]`)
5. **Build TSS message**:
   - Use `buildWithdrawAdditionalData()` helper (see `tests/helpers/tss.ts`)
   - instruction_id = 1
   - additional_data = [sub_tx_id, universal_tx_id, push_account, token, gas_fee, target]
   - **Common fields first**: sub_tx_id, universal_tx_id, push_account, token, gas_fee
   - **Withdraw-specific**: target (recipient)
     - **SOL**: `token` = `Pubkey::default()`, `target` = SOL recipient pubkey
     - **SPL**: `token` = mint pubkey, `target` = recipient owner pubkey (recipient ATA derived on-chain)
6. **Sign**: Call `signTssMessage()` → Keccak-256 hash → secp256k1 sign → signature + recovery_id
7. **Build Solana transaction**:
   - Function: `finalize_universal_tx`
   - **IMPORTANT - No target parameter**: Target derived from `recipient` account
   - Accounts:
     - Required: `caller`, `config`, `vault_sol`, `cea_authority`, `tss_pda`, `executed_sub_tx`, `system_program`
     - Mode-specific: `recipient` (recipient pubkey), `destination_program` = SystemProgram.programId
     - SPL (if token): `vault_ata`, `cea_ata`, `mint`, `token_program`, `rent`, `associated_token_program`, `recipient_ata`
     - Remaining: must be empty
8. **Submit and verify**: Sign with UV keypair, send to Solana, wait for `UniversalTxFinalized` event

### Revert Flow:

1. **Event received**: Revert instruction from Push Chain
2. **Build TSS message**:
   - instruction_id = 3 (both SOL and SPL)
   - Call `signTssMessage()` with:
     - `additional`:
       - SOL: `[sub_tx_id, universal_tx_id, recipient_pubkey, gas_fee_buf]`
       - SPL: `[sub_tx_id, universal_tx_id, mint_pubkey, recipient_pubkey, gas_fee_buf]`
   - **Note**: `signTssMessage()` does **not** auto-include `sub_tx_id` / `universal_tx_id`. Include them in `additional` as specified.
3. **Sign and submit**:
   - `signTssMessage()` returns signature, recovery_id, message_hash
   - See account struct: `RevertUniversalTx` (unified SOL/SPL) in `revert.rs`

### Rescue Flow (emergency only):

1. **Trigger**: Push Chain determines funds are locked and unreachable; emits rescue authorization
2. **Build TSS message** (instruction_id = 4 for both SOL and SPL):
   - Call `buildRescueAdditionalData(subTxId, universalTxId, recipient, gasFee, tokenMint?)` from `tests/helpers/tss.ts`
   - SOL additional: `[sub_tx_id, universal_tx_id, recipient_pubkey, gas_fee_buf]`
   - SPL additional: `[sub_tx_id, universal_tx_id, mint_pubkey, recipient_pubkey, gas_fee_buf]`
3. **Sign**: `signTssMessage({ instruction: TssInstruction.Rescue, amount, additional })`
4. **Submit** `rescue_funds` with accounts:
   - Always required: `config`, `vault`, `fee_vault`, `tss_pda`, `recipient`, `executed_sub_tx`, `caller`, `system_program`
   - SOL only: `token_vault=null`, `recipient_token_account=null`, `token_mint=null`, `token_program=null`
   - SPL only: `token_vault` (vault ATA), `recipient_token_account` (recipient ATA), `token_mint`, `token_program`
5. **Replay guard** — `ExecutedSubTx` PDA keyed by `sub_tx_id` prevents duplicate rescue execution
6. **Events emitted**:
   - `FundsRescued { sub_tx_id, universal_tx_id, token, amount, revert_instruction }`
   - For rescue, `revert_instruction.revert_recipient = recipient` and `revert_instruction.revert_msg = []`
   - `InboundFeeReimbursed { sub_tx_id, relayer, amount_lamports }`

---

## 10. Testing Checklist

Before production:
- [ ] Payload decode matches encode (roundtrip)
- [ ] TSS message hash matches on-chain reconstruction
- [ ] Account order/flags match in all three places (hash, param, remaining)
- [ ] CEA ATA creation works (SPL execute)
- [ ] Error handling for all error codes
- [ ] Event verification works

---

## 11. Reference Implementation Files

### 11.1 Payload Encoding/Decoding

**File**: `contracts/svm-gateway/app/execute-payload.ts`

**Key Functions**:
- `accountsToWritableFlags()` - Converts accounts array to bitpacked writable flags

**Usage**: See test file `contracts/svm-gateway/tests/execute.test.ts` (search for `encodeExecutePayload`)

### 11.2 TSS Message Signing

**File**: `contracts/svm-gateway/tests/helpers/tss.ts`

**Key Functions**:
- `signTssMessage()` - Builds and signs TSS message hash
  - Takes: `{ instruction, amount, additional, chainId }`
  - Returns: `{ signature, recoveryId, messageHash }`
- `buildExecuteAdditionalData()` - Constructs additional fields for execute (instruction_id=2)
  - **Common fields first**, then execute-specific
- `buildWithdrawAdditionalData()` - Constructs additional fields for withdraw (instruction_id=1)
  - Format: [sub_tx_id, universal_tx_id, push_account, token, gas_fee, target]
  - **Common fields first**, then withdraw-specific (target)
- `buildRescueAdditionalData()` - Constructs additional fields for rescue (instruction_id=4)
  - SOL: `[sub_tx_id, universal_tx_id, recipient, gas_fee]`
  - SPL: `[sub_tx_id, universal_tx_id, mint, recipient, gas_fee]`

**Instruction IDs** (TssInstruction enum):
- `TssInstruction.Withdraw = 1` - Unified withdraw (SOL/SPL)
- `TssInstruction.Execute = 2` - Unified execute (SOL/SPL)
- `TssInstruction.Revert = 3` - Unified revert (SOL/SPL)
- `TssInstruction.Rescue = 4` - Emergency rescue (SOL/SPL, replay-protected with `sub_tx_id`)

**Usage**: See test file `contracts/svm-gateway/tests/execute.test.ts` (search for `signTssMessage` or `buildExecuteAdditionalData`)

### 11.3 Program Implementation

**Execute Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`
  - `finalize_universal_tx()` - unified withdraw + execute handler
  - `FinalizeUniversalTx` struct - unified account struct for SOL/SPL execute + withdraw

**Withdraw / Revert Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/revert.rs`
  - `revert_universal_tx()` - unified SOL/SPL revert handler

**Deposit Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/deposit.rs`
  - `send_universal_tx()` - Universal deposit entrypoint
  - `route_universal_tx()` - Routes to GAS or FUNDS handlers

**TSS Validation**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/tss.rs`
  - `validate_message()` - Validates TSS signature and message hash

**Utilities**:
- `contracts/svm-gateway/programs/universal-gateway/src/utils/validation.rs`
  - `validate_remaining_accounts()` - Validates account list and rejects outer signers
- `contracts/svm-gateway/programs/universal-gateway/src/utils/pricing.rs`
  - `calculate_sol_price()` - Pyth price oracle integration

### 11.4 Test Examples

**Execute Tests**:
- `contracts/svm-gateway/tests/execute.test.ts` - Complete execute flow examples
  - Search for `"should execute SOL transaction"` - Basic SOL execute
  - Search for `"should execute SPL transaction"` - Basic SPL execute
  - Search for `"should handle heavy transactions"` - Large payload examples

**Withdraw Tests**:
- `contracts/svm-gateway/tests/withdraw.test.ts` - Complete withdraw flow examples
  - Search for `"transfers SOL with a valid signature"` - SOL withdraw
  - Search for `"transfers SPL tokens with a valid signature"` - SPL withdraw

**Integration Test Script**:
- `contracts/svm-gateway/app/gateway-test.ts` - End-to-end integration test script
  - Tests all flows: execute, withdraw, revert (SOL and SPL)
  - Includes transaction size limit testing

### 11.5 Account Structures (Rust)

**Unified Execute/Withdraw Struct** (see `execute.rs`):
- `FinalizeUniversalTx` - Required + optional accounts for unified execute + withdraw operations
  - **Required accounts** (all modes): `caller`, `config`, `vault_sol`, `cea_authority`, `tss_pda`, `executed_sub_tx`, `system_program`, `destination_program`
  - **Mode-specific accounts**:
    - `destination_program: UncheckedAccount` - ALWAYS required (non-optional)
      - Withdraw mode: SystemProgram.programId (sentinel)
      - Execute mode: Target program pubkey (must be executable)
    - `recipient: Option<UncheckedAccount>` - Mode-dependent optional account
      - Withdraw mode: Required (recipient address, mut)
      - Execute mode: Must be None
  - **SPL optional accounts** (all-or-none based on mint presence):
    - `vault_ata`, `cea_ata`, `mint`, `token_program`, `rent`, `associated_token_program`
    - `recipient_ata` - Withdraw only (recipient's token account)
  - **Anchor client note**: For `recipient`, pass `null` for execute mode or recipient pubkey for withdraw mode
  - **Execute mode**: `destination_program` = target program, `recipient` = None, remaining_accounts with CPI accounts
  - **Withdraw mode**: `destination_program` = SystemProgram.programId, `recipient` set, remaining_accounts empty

**Revert Structs** (see `revert.rs`):
- `RevertUniversalTx` - Unified required accounts for SOL and SPL revert (instruction_id=3)

**Rescue Struct** (see `rescue.rs`):
- `RescueFunds` - Unified accounts for SOL and SPL rescue (instruction_id=4); SPL accounts are optional

**State Structures** (see `state.rs`):
- `GatewayAccountMeta` - Account metadata (pubkey + is_writable)
- `Config` - Gateway configuration (min/max caps, paused state, etc.)
- `TssPda` - TSS state (chain_id, tss_eth_address, bump)
- `ExecutedSubTx` - Replay protection tracker (8-byte discriminator only)

---

## 12. Address Lookup Tables (ALTs) for Transaction Size Optimization

The gateway ships one Address Lookup Table per deployed program. Its scope is the `send_universal_tx` (inbound) path, where the SPL FUNDS_AND_PAYLOAD variant would otherwise exceed the 1232-byte legacy limit. The `finalize_universal_tx` (outbound) path does not use an ALT; large execute payloads use the tx-size ref route (`store_execute_ix_data` + `finalize_universal_tx_with_ix_data_ref`) instead.

**Static addresses packed into the ALT** (all constant per program):

| Address | Purpose |
|---------|---------|
| `config` PDA | Gateway config |
| `vault` PDA | SOL vault |
| `fee_vault` PDA | Inbound fee vault |
| `rate_limit_config` PDA | Block/epoch caps |
| Pyth SOL/USD price account | Oracle |
| SPL Token program | `Tokenkeg...` |
| System program | `1111...` |
| `event_authority` PDA | `emit_cpi!` self-CPI target |
| Program id (self) | `emit_cpi!` requires it as a passed account |

The deployed ALT address per program is persisted in `universal-alt.json`, keyed by program label (`main` at the top level, `dummy` under a nested `dummy` key). `app/gateway-test.ts` resolves the ALT via `resolveAltAddress()` and consumes it only in the `send_universal_tx` block.

**Deploying a fresh ALT for a new program:**
```bash
npx ts-node app/create-universal-alt.ts main    # or: dummy
```

**Adding new addresses to an existing deployed ALT** (e.g. after migrating events to `emit_cpi`, the two event accounts must be added if the ALT was created before the migration):
```bash
npx ts-node scripts/extend-alt.ts \
  --alt <ALT_ADDRESS_FROM_universal-alt.json> \
  --accounts <EVENT_AUTHORITY_PDA>,<PROGRAM_ID>
```

**Deactivating a stale ALT (recover rent):**
```bash
npx ts-node scripts/deactivate-alt.ts --alt <ALT_ADDRESS>
```

**Building a versioned transaction against the ALT (inbound path):**
```typescript
import { TransactionMessage, VersionedTransaction } from '@solana/web3.js';

const { value: alt } = await connection.getAddressLookupTable(ALT_ADDRESS);
if (!alt) throw new Error("Lookup table not found on-chain");

const { blockhash } = await connection.getLatestBlockhash();
const messageV0 = new TransactionMessage({
  payerKey: userPublicKey,
  recentBlockhash: blockhash,
  instructions: [sendUniversalTxInstruction],
}).compileToV0Message([alt]);

const tx = new VersionedTransaction(messageV0);
```
