import * as anchor from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { getAssociatedTokenAddress } from "@solana/spl-token";
import {
  accountsToWritableFlags,
  GatewayAccountMeta,
} from "../../app/execute-payload";
import { createHash, randomBytes } from "crypto";

// =============================================================================
// Constants
// =============================================================================

export const USDT_DECIMALS = 6;
export const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

/** Buffer for Solana tx fees + compute unit costs (~0.0001 SOL) */
export const COMPUTE_BUFFER = BigInt(100_000);

/** Base Solana fee per signature — matches SIGNATURE_FEE_LAMPORTS in execute.rs. */
export const SIGNATURE_FEE_LAMPORTS = BigInt(5_000);

// =============================================================================
// Utilities
// =============================================================================

export const asLamports = (sol: number) =>
  new anchor.BN(sol * anchor.web3.LAMPORTS_PER_SOL);
export const asTokenAmount = (tokens: number) =>
  new anchor.BN(Number(BigInt(tokens) * TOKEN_MULTIPLIER));

/** Compute the first 8 bytes of SHA-256 of `name` — matches Anchor's discriminator format */
export const computeDiscriminator = (name: string): Buffer =>
  createHash("sha256").update(name).digest().slice(0, 8);

// =============================================================================
// ID generators
// =============================================================================

/**
 * Returns a sub_tx_id generator with its own local counter.
 * Each test file should call `makeTxIdGenerator()` once and use the returned function.
 * The local counter + Date.now() + 24 random bytes guarantees uniqueness within a run.
 */
export const makeTxIdGenerator = () => {
  let counter = 0;
  return (): number[] => {
    counter++;
    const buffer = Buffer.alloc(32);
    buffer.writeUInt32BE(counter, 0);
    buffer.writeUInt32BE(Date.now() % 0xffffffff, 4);
    randomBytes(24).copy(buffer, 8);
    return Array.from(buffer);
  };
};

/** Generate a random 20-byte EVM-style sender address (never all-zeros) */
export const generateSender = (): number[] => {
  const buffer = Buffer.alloc(20);
  randomBytes(20).copy(buffer);
  if (buffer.every((b) => b === 0)) buffer[0] = 1;
  return Array.from(buffer);
};

// =============================================================================
// PDA derivers
// =============================================================================

export const getExecutedTxPda = (
  txId: number[],
  programId: PublicKey
): PublicKey => {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from("executed_sub_tx"), Buffer.from(txId)],
    programId
  );
  return pda;
};

export const getCeaAuthorityPda = (
  sender: number[],
  programId: PublicKey
): PublicKey => {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from("push_identity"), Buffer.from(sender)],
    programId
  );
  return pda;
};

export const getFeeVaultPda = (programId: PublicKey): PublicKey => {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from("fee_vault")],
    programId
  );
  return pda;
};

export const getTokenRateLimitPda = (
  tokenMint: PublicKey,
  programId: PublicKey
): PublicKey => {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from("rate_limit"), tokenMint.toBuffer()],
    programId
  );
  return pda;
};

export const getCeaAta = async (
  sender: number[],
  mint: PublicKey,
  programId: PublicKey
): Promise<PublicKey> => {
  const ceaAuthority = getCeaAuthorityPda(sender, programId);
  return getAssociatedTokenAddress(mint, ceaAuthority, true);
};

// =============================================================================
// Fee helpers
// =============================================================================

/** Minimum lamports to keep ExecutedSubTx account (8-byte discriminator only) rent-exempt */
export const getExecutedTxRent = async (
  connection: anchor.web3.Connection
): Promise<number> => connection.getMinimumBalanceForRentExemption(8);

/** Minimum lamports to keep a standard SPL token account (165 bytes) rent-exempt */
export const getTokenAccountRent = async (
  connection: anchor.web3.Connection
): Promise<number> => connection.getMinimumBalanceForRentExemption(165);

/** Returns true if the CEA ATA account exists and has data */
export const ceaAtaExists = async (
  connection: anchor.web3.Connection,
  ceaAta: PublicKey
): Promise<boolean> => {
  const info = await connection.getAccountInfo(ceaAta);
  return info !== null && info.data.length > 0;
};

/**
 * Calculate gas_fee for SOL execute operations.
 * gasUsed = SIGNATURE_FEE + executed_sub_tx_rent  (matches on-chain execute.rs accounting)
 * gasFee  = gasUsed + COMPUTE_BUFFER             (COMPUTE_BUFFER becomes gas_to_refund)
 */
