import * as anchor from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import pkg from "js-sha3";
const { keccak_256 } = pkg;
import * as secp from "@noble/secp256k1";
import { randomBytes } from "crypto";

export enum TssInstruction {
  Withdraw = 1, // Unified withdraw (vault→CEA→recipient)
  Execute = 2, // Unified execute (vault→CEA→CPI)
  Revert = 3,  // Unified revert (SOL or SPL)
  Rescue = 4,  // Emergency rescue (SOL or SPL)
}

// Default to Devnet cluster pubkey if not specified
export const TSS_CHAIN_ID =
  process.env.TSS_CHAIN_ID ?? "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";

// Far-future deadline for tests: Jan 1 2100 (unix seconds). Use this as the
// default so tests don't need to manage validity windows explicitly.
export const DEFAULT_DEADLINE = BigInt(4102444800);

function getTssPrivateKey(): string {
  const priv =
    process.env.TSS_PRIVKEY ||
    process.env.ETH_PRIVATE_KEY ||
    process.env.PRIVATE_KEY;
  if (!priv) {
    throw new Error(
      "TSS private key not set. Export TSS_PRIVKEY (or ETH_PRIVATE_KEY / PRIVATE_KEY) before running tests."
    );
  }
  return priv;
}

// Compute ETH address from private key
const privateKeyHex = getTssPrivateKey();
const PRIVATE_KEY = Buffer.from(privateKeyHex, "hex");
const PUBLIC_KEY = secp.getPublicKey(PRIVATE_KEY, false).slice(1); // remove 0x04 prefix
const ETH_ADDRESS_HEX = keccak_256(PUBLIC_KEY).slice(-40);
const ETH_ADDRESS_BYTES = Buffer.from(ETH_ADDRESS_HEX, "hex");

export function getTssEthAddress(): number[] {
  return Array.from(ETH_ADDRESS_BYTES);
}

export interface TssSignature {
  signature: number[];
  recoveryId: number;
  messageHash: number[];
}

type BytesLike = Uint8Array | number[];

interface SignParams {
  instruction: TssInstruction;
  amount?: bigint;
  additional: BytesLike[];
  chainId?: string;
  deadline?: bigint;
}

export async function signTssMessage({
  instruction,
  amount,
  additional,
  chainId,
  deadline,
}: SignParams): Promise<TssSignature> {
  // Build message EXACTLY like Rust program:
  // PREFIX || instruction_id || chain_id || deadline (i64 BE) || [amount (u64 BE)] || additional_data
  const chainIdToUse = chainId ?? TSS_CHAIN_ID;
  const deadlineToUse = deadline ?? DEFAULT_DEADLINE;
  const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
  const instructionId = Buffer.from([instruction]);
  const chainIdBytes = Buffer.from(chainIdToUse, "utf8");
  const deadlineBuf = Buffer.alloc(8);
  deadlineBuf.writeBigInt64BE(deadlineToUse);

  const segments: Buffer[] = [PREFIX, instructionId, chainIdBytes, deadlineBuf];

  if (typeof amount === "bigint") {
    const amountBE = Buffer.alloc(8);
    amountBE.writeBigUInt64BE(amount);
    segments.push(amountBE);
  }

  // All additional data goes directly into segments
  additional.forEach((item) => {
    segments.push(Buffer.from(item));
  });

  const concat = Buffer.concat(segments);
  const messageHashHex = keccak_256(concat);
  const messageHash = Buffer.from(messageHashHex, "hex");

  const priv = privateKeyHex;
  const sig = await secp.sign(messageHash, priv, {
    recovered: true,
    der: false,
  });
  const signature: Uint8Array = sig[0];
  let recoveryId: number = sig[1];

  return {
    signature: Array.from(signature),
    recoveryId,
    messageHash: Array.from(messageHash),
  };
}

export function pubkeyToBytes(pubkey: PublicKey): Uint8Array {
  return pubkey.toBuffer();
}

/**
 * Generate a universal transaction ID (32 bytes) for testing
 * In production, this comes from the source chain (EVM/Push Chain)
 */
export function generateUniversalTxId(): number[] {
  return Array.from(randomBytes(32));
}

// =========================
// WITHDRAW MESSAGE HELPERS
// =========================

/**
 * Build withdraw message additional_data
 *
 * New format (common fields first):
 * 1. sub_tx_id (32 bytes) - common
 * 2. universal_tx_id (32 bytes) - common
 * 3. push_account (20 bytes) - common
 * 4. token (32 bytes) - common
 * 5. gas_fee (u64 BE) - common
 * 6. target (32 bytes) - withdraw specific
 */
export function buildWithdrawAdditionalData(
  universalTxId: BytesLike,
  subTxId: BytesLike,
  pushAccount: BytesLike,
  token: PublicKey,
  target: PublicKey,
  gasFee: bigint = BigInt(0)
): BytesLike[] {
  const gasFeeBuf = Buffer.alloc(8);
  gasFeeBuf.writeBigUInt64BE(gasFee, 0);

  return [
    subTxId, // sub_tx_id (32 bytes) - common
    universalTxId, // universal_tx_id (32 bytes) - common
    pushAccount, // push_account (20 bytes) - common
    token.toBuffer(), // token (32 bytes) - common
    gasFeeBuf, // gas_fee (8 bytes, u64 BE) - common
    target.toBuffer(), // target/recipient (32 bytes) - withdraw specific
  ];
}

