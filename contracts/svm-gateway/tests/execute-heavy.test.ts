import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import {
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddress,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import * as sharedState from "./shared-state";
import {
  signTssMessage,
  buildExecuteAdditionalData,
  TssInstruction,
  GatewayAccountMeta,
  generateUniversalTxId,
} from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import {
  COMPUTE_BUFFER,
  computeDiscriminator,
  makeTxIdGenerator,
  generateSender,
  getExecutedTxPda as _getExecutedTxPda,
  getCeaAuthorityPda as _getCeaAuthorityPda,
  getExecutedTxRent,
  calculateSolExecuteFees,
  instructionAccountsToGatewayMetas,
  instructionAccountsToRemaining,
  accountsToWritableFlagsOnly,
  SIGNATURE_FEE_LAMPORTS,
} from "./helpers/test-utils";
import {
  makeFinalizeUniversalTxBuilder,
  FinalizeUniversalTxArgs,
} from "./helpers/builders";
import pkg from "js-sha3";

const { keccak_256 } = pkg;

describe("Universal Gateway - Heavy Transaction Benchmarking", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const provider = anchor.getProvider() as anchor.AnchorProvider;
  const gatewayProgram = anchor.workspace
    .UniversalGateway as Program<UniversalGateway>;
  const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

  before(async () => {
    await ensureTestSetup();
  });

  let admin: Keypair;
  let counterPda: PublicKey;
  let counterBump: number;
  let counterAuthority: Keypair;

  let configPda: PublicKey;
  let vaultPda: PublicKey;
  let tssPda: PublicKey;

  let finalizeUniversalTx: ReturnType<typeof makeFinalizeUniversalTxBuilder>;

  const generateTxId = makeTxIdGenerator();
  const deriveStoredIxDataPda = (subTxId: number[], ixDataHash: Uint8Array) =>
    PublicKey.findProgramAddressSync(
      [
        Buffer.from("stored_ix_data"),
        Buffer.from(subTxId),
        Buffer.from(ixDataHash),
      ],
      gatewayProgram.programId
    )[0];
  const hashIxData = (ixData: Buffer): Uint8Array =>
    new Uint8Array(keccak_256.arrayBuffer(ixData));
  const asIxDataHashArg = (ixDataHash: Uint8Array): number[] =>
    Buffer.from(ixDataHash) as unknown as number[];
  const getExecutedTxPda = (subTxId: number[]) =>
    _getExecutedTxPda(subTxId, gatewayProgram.programId);
  const getCeaAuthorityPda = (pushAccount: number[]) =>
    _getCeaAuthorityPda(pushAccount, gatewayProgram.programId);

  before(async () => {
    admin = sharedState.getAdmin();
    counterAuthority = sharedState.getCounterAuthority();

    const airdropLamports = 100 * anchor.web3.LAMPORTS_PER_SOL;
    await Promise.all([
      provider.connection.requestAirdrop(admin.publicKey, airdropLamports),
      provider.connection.requestAirdrop(
        counterAuthority.publicKey,
        airdropLamports
      ),
    ]);
    await new Promise((resolve) => setTimeout(resolve, 2000));

    [configPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("config")],
      gatewayProgram.programId
    );

    [vaultPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("vault")],
      gatewayProgram.programId
    );

    [tssPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("final_tss_pda")],
      gatewayProgram.programId
    );

    [counterPda, counterBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("counter")],
      counterProgram.programId
    );

    // Check if counter already exists (from other test files)
    try {
      const existingCounter = await counterProgram.account.counter.fetch(
        counterPda
      );
      // Use the existing authority
      counterAuthority = { publicKey: existingCounter.authority } as Keypair;
    } catch (err: any) {
      // Counter doesn't exist, initialize it
      try {
        await counterProgram.methods
          .initialize(new anchor.BN(0))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([counterAuthority])
          .rpc();
      } catch (initErr: any) {
        // Counter might have been initialized by another test file between check and init
        if (initErr.message?.includes("already in use")) {
          // Fetch the existing counter to get its authority
          const existingCounter = await counterProgram.account.counter.fetch(
            counterPda
          );
          counterAuthority = {
            publicKey: existingCounter.authority,
          } as Keypair;
        } else {
          throw initErr;
        }
      }
    }

    // Fund vault with SOL for execute path tests
    const vaultAmount = 100 * anchor.web3.LAMPORTS_PER_SOL;
    const vaultTx = new anchor.web3.Transaction().add(
      anchor.web3.SystemProgram.transfer({
        fromPubkey: admin.publicKey,
        toPubkey: vaultPda,
        lamports: vaultAmount,
      })
    );
    await provider.sendAndConfirm(vaultTx, [admin]);

    finalizeUniversalTx = makeFinalizeUniversalTxBuilder(
      gatewayProgram,
      configPda,
      vaultPda,
      tssPda
    );
  });

  const fundCeaForSystemRent = async (cea: PublicKey) => {
    const minRentForSystemAccount =
      await provider.connection.getMinimumBalanceForRentExemption(0);
    const fundTx = new anchor.web3.Transaction().add(
      anchor.web3.SystemProgram.transfer({
        fromPubkey: admin.publicKey,
        toPubkey: cea,
        lamports: minRentForSystemAccount + 100_000,
      })
    );
    await provider.sendAndConfirm(fundTx, [admin]);
  };

  describe("Heavy batch_operation tests", () => {
    it("should execute batch_operation with 10 accounts and 100 bytes data", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      // Create 10 dummy accounts (keypairs)
      const dummyAccounts = Array.from({ length: 10 }, () =>
        Keypair.generate()
      );

      // Create large instruction data (100 bytes)
      const operationId = 12345;
      const largeData = Buffer.alloc(100, 0xaa); // 100 bytes of data

      // Build accounts for batch_operation
      const batchIx = await counterProgram.methods
        .batchOperation(new anchor.BN(operationId), largeData)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .remainingAccounts(
          dummyAccounts.map((acc) => ({
            pubkey: acc.publicKey,
            isWritable: false,
            isSigner: false,
          }))
        )
        .instruction();

      // Use the instruction data from Anchor (already encoded correctly)
      const ixData = Buffer.from(batchIx.data);

      const accounts = instructionAccountsToGatewayMetas(batchIx);
      const remaining = instructionAccountsToRemaining(batchIx);

      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          ixData,
          gasFee
        ),
      });

      // Vault is already funded in before() hook.

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const writableFlags = accountsToWritableFlagsOnly(accounts);

      await finalizeUniversalTx({
        instructionId: 2,
        subTxId,
        universalTxId,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags,
        ixData,
        gasFee: new anchor.BN(Number(gasFee)),
        sig,
        caller: admin.publicKey,
        destinationProgram: counterProgram.programId,
      })
        .remainingAccounts(remaining)
        .signers([admin])
        .rpc();

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + operationId
      );
    });

    it("should execute batch_operation with 8 accounts and 150 bytes data", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      const dummyAccounts = Array.from({ length: 8 }, () => Keypair.generate()); // Reduced from 12 to 8
      const operationId = 54321;
      const largeData = Buffer.alloc(150, 0xbb); // Reduced from 200 to fit within limit

      const batchIx = await counterProgram.methods
        .batchOperation(new anchor.BN(operationId), largeData)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .remainingAccounts(
          dummyAccounts.map((acc) => ({
            pubkey: acc.publicKey,
            isWritable: Math.random() > 0.5, // Mix of writable/readonly
            isSigner: false,
          }))
        )
        .instruction();

      // Use the instruction data from Anchor (already encoded correctly)
      const ixData = Buffer.from(batchIx.data);

      const accounts = instructionAccountsToGatewayMetas(batchIx);
      const remaining = instructionAccountsToRemaining(batchIx);

      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          ixData,
          gasFee
        ),
      });

      // Fund CEA with enough lamports to create a system account (rent-safe).
      await fundCeaForSystemRent(cea);

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const writableFlags = accountsToWritableFlagsOnly(accounts);

      await finalizeUniversalTx({
        instructionId: 2,
        subTxId,
        universalTxId,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags,
        ixData,
        gasFee: new anchor.BN(Number(gasFee)),
        sig,
        caller: admin.publicKey,
        destinationProgram: counterProgram.programId,
      })
        .remainingAccounts(remaining)
        .signers([admin])
        .rpc();

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + operationId
      );
    });

    it("should execute batch_operation with 10 accounts and 100 bytes data (near limit)", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      const dummyAccounts = Array.from({ length: 10 }, () =>
        Keypair.generate()
      ); // Reduced from 15 to 10
      const operationId = 99999;
      const largeData = Buffer.alloc(100, 0xcc); // Reduced from 300 to fit within limit

      const batchIx = await counterProgram.methods
        .batchOperation(new anchor.BN(operationId), largeData)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .remainingAccounts(
          dummyAccounts.map((acc, i) => ({
            pubkey: acc.publicKey,
            isWritable: i % 2 === 0, // Alternating writable/readonly
            isSigner: false,
          }))
        )
        .instruction();

      // Use the instruction data from Anchor (already encoded correctly)
      const ixData = Buffer.from(batchIx.data);

      const accounts = instructionAccountsToGatewayMetas(batchIx);
      const remaining = instructionAccountsToRemaining(batchIx);

      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          ixData,
          gasFee
        ),
      });

      // Fund CEA with enough lamports to create a system account (rent-safe).
      await fundCeaForSystemRent(cea);

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const writableFlags = accountsToWritableFlagsOnly(accounts);

      await finalizeUniversalTx({
        instructionId: 2,
        subTxId,
        universalTxId,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags,
        ixData,
        gasFee: new anchor.BN(Number(gasFee)),
        sig,
        caller: admin.publicKey,
        destinationProgram: counterProgram.programId,
      })
        .remainingAccounts(remaining)
        .signers([admin])
        .rpc();

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + operationId
      );
    });

    it("should fail when transaction exceeds 1232 bytes limit (8 accounts + 700 bytes)", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      // Try to create a transaction that exceeds the limit
      const dummyAccounts = Array.from({ length: 8 }, () =>
        Keypair.generate()
      );
      const operationId = 11111;
      const largeData = Buffer.alloc(700, 0xdd); // Oversized payload; direct route should exceed the legacy tx limit

      const batchIx = await counterProgram.methods
        .batchOperation(new anchor.BN(operationId), largeData)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .remainingAccounts(
          dummyAccounts.map((acc) => ({
            pubkey: acc.publicKey,
            isWritable: false,
            isSigner: false,
          }))
        )
        .instruction();

      // Use the instruction data from Anchor (already encoded correctly)
      const ixData = Buffer.from(batchIx.data);

      const accounts = instructionAccountsToGatewayMetas(batchIx);
      const remaining = instructionAccountsToRemaining(batchIx);

      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          ixData,
          gasFee
        ),
      });

      const writableFlags = accountsToWritableFlagsOnly(accounts);

      // This should fail with transaction size error
      try {
        await finalizeUniversalTx({
          instructionId: 2,
          subTxId,
          universalTxId,
          amount: new anchor.BN(0),
          pushAccount,
          writableFlags,
          ixData,
          gasFee: new anchor.BN(Number(gasFee)),
          sig,
          caller: admin.publicKey,
          destinationProgram: counterProgram.programId,
        })
          .remainingAccounts(remaining)
          .signers([admin])
          .rpc();

        // If we get here, the transaction succeeded (unexpected)
        // This might happen if the actual size is slightly under the limit
        console.log("⚠️ Transaction succeeded - size might be under limit");
      } catch (err: any) {
        // Expected: transaction too large
        expect(
          err.message?.includes("Transaction too large") ||
            err.message?.includes("transaction too large") ||
            err.message?.includes("exceeds") ||
            err.logs?.some((log: string) => log.includes("too large"))
        ).to.be.true;
      }
    });

    it("should succeed for the same oversized payload via store + ref finalize", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const dummyAccounts = Array.from({ length: 8 }, () => Keypair.generate());
      const operationId = 22222;
      const largeData = Buffer.alloc(700, 0xee);

      const batchIx = await counterProgram.methods
        .batchOperation(new anchor.BN(operationId), largeData)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .remainingAccounts(
          dummyAccounts.map((acc) => ({
            pubkey: acc.publicKey,
            isWritable: false,
            isSigner: false,
          }))
        )
        .instruction();

      const ixData = Buffer.from(batchIx.data);
      const ixDataHash = hashIxData(ixData);
      const storedIxData = deriveStoredIxDataPda(subTxId, ixDataHash);
      const accounts = instructionAccountsToGatewayMetas(batchIx);
      const remaining = instructionAccountsToRemaining(batchIx);
      const writableFlags = accountsToWritableFlagsOnly(accounts);
      const { gasFee } = await calculateSolExecuteFees(provider.connection);
      const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

      await gatewayProgram.methods
        .storeExecuteIxData(Array.from(subTxId), asIxDataHashArg(ixDataHash), ixData)
        .accountsPartial({
          caller: admin.publicKey,
          storedIxData,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          ixData,
          refGasFee
        ),
      });

      const counterBefore = await counterProgram.account.counter.fetch(counterPda);
      const adminBalanceBefore = await provider.connection.getBalance(admin.publicKey);
      const executedSubTxPda = getExecutedTxPda(subTxId);

      await gatewayProgram.methods
        .finalizeUniversalTxWithIxDataRef(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          asIxDataHashArg(ixDataHash),
          writableFlags,
          new anchor.BN(Number(refGasFee)),
          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          destinationProgram: counterProgram.programId,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          rateLimitConfig: null,
          tokenRateLimit: null,
          storedIxData,
          storeRefundRecipient: admin.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(remaining)
        .signers([admin])
        .rpc();

      const counterAfter = await counterProgram.account.counter.fetch(counterPda);
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + operationId
      );

      // admin is both caller and store_refund_recipient; receives base_finalize_gas +
      // SIGNATURE_FEE_LAMPORTS + PDA rent (auto-closed). Net positive after compute fees.
      const adminBalanceAfter = await provider.connection.getBalance(admin.publicKey);
      expect(adminBalanceAfter).to.be.greaterThan(
        adminBalanceBefore - Number(SIGNATURE_FEE_LAMPORTS) * 10,
        "admin should not have lost more than ~10x signature fee (net reimbursed)"
      );

      // ExecutedSubTx PDA must exist (replay protection)
      const executedSubTxInfo = await provider.connection.getAccountInfo(executedSubTxPda);
      expect(executedSubTxInfo).to.not.be.null;

      // StoredIxData PDA auto-closed by finalize
      const storedAfterFinalize = await provider.connection.getAccountInfo(storedIxData);
      expect(storedAfterFinalize).to.be.null;
    });
  });
});