export const calculateSolExecuteFees = async (
  connection: anchor.web3.Connection
): Promise<{ gasFee: bigint; gasUsed: bigint }> => {
  const executedTxRent = BigInt(await getExecutedTxRent(connection));
  const gasUsed = SIGNATURE_FEE_LAMPORTS + executedTxRent;
  return { gasFee: executedTxRent + COMPUTE_BUFFER, gasUsed };
};

/**
 * Calculate gas_fee for SPL execute operations.
 * gasUsed = SIGNATURE_FEE + executed_sub_tx_rent + cea_ata_rent (if not yet created)
 * gasFee  = gasUsed + COMPUTE_BUFFER  (COMPUTE_BUFFER becomes gas_to_refund)
 */
export const calculateSplExecuteFees = async (
  connection: anchor.web3.Connection,
  ceaAta: PublicKey
): Promise<{ gasFee: bigint; gasUsed: bigint }> => {
  const executedTxRent = BigInt(await getExecutedTxRent(connection));
  const ataExists = await ceaAtaExists(connection, ceaAta);
  const ceaAtaRent = ataExists
    ? BigInt(0)
    : BigInt(await getTokenAccountRent(connection));
  const gasUsed = SIGNATURE_FEE_LAMPORTS + executedTxRent + ceaAtaRent;
  return { gasFee: executedTxRent + ceaAtaRent + COMPUTE_BUFFER, gasUsed };
};

// =============================================================================
// Account transformers
// =============================================================================

// SECURITY NOTE: instructionAccountsToGatewayMetas and instructionAccountsToRemaining
// MUST produce accounts in the SAME ORDER. The accounts used for TSS signing (via
// buildExecuteAdditionalData) MUST exactly match the accounts passed to .remainingAccounts().
// Any mismatch causes MessageHashMismatch — this is intentional replay/tamper protection.

export const instructionAccountsToGatewayMetas = (
  ix: anchor.web3.TransactionInstruction
): GatewayAccountMeta[] =>
  ix.keys.map((key) => ({ pubkey: key.pubkey, isWritable: key.isWritable }));

export const instructionAccountsToRemaining = (
  ix: anchor.web3.TransactionInstruction
) =>
  ix.keys.map((key) => ({
    pubkey: key.pubkey,
    isWritable: key.isWritable,
    isSigner: false,
  }));

export const accountsToWritableFlagsOnly = (accounts: GatewayAccountMeta[]) =>
  accountsToWritableFlags(accounts);

// =============================================================================
// emit_cpi event extraction
// =============================================================================

/**
 * Extract Anchor `emit_cpi!` events from a confirmed transaction.
 *
 * `emit_cpi` wraps events as self-CPIs to the program's `event_authority` PDA;
 * the encoded event bytes live in the inner instruction's data (not in program
 * logs). Layout: [EVENT_IX_TAG_LE: 8 bytes] || [event_discriminator: 8 bytes]
 * || [borsh(event)].
 *
 * The `Program data:` string that `Program::coder().events.decode()` accepts is
 * the base64 of the last two fields, so we strip the 8-byte tag and pass the
 * remainder in base64.
 */
export const extractEventCpi = async (
  connection: anchor.web3.Connection,
  program: anchor.Program<any>,
  signature: string,
  maxRetries: number = 10
): Promise<{ name: string; data: any }[]> => {
  let tx: Awaited<ReturnType<typeof connection.getTransaction>> = null;
  for (let i = 0; i < maxRetries; i++) {
    tx = await connection.getTransaction(signature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (tx?.meta) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  if (!tx?.meta) return [];

  const accountKeys = tx.transaction.message
    .getAccountKeys({ accountKeysFromLookups: tx.meta.loadedAddresses })
    .keySegments()
    .flat();
  const programIdx = accountKeys.findIndex((k) =>
    k.equals(program.programId)
  );
  if (programIdx === -1) return [];

  const eventCoder = new anchor.BorshEventCoder(program.idl);
  const events: { name: string; data: any }[] = [];
  for (const inner of tx.meta.innerInstructions ?? []) {
    for (const ix of inner.instructions) {
      if (ix.programIdIndex !== programIdx) continue;
      // `data` is base58 from web3.js; decode, strip 8-byte EVENT_IX_TAG_LE, re-encode base64.
      const raw = anchor.utils.bytes.bs58.decode(ix.data);
      if (raw.length < 8) continue;
      const eventBytes = raw.slice(8);
      const decoded = eventCoder.decode(
        anchor.utils.bytes.base64.encode(eventBytes)
      );
      if (decoded) events.push(decoded);
    }
  }
  return events;
};