// =========================
// EXECUTE MESSAGE HELPERS
// =========================

export interface GatewayAccountMeta {
  pubkey: PublicKey;
  isWritable: boolean;
}

/**
 * Build execute message additional_data buffers (accounts and ix_data with length prefixes)
 *
 * IMPORTANT: targetProgramFromPayload MUST come from decoded payload, NOT external metadata.
 * The decoded payload is the canonical source of truth for the destination program.
 *
 * New format (common fields first):
 * 1. sub_tx_id (32 bytes) - common
 * 2. universal_tx_id (32 bytes) - common
 * 3. push_account (20 bytes) - common
 * 4. token (32 bytes) - common
 * 5. gas_fee (u64 BE) - common
 * 6. target_program (32 bytes) - execute specific, MUST match decoded payload
 * 7. accounts_buf (variable) - execute specific
 * 8. ix_data_buf (variable) - execute specific
 */
export function buildExecuteAdditionalData(
  universalTxId: BytesLike,
  subTxId: BytesLike,
  targetProgramFromPayload: PublicKey, // ← MUST come from decoded payload
  pushAccount: BytesLike,
  accounts: GatewayAccountMeta[],
  ixData: Uint8Array,
  gasFee: bigint = BigInt(0),
  token: PublicKey = PublicKey.default
): BytesLike[] {
  // Build accounts buffer with length prefix (u32 BE)
  const accountsCount = Buffer.alloc(4);
  accountsCount.writeUInt32BE(accounts.length, 0);
  const accountsBuf = Buffer.concat([
    accountsCount,
    ...accounts.map((acc) =>
      Buffer.concat([
        acc.pubkey.toBuffer(),
        Buffer.from([acc.isWritable ? 1 : 0]),
      ])
    ),
  ]);

  // Build ix_data buffer with length prefix (u32 BE)
  const ixDataLength = Buffer.alloc(4);
  ixDataLength.writeUInt32BE(ixData.length, 0);
  const ixDataBuf = Buffer.concat([ixDataLength, Buffer.from(ixData)]);

  const gasFeeBigInt =
    gasFee !== undefined && gasFee !== null
      ? typeof gasFee === "bigint"
        ? gasFee
        : BigInt(gasFee)
      : BigInt(0);
  const gasFeeBuf = Buffer.alloc(8);
  gasFeeBuf.writeBigUInt64BE(gasFeeBigInt, 0);

  return [
    subTxId, // sub_tx_id (32 bytes) - common
    universalTxId, // universal_tx_id (32 bytes) - common
    pushAccount, // push_account (20 bytes) - common
    token.toBuffer(), // token (32 bytes) - common
    gasFeeBuf, // gas_fee (8 bytes, u64 BE) - common
    targetProgramFromPayload.toBuffer(), // target_program (32 bytes) - execute specific, from decoded payload
    accountsBuf, // accounts with length prefix - execute specific
    ixDataBuf, // ix_data with length prefix - execute specific
  ];
}

// =========================
// RESCUE MESSAGE HELPERS
// =========================

/**
 * Build rescue message additional_data (instruction_id=4 for both SOL and SPL).
 *
 * SOL:  [sub_tx_id, universal_tx_id, recipient, gas_fee]
 * SPL:  [sub_tx_id, universal_tx_id, mint, recipient, gas_fee]
 *
 * Replay-protected via ExecutedSubTx PDA (EVM parity: isExecuted[subTxId]).
 */
export function buildRescueAdditionalData(
  subTxId: BytesLike,
  universalTxId: BytesLike,
  recipient: PublicKey,
  gasFee: bigint = BigInt(0),
  tokenMint?: PublicKey
): BytesLike[] {
  const gasFeeBuf = Buffer.alloc(8);
  gasFeeBuf.writeBigUInt64BE(gasFee, 0);

  if (tokenMint) {
    return [subTxId, universalTxId, tokenMint.toBuffer(), recipient.toBuffer(), gasFeeBuf];
  }
  return [subTxId, universalTxId, recipient.toBuffer(), gasFeeBuf];
}

// =========================
// REVERT MESSAGE HELPERS
// =========================

export function buildRevertAdditionalData(
  subTxId: BytesLike,
  universalTxId: BytesLike,
  recipient: PublicKey,
  revertMsg: Uint8Array,
  gasFee: bigint = BigInt(0),
  tokenMint?: PublicKey
): BytesLike[] {
  const gasFeeBuf = Buffer.alloc(8);
  gasFeeBuf.writeBigUInt64BE(gasFee, 0);
  const revertMsgHash = Buffer.from(keccak_256.arrayBuffer(Buffer.from(revertMsg)));

  if (tokenMint) {
    return [
      subTxId,
      universalTxId,
      tokenMint.toBuffer(),
      recipient.toBuffer(),
      gasFeeBuf,
      revertMsgHash,
    ];
  }

  return [subTxId, universalTxId, recipient.toBuffer(), gasFeeBuf, revertMsgHash];
}
