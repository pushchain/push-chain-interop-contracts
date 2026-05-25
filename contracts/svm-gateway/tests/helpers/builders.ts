import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../../target/types/universal_gateway";
import { PublicKey, SystemProgram } from "@solana/web3.js";
import { getCeaAuthorityPda, getExecutedTxPda } from "./test-utils";
import { DEFAULT_DEADLINE } from "./tss";

// =============================================================================
// FinalizeUniversalTx builder
// =============================================================================

export interface FinalizeUniversalTxArgs {
  instructionId: number;
  subTxId: number[];
  universalTxId: number[] | Uint8Array;
  amount: anchor.BN;
  pushAccount: number[];
  writableFlags?: Buffer;
  ixData?: Buffer;
  gasFee: anchor.BN;
  deadline?: anchor.BN;
  sig: {
    signature: ArrayLike<number>;
    recoveryId: number;
    messageHash: ArrayLike<number>;
  };
  caller: PublicKey;
  destinationProgram?: PublicKey;
  recipient?: PublicKey | null;
  vaultAta?: PublicKey | null;
  ceaAta?: PublicKey | null;
  mint?: PublicKey | null;
  tokenProgram?: PublicKey | null;
  rent?: PublicKey | null;
  associatedTokenProgram?: PublicKey | null;
  recipientAta?: PublicKey | null;
  rateLimitConfig?: PublicKey | null;
  tokenRateLimit?: PublicKey | null;
}

/**
 * Returns a `finalizeUniversalTx` builder bound to the given program and PDAs.
 *
 * Usage (call once in before(), assign to a `let` variable):
 *   finalizeUniversalTx = makeFinalizeUniversalTxBuilder(gatewayProgram, configPda, vaultPda, tssPda);
 *
 * The returned function collapses the 13-arg method call + 15-field accounts block.
 * Call sites still chain .signers([...]).rpc() — and .remainingAccounts([...]) for execute.
 * All test assertions remain in the test body unchanged.
 */
export const makeFinalizeUniversalTxBuilder =
  (
    program: Program<UniversalGateway>,
    configPda: PublicKey,
    vaultPda: PublicKey,
    tssPda: PublicKey
  ) =>
  ({
    instructionId,
    subTxId,
    universalTxId,
    amount,
    pushAccount,
    writableFlags = Buffer.alloc(0),
    ixData = Buffer.from([]),
    gasFee,
    deadline,
    sig,
    caller,
    destinationProgram,
    recipient = null,
    vaultAta = null,
    ceaAta = null,
    mint = null,
    tokenProgram = null,
    rent = null,
    associatedTokenProgram = null,
    recipientAta = null,
    rateLimitConfig = null,
    tokenRateLimit = null,
  }: FinalizeUniversalTxArgs) =>
    program.methods
      .finalizeUniversalTx(
        instructionId,
        Array.from(subTxId),
        Array.from(universalTxId),
        amount,
        Array.from(pushAccount),
        writableFlags,
        ixData,
        gasFee,
        deadline ?? new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority: getCeaAuthorityPda(
          Array.from(pushAccount),
          program.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(Array.from(subTxId), program.programId),
        destinationProgram: destinationProgram ?? SystemProgram.programId,
        recipient,
        vaultAta,
        ceaAta,
        mint,
        tokenProgram,
        rent,
        associatedTokenProgram,
        recipientAta,
        rateLimitConfig,
        tokenRateLimit,
        storedIxData: null,
        storeRefundRecipient: null,
        systemProgram: SystemProgram.programId,
      });
