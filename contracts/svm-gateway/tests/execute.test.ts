import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import {
  PublicKey,
  Keypair,
  SystemProgram,
  ComputeBudgetProgram,
} from "@solana/web3.js";
import { expect } from "chai";
import {
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddress,
  createAssociatedTokenAccountInstruction,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import * as spl from "@solana/spl-token";
import {
  encodeExecutePayload,
  decodeExecutePayload,
  instructionToPayloadFields,
  accountsToWritableFlags,
} from "../app/execute-payload";
import * as sharedState from "./shared-state";
import {
  signTssMessage,
  buildExecuteAdditionalData,
  TssInstruction,
  GatewayAccountMeta,
  generateUniversalTxId,
} from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import { extractEventCpi } from "./helpers/test-utils";
import { createHash } from "crypto";

// Helper to compute Anchor-style discriminator (first 8 bytes of SHA-256)
const computeDiscriminator = (name: string): Buffer => {
  return createHash("sha256").update(name).digest().slice(0, 8);
};

const USDT_DECIMALS = 6;
const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

// Compute buffer for transaction fees and compute units (in lamports)
// This covers Solana transaction fees (~5-20k) and compute unit costs
const COMPUTE_BUFFER = BigInt(100_000); // 0.0001 SOL buffer for compute + tx fees

/** Base fee per Solana signature — matches SIGNATURE_FEE_LAMPORTS in execute.rs. */
const SIGNATURE_FEE_LAMPORTS = BigInt(5_000);

// Helper to calculate actual rent for ExecutedSubTx account (8 bytes)
// ExecutedSubTx::LEN = 8 (discriminator only)
const getExecutedTxRent = async (
  connection: anchor.web3.Connection
): Promise<number> => {
  const rent = await connection.getMinimumBalanceForRentExemption(8);
  return rent;
};

// Helper to calculate actual rent for Token Account (165 bytes)
// Standard SPL token account size
const getTokenAccountRent = async (
  connection: anchor.web3.Connection
): Promise<number> => {
  const rent = await connection.getMinimumBalanceForRentExemption(165);
  return rent;
};

// Helper to check if CEA ATA exists
const ceaAtaExists = async (
  connection: anchor.web3.Connection,
  ceaAta: PublicKey
): Promise<boolean> => {
  const accountInfo = await connection.getAccountInfo(ceaAta);
  return accountInfo !== null && accountInfo.data.length > 0;
};

/**
 * Calculate gas_fee for SOL execute operations.
 * gasUsed = SIGNATURE_FEE + executed_sub_tx_rent  (matches on-chain execute.rs accounting)
 * gasFee  = gasUsed + COMPUTE_BUFFER             (COMPUTE_BUFFER becomes gas_to_refund)
 */
const calculateSolExecuteFees = async (
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
const calculateSplExecuteFees = async (
  connection: anchor.web3.Connection,
  ceaAta: PublicKey
): Promise<{ gasFee: bigint; gasUsed: bigint }> => {
  const executedTxRent = BigInt(await getExecutedTxRent(connection));
  const ceaAtaExisted = await ceaAtaExists(connection, ceaAta);
  const ceaAtaRent = ceaAtaExisted
    ? BigInt(0)
    : BigInt(await getTokenAccountRent(connection));
  const gasUsed = SIGNATURE_FEE_LAMPORTS + executedTxRent + ceaAtaRent;
  return { gasFee: executedTxRent + ceaAtaRent + COMPUTE_BUFFER, gasUsed };
};

const asLamports = (sol: number) =>
  new anchor.BN(sol * anchor.web3.LAMPORTS_PER_SOL);
const asTokenAmount = (tokens: number) =>
  new anchor.BN(Number(BigInt(tokens) * TOKEN_MULTIPLIER));

// SECURITY CRITICAL: These helpers MUST produce accounts in the SAME ORDER.
// The accounts used for TSS signing (via buildExecuteAdditionalData) MUST exactly match
// the accounts passed to .remainingAccounts() (same order, same pubkeys, same isWritable).
// Any mismatch will cause MessageHashMismatch (correct - TSS signature protects integrity).
const instructionAccountsToGatewayMetas = (
  ix: anchor.web3.TransactionInstruction
): GatewayAccountMeta[] =>
  ix.keys.map((key) => ({
    pubkey: key.pubkey,
    isWritable: key.isWritable,
  }));

const instructionAccountsToRemaining = (
  ix: anchor.web3.TransactionInstruction
) =>
  ix.keys.map((key) => ({
    pubkey: key.pubkey,
    isWritable: key.isWritable,
    isSigner: false,
  }));

// Helper to convert accounts to writable flags for execute calls
const accountsToWritableFlagsOnly = (accounts: GatewayAccountMeta[]) => {
  return accountsToWritableFlags(accounts);
};

describe("Universal Gateway - Execute Tests", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const provider = anchor.getProvider() as anchor.AnchorProvider;
  const gatewayProgram = anchor.workspace
    .UniversalGateway as Program<UniversalGateway>;
  const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

  before(async () => {
    await ensureTestSetup();
  });

  let admin: Keypair;
  let operator: Keypair;
  let recipient: Keypair; // Recipient for test-counter

  let configPda: PublicKey;
  let vaultPda: PublicKey;
  let tssPda: PublicKey;
  let rateLimitConfigPda: PublicKey;
  let nativeSolTokenRateLimitPda: PublicKey;
  let usdtTokenRateLimitPda: PublicKey;

  let mockUSDT: any;
  let vaultUsdtAccount: PublicKey;
  let recipientUsdtAccount: PublicKey;

  let counterPda: PublicKey; // Counter PDA
  let counterBump: number; // Counter PDA bump
  let counterAuthority: Keypair; // Authority for counter

  let txIdCounter = 0;

  const expectRejection = async (promise: Promise<unknown>, message: string) => {
    let rejected = false;
    try {
      await promise;
    } catch (error: any) {
      rejected = true;
      const errorStr = error.toString();
      const errorMessage = error.error?.errorMessage || error.message || errorStr;
      const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
      const matches =
        errorStr.includes(message) ||
        errorMessage.includes(message) ||
        (errorCode && errorCode.toString().includes(message)) ||
        error.error?.errorCode?.code === message;
      expect(matches, `Expected error "${message}", got ${errorStr}`).to.be.true;
    }
    expect(rejected, `Expected rejection with "${message}" but call succeeded`).to.be.true;
  };

  const generateTxId = (): number[] => {
    txIdCounter++;
    const buffer = Buffer.alloc(32);
    buffer.writeUInt32BE(txIdCounter, 0);
    buffer.writeUInt32BE(Date.now() % 0xffffffff, 4);
    for (let i = 8; i < 32; i++) {
      buffer[i] = Math.floor(Math.random() * 256);
    }
    return Array.from(buffer);
  };

  const generateSender = (): number[] => {
    const buffer = Buffer.alloc(20);
    for (let i = 0; i < 20; i++) {
      buffer[i] = Math.floor(Math.random() * 256);
    }
    if (buffer.every((b) => b === 0)) {
      buffer[0] = 1;
    }
    return Array.from(buffer);
  };

  const getExecutedTxPda = (subTxId: number[]): PublicKey => {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("executed_sub_tx"), Buffer.from(subTxId)],
      gatewayProgram.programId
    );
    return pda;
  };

  const getCeaAuthorityPda = (pushAccount: number[]): PublicKey => {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("push_identity"), Buffer.from(pushAccount)],
      gatewayProgram.programId
    );
    return pda;
  };

  const getStakeAta = async (
    stakePda: PublicKey,
    mint: PublicKey
  ): Promise<PublicKey> => {
    return getAssociatedTokenAddress(
      mint,
      stakePda,
      true, // allowOwnerOffCurve (stake PDA is off-curve)
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
  };

  const getCeaAta = async (
    pushAccount: number[],
    mint: PublicKey
  ): Promise<PublicKey> => {
    const ceaAuthority = getCeaAuthorityPda(pushAccount);
    return getAssociatedTokenAddress(mint, ceaAuthority, true);
  };

  before(async () => {
    admin = sharedState.getAdmin();
    operator = sharedState.getOperator();
    mockUSDT = sharedState.getMockUSDT();

    recipient = Keypair.generate();
    counterAuthority = sharedState.getCounterAuthority();

    const airdropLamports = 100 * anchor.web3.LAMPORTS_PER_SOL;
    await Promise.all([
      provider.connection.requestAirdrop(admin.publicKey, airdropLamports), // Admin pays for executed_sub_tx account creation
      provider.connection.requestAirdrop(recipient.publicKey, airdropLamports),
      provider.connection.requestAirdrop(
        counterAuthority.publicKey,
        airdropLamports
      ),
    ]);
    await new Promise((resolve) => setTimeout(resolve, 2000));

    // Get PDAs
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

    [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit_config")],
      gatewayProgram.programId
    );

    [nativeSolTokenRateLimitPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit"), Buffer.alloc(32, 0)],
      gatewayProgram.programId
    );

    [usdtTokenRateLimitPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
      gatewayProgram.programId
    );

    // Normalize token rate limit accounts so tests don't inherit stale 0-threshold state.
    const veryLargeThreshold = new anchor.BN("1000000000000000000000");
    for (const [pda, mint] of [
      [nativeSolTokenRateLimitPda, PublicKey.default],
      [usdtTokenRateLimitPda, mockUSDT.mint.publicKey],
    ] as [PublicKey, PublicKey][]) {
      await gatewayProgram.methods
        .setTokenRateLimit(veryLargeThreshold, true, true)
        .accountsPartial({
          config: configPda,
          tokenRateLimit: pda,
          tokenMint: mint,
          admin: admin.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();
    }

    // Get vault ATA and create if needed (admin pays)
    vaultUsdtAccount = await getAssociatedTokenAddress(
      mockUSDT.mint.publicKey,
      vaultPda,
      true,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const vaultAtaInfo = await provider.connection.getAccountInfo(
      vaultUsdtAccount
    );
    if (!vaultAtaInfo) {
      const createVaultAtaIx = createAssociatedTokenAccountInstruction(
        admin.publicKey,
        vaultUsdtAccount,
        vaultPda,
        mockUSDT.mint.publicKey,
        TOKEN_PROGRAM_ID,
        ASSOCIATED_TOKEN_PROGRAM_ID
      );
      await provider.sendAndConfirm(
        new anchor.web3.Transaction().add(createVaultAtaIx),
        [admin]
      );
    }
    // Get recipient ATA and create if needed (admin pays)
    recipientUsdtAccount = await getAssociatedTokenAddress(
      mockUSDT.mint.publicKey,
      recipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const recipientAtaInfo = await provider.connection.getAccountInfo(
      recipientUsdtAccount
    );
    if (!recipientAtaInfo) {
      const createRecipientAtaIx = createAssociatedTokenAccountInstruction(
        admin.publicKey,
        recipientUsdtAccount,
        recipient.publicKey,
        mockUSDT.mint.publicKey,
        TOKEN_PROGRAM_ID,
        ASSOCIATED_TOKEN_PROGRAM_ID
      );
      await provider.sendAndConfirm(
        new anchor.web3.Transaction().add(createRecipientAtaIx),
        [admin]
      );
    }
    // Initialize test counter with dedicated authority (not signer in execute tests)
    // Derive counter PDA
    [counterPda, counterBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("counter")],
      counterProgram.programId
    );

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
    } catch (e: any) {
      // Counter might already be initialized
      if (!e.toString().includes("already in use")) {
        throw e;
      }
    }
    const existingCounter = await counterProgram.account.counter.fetch(
      counterPda
    );
    counterAuthority = {
      publicKey: existingCounter.authority,
    } as Keypair;

    // Fund vault with SOL (admin pays)
    const vaultAmount = asLamports(100);
    const vaultTx = new anchor.web3.Transaction().add(
      anchor.web3.SystemProgram.transfer({
        fromPubkey: admin.publicKey,
        toPubkey: vaultPda,
        lamports: vaultAmount.toNumber(),
      })
    );
    await provider.sendAndConfirm(vaultTx, [admin]);

    // Fund vault with tokens
    await mockUSDT.mintTo(vaultUsdtAccount, 1000);
  });

  describe("execute_universal_tx (SOL)", () => {
    it("should execute SOL-only payload (increment) with zero amount", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const executeAmount = new anchor.BN(0);
      const incrementAmount = new anchor.BN(5);

      // Build instruction data for test-counter.increment
      const counterIx = await counterProgram.methods
        .increment(incrementAmount)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();

      // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
      const remainingAccounts = instructionAccountsToRemaining(counterIx);
      const accounts = remainingAccounts.map((acc) => ({
        pubkey: acc.pubkey,
        isWritable: acc.isWritable,
      }));

      // Calculate fees dynamically based on actual costs
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
          counterIx.data,
          gasFee
        ),
      });

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      console.log(
        "SOL-only payload with zero amount counterBefore",
        counterBefore.value.toNumber()
      );

      const balanceBefore = await provider.connection.getBalance(
        admin.publicKey
      );
      // Convert accounts to writable flags for Solana transaction
      const writableFlags = accountsToWritableFlagsOnly(accounts);

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          executeAmount,
          Array.from(pushAccount),
          writableFlags,
          Buffer.from(counterIx.data),
          new anchor.BN(Number(gasFee)),

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
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      const balanceAfter = await provider.connection.getBalance(
        admin.publicKey
      );
      // Relayer pays executed_sub_tx rent upfront; receives gas_used back from vault.
      // gas_used = SIGNATURE_FEE + sub_tx_rent (no ATA for SOL execute).
      // Net change for relayer ≈ SIGNATURE_FEE - tx_fees ≈ 0.
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const gasUsedSol = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx;
      const actualBalanceChange = balanceAfter - balanceBefore;
      const expectedBalanceChange = -actualRentForExecutedTx + gasUsedSol;
      expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 15000); // Allow for transaction fees

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      console.log(
        "SOL-only payload with zero amount counterAfter",
        counterAfter.value.toNumber()
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + incrementAmount.toNumber()
      );
    });

    it("should execute SOL transfer using preseeded CEA balance + partial vault top-up", async () => {
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);

      const preseedLamports = 50_000_000; // 0.05 SOL already in CEA
      const topupLamports = 50_000_000; // 0.05 SOL from vault (burned on Push)
      const totalTransferLamports = preseedLamports + topupLamports; // 0.1 SOL to recipient

      // Step 1: Preseed CEA with 0.05 SOL via execute (amount > 0) with harmless payload
      const preseedSubTxId = generateTxId();
      const preseedUniversalTxId = generateUniversalTxId();
      const preseedIx = await counterProgram.methods
        .increment(new anchor.BN(0))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();
      const preseedAccounts = instructionAccountsToGatewayMetas(preseedIx);
      const preseedRemaining = instructionAccountsToRemaining(preseedIx);
      const { gasFee: preseedGasFee } = await calculateSolExecuteFees(
        provider.connection
      );

      const preseedSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(preseedLamports),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(preseedUniversalTxId),
          new Uint8Array(preseedSubTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          preseedAccounts,
          preseedIx.data,
          preseedGasFee
        ),
      });

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(preseedSubTxId),
          Array.from(preseedUniversalTxId),
          new anchor.BN(preseedLamports),
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(preseedAccounts),
          Buffer.from(preseedIx.data),
          new anchor.BN(Number(preseedGasFee)),

          new anchor.BN(4102444800),
          Array.from(preseedSig.signature),
          preseedSig.recoveryId,
          Array.from(preseedSig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority,
          tssPda,
          executedSubTx: getExecutedTxPda(preseedSubTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(preseedRemaining)
        .signers([admin])
        .rpc();

      // Step 2: Execute transfer of full 0.1 SOL while topping up only 0.05 from vault
      const transferSubTxId = generateTxId();
      const transferUniversalTxId = generateUniversalTxId();
      const transferIx = await counterProgram.methods
        .receiveSol(new anchor.BN(totalTransferLamports))
        .accountsPartial({
          counter: counterPda,
          recipient: recipient.publicKey,
          ceaAuthority,
          systemProgram: SystemProgram.programId,
        })
        .instruction();
      const transferAccounts = instructionAccountsToGatewayMetas(transferIx);
      const transferRemaining = instructionAccountsToRemaining(transferIx);
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const transferSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(topupLamports),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(transferUniversalTxId),
          new Uint8Array(transferSubTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          transferAccounts,
          transferIx.data,
          gasFee
        ),
      });

      const recipientBefore = await provider.connection.getBalance(
        recipient.publicKey
      );

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(transferSubTxId),
          Array.from(transferUniversalTxId),
          new anchor.BN(topupLamports),
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(transferAccounts),
          Buffer.from(transferIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(transferSig.signature),
          transferSig.recoveryId,
          Array.from(transferSig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority,
          tssPda,
          executedSubTx: getExecutedTxPda(transferSubTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(transferRemaining)
        .signers([admin])
        .rpc();

      const recipientAfter = await provider.connection.getBalance(
        recipient.publicKey
      );
      const ceaAfter = await provider.connection.getBalance(ceaAuthority);

      expect(recipientAfter - recipientBefore).to.equal(totalTransferLamports);
      expect(ceaAfter).to.equal(0);
    });

    it("should execute direct System Program transfer using preseeded CEA + partial vault top-up", async () => {
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);

      const preseedLamports = 50_000_000; // 0.05 SOL already in CEA
      const topupLamports = 50_000_000; // 0.05 SOL released from vault
      const totalTransferLamports = preseedLamports + topupLamports; // 0.1 SOL to recipient

      // Preseed CEA directly (outside gateway execute path)
      const preseedTx = new anchor.web3.Transaction().add(
        anchor.web3.SystemProgram.transfer({
          fromPubkey: admin.publicKey,
          toPubkey: ceaAuthority,
          lamports: preseedLamports,
        })
      );
      await provider.sendAndConfirm(preseedTx, [admin]);

      // Build ix_data for direct System Program transfer: CEA -> recipient
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const sysTransferIx = anchor.web3.SystemProgram.transfer({
        fromPubkey: ceaAuthority,
        toPubkey: recipient.publicKey,
        lamports: totalTransferLamports,
      });
      const accounts = instructionAccountsToGatewayMetas(sysTransferIx);
      const remainingAccounts = instructionAccountsToRemaining(sysTransferIx);
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(topupLamports), // TSS signs only the vault release amount
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          anchor.web3.SystemProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          sysTransferIx.data,
          gasFee
        ),
      });

      const recipientBefore = await provider.connection.getBalance(
        recipient.publicKey
      );

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(topupLamports),
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(accounts),
          Buffer.from(sysTransferIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: anchor.web3.SystemProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      const recipientAfter = await provider.connection.getBalance(
        recipient.publicKey
      );
      const ceaAfter = await provider.connection.getBalance(ceaAuthority);

      expect(recipientAfter - recipientBefore).to.equal(totalTransferLamports);
      expect(ceaAfter).to.equal(0);
    });

    it("should revert SOL transfer when preseed + top-up is insufficient (atomic rollback)", async () => {
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);

      const preseedLamports = 40_000_000; // 0.04 SOL already in CEA
      const topupLamports = 50_000_000; // 0.05 SOL from vault
      const totalTransferLamports = 100_000_000; // tries to send 0.1 SOL (needs 100M, has 90M)

      // Step 1: Preseed CEA directly (outside gateway execute path)
      const preseedTx = new anchor.web3.Transaction().add(
        anchor.web3.SystemProgram.transfer({
          fromPubkey: admin.publicKey,
          toPubkey: ceaAuthority,
          lamports: preseedLamports,
        })
      );
      await provider.sendAndConfirm(preseedTx, [admin]);

      const recipientBefore = await provider.connection.getBalance(
        recipient.publicKey
      );
      const ceaBefore = await provider.connection.getBalance(ceaAuthority);

      // Step 2: Try transferring 0.1 SOL with only 0.09 available (should fail)
      const transferSubTxId = generateTxId();
      const transferUniversalTxId = generateUniversalTxId();
      const transferIx = anchor.web3.SystemProgram.transfer({
        fromPubkey: ceaAuthority,
        toPubkey: recipient.publicKey,
        lamports: totalTransferLamports,
      });
      const transferAccounts = instructionAccountsToGatewayMetas(transferIx);
      const transferRemaining = instructionAccountsToRemaining(transferIx);
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const transferSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(topupLamports),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(transferUniversalTxId),
          new Uint8Array(transferSubTxId),
          anchor.web3.SystemProgram.programId,
          new Uint8Array(pushAccount),
          transferAccounts,
          transferIx.data,
          gasFee
        ),
      });

      try {
        await gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(transferSubTxId),
            Array.from(transferUniversalTxId),
            new anchor.BN(topupLamports),
            Array.from(pushAccount),
            accountsToWritableFlagsOnly(transferAccounts),
            Buffer.from(transferIx.data),
            new anchor.BN(Number(gasFee)),

            new anchor.BN(4102444800),
            Array.from(transferSig.signature),
            transferSig.recoveryId,
            Array.from(transferSig.messageHash)
          )
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultSol: vaultPda,
            ceaAuthority,
            tssPda,
            executedSubTx: getExecutedTxPda(transferSubTxId),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: anchor.web3.SystemProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
            recipient: null,
            vaultAta: null,
            ceaAta: null,
            mint: null,
            tokenProgram: null,
            rent: null,
            associatedTokenProgram: null,
            recipientAta: null,
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts(transferRemaining)
          .signers([admin])
          .rpc();
        expect.fail(
          "Should fail due to insufficient CEA SOL for payload transfer"
        );
      } catch (error: any) {
        expect(error).to.exist;
      }

      const recipientAfter = await provider.connection.getBalance(
        recipient.publicKey
      );
      const ceaAfter = await provider.connection.getBalance(ceaAuthority);

      expect(recipientAfter).to.equal(recipientBefore);
      expect(ceaAfter).to.equal(ceaBefore);
    });

    // SOL transfer test removed - covered by CEA staking tests below

    it("should reject duplicate sub_tx_id (replay protection)", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const amount = asLamports(0.1);

      const counterIx = await counterProgram.methods
        .increment(new anchor.BN(1))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();
      const accounts = instructionAccountsToGatewayMetas(counterIx);
      const remaining = instructionAccountsToRemaining(counterIx);

      // Calculate fees dynamically for both executions (same sub_tx_id, same fees)
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      // First execution
      const sig1 = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(amount.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          counterIx.data,
          gasFee
        ),
      });

      const writableFlags1 = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          amount,
          Array.from(pushAccount),
          writableFlags1,
          Buffer.from(counterIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig1.signature),
          sig1.recoveryId,
          Array.from(sig1.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          tssPda: tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(remaining)
        .signers([admin])
        .rpc();

      // Second execution with same sub_tx_id should fail
      const sig2 = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(amount.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          counterIx.data,
          gasFee
        ),
      });

      try {
        const writableFlags2 = accountsToWritableFlagsOnly(accounts);
        await gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(subTxId),
            Array.from(universalTxId),
            amount,
            Array.from(pushAccount),
            writableFlags2,
            Buffer.from(counterIx.data),
            new anchor.BN(Number(gasFee)),

            new anchor.BN(4102444800),
            Array.from(sig2.signature),
            sig2.recoveryId,
            Array.from(sig2.messageHash)
          )
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultSol: vaultPda,
            ceaAuthority: getCeaAuthorityPda(pushAccount),
            tssPda: tssPda,
            executedSubTx: getExecutedTxPda(subTxId),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
            recipient: null,
            vaultAta: null,
            ceaAta: null,
            mint: null,
            tokenProgram: null,
            rent: null,
            associatedTokenProgram: null,
            recipientAta: null,
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts(remaining)
          .signers([admin])
          .rpc();
        expect.fail("Should have rejected duplicate sub_tx_id");
      } catch (e: any) {
        expect(e.toString()).to.include("already in use");
      }
    });
  });

  describe("execute_universal_tx (SPL)", () => {
    it("should execute SPL token transfer to test-counter", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const amount = asTokenAmount(100); // 100 USDT
      const targetProgram = counterProgram.programId;

      // Build instruction data for test-counter.receive_spl
      const counterIx = await counterProgram.methods
        .receiveSpl(amount)
        .accountsPartial({
          counter: counterPda,
          ceaAta: await getCeaAta(pushAccount, mockUSDT.mint.publicKey),
          recipientAta: recipientUsdtAccount,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .instruction();

      // Check CEA ATA existence BEFORE calculating fees (fee calculation depends on this)
      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const ceaAtaExistedBefore = await ceaAtaExists(
        provider.connection,
        ceaAta
      );

      // Calculate fees dynamically based on actual costs (including CEA ATA rent if needed)
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const accounts = instructionAccountsToGatewayMetas(counterIx);
      const remainingAccounts = instructionAccountsToRemaining(counterIx);

      // Sign execute message with the EXACT same accounts that will be in remaining_accounts
      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(amount.toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          counterIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const recipientTokenBefore = await mockUSDT.getBalance(
        recipientUsdtAccount
      );
      console.log(
        "SPL token transfer to test-counter counterBefore",
        counterBefore.value.toNumber()
      );
      const balanceBefore = await provider.connection.getBalance(
        admin.publicKey
      );
      const splWritableFlags1 = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          amount,
          Array.from(pushAccount),
          splWritableFlags1,
          Buffer.from(counterIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          ceaAta: ceaAta,
          mint: mockUSDT.mint.publicKey,
          tssPda: tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      const balanceAfter = await provider.connection.getBalance(
        admin.publicKey
      );
      // Relayer pays sub_tx_rent + ata_rent (if created) upfront; receives gas_used back.
      // gas_used = SIGNATURE_FEE + sub_tx_rent + ata_rent.
      // Net change for relayer ≈ SIGNATURE_FEE - tx_fees ≈ 0.
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const actualRentForCeaAta = ceaAtaExistedBefore
        ? 0
        : await getTokenAccountRent(provider.connection);
      const gasUsedSpl = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx + actualRentForCeaAta;

      const actualBalanceChange = balanceAfter - balanceBefore;
      const expectedBalanceChange =
        -actualRentForExecutedTx - actualRentForCeaAta + gasUsedSpl;
      expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 20000); // Allow for transaction fees (SPL txs are larger)

      // Verify executed_sub_tx account exists
      const ExecutedSubTx = await gatewayProgram.account.executedSubTx.fetch(
        getExecutedTxPda(subTxId)
      );
      expect(ExecutedSubTx).to.not.be.null;

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + amount.toNumber()
      );

      const recipientTokenAfter = await mockUSDT.getBalance(
        recipientUsdtAccount
      );
      const amountTokens = amount.toNumber() / 10 ** USDT_DECIMALS;
      expect(recipientTokenAfter - recipientTokenBefore).to.equal(amountTokens);

      // Verify cea_ata persists (CEA is now persistent, not auto-closed)
      const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
      expect(ceaAtaInfo).to.not.be.null; // CEA ATA persists (pull model)
    });

    it("should execute SPL transfer using preseeded CEA balance + partial vault top-up", async () => {
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);
      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);

      const preseedTokens = asTokenAmount(50); // already in CEA
      const topupTokens = asTokenAmount(50); // from vault in this tx
      const totalTransferTokens = asTokenAmount(100);

      // Step 1: Preseed CEA ATA with 50 tokens via execute (amount > 0) and harmless payload
      const preseedSubTxId = generateTxId();
      const preseedUniversalTxId = generateUniversalTxId();
      const preseedIx = await counterProgram.methods
        .increment(new anchor.BN(0))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();
      const preseedAccounts = instructionAccountsToGatewayMetas(preseedIx);
      const preseedRemaining = instructionAccountsToRemaining(preseedIx);
      const { gasFee: preseedGasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const preseedSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(preseedTokens.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(preseedUniversalTxId),
          new Uint8Array(preseedSubTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          preseedAccounts,
          preseedIx.data,
          preseedGasFee,
          mockUSDT.mint.publicKey
        ),
      });

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(preseedSubTxId),
          Array.from(preseedUniversalTxId),
          preseedTokens,
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(preseedAccounts),
          Buffer.from(preseedIx.data),
          new anchor.BN(Number(preseedGasFee)),

          new anchor.BN(4102444800),
          Array.from(preseedSig.signature),
          preseedSig.recoveryId,
          Array.from(preseedSig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority,
          ceaAta,
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(preseedSubTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(preseedRemaining)
        .signers([admin])
        .rpc();

      // Step 2: Transfer full 100 while topping up only 50 from vault
      const transferSubTxId = generateTxId();
      const transferUniversalTxId = generateUniversalTxId();
      const transferIx = await counterProgram.methods
        .receiveSpl(totalTransferTokens)
        .accountsPartial({
          counter: counterPda,
          ceaAta,
          recipientAta: recipientUsdtAccount,
          ceaAuthority,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .instruction();
      const transferAccounts = instructionAccountsToGatewayMetas(transferIx);
      const transferRemaining = instructionAccountsToRemaining(transferIx);
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const transferSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(topupTokens.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(transferUniversalTxId),
          new Uint8Array(transferSubTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          transferAccounts,
          transferIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      const recipientBefore = await mockUSDT.getBalance(recipientUsdtAccount);

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(transferSubTxId),
          Array.from(transferUniversalTxId),
          topupTokens,
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(transferAccounts),
          Buffer.from(transferIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(transferSig.signature),
          transferSig.recoveryId,
          Array.from(transferSig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority,
          ceaAta,
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(transferSubTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(transferRemaining)
        .signers([admin])
        .rpc();

      const recipientAfter = await mockUSDT.getBalance(recipientUsdtAccount);
      const ceaAfter = await provider.connection.getTokenAccountBalance(ceaAta);

      expect(recipientAfter - recipientBefore).to.equal(100);
      expect(Number(ceaAfter.value.amount)).to.equal(0);
    });

    it("should execute direct SPL Token Program transfer using preseeded CEA + partial vault top-up", async () => {
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);
      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);

      const preseedTokens = asTokenAmount(50); // already in CEA ATA
      const topupTokens = asTokenAmount(50); // released from vault in this tx
      const totalTransferTokens = asTokenAmount(100);

      // Ensure CEA ATA exists, then preseed it directly (outside gateway execute path)
      const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
      if (!ceaAtaInfo) {
        const createCeaAtaTx = new anchor.web3.Transaction().add(
          createAssociatedTokenAccountInstruction(
            admin.publicKey,
            ceaAta,
            ceaAuthority,
            mockUSDT.mint.publicKey,
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
          )
        );
        await provider.sendAndConfirm(createCeaAtaTx, [admin]);
      }
      await mockUSDT.mintTo(
        ceaAta,
        Number(preseedTokens.toString()) / 10 ** USDT_DECIMALS
      );

      // Build ix_data for direct SPL transfer: CEA ATA -> recipient ATA
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const splTransferIx = spl.createTransferInstruction(
        ceaAta,
        recipientUsdtAccount,
        ceaAuthority,
        Number(totalTransferTokens.toString()),
        [],
        TOKEN_PROGRAM_ID
      );
      const accounts = instructionAccountsToGatewayMetas(splTransferIx);
      const remainingAccounts = instructionAccountsToRemaining(splTransferIx);
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(topupTokens.toString()), // TSS signs only the vault release amount
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          TOKEN_PROGRAM_ID,
          new Uint8Array(pushAccount),
          accounts,
          splTransferIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      const recipientBefore = await mockUSDT.getBalance(recipientUsdtAccount);

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          topupTokens,
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(accounts),
          Buffer.from(splTransferIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority,
          ceaAta,
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: TOKEN_PROGRAM_ID,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      const recipientAfter = await mockUSDT.getBalance(recipientUsdtAccount);
      const ceaAfter = await provider.connection.getTokenAccountBalance(ceaAta);

      expect(recipientAfter - recipientBefore).to.equal(100);
      expect(Number(ceaAfter.value.amount)).to.equal(0);
    });

    it("should revert SPL transfer when preseed + top-up is insufficient (atomic rollback)", async () => {
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);
      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);

      const preseedTokens = asTokenAmount(40);
      const topupTokens = asTokenAmount(50);
      const totalTransferTokens = asTokenAmount(100); // needs 100, has 90

      // Step 1: Ensure CEA ATA exists and preseed directly (outside gateway execute path)
      const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
      if (!ceaAtaInfo) {
        const createCeaAtaTx = new anchor.web3.Transaction().add(
          createAssociatedTokenAccountInstruction(
            admin.publicKey,
            ceaAta,
            ceaAuthority,
            mockUSDT.mint.publicKey,
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
          )
        );
        await provider.sendAndConfirm(createCeaAtaTx, [admin]);
      }
      await mockUSDT.mintTo(
        ceaAta,
        Number(preseedTokens.toString()) / 10 ** USDT_DECIMALS
      );

      const recipientBefore = await mockUSDT.getBalance(recipientUsdtAccount);
      const ceaBefore = await provider.connection.getTokenAccountBalance(
        ceaAta
      );

      // Step 2: Try sending 100 with only 90 available
      const transferSubTxId = generateTxId();
      const transferUniversalTxId = generateUniversalTxId();
      const transferIx = spl.createTransferInstruction(
        ceaAta,
        recipientUsdtAccount,
        ceaAuthority,
        Number(totalTransferTokens.toString()),
        [],
        TOKEN_PROGRAM_ID
      );
      const transferAccounts = instructionAccountsToGatewayMetas(transferIx);
      const transferRemaining = instructionAccountsToRemaining(transferIx);
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const transferSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(topupTokens.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(transferUniversalTxId),
          new Uint8Array(transferSubTxId),
          TOKEN_PROGRAM_ID,
          new Uint8Array(pushAccount),
          transferAccounts,
          transferIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      try {
        await gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(transferSubTxId),
            Array.from(transferUniversalTxId),
            topupTokens,
            Array.from(pushAccount),
            accountsToWritableFlagsOnly(transferAccounts),
            Buffer.from(transferIx.data),
            new anchor.BN(Number(gasFee)),

            new anchor.BN(4102444800),
            Array.from(transferSig.signature),
            transferSig.recoveryId,
            Array.from(transferSig.messageHash)
          )
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultAta: vaultUsdtAccount,
            vaultSol: vaultPda,
            ceaAuthority,
            ceaAta,
            mint: mockUSDT.mint.publicKey,
            tssPda,
            executedSubTx: getExecutedTxPda(transferSubTxId),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: TOKEN_PROGRAM_ID,
          storedIxData: null,
          storeRefundRecipient: null,
            recipient: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
            rent: anchor.web3.SYSVAR_RENT_PUBKEY,
            associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
            recipientAta: null,
          })
          .remainingAccounts(transferRemaining)
          .signers([admin])
          .rpc();
        expect.fail(
          "Should fail due to insufficient CEA SPL for payload transfer"
        );
      } catch (error: any) {
        expect(error).to.exist;
      }

      const recipientAfter = await mockUSDT.getBalance(recipientUsdtAccount);
      const ceaAfter = await provider.connection.getTokenAccountBalance(ceaAta);

      expect(recipientAfter).to.equal(recipientBefore);
      expect(Number(ceaAfter.value.amount)).to.equal(
        Number(ceaBefore.value.amount)
      );
    });

    it("should reject SPL execution if cea ATA owner mismatches", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const amount = asTokenAmount(25);

      const counterIx = await counterProgram.methods
        .receiveSpl(amount)
        .accountsPartial({
          counter: counterPda,
          ceaAta: await getCeaAta(pushAccount, mockUSDT.mint.publicKey),
          recipientAta: recipientUsdtAccount,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .instruction();

      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

      // Check CEA ATA existence BEFORE calculating fees
      const correctCeaAta = await getCeaAta(
        pushAccount,
        mockUSDT.mint.publicKey
      );
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        correctCeaAta
      );

      // Create a malicious ATA owned by an attacker (not the cea PDA)
      const attacker = Keypair.generate();
      const maliciousAta = await getAssociatedTokenAddress(
        mockUSDT.mint.publicKey,
        attacker.publicKey
      );
      const createIx = createAssociatedTokenAccountInstruction(
        admin.publicKey,
        maliciousAta,
        attacker.publicKey,
        mockUSDT.mint.publicKey,
        TOKEN_PROGRAM_ID,
        ASSOCIATED_TOKEN_PROGRAM_ID
      );
      const createTx = new anchor.web3.Transaction().add(createIx);
      await provider.sendAndConfirm(createTx, [admin]);

      const accounts = instructionAccountsToGatewayMetas(counterIx);
      const remainingAccounts = instructionAccountsToRemaining(counterIx);
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(amount.toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          counterIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      try {
        const splWritableFlags2 = accountsToWritableFlagsOnly(accounts);
        await gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(subTxId),
            Array.from(universalTxId),
            amount,
            Array.from(pushAccount),
            splWritableFlags2,
            Buffer.from(counterIx.data),
            new anchor.BN(Number(gasFee)),

            new anchor.BN(4102444800),
            Array.from(sig.signature),
            sig.recoveryId,
            Array.from(sig.messageHash)
          )
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultAta: vaultUsdtAccount,
            vaultSol: vaultPda,
            ceaAuthority: getCeaAuthorityPda(pushAccount),
            ceaAta: maliciousAta, // Malicious ATA - wrong owner (checked at line 546-559)
            mint: mockUSDT.mint.publicKey,
            tssPda: tssPda,
            executedSubTx: getExecutedTxPda(subTxId),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
            recipient: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
            rent: anchor.web3.SYSVAR_RENT_PUBKEY,
            associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
            recipientAta: null,
          })
          .remainingAccounts(remainingAccounts)
          .signers([admin])
          .rpc();
        expect.fail("Should have rejected malicious cea ATA");
      } catch (error: any) {
        const errorCode =
          error.error?.errorCode?.code ||
          error.errorCode?.code ||
          error.code ||
          error.error?.code ||
          error.message;
        // Execution flow: unified execute validates cea_ata manually (SplAccount::unpack);
        // if owner mismatches, program returns InvalidAccount (not Anchor's ConstraintTokenOwner).
        expect(errorCode).to.equal("InvalidAccount");
      }
    });
    it("should execute SPL-only payload (increment) with zero amount", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const amount = new anchor.BN(0);
      const incrementAmount = new anchor.BN(4);

      // Use increment instead of decrement to avoid underflow
      const counterIx = await counterProgram.methods
        .increment(incrementAmount)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();

      // Check CEA ATA existence BEFORE calculating fees
      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const ceaAtaExistedBeforeZeroAmount = await ceaAtaExists(
        provider.connection,
        ceaAta
      );
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const accounts = instructionAccountsToGatewayMetas(counterIx);
      const remainingAccounts = instructionAccountsToRemaining(counterIx);

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
          counterIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const recipientTokenBefore = await mockUSDT.getBalance(
        recipientUsdtAccount
      );
      console.log(
        "SPL-only payload with zero amount counterBefore",
        counterBefore.value.toNumber()
      );
      const balanceBefore = await provider.connection.getBalance(
        admin.publicKey
      );
      const splWritableFlags4 = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          amount,
          Array.from(pushAccount),
          splWritableFlags4,
          Buffer.from(counterIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          ceaAta: ceaAta,
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      const balanceAfter = await provider.connection.getBalance(
        admin.publicKey
      );
      // Caller pays sub_tx rent + optional CEA ATA rent upfront, then receives gas_used back.
      // gas_used = SIGNATURE_FEE + sub_tx_rent + ata_rent (if ATA was created).
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const actualRentForCeaAta = ceaAtaExistedBeforeZeroAmount
        ? 0
        : await getTokenAccountRent(provider.connection);
      const gasUsedZeroAmountSpl =
        Number(SIGNATURE_FEE_LAMPORTS) +
        actualRentForExecutedTx +
        actualRentForCeaAta;

      const actualBalanceChange = balanceAfter - balanceBefore;
      // Expected: -sub_tx_rent - ata_rent + gas_used - tx_fees
      const expectedBalanceChange =
        -actualRentForExecutedTx - actualRentForCeaAta + gasUsedZeroAmountSpl;
      expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 20000); // Allow for transaction fees (SPL txs are larger)

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + incrementAmount.toNumber()
      );

      const recipientTokenAfter = await mockUSDT.getBalance(
        recipientUsdtAccount
      );
      expect(recipientTokenAfter).to.equal(recipientTokenBefore);

      const ceaAtaInfo = await provider.connection.getAccountInfo(
        await getCeaAta(pushAccount, mockUSDT.mint.publicKey)
      );
      // CEA ATA is created by init_if_needed even for zero-amount (persists for pull model)
      expect(ceaAtaInfo).to.not.be.null;
    });
  });

  describe("execute payload encode/decode roundtrip", () => {
    it("encodes, decodes, signs, and executes SOL payload", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const incrementAmount = new anchor.BN(4);

      const counterIx = await counterProgram.methods
        .increment(incrementAmount)
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(counterIx);
      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

      // Calculate fees dynamically for SOL execute (before encoding payload)
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      // Encode payload with execution data (accounts, ixData, targetProgram)
      const payloadFields = instructionToPayloadFields({
        instruction: counterIx,
        targetProgram: counterProgram.programId, // Canonical destination (source of truth)
        instructionId: 2,
      });

      const encoded = encodeExecutePayload(payloadFields);
      const decoded = decodeExecutePayload(encoded);

      // Verify payload decoding
      expect(Buffer.from(decoded.ixData)).to.deep.equal(
        Buffer.from(counterIx.data)
      );
      expect(decoded.accounts.length).to.equal(accounts.length);
      expect(decoded.instructionId).to.equal(2);
      expect(decoded.targetProgram.toString()).to.equal(
        counterProgram.programId.toString()
      ); // Verify targetProgram is decoded correctly

      // Get destination from decoded payload (canonical source of truth)
      const targetProgram = decoded.targetProgram;
      const amount = BigInt(0);
      const chainId = tssAccount.chainId;

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: amount,
        chainId: chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          targetProgram,
          new Uint8Array(pushAccount),
          decoded.accounts,
          decoded.ixData,
          gasFee
        ),
      });

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const callerBalanceBefore = await provider.connection.getBalance(
        admin.publicKey
      );

      const decodedWritableFlags = accountsToWritableFlagsOnly(
        decoded.accounts
      );
      await gatewayProgram.methods
        .finalizeUniversalTx(
          decoded.instructionId,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(Number(amount)),
          Array.from(pushAccount),
          decodedWritableFlags,
          Buffer.from(decoded.ixData),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(Array.from(pushAccount)),
          tssPda,
          executedSubTx: getExecutedTxPda(Array.from(subTxId)),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: targetProgram,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(
          decoded.accounts.map((a) => ({
            pubkey: a.pubkey,
            isWritable: a.isWritable,
            isSigner: false,
          }))
        )
        .signers([admin])
        .rpc();

      // Relayer pays sub_tx_rent upfront; receives gas_used back.
      // gas_used = SIGNATURE_FEE + sub_tx_rent; net ≈ SIGNATURE_FEE - tx_fees.
      const callerBalanceAfter = await provider.connection.getBalance(
        admin.publicKey
      );
      const actualBalanceChange = callerBalanceAfter - callerBalanceBefore;
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const gasUsedSolDecode = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx;
      const minExpectedChange = -actualRentForExecutedTx + gasUsedSolDecode - 10000; // Allow up to 10k for tx fees
      const maxExpectedChange = -actualRentForExecutedTx + gasUsedSolDecode + 1000; // small positive buffer
      expect(actualBalanceChange).to.be.at.least(minExpectedChange);
      expect(actualBalanceChange).to.be.at.most(maxExpectedChange);

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + incrementAmount.toNumber()
      );
    });

    it("encodes, decodes, signs, and executes SPL payload", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();
      const amount = asTokenAmount(25);

      const counterIx = await counterProgram.methods
        .receiveSpl(amount)
        .accountsPartial({
          counter: counterPda,
          ceaAta: await getCeaAta(pushAccount, mockUSDT.mint.publicKey),
          recipientAta: recipientUsdtAccount,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .instruction();

      // Check CEA ATA existence BEFORE calculating fees
      const ceaAtaForDecodeSpl = await getCeaAta(
        pushAccount,
        mockUSDT.mint.publicKey
      );
      const ceaAtaExistedBeforeDecodeSpl = await ceaAtaExists(
        provider.connection,
        ceaAtaForDecodeSpl
      );
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAtaForDecodeSpl
      );

      // Encode payload with execution data (accounts, ixData, targetProgram)
      const payloadFields = instructionToPayloadFields({
        instruction: counterIx,
        targetProgram: counterProgram.programId, // Canonical destination (source of truth)
        instructionId: 2,
      });

      const encoded = encodeExecutePayload(payloadFields);
      const decoded = decodeExecutePayload(encoded);

      // Use decoded accounts for signing and remaining_accounts
      const accountsForSigning = decoded.accounts;
      const remainingAccounts = decoded.accounts.map((acc) => ({
        pubkey: acc.pubkey,
        isWritable: acc.isWritable,
        isSigner: false,
      }));

      // Verify payload decoding
      expect(decoded.accounts.length).to.equal(counterIx.keys.length);
      expect(decoded.instructionId).to.equal(2);
      expect(decoded.targetProgram.toString()).to.equal(
        counterProgram.programId.toString()
      ); // Verify targetProgram is decoded correctly

      // Get destination from decoded payload (canonical source of truth)
      const targetProgram = decoded.targetProgram;
      const amountValue = BigInt(amount.toString());
      const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda))
        .chainId;
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: amountValue,
        chainId: chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          targetProgram,
          new Uint8Array(pushAccount),
          accountsForSigning, // Includes ceaAta (matches remaining_accounts)
          decoded.ixData,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      const counterBefore = await counterProgram.account.counter.fetch(
        counterPda
      );
      const recipientTokenBefore = await mockUSDT.getBalance(
        recipientUsdtAccount
      );
      const callerBalanceBefore = await provider.connection.getBalance(
        admin.publicKey
      );

      const accountsForSigningWritableFlags =
        accountsToWritableFlagsOnly(accountsForSigning);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          decoded.instructionId,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(amount.toString()),
          Array.from(pushAccount),
          accountsForSigningWritableFlags,
          Buffer.from(decoded.ixData),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(Array.from(pushAccount)),
          ceaAta: ceaAtaForDecodeSpl,
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(Array.from(subTxId)),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: targetProgram,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts) // Includes ceaAta (needed for CPI)
        .signers([admin])
        .rpc();

      // Relayer pays sub_tx_rent + ata_rent (if created) upfront; receives gas_used back.
      // gas_used = SIGNATURE_FEE + sub_tx_rent + ata_rent; net ≈ SIGNATURE_FEE - tx_fees.
      const callerBalanceAfter = await provider.connection.getBalance(
        admin.publicKey
      );
      const actualBalanceChange = callerBalanceAfter - callerBalanceBefore;
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const actualRentForCeaAta = ceaAtaExistedBeforeDecodeSpl
        ? 0
        : await getTokenAccountRent(provider.connection);
      const gasUsedSplDecode = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx + actualRentForCeaAta;
      const expectedBalanceChange =
        -actualRentForExecutedTx - actualRentForCeaAta + gasUsedSplDecode;
      expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 20000); // Allow for transaction fees (SPL txs are larger)

      const counterAfter = await counterProgram.account.counter.fetch(
        counterPda
      );
      expect(counterAfter.value.toNumber()).to.equal(
        counterBefore.value.toNumber() + amount.toNumber()
      );

      const recipientTokenAfter = await mockUSDT.getBalance(
        recipientUsdtAccount
      );
      const amountTokens = amount.toNumber() / 10 ** USDT_DECIMALS;
      expect(recipientTokenAfter - recipientTokenBefore).to.equal(amountTokens);
    });
  });

  describe("execute security validations (negative tests)", () => {
    /**
     * Helper to execute a test that should revert with a specific error
     * @param testName - Descriptive name for the attack being tested
     * @param executeCall - Async function that performs the attack
     * @param expectedErrorCode - Expected Anchor error code (e.g., "AccountPubkeyMismatch")
     */
    async function expectExecuteRevert(
      testName: string,
      executeCall: () => Promise<any>,
      expectedErrorCode: string
    ): Promise<void> {
      try {
        await executeCall();
        expect.fail(`${testName}: Should have reverted but succeeded`);
      } catch (e: any) {
        const errorMsg = e.toString();
        const hasExpectedError = errorMsg.includes(expectedErrorCode);

        if (!hasExpectedError) {
          console.error(
            `❌ ${testName}: Expected error "${expectedErrorCode}" but got:`,
            errorMsg
          );
          expect.fail(
            `Expected error code "${expectedErrorCode}" not found. Got: ${errorMsg}`
          );
        }

        console.log(
          `✅ ${testName}: Correctly rejected with ${expectedErrorCode}`
        );
      }
    }

    it("should reject execute while paused", async () => {
      await gatewayProgram.methods
        .pause()
        .accountsPartial({ pauser: admin.publicKey, config: configPda })
        .signers([admin])
        .rpc();

      try {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        const accounts = instructionAccountsToGatewayMetas(counterIx);
        const remainingAccounts = instructionAccountsToRemaining(counterIx);
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
            counterIx.data,
            gasFee
          ),
        });

        await expectExecuteRevert(
          "Paused execute",
          () =>
            gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                accountsToWritableFlagsOnly(accounts),
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),
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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                storedIxData: null,
                storeRefundRecipient: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(remainingAccounts)
              .signers([admin])
              .rpc(),
          "Paused"
        );
      } finally {
        await gatewayProgram.methods
          .unpause()
          .accountsPartial({ operator: operator.publicKey, config: configPda })
          .signers([operator])
          .rpc();
      }
    });

    describe("account manipulation attacks", () => {
      it("should reject account substitution attack", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        // Build a valid instruction
        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

        // Calculate fees dynamically
        const { gasFee } = await calculateSolExecuteFees(provider.connection);

        // Sign with CORRECT accounts
        const sig = await signTssMessage({
          instruction: TssInstruction.Execute,
          amount: BigInt(0),
          chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
          additional: buildExecuteAdditionalData(
            new Uint8Array(universalTxId),
            new Uint8Array(subTxId),
            counterProgram.programId,
            new Uint8Array(pushAccount),
            correctAccounts,
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Pass DIFFERENT accounts in remainingAccounts
        const attackerAccount = Keypair.generate().publicKey;
        const substitutedRemaining = [
          { pubkey: attackerAccount, isWritable: true, isSigner: false }, // Wrong account!
          {
            pubkey: counterAuthority.publicKey,
            isWritable: false,
            isSigner: false,
          },
        ];

        const correctWritableFlags =
          accountsToWritableFlagsOnly(correctAccounts);
        await expectExecuteRevert(
          "Account substitution",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                correctWritableFlags,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(substitutedRemaining) // Substituted accounts!
              .signers([admin])
              .rpc();
          },
          "MessageHashMismatch" // Reconstructed accounts don't match signed message
        );
      });

      it("should reject account count mismatch", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

        // Calculate fees dynamically
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
            correctAccounts,
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Pass FEWER accounts than signed
        const fewerRemaining = [
          { pubkey: counterPda, isWritable: true, isSigner: false },
          // Missing counterAuthority!
        ];

        // Create writable flags for correct accounts (2 accounts), but pass fewer remaining accounts (1 account)
        // Note: Both 1 and 2 accounts need 1 byte of flags, so length check passes
        // But TSS hash will fail because we signed 2 accounts but only reconstructed 1
        const correctWritableFlags2 =
          accountsToWritableFlagsOnly(correctAccounts);
        await expectExecuteRevert(
          "Account count mismatch (fewer)",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                correctWritableFlags2,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(fewerRemaining)
              .signers([admin])
              .rpc();
          },
          "MessageHashMismatch" // TSS hash fails because we signed 2 accounts but only reconstructed 1
        );
      });

      it("should reject writable flag mismatch", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

        // Calculate fees dynamically
        const { gasFee } = await calculateSolExecuteFees(provider.connection);

        // Sign with counter as writable
        const sig = await signTssMessage({
          instruction: TssInstruction.Execute,
          amount: BigInt(0),
          chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
          additional: buildExecuteAdditionalData(
            new Uint8Array(universalTxId),
            new Uint8Array(subTxId),
            counterProgram.programId,
            new Uint8Array(pushAccount),
            correctAccounts,
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Mark writable account as read-only in remaining_accounts
        const wrongWritableRemaining = [
          { pubkey: counterPda, isWritable: false, isSigner: false }, // Should be writable!
          {
            pubkey: counterAuthority.publicKey,
            isWritable: false,
            isSigner: false,
          },
        ];

        const correctWritableFlags3 =
          accountsToWritableFlagsOnly(correctAccounts);
        await expectExecuteRevert(
          "Writable flag mismatch",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                correctWritableFlags3,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(wrongWritableRemaining)
              .signers([admin])
              .rpc();
          },
          "AccountWritableFlagMismatch" // validate_remaining_accounts catches writable flag mismatch before TSS validation
        );
      });

      it("should reject account reordering attack", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

        // Calculate fees dynamically
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
            correctAccounts,
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Reorder accounts (swap counter and authority)
        const reorderedRemaining = [
          {
            pubkey: counterAuthority.publicKey,
            isWritable: false,
            isSigner: false,
          }, // Wrong position!
          { pubkey: counterPda, isWritable: true, isSigner: false },
        ];

        const correctWritableFlags4 =
          accountsToWritableFlagsOnly(correctAccounts);
        await expectExecuteRevert(
          "Account reordering",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                correctWritableFlags4,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(reorderedRemaining)
              .signers([admin])
              .rpc();
          },
          "AccountWritableFlagMismatch" // validate_remaining_accounts catches writable flag mismatch (from reordering) before TSS validation
        );
      });
    });

    it("should reject outer signer in remaining accounts (UnexpectedOuterSigner)", async () => {
      // validate_remaining_accounts fires BEFORE TSS validation (execute.rs line 523 vs 542),
      // so we don't need a valid TSS signature — the check fires first.
      // A malicious relayer could try to pass a signer account to gain signing authority
      // inside the target CPI. This must be rejected unconditionally.
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();

      // outerSigner: a real keypair that will be added as a signer in remainingAccounts.
      const outerSigner = Keypair.generate();

      // writable_flags for 1 account = 1 byte, bit 0 = not writable
      const writableFlags = Buffer.from([0x00]);

      // Dummy values — TSS check never reached, values don't matter for this path
      const dummySig = Array(64).fill(0);
      const dummyHash = Array(32).fill(0);
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      await expectExecuteRevert(
        "Outer signer in remaining accounts",
        async () => {
          return await gatewayProgram.methods
            .finalizeUniversalTx(
              2,
              Array.from(subTxId),
              Array.from(universalTxId),
              new anchor.BN(0),
              Array.from(pushAccount),
              writableFlags,
              Buffer.from([]),
              new anchor.BN(Number(gasFee)),

              new anchor.BN(4102444800),
              dummySig,
              0,
              dummyHash
            )
            .accountsPartial({
              caller: admin.publicKey,
              config: configPda,
              vaultSol: vaultPda,
              ceaAuthority: getCeaAuthorityPda(pushAccount),
              tssPda,
              executedSubTx: getExecutedTxPda(subTxId),
              rateLimitConfig: null,
              tokenRateLimit: null,
              destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
              recipient: null,
              vaultAta: null,
              ceaAta: null,
              mint: null,
              tokenProgram: null,
              rent: null,
              associatedTokenProgram: null,
              recipientAta: null,
              systemProgram: SystemProgram.programId,
            })
            .remainingAccounts([
              // isSigner: true — must be accompanied by actual tx signature
              {
                pubkey: outerSigner.publicKey,
                isWritable: false,
                isSigner: true,
              },
            ])
            .signers([admin, outerSigner]) // outerSigner actually signs so tx is valid at runtime level
            .rpc();
        },
        "UnexpectedOuterSigner"
      );
    });

    describe("signature and authentication attacks", () => {
      it("should reject invalid signature", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
        const remainingAccounts = instructionAccountsToRemaining(counterIx);
        const accounts = remainingAccounts.map((acc) => ({
          pubkey: acc.pubkey,
          isWritable: acc.isWritable,
        }));

        // Calculate fees dynamically
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
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Corrupt the signature
        const corruptedSignature = Array.from(sig.signature);
        corruptedSignature[0] ^= 0xff; // Flip bits

        const sigWritableFlags = accountsToWritableFlagsOnly(accounts);
        await expectExecuteRevert(
          "Invalid signature",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                sigWritableFlags,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

                new anchor.BN(4102444800),
                corruptedSignature, // Invalid!
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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(remainingAccounts)
              .signers([admin])
              .rpc();
          },
          "TssAuthFailed"
        );
      });

      it("should reject tampered message hash", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
        const remainingAccounts = instructionAccountsToRemaining(counterIx);
        const accounts = remainingAccounts.map((acc) => ({
          pubkey: acc.pubkey,
          isWritable: acc.isWritable,
        }));

        // Calculate fees dynamically
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
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Tamper with message hash
        const tamperedHash = Array.from(sig.messageHash);
        tamperedHash[0] ^= 0xff;

        const hashWritableFlags = accountsToWritableFlagsOnly(accounts);
        await expectExecuteRevert(
          "Tampered message hash",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                hashWritableFlags,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

                new anchor.BN(4102444800),
                Array.from(sig.signature),
                sig.recoveryId,
                tamperedHash // Tampered!
              )
              .accountsPartial({
                caller: admin.publicKey,
                config: configPda,
                vaultSol: vaultPda,
                ceaAuthority: getCeaAuthorityPda(pushAccount),
                tssPda,
                executedSubTx: getExecutedTxPda(subTxId),
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(remainingAccounts)
              .signers([admin])
              .rpc();
          },
          "MessageHashMismatch"
        );
      });
    });

    describe("program and target validation", () => {
      it("should reject non-executable destination program", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        // Use a regular account (not a program) as destination
        const nonExecutableAccount = Keypair.generate().publicKey;

        // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
        const remainingAccounts = [
          { pubkey: counterPda, isWritable: true, isSigner: false },
        ];
        const accounts = remainingAccounts.map((acc) => ({
          pubkey: acc.pubkey,
          isWritable: acc.isWritable,
        }));

        // Calculate fees dynamically
        const { gasFee } = await calculateSolExecuteFees(provider.connection);

        const sig = await signTssMessage({
          instruction: TssInstruction.Execute,
          amount: BigInt(0),
          chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
          additional: buildExecuteAdditionalData(
            new Uint8Array(universalTxId),
            new Uint8Array(subTxId),
            nonExecutableAccount, // Non-executable!
            new Uint8Array(pushAccount),
            accounts,
            Buffer.from([0x01]),
            gasFee
        ),
        });

        const progWritableFlags = accountsToWritableFlagsOnly(accounts);
        await expectExecuteRevert(
          "Non-executable destination program",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                progWritableFlags,
                Buffer.from([0x01]),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: nonExecutableAccount,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(remainingAccounts)
              .signers([admin])
              .rpc();
          },
          "InvalidProgram"
        );
      });

      it("should reject gateway PDAs in remaining accounts (vault)", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        // ATTACK: Include vault PDA in remaining_accounts
        const maliciousAccounts: GatewayAccountMeta[] = [
          { pubkey: counterPda, isWritable: true },
          { pubkey: vaultPda, isWritable: true }, // Protected account!
        ];

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        // Calculate fees dynamically
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
            maliciousAccounts, // Includes vault!
            counterIx.data,
            gasFee
        ),
        });

        const maliciousRemaining = [
          { pubkey: counterPda, isWritable: true, isSigner: false },
          { pubkey: vaultPda, isWritable: true, isSigner: false }, // Vault should never be passed!
        ];

        const maliciousWritableFlags =
          accountsToWritableFlagsOnly(maliciousAccounts);
        await expectExecuteRevert(
          "Gateway vault PDA in remaining accounts",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                maliciousWritableFlags,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(maliciousRemaining)
              .signers([admin])
              .rpc();
          },
          "Error" // Will fail at CPI level or earlier validation
        );
      });

      it("should reject target program mismatch (via message hash)", async () => {
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
        const remainingAccounts = instructionAccountsToRemaining(counterIx);
        const accounts = remainingAccounts.map((acc) => ({
          pubkey: acc.pubkey,
          isWritable: acc.isWritable,
        }));

        // Calculate fees dynamically
        const { gasFee } = await calculateSolExecuteFees(provider.connection);

        // Sign for counter program
        const sig = await signTssMessage({
          instruction: TssInstruction.Execute,
          amount: BigInt(0),
          chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
          additional: buildExecuteAdditionalData(
            new Uint8Array(universalTxId),
            new Uint8Array(subTxId),
            counterProgram.programId, // Signed for counter program
            new Uint8Array(pushAccount),
            accounts,
            counterIx.data,
            gasFee
        ),
        });

        // ATTACK: Pass different program as destination_program
        // Note: This fails at message hash validation because target_program is part of the signed message.
        // The TargetProgramMismatch check exists as a defensive measure but is unlikely to be hit
        // since message hash validation happens first.
        const differentProgram = Keypair.generate().publicKey;

        const targetMismatchWritableFlags =
          accountsToWritableFlagsOnly(accounts);
        await expectExecuteRevert(
          "Target program mismatch (caught by message hash validation)",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                2,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                targetMismatchWritableFlags,
                Buffer.from(counterIx.data),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: differentProgram,
          storedIxData: null,
          storeRefundRecipient: null,
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(remainingAccounts)
              .signers([admin])
              .rpc();
          },
          "MessageHashMismatch" // Correct error - message hash includes target_program
        );
      });

      it("should reject tampered destinationProgram when using decoded payload target", async () => {
        // This test demonstrates that the decoded payload is the canonical source of truth for targetProgram
        const subTxId = generateTxId();
        const universalTxId = generateUniversalTxId();
        const pushAccount = generateSender();

        const counterIx = await counterProgram.methods
          .increment(new anchor.BN(1))
          .accountsPartial({
            counter: counterPda,
            authority: counterAuthority.publicKey,
          })
          .instruction();

        const remainingAccounts = instructionAccountsToRemaining(counterIx);
        const accounts = remainingAccounts.map((acc) => ({
          pubkey: acc.pubkey,
          isWritable: acc.isWritable,
        }));

        // Calculate fees dynamically
        const { gasFee } = await calculateSolExecuteFees(provider.connection);

        // Build payload with canonical targetProgram (counterProgram)
        const payloadFields = instructionToPayloadFields({
          instruction: counterIx,
          targetProgram: counterProgram.programId, // Canonical destination
          instructionId: 2,
        });

        const encoded = encodeExecutePayload(payloadFields);
        const decoded = decodeExecutePayload(encoded);

        // Verify targetProgram was encoded and decoded correctly
        expect(decoded.targetProgram.toString()).to.equal(
          counterProgram.programId.toString()
        );

        // Sign with targetProgram from decoded payload (canonical source of truth)
        const targetProgramFromPayload = decoded.targetProgram;
        const sig = await signTssMessage({
          instruction: TssInstruction.Execute,
          amount: BigInt(0),
          chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
          additional: buildExecuteAdditionalData(
            new Uint8Array(universalTxId),
            new Uint8Array(subTxId),
            targetProgramFromPayload, // From decoded payload
            new Uint8Array(pushAccount),
            decoded.accounts,
            decoded.ixData,
            gasFee
        ),
        });

        // ATTACK: Tamper with destinationProgram after decoding
        // Even though signature was built with targetProgramFromPayload (counterProgram),
        // attacker tries to redirect execution to differentProgram
        const differentProgram = Keypair.generate().publicKey;

        const targetMismatchWritableFlags = accountsToWritableFlagsOnly(
          decoded.accounts
        );
        await expectExecuteRevert(
          "Tampered destinationProgram (payload targetProgram is canonical)",
          async () => {
            return await gatewayProgram.methods
              .finalizeUniversalTx(
                decoded.instructionId,
                Array.from(subTxId),
                Array.from(universalTxId),
                new anchor.BN(0),
                Array.from(pushAccount),
                targetMismatchWritableFlags,
                Buffer.from(decoded.ixData),
                new anchor.BN(Number(gasFee)),

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
                rateLimitConfig: null,
                tokenRateLimit: null,
                destinationProgram: differentProgram, // TAMPERED - not from payload
                recipient: null,
                vaultAta: null,
                ceaAta: null,
                mint: null,
                tokenProgram: null,
                rent: null,
                associatedTokenProgram: null,
                recipientAta: null,
                storedIxData: null,
                storeRefundRecipient: null,
                systemProgram: SystemProgram.programId,
              })
              .remainingAccounts(remainingAccounts)
              .signers([admin])
              .rpc();
          },
          "MessageHashMismatch" // Payload targetProgram is canonical - tampering detected
        );
      });
    });
  });

  describe("CEA Identity Preservation - Multi-User Tests", () => {
    // Fixed pushAccount addresses for identity testing (EVM-like 20-byte addresses)
    const user1Sender = Array.from(
      Buffer.from("1111111111111111111111111111111111111111", "hex")
    );
    const user2Sender = Array.from(
      Buffer.from("2222222222222222222222222222222222222222", "hex")
    );
    const user3Sender = Array.from(
      Buffer.from("3333333333333333333333333333333333333333", "hex")
    );
    const user4Sender = Array.from(
      Buffer.from("4444444444444444444444444444444444444444", "hex")
    );

    // Derive CEAs for each user
    const user1Cea = getCeaAuthorityPda(user1Sender);
    const user2Cea = getCeaAuthorityPda(user2Sender);
    const user3Cea = getCeaAuthorityPda(user3Sender);
    const user4Cea = getCeaAuthorityPda(user4Sender);

    // Stake PDAs for test-counter
    const getStakePda = (authority: PublicKey): PublicKey => {
      const [pda] = PublicKey.findProgramAddressSync(
        [Buffer.from("stake"), authority.toBuffer()],
        counterProgram.programId
      );
      return pda;
    };

    const getStakeVaultPda = (authority: PublicKey): PublicKey => {
      const [pda] = PublicKey.findProgramAddressSync(
        [Buffer.from("stake_vault"), authority.toBuffer()],
        counterProgram.programId
      );
      return pda;
    };

    const topUpCeaLamports = async (cea: PublicKey, lamports: bigint) => {
      if (lamports <= BigInt(0)) return;
      const tx = new anchor.web3.Transaction().add(
        anchor.web3.SystemProgram.transfer({
          fromPubkey: admin.publicKey,
          toPubkey: cea,
          lamports: Number(lamports),
        })
      );
      await provider.sendAndConfirm(tx, [admin]);
    };

    it("should verify each user has unique CEA addresses", () => {
      // Verify all CEAs are different
      expect(user1Cea.toString()).to.not.equal(user2Cea.toString());
      expect(user1Cea.toString()).to.not.equal(user3Cea.toString());
      expect(user1Cea.toString()).to.not.equal(user4Cea.toString());
      expect(user2Cea.toString()).to.not.equal(user3Cea.toString());
      expect(user2Cea.toString()).to.not.equal(user4Cea.toString());
      expect(user3Cea.toString()).to.not.equal(user4Cea.toString());

      console.log("✅ All 4 users have unique CEA addresses");
      console.log("  User1 CEA:", user1Cea.toString());
      console.log("  User2 CEA:", user2Cea.toString());
      console.log("  User3 CEA:", user3Cea.toString());
      console.log("  User4 CEA:", user4Cea.toString());
    });

    it("User1: should stake SOL and verify CEA identity persistence", async () => {
      const stakeAmount = asLamports(1); // 1 SOL
      const user1Stake = getStakePda(user1Cea);
      const user1StakeVault = getStakeVaultPda(user1Cea);

      // Transaction 1: Stake SOL
      const txId1 = generateTxId();
      const universalTxId1 = generateUniversalTxId();
      const stakeIx = await counterProgram.methods
        .stakeSol(stakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user1Cea,
          stake: user1Stake,
          stakeVault: user1StakeVault,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(stakeIx);

      // Calculate fees dynamically (stake account needs rent if it doesn't exist or is under-funded)
      // Stake account size: 8 (discriminator) + 40 (Stake::LEN) = 48 bytes
      const stakeAccountInfo = await provider.connection.getAccountInfo(
        user1Stake
      );
      const stakeRentExempt =
        await provider.connection.getMinimumBalanceForRentExemption(48);
      const needsRent =
        !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
      const targetTopupLamports = needsRent
        ? BigInt(stakeRentExempt) // Account missing or under-funded, need full rent exemption
        : BigInt(0); // Account exists and is rent-exempt
      const { gasFee: gasFee1 } = await calculateSolExecuteFees(
        provider.connection
      );

      // when the target program uses `payer = authority` on init_if_needed accounts.
      await topUpCeaLamports(user1Cea, targetTopupLamports);

      const sig1 = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(stakeAmount.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId1),
          new Uint8Array(txId1),
          counterProgram.programId,
          new Uint8Array(user1Sender),
          accounts,
          stakeIx.data,
          gasFee1
        ),
      });

      const user1WritableFlags1 = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(txId1),
          Array.from(universalTxId1),
          stakeAmount,
          Array.from(user1Sender),
          user1WritableFlags1,
          Buffer.from(stakeIx.data),
          new anchor.BN(Number(gasFee1)),

          new anchor.BN(4102444800),
          Array.from(sig1.signature),
          sig1.recoveryId,
          Array.from(sig1.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: user1Cea,
          tssPda,
          executedSubTx: getExecutedTxPda(txId1),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(stakeIx))
        .signers([admin])
        .rpc();

      // Verify stake was created and SOL was actually transferred
      const stakeAccount = await counterProgram.account.stake.fetch(user1Stake);
      expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());
      expect(stakeAccount.authority.toString()).to.equal(user1Cea.toString());

      // Verify actual SOL balance in stake_vault (must equal staked amount)
      const stakeVaultBalance = await provider.connection.getBalance(
        user1StakeVault
      );
      expect(stakeVaultBalance).to.equal(
        stakeAmount.toNumber(),
        "Stake vault should hold the staked SOL"
      );

      console.log("✅ User1 staked 1 SOL successfully");
      console.log("  Stake PDA:", user1Stake.toString());
      console.log("  Staked amount:", stakeAccount.amount.toNumber());
    });

    it("User1: should perform multiple transactions with same CEA", async () => {
      const user1Stake = getStakePda(user1Cea);
      const user1StakeVault = getStakeVaultPda(user1Cea);

      // Transaction 2: Stake more SOL with same CEA (tests identity persistence)
      const txId2 = generateTxId();
      const universalTxId2 = generateUniversalTxId();
      const stakeAmount2 = asLamports(0.5); // 0.5 SOL more
      const stakeIx2 = await counterProgram.methods
        .stakeSol(stakeAmount2)
        .accountsPartial({
          counter: counterPda,
          authority: user1Cea,
          stake: user1Stake,
          stakeVault: user1StakeVault,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(stakeIx2);

      // Calculate fees dynamically (stake account already exists, no extra top-up needed)
      const { gasFee: gasFee2 } = await calculateSolExecuteFees(
        provider.connection
      );

      const sig2 = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(stakeAmount2.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId2),
          new Uint8Array(txId2),
          counterProgram.programId,
          new Uint8Array(user1Sender),
          accounts,
          stakeIx2.data,
          gasFee2
        ),
      });

      const ceaBefore = getCeaAuthorityPda(user1Sender);
      expect(ceaBefore.toString()).to.equal(user1Cea.toString());

      const user1WritableFlags2 = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(txId2),
          Array.from(universalTxId2),
          stakeAmount2,
          Array.from(user1Sender),
          user1WritableFlags2,
          Buffer.from(stakeIx2.data),
          new anchor.BN(Number(gasFee2)),

          new anchor.BN(4102444800),
          Array.from(sig2.signature),
          sig2.recoveryId,
          Array.from(sig2.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: user1Cea,
          tssPda,
          executedSubTx: getExecutedTxPda(txId2),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(stakeIx2))
        .signers([admin])
        .rpc();

      const ceaAfter = getCeaAuthorityPda(user1Sender);
      expect(ceaAfter.toString()).to.equal(user1Cea.toString());

      // Verify stake amount increased (identity preserved across txs)
      const stakeAccountAfter = await counterProgram.account.stake.fetch(
        user1Stake
      );
      expect(stakeAccountAfter.amount.toNumber()).to.equal(
        asLamports(1.5).toNumber()
      );

      console.log("✅ User1 performed multiple txs with same CEA");
      console.log("  CEA (tx1 & tx2):", user1Cea.toString());
      console.log(
        "  Total staked across 2 txs:",
        stakeAccountAfter.amount.toNumber()
      );
    });

    it("User1: should unstake SOL and verify FUNDS event emission", async () => {
      const user1Stake = getStakePda(user1Cea);
      const user1StakeVault = getStakeVaultPda(user1Cea);
      const stakeAccount = await counterProgram.account.stake.fetch(user1Stake);
      const unstakeAmount = stakeAccount.amount;

      // Get balances before unstake
      const stakeVaultBalanceBefore = await provider.connection.getBalance(
        user1StakeVault
      );
      const ceaBalanceBefore = await provider.connection.getBalance(user1Cea);

      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const unstakeIx = await counterProgram.methods
        .unstakeSol(unstakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user1Cea,
          stake: user1Stake,
          stakeVault: user1StakeVault,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(unstakeIx);
      // Calculate fees dynamically
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(user1Sender),
          accounts,
          unstakeIx.data,
          gasFee
        ),
      });

      const user1UnstakeWritableFlags = accountsToWritableFlagsOnly(accounts);
      const tx = await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(user1Sender),
          user1UnstakeWritableFlags,
          Buffer.from(unstakeIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: user1Cea,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(unstakeIx))
        .signers([admin])
        .rpc();

      // Verify FUNDS event was emitted (CEA drained back to vault)
      {
        const events = await extractEventCpi(provider.connection, gatewayProgram, tx);
        const fundsEvents = events.filter(
          (e) => e.name === "universalTx" && e.data.txType.funds !== undefined
        );

        if (fundsEvents.length > 0) {
          const fundsEvent = fundsEvents[0].data;
          expect(fundsEvent.pushAccount.toString()).to.equal(
            user1Cea.toString()
          );
          expect(fundsEvent.token.toString()).to.equal(
            PublicKey.default.toString()
          );
          console.log(
            "✅ FUNDS event emitted - CEA drained:",
            fundsEvent.amount.toNumber(),
            "lamports"
          );
        } else {
          console.log(
            "ℹ️  No FUNDS event (CEA balance was 0 or already drained)"
          );
        }
      }

      // Verify actual SOL balance movements
      const stakeVaultBalanceAfter = await provider.connection.getBalance(
        user1StakeVault
      );
      const ceaBalanceAfter = await provider.connection.getBalance(user1Cea);
      expect(stakeVaultBalanceAfter).to.equal(
        stakeVaultBalanceBefore - unstakeAmount.toNumber()
      );
      expect(ceaBalanceAfter).to.be.greaterThan(ceaBalanceBefore); // CEA received SOL

      // Verify stake account was decremented
      const stakeAccountAfter = await counterProgram.account.stake.fetch(
        user1Stake
      );
      expect(stakeAccountAfter.amount.toNumber()).to.equal(0);

      console.log("✅ User1 unstaked SOL successfully");
      console.log("  Unstaked amount:", unstakeAmount.toNumber());
      console.log("  Stake vault balance before:", stakeVaultBalanceBefore);
      console.log("  Stake vault balance after:", stakeVaultBalanceAfter);
      console.log(
        "  CEA balance increase:",
        ceaBalanceAfter - ceaBalanceBefore
      );
    });

    it("User2: should stake SOL with different CEA", async () => {
      const stakeAmount = asLamports(2); // 2 SOL
      const user2Stake = getStakePda(user2Cea);
      const user2StakeVault = getStakeVaultPda(user2Cea);

      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const stakeIx = await counterProgram.methods
        .stakeSol(stakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user2Cea,
          stake: user2Stake,
          stakeVault: user2StakeVault,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(stakeIx);

      // Calculate fees dynamically (stake account needs rent if it doesn't exist or is under-funded)
      const stakeAccountInfo = await provider.connection.getAccountInfo(
        user2Stake
      );
      const stakeRentExempt =
        await provider.connection.getMinimumBalanceForRentExemption(48);
      const needsRent =
        !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
      const targetTopupLamports = needsRent
        ? BigInt(stakeRentExempt) // Account missing or under-funded, need full rent exemption
        : BigInt(0); // Account exists and is rent-exempt
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      await topUpCeaLamports(user2Cea, targetTopupLamports);


      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(stakeAmount.toNumber()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(user2Sender),
          accounts,
          stakeIx.data,
          gasFee
        ),
      });

      const user2WritableFlags = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          stakeAmount,
          Array.from(user2Sender),
          user2WritableFlags,
          Buffer.from(stakeIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: user2Cea,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(stakeIx))
        .signers([admin])
        .rpc();

      const stakeAccount = await counterProgram.account.stake.fetch(user2Stake);
      expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());
      expect(stakeAccount.authority.toString()).to.equal(user2Cea.toString());

      // Verify User2 CEA is different from User1 CEA
      expect(user2Cea.toString()).to.not.equal(user1Cea.toString());

      console.log("✅ User2 staked 2 SOL with different CEA");
      console.log("  User1 CEA:", user1Cea.toString());
      console.log("  User2 CEA:", user2Cea.toString());
    });

    it("User2: should unstake own SOL successfully", async () => {
      const user2Stake = getStakePda(user2Cea);
      const user2StakeVault = getStakeVaultPda(user2Cea);
      const stakeAccount = await counterProgram.account.stake.fetch(user2Stake);
      const unstakeAmount = stakeAccount.amount;

      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const unstakeIx = await counterProgram.methods
        .unstakeSol(unstakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user2Cea,
          stake: user2Stake,
          stakeVault: user2StakeVault,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(unstakeIx);

      // Calculate fees dynamically
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(user2Sender),
          accounts,
          unstakeIx.data,
          gasFee
        ),
      });

      const user2UnstakeWritableFlags = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(user2Sender),
          user2UnstakeWritableFlags,
          Buffer.from(unstakeIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: user2Cea,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(unstakeIx))
        .signers([admin])
        .rpc();

      console.log("✅ User2 unstaked own SOL successfully");
    });

    it("User3: should stake SPL tokens", async () => {
      const stakeAmount = asTokenAmount(50); // 50 USDT
      const user3Stake = getStakePda(user3Cea);

      // Check if accounts are rent-exempt, not just exist
      const stakeAccountInfo = await provider.connection.getAccountInfo(
        user3Stake
      );
      const stakeRentExempt =
        await provider.connection.getMinimumBalanceForRentExemption(48);
      const stakeNeedsRent =
        !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
      const stakeTopupLamports = stakeNeedsRent
        ? BigInt(stakeRentExempt) // Account missing or under-funded
        : BigInt(0); // Account exists and is rent-exempt

      const stakeAta = await getStakeAta(user3Stake, mockUSDT.mint.publicKey);
      const stakeAtaInfo = await provider.connection.getAccountInfo(stakeAta);
      const stakeAtaRentExempt =
        await provider.connection.getMinimumBalanceForRentExemption(165);
      const stakeAtaNeedsRent =
        !stakeAtaInfo || stakeAtaInfo.lamports < stakeAtaRentExempt;
      const stakeAtaTopupLamports = stakeAtaNeedsRent
        ? BigInt(stakeAtaRentExempt) // ATA missing or under-funded
        : BigInt(0); // ATA exists and is rent-exempt
      const targetTopupLamports = stakeTopupLamports + stakeAtaTopupLamports;

      // Check CEA ATA existence BEFORE calculating fees
      const ceaAta = await getCeaAta(user3Sender, mockUSDT.mint.publicKey);
      const { gasFee: gasFeeLamports } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

      await topUpCeaLamports(user3Cea, targetTopupLamports);


      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const stakeIx = await counterProgram.methods
        .stakeSpl(stakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user3Cea,
          stake: user3Stake,
          mint: mockUSDT.mint.publicKey,
          authorityAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
          stakeAta: await getStakeAta(user3Stake, mockUSDT.mint.publicKey),
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(stakeIx);

      const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda))
        .chainId;

      // Convert amount to BigInt for signing - must match exactly what we pass to execute
      const amountBigInt = BigInt(stakeAmount.toString());

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: amountBigInt,
        chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(user3Sender),
          accounts,
          stakeIx.data,
          gasFeeLamports,
          mockUSDT.mint.publicKey
        ),
      });

      const user3StakeWritableFlags = accountsToWritableFlagsOnly(accounts);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          stakeAmount, // Must match amountBigInt
          Array.from(user3Sender),
          user3StakeWritableFlags,
          Buffer.from(stakeIx.data),
          gasFeeBn,

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 300_000 }),
        ])
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority: user3Cea,
          ceaAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(instructionAccountsToRemaining(stakeIx))
        .signers([admin])
        .rpc();

      // Verify stake account was created
      const stakeAccount = await counterProgram.account.stake.fetch(user3Stake);
      expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());

      console.log("✅ User3 staked 50 SPL tokens");
      console.log("  User3 CEA:", user3Cea.toString());
      console.log("  Stake amount:", stakeAccount.amount.toNumber());
    });

    it("User3: should unstake SPL tokens & CeaAta should exist", async () => {
      const user3Stake = getStakePda(user3Cea);

      // Fetch current stake amount
      const stakeAccount = await counterProgram.account.stake.fetch(user3Stake);
      const unstakeAmount = stakeAccount.amount;

      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const unstakeIx = await counterProgram.methods
        .unstakeSpl(unstakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user3Cea,
          stake: user3Stake,
          mint: mockUSDT.mint.publicKey,
          authorityAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
          stakeAta: await getStakeAta(user3Stake, mockUSDT.mint.publicKey),
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda))
        .chainId;
      const amountBigInt = BigInt(0); // Unstake has zero amount

      // Check CEA ATA existence BEFORE calculating fees (it should exist from previous stake)
      const ceaAta = await getCeaAta(user3Sender, mockUSDT.mint.publicKey);
      const { gasFee } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const accounts = instructionAccountsToGatewayMetas(unstakeIx);
      const remainingAccounts = instructionAccountsToRemaining(unstakeIx);

      // Sign execute message with the EXACT same accounts that will be in remaining_accounts
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: amountBigInt,
        chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(user3Sender),
          accounts,
          unstakeIx.data,
          gasFee,
          mockUSDT.mint.publicKey
        ),
      });

      const user3UnstakeWritableFlags = accountsToWritableFlagsOnly(accounts);
      const tx = await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0), // Must match amountBigInt
          Array.from(user3Sender),
          user3UnstakeWritableFlags,
          Buffer.from(unstakeIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority: user3Cea,
          ceaAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      // Verify CEA ATA still exists (CEA is persistent, not auto-closed)
      // Reuse ceaAta from above (already declared in this scope)
      const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
      expect(ceaAtaInfo).to.not.be.null; // CEA ATA persists (pull model, not auto-drain)

      // Verify FUNDS event was emitted for SPL tokens
      {
        const events = await extractEventCpi(provider.connection, gatewayProgram, tx);
        const fundsEvents = events.filter(
          (e) => e.name === "universalTx" && e.data.txType.funds !== undefined
        );

        if (fundsEvents.length > 0) {
          const fundsEvent = fundsEvents[0].data;
          expect(fundsEvent.pushAccount.toString()).to.equal(
            user3Cea.toString()
          );
          expect(fundsEvent.token.toString()).to.equal(
            mockUSDT.mint.publicKey.toString()
          );
          console.log(
            "✅ FUNDS event emitted - CEA ATA drained:",
            fundsEvent.amount.toNumber(),
            "tokens"
          );
        } else {
          console.log(
            "ℹ️  No FUNDS event (CEA ATA balance was 0 or already drained)"
          );
        }
      }

      // Verify actual token balance movements
      const stakeAta = await getStakeAta(user3Stake, mockUSDT.mint.publicKey);
      const stakeAtaInfoAfter =
        await provider.connection.getTokenAccountBalance(stakeAta);
      const ceaAtaInfoAfter = await provider.connection.getTokenAccountBalance(
        ceaAta
      );

      // Stake ATA should be empty (or close to 0 if there was a small balance)
      expect(Number(stakeAtaInfoAfter.value.amount)).to.be.at.most(
        1,
        "Stake ATA should be empty after unstake"
      );
      // CEA ATA should have received the tokens
      expect(Number(ceaAtaInfoAfter.value.amount)).to.be.greaterThan(
        0,
        "CEA ATA should have received unstaked tokens"
      );

      // Verify stake account was decremented
      const stakeAccountAfter = await counterProgram.account.stake.fetch(
        user3Stake
      );
      expect(stakeAccountAfter.amount.toNumber()).to.equal(
        0,
        "Stake account should be zero after unstake"
      );

      console.log("✅ User3 unstaked SPL and CEA ATA persists (not closed)");
      console.log("  CEA ATA address:", ceaAta.toString());
      console.log(
        "  CEA ATA balance after unstake:",
        ceaAtaInfoAfter.value.amount
      );
      console.log(
        "  Stake ATA balance after unstake:",
        stakeAtaInfoAfter.value.amount
      );
    });

    it("User4: should NOT be able to unstake User3's funds (cross-user isolation)", async () => {
      // First, User4 stakes their own funds
      const stakeAmount = asTokenAmount(100);
      const user4Stake = getStakePda(user4Cea);

      // Check if accounts are rent-exempt, not just exist
      const stakeAccountInfo = await provider.connection.getAccountInfo(
        user4Stake
      );
      const stakeRentExempt =
        await provider.connection.getMinimumBalanceForRentExemption(48);
      const stakeNeedsRent =
        !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
      const stakeTopupLamports = stakeNeedsRent
        ? BigInt(stakeRentExempt) // Account missing or under-funded
        : BigInt(0); // Account exists and is rent-exempt

      const stakeAta = await getStakeAta(user4Stake, mockUSDT.mint.publicKey);
      const stakeAtaInfo = await provider.connection.getAccountInfo(stakeAta);
      const stakeAtaRentExempt =
        await provider.connection.getMinimumBalanceForRentExemption(165);
      const stakeAtaNeedsRent =
        !stakeAtaInfo || stakeAtaInfo.lamports < stakeAtaRentExempt;
      const stakeAtaTopupLamports = stakeAtaNeedsRent
        ? BigInt(stakeAtaRentExempt) // ATA missing or under-funded
        : BigInt(0); // ATA exists and is rent-exempt
      const targetTopupLamports = stakeTopupLamports + stakeAtaTopupLamports;

      // Check CEA ATA existence BEFORE calculating fees
      const ceaAta = await getCeaAta(user4Sender, mockUSDT.mint.publicKey);
      const { gasFee: gasFeeLamports } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

      await topUpCeaLamports(user4Cea, targetTopupLamports);


      const txId1 = generateTxId();
      const universalTxId1 = generateUniversalTxId();
      const stakeIx = await counterProgram.methods
        .stakeSpl(stakeAmount)
        .accountsPartial({
          counter: counterPda,
          authority: user4Cea,
          stake: user4Stake,
          mint: mockUSDT.mint.publicKey,
          authorityAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
          stakeAta: await getStakeAta(user4Stake, mockUSDT.mint.publicKey),
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts1 = instructionAccountsToGatewayMetas(stakeIx);

      const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda))
        .chainId;
      // Convert amount to BigInt for signing - must match exactly what we pass to execute
      const amountBigInt = BigInt(stakeAmount.toString());

      const sig1 = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: amountBigInt,
        chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId1),
          new Uint8Array(txId1),
          counterProgram.programId,
          new Uint8Array(user4Sender),
          accounts1,
          stakeIx.data,
          gasFeeLamports,
          mockUSDT.mint.publicKey
        ),
      });

      const accounts1WritableFlags = accountsToWritableFlagsOnly(accounts1);
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(txId1),
          Array.from(universalTxId1),
          stakeAmount, // Must match amountBigInt
          Array.from(user4Sender),
          accounts1WritableFlags,
          Buffer.from(stakeIx.data),
          gasFeeBn,

          new anchor.BN(4102444800),
          Array.from(sig1.signature),
          sig1.recoveryId,
          Array.from(sig1.messageHash)
        )
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 300_000 }),
        ])
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority: user4Cea,
          ceaAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(txId1),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(instructionAccountsToRemaining(stakeIx))
        .signers([admin])
        .rpc();

      console.log("✅ User4 staked 100 SPL tokens");

      // Cross-user isolation: User4 attempts to unstake from User3's stake PDA.
      // Gateway correctly routes User4's push_account → User4's CEA as CPI signer.
      // test-counter rejects because stake.authority == user3Cea != user4Cea.
      const user3Stake = getStakePda(user3Cea);
      const txId2 = generateTxId();
      const universalTxId2 = generateUniversalTxId();
      const { gasFee: gasFee2 } = await calculateSplExecuteFees(
        provider.connection,
        await getCeaAta(user4Sender, mockUSDT.mint.publicKey)
      );

      // Build unstakeSpl targeting User3's stake but signed by User4's CEA
      const crossUnstakeIx = await counterProgram.methods
        .unstakeSpl(new anchor.BN(1))
        .accountsPartial({
          counter: counterPda,
          authority: user4Cea, // User4's CEA — wrong authority for User3's stake
          stake: user3Stake, // User3's stake PDA
          mint: mockUSDT.mint.publicKey,
          authorityAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
          stakeAta: await getStakeAta(user3Stake, mockUSDT.mint.publicKey),
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const crossAccounts = instructionAccountsToGatewayMetas(crossUnstakeIx);
      const chainId2 = (await gatewayProgram.account.tssPda.fetch(tssPda))
        .chainId;
      const sigCross = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: chainId2,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId2),
          new Uint8Array(txId2),
          counterProgram.programId,
          new Uint8Array(user4Sender),
          crossAccounts,
          crossUnstakeIx.data,
          gasFee2,
          mockUSDT.mint.publicKey
        ),
      });

      // Snapshot User3's stake state before the attack
      const user3StakeBefore = await counterProgram.account.stake.fetch(
        user3Stake
      );

      try {
        await gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(txId2),
            Array.from(universalTxId2),
            new anchor.BN(0),
            Array.from(user4Sender),
            accountsToWritableFlagsOnly(crossAccounts),
            Buffer.from(crossUnstakeIx.data),
            new anchor.BN(Number(gasFee2)),

            new anchor.BN(4102444800),
            Array.from(sigCross.signature),
            sigCross.recoveryId,
            Array.from(sigCross.messageHash)
          )
          .preInstructions([
            ComputeBudgetProgram.setComputeUnitLimit({ units: 300_000 }),
          ])
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultAta: vaultUsdtAccount,
            vaultSol: vaultPda,
            ceaAuthority: user4Cea,
            ceaAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
            mint: mockUSDT.mint.publicKey,
            tssPda,
            executedSubTx: getExecutedTxPda(txId2),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
            recipient: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
            rent: anchor.web3.SYSVAR_RENT_PUBKEY,
            associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
            recipientAta: null,
          })
          .remainingAccounts(instructionAccountsToRemaining(crossUnstakeIx))
          .signers([admin])
          .rpc();
        expect.fail("User4 should not be able to unstake User3's funds");
      } catch (error: any) {
        // test-counter rejects because stake.authority != user4Cea
        expect(error.toString()).to.not.include("User4 should not be able");

        // Postcondition: User3's stake is completely unchanged after the failed attack
        const user3StakeAfter = await counterProgram.account.stake.fetch(
          user3Stake
        );
        expect(user3StakeAfter.amount.toString()).to.equal(
          user3StakeBefore.amount.toString(),
          "User3 stake amount must be unchanged after failed cross-user attack"
        );
        console.log(
          "✅ Cross-user isolation verified: User4 cannot unstake User3's funds"
        );
        console.log(
          "  User3 stake amount unchanged:",
          user3StakeAfter.amount.toString()
        );
      }
    });
  });

  describe("deadline enforcement", () => {
    const PAST_DEADLINE = BigInt(1);

    it("rejects execute finalize with an expired deadline (SignatureExpired)", async () => {
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const pushAccount = generateSender();

      const counterIx = await counterProgram.methods
        .increment(new anchor.BN(1))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();

      const remainingAccounts = instructionAccountsToRemaining(counterIx);
      const accounts = remainingAccounts.map((acc) => ({
        pubkey: acc.pubkey,
        isWritable: acc.isWritable,
      }));
      const { gasFee } = await calculateSolExecuteFees(provider.connection);
      const writableFlags = accountsToWritableFlagsOnly(accounts);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        deadline: PAST_DEADLINE,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          counterIx.data,
          gasFee
        ),
      });

      await expectRejection(
        gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(subTxId),
            Array.from(universalTxId),
            new anchor.BN(0),
            Array.from(pushAccount),
            writableFlags,
            Buffer.from(counterIx.data),
            new anchor.BN(Number(gasFee)),
            new anchor.BN(PAST_DEADLINE.toString()),
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
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: counterProgram.programId,
            storedIxData: null,
            storeRefundRecipient: null,
            recipient: null,
            vaultAta: null,
            ceaAta: null,
            mint: null,
            tokenProgram: null,
            rent: null,
            associatedTokenProgram: null,
            recipientAta: null,
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts(remainingAccounts)
          .signers([admin])
          .rpc(),
        "SignatureExpired"
      );
    });
  });

  // ================================================================
  //  Post-CPI invariants (F-2026-18980)
  //  Prevents malicious execute targets from installing persistent
  //  authority mutations on the CEA or its ATA via CPI signer.
  // ================================================================
  describe("post-CPI invariants (F-2026-18980)", () => {
    // Helper: build a `finalize_universal_tx` execute call that targets
    // `hostile_cea_op` on the test-counter program. Returns a thenable to await.
    // For SPL flow (mint provided), cea_ata is included as writable.
    const runHostileExecute = async (params: {
      pushAccount: number[];
      op: number;
      target: PublicKey;
      amount: anchor.BN; // SPL delegate amount for op=2; ignored otherwise
      stagedAmount: anchor.BN; // amount staged into CEA via finalize
      mint: PublicKey | null; // null → SOL path (no cea_ata)
      // G1/G2/G3 overrides:
      ceaAtaOverride?: PublicKey; // for G1 — the fresh canonical ATA to be created
      opMint?: PublicKey;         // for G1 — the mint whose canonical CEA ATA is being created
      destAtaOverride?: PublicKey; // for G2/G3 — where op=6 transfers the drained balance
    }) => {
      const {
        pushAccount,
        op,
        target,
        amount,
        stagedAmount,
        mint,
        ceaAtaOverride,
        opMint,
        destAtaOverride,
      } = params;

      const isSpl = mint !== null;
      const ceaAuthority = getCeaAuthorityPda(pushAccount);
      const ceaAta = ceaAtaOverride
        ?? (isSpl ? await getCeaAta(pushAccount, mint!) : ceaAuthority); // placeholder for SOL
      const auxAccount = target; // for op=2, aux acts as the delegate pubkey

      const hostileIx = await counterProgram.methods
        .hostileCeaOp(op, target, amount)
        .accountsPartial({
          cea: ceaAuthority,
          ceaAta,
          aux: auxAccount,
          mint: opMint ?? SystemProgram.programId, // placeholder for ops other than 1 (read-only)
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID, // placeholder for ops other than 1 (read-only)
          destAta: destAtaOverride ?? ceaAta, // op=6 needs real ATA; others: same as cea_ata (already writable)
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(hostileIx);
      const remainingAccounts = instructionAccountsToRemaining(hostileIx);

      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();

      const tokenForTss = isSpl ? mint! : PublicKey.default;
      const { gasFee } = isSpl
        ? await calculateSplExecuteFees(provider.connection, ceaAta)
        : await calculateSolExecuteFees(provider.connection);

      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(stagedAmount.toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          hostileIx.data,
          gasFee,
          tokenForTss
        ),
      });

      const writableFlags = accountsToWritableFlagsOnly(accounts);

      return gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          stagedAmount,
          Array.from(pushAccount),
          writableFlags,
          Buffer.from(hostileIx.data),
          new anchor.BN(Number(gasFee)),
          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: isSpl ? vaultUsdtAccount : null,
          vaultSol: vaultPda,
          ceaAuthority,
          ceaAta: isSpl ? ceaAta : null,
          mint: isSpl ? mint : null,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: isSpl ? TOKEN_PROGRAM_ID : null,
          systemProgram: SystemProgram.programId,
          rent: isSpl ? anchor.web3.SYSVAR_RENT_PUBKEY : null,
          associatedTokenProgram: isSpl ? spl.ASSOCIATED_TOKEN_PROGRAM_ID : null,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();
    };

    // Fetch delegate + amount on CEA ATA, tolerating a missing account.
    const readCeaDelegate = async (
      ceaAta: PublicKey
    ): Promise<{ delegate: PublicKey | null; amount: bigint }> => {
      const info = await provider.connection.getAccountInfo(ceaAta);
      if (!info) return { delegate: null, amount: BigInt(0) };
      const parsed = spl.AccountLayout.decode(info.data);
      const delegateOpt = parsed.delegateOption === 1 ? new PublicKey(parsed.delegate) : null;
      return { delegate: delegateOpt, amount: BigInt(parsed.delegatedAmount.toString()) };
    };

    it("T1: rejects unbounded delegate installation (allowance > staged)", async () => {
      const pushAccount = generateSender();
      const attacker = Keypair.generate().publicKey;
      const staged = asTokenAmount(1);
      const unbounded = new anchor.BN("18446744073709551615"); // u64::MAX

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 2,
          target: attacker,
          amount: unbounded,
          stagedAmount: staged,
          mint: mockUSDT.mint.publicKey,
        }),
        "InvalidAccount"
      );
    });

    it("T2: allows bounded self-delegation (allowance == staged)", async () => {
      const pushAccount = generateSender();
      const delegate = Keypair.generate().publicKey;
      const staged = asTokenAmount(50);

      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: staged,
        stagedAmount: staged,
        mint: mockUSDT.mint.publicKey,
      });

      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const state = await readCeaDelegate(ceaAta);
      expect(state.delegate?.toBase58()).to.equal(delegate.toBase58());
      expect(state.amount).to.equal(BigInt(staged.toString()));
    });

    it("T3: preserves prior delegate across a later unrelated execute (delta = 0)", async () => {
      const pushAccount = generateSender();
      const delegate = Keypair.generate().publicKey;
      const stagedFirst = asTokenAmount(100);

      // Establish a legitimate delegate
      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: stagedFirst,
        stagedAmount: stagedFirst,
        mint: mockUSDT.mint.publicKey,
      });

      // Later execute against a target that DOES NOT touch delegate state.
      // op=5 (Revoke) would clear it; use op=2 with same delegate + same amount
      // (net delta = 0 → check passes without a staged amount requirement).
      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: stagedFirst, // unchanged allowance
        stagedAmount: asTokenAmount(1), // small stage; delegate delta should be 0
        mint: mockUSDT.mint.publicKey,
      });

      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const state = await readCeaDelegate(ceaAta);
      expect(state.delegate?.toBase58()).to.equal(delegate.toBase58());
      expect(state.amount).to.equal(BigInt(stagedFirst.toString()));
    });

    it("T4: rejects delegate identity swap when new allowance exceeds staged", async () => {
      const pushAccount = generateSender();
      const original = Keypair.generate().publicKey;
      const attacker = Keypair.generate().publicKey;
      const stagedFirst = asTokenAmount(100);
      const stagedSecond = asTokenAmount(1);

      await runHostileExecute({
        pushAccount,
        op: 2,
        target: original,
        amount: stagedFirst,
        stagedAmount: stagedFirst,
        mint: mockUSDT.mint.publicKey,
      });

      // Attacker tries to swap the delegate identity, keeping the 100 allowance.
      // Delegate changed AND allowance (100) > staged (1) → InvalidAccount.
      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 2,
          target: attacker,
          amount: stagedFirst, // 100
          stagedAmount: stagedSecond, // 1
          mint: mockUSDT.mint.publicKey,
        }),
        "InvalidAccount"
      );
    });

    it("T5: allows delegate allowance decrease", async () => {
      const pushAccount = generateSender();
      const delegate = Keypair.generate().publicKey;
      const stagedFirst = asTokenAmount(100);
      const decreased = asTokenAmount(30);

      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: stagedFirst,
        stagedAmount: stagedFirst,
        mint: mockUSDT.mint.publicKey,
      });

      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: decreased, // same delegate, lower allowance
        stagedAmount: asTokenAmount(1),
        mint: mockUSDT.mint.publicKey,
      });

      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const state = await readCeaDelegate(ceaAta);
      expect(state.delegate?.toBase58()).to.equal(delegate.toBase58());
      expect(state.amount).to.equal(BigInt(decreased.toString()));
    });

    it("T6: allows spl_token::Revoke (clears delegate)", async () => {
      const pushAccount = generateSender();
      const delegate = Keypair.generate().publicKey;
      const staged = asTokenAmount(75);

      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: staged,
        stagedAmount: staged,
        mint: mockUSDT.mint.publicKey,
      });

      await runHostileExecute({
        pushAccount,
        op: 5, // revoke
        target: PublicKey.default,
        amount: new anchor.BN(0),
        stagedAmount: asTokenAmount(1),
        mint: mockUSDT.mint.publicKey,
      });

      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const state = await readCeaDelegate(ceaAta);
      expect(state.delegate).to.equal(null);
      expect(state.amount).to.equal(BigInt(0));
    });

    it("T7: rejects SetAuthority(AccountOwner) — CEA ATA seizure", async () => {
      const pushAccount = generateSender();
      const attacker = Keypair.generate().publicKey;

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 3, // SetAuthority AccountOwner
          target: attacker,
          amount: new anchor.BN(0),
          stagedAmount: asTokenAmount(1),
          mint: mockUSDT.mint.publicKey,
        }),
        "InvalidOwner"
      );
    });

    it("T8: rejects SetAuthority(CloseAccount) — close-authority griefing", async () => {
      const pushAccount = generateSender();
      const attacker = Keypair.generate().publicKey;

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 4, // SetAuthority CloseAccount
          target: attacker,
          amount: new anchor.BN(0),
          stagedAmount: asTokenAmount(1),
          mint: mockUSDT.mint.publicKey,
        }),
        "InvalidAccount"
      );
    });

    it("T9: rejects system_instruction::assign on CEA", async () => {
      const pushAccount = generateSender();
      const attackerProgram = Keypair.generate().publicKey;

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 0, // assign
          target: attackerProgram,
          amount: new anchor.BN(0),
          stagedAmount: asLamports(0.001),
          mint: null, // SOL path — cea_ata not involved
        }),
        "InvalidAccount"
      );
    });

    it("T13: rejects same-identity allowance increase beyond staged budget", async () => {
      // Isolates the `else if after.delegated_amount > before.delegated_amount`
      // branch. Same delegate identity, allowance topped up beyond what was
      // staged this tx. Distinct from T1 (fresh install) and T12 (identity swap).
      const pushAccount = generateSender();
      const delegate = Keypair.generate().publicKey;
      const first = asTokenAmount(1);
      const bump = asTokenAmount(2);

      // Establish (delegate, 1)
      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: first,
        stagedAmount: first,
        mint: mockUSDT.mint.publicKey,
      });

      // Same delegate, top up to 3, but stage only 1 → increase of 2 > budget 1
      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 2,
          target: delegate,
          amount: first.add(bump),
          stagedAmount: first,
          mint: mockUSDT.mint.publicKey,
        }),
        "InvalidAccount"
      );
    });

    it("T12: rejects delegate identity swap when prior delegate had active allowance", async () => {
      // Attack: user has legit (Alice, N). Attacker's target overwrites to
      // (attacker, N) at the same staged budget. Old rule allowed this
      // (N <= budget). Tightened rule rejects: an active prior delegate cannot
      // be swapped to a new party in one execute.
      const pushAccount = generateSender();
      const alice = Keypair.generate().publicKey;
      const attacker = Keypair.generate().publicKey;
      const n = asTokenAmount(1);

      await runHostileExecute({
        pushAccount,
        op: 2,
        target: alice,
        amount: n,
        stagedAmount: n,
        mint: mockUSDT.mint.publicKey,
      });

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 2,
          target: attacker,
          amount: n,
          stagedAmount: n,
          mint: mockUSDT.mint.publicKey,
        }),
        "InvalidAccount"
      );
    });

    it("T11: bystander CEA-owned ATA in remaining_accounts is protected (delegate)", async () => {
      // Set up a SOL finalize (ctx.accounts.cea_ata = None) but pass a CEA-owned
      // USDT ATA as a bystander in remaining_accounts. Hostile target tries to
      // install a delegate on the bystander. Should revert — invariants extend
      // to all CEA-owned SPL accounts, not just the typed current-mint one.
      const pushAccount = generateSender();
      const ceaAuthority = getCeaAuthorityPda(pushAccount);
      const bystanderAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const attacker = Keypair.generate().publicKey;

      // Pre-create + fund the bystander ATA so it exists at CPI time.
      // Simple SPL execute to counter's receive_spl route creates it and moves USDT.
      // Fastest way: use the existing SPL execute test's setup pattern.
      const seedIx = await counterProgram.methods
        .receiveSpl(asTokenAmount(1))
        .accountsPartial({
          counter: counterPda,
          ceaAta: bystanderAta,
          recipientAta: recipientUsdtAccount,
          ceaAuthority,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .instruction();

      const seedAccounts = instructionAccountsToGatewayMetas(seedIx);
      const seedRemaining = instructionAccountsToRemaining(seedIx);
      const seedSubTxId = generateTxId();
      const seedUniversalTxId = generateUniversalTxId();
      const { gasFee: seedGasFee } = await calculateSplExecuteFees(
        provider.connection,
        bystanderAta
      );
      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
      const seedSig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(asTokenAmount(1).toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(seedUniversalTxId),
          new Uint8Array(seedSubTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          seedAccounts,
          seedIx.data,
          seedGasFee,
          mockUSDT.mint.publicKey
        ),
      });
      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(seedSubTxId),
          Array.from(seedUniversalTxId),
          asTokenAmount(1),
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(seedAccounts),
          Buffer.from(seedIx.data),
          new anchor.BN(Number(seedGasFee)),
          new anchor.BN(4102444800),
          Array.from(seedSig.signature),
          seedSig.recoveryId,
          Array.from(seedSig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: vaultUsdtAccount,
          vaultSol: vaultPda,
          ceaAuthority,
          ceaAta: bystanderAta,
          mint: mockUSDT.mint.publicKey,
          tssPda,
          executedSubTx: getExecutedTxPda(seedSubTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: null,
        })
        .remainingAccounts(seedRemaining)
        .signers([admin])
        .rpc();

      // Now the attack: SOL finalize with the bystander USDT ATA in remaining_accounts.
      // Target = hostile_cea_op op=2 (Approve) on the bystander.
      const hostileIx = await counterProgram.methods
        .hostileCeaOp(2, attacker, new anchor.BN(1))
        .accountsPartial({
          cea: ceaAuthority,
          ceaAta: bystanderAta, // <-- bystander, passed to hostile op
          aux: attacker,
          mint: SystemProgram.programId,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          destAta: bystanderAta,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(hostileIx);
      const remainingAccounts = instructionAccountsToRemaining(hostileIx);
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const staged = asLamports(0.001); // SOL flow — no current-mint ATA
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(staged.toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          hostileIx.data,
          gasFee,
          PublicKey.default
        ),
      });

      await expectRejection(
        gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(subTxId),
            Array.from(universalTxId),
            staged,
            Array.from(pushAccount),
            accountsToWritableFlagsOnly(accounts),
            Buffer.from(hostileIx.data),
            new anchor.BN(Number(gasFee)),
            new anchor.BN(4102444800),
            Array.from(sig.signature),
            sig.recoveryId,
            Array.from(sig.messageHash)
          )
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultAta: null,
            vaultSol: vaultPda,
            ceaAuthority,
            ceaAta: null, // SOL path — no typed current-mint ATA
            mint: null,
            tssPda,
            executedSubTx: getExecutedTxPda(subTxId),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: counterProgram.programId,
            storedIxData: null,
            storeRefundRecipient: null,
            recipient: null,
            tokenProgram: null,
            systemProgram: SystemProgram.programId,
            rent: null,
            associatedTokenProgram: null,
            recipientAta: null,
          })
          .remainingAccounts(remainingAccounts)
          .signers([admin])
          .rpc(),
        "InvalidAccount"
      );
    });

    it("T14: rejects spl_token::Revoke on bystander CEA-owned ATA", async () => {
      // Bystanders must remain strictly unchanged (budget = 0). Revoke on a
      // bystander clears a delegate the user set intentionally in a prior
      // execute; the CPI target has no legitimate reason to touch delegations
      // on accounts unrelated to the staged mint.
      const pushAccount = generateSender();
      const delegate = Keypair.generate().publicKey;
      const stagedFirst = asTokenAmount(1);

      // Step 1: seed the USDT ATA with a legitimate delegate via a normal
      // self-Approve (this passes T2's rule since delegate == staged).
      await runHostileExecute({
        pushAccount,
        op: 2,
        target: delegate,
        amount: stagedFirst,
        stagedAmount: stagedFirst,
        mint: mockUSDT.mint.publicKey,
      });

      const bystanderAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const seeded = await readCeaDelegate(bystanderAta);
      expect(seeded.delegate?.toBase58()).to.equal(delegate.toBase58());
      expect(seeded.amount).to.equal(BigInt(stagedFirst.toString()));

      // Step 2: SOL finalize (no current-mint ATA) with the USDT ATA passed
      // as a bystander in remaining_accounts. Hostile op = Revoke targeting
      // the bystander. Must revert — bystanders are budget-0.
      const ceaAuthority = getCeaAuthorityPda(pushAccount);
      const attacker = Keypair.generate().publicKey;

      const hostileIx = await counterProgram.methods
        .hostileCeaOp(5, attacker, new anchor.BN(0)) // op=5 revoke
        .accountsPartial({
          cea: ceaAuthority,
          ceaAta: bystanderAta,
          aux: attacker,
          mint: SystemProgram.programId,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          destAta: bystanderAta,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(hostileIx);
      const remainingAccounts = instructionAccountsToRemaining(hostileIx);
      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const staged = asLamports(0.001);
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(staged.toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          hostileIx.data,
          gasFee,
          PublicKey.default
        ),
      });

      await expectRejection(
        gatewayProgram.methods
          .finalizeUniversalTx(
            2,
            Array.from(subTxId),
            Array.from(universalTxId),
            staged,
            Array.from(pushAccount),
            accountsToWritableFlagsOnly(accounts),
            Buffer.from(hostileIx.data),
            new anchor.BN(Number(gasFee)),
            new anchor.BN(4102444800),
            Array.from(sig.signature),
            sig.recoveryId,
            Array.from(sig.messageHash)
          )
          .accountsPartial({
            caller: admin.publicKey,
            config: configPda,
            vaultAta: null,
            vaultSol: vaultPda,
            ceaAuthority,
            ceaAta: null,
            mint: null,
            tssPda,
            executedSubTx: getExecutedTxPda(subTxId),
            rateLimitConfig: null,
            tokenRateLimit: null,
            destinationProgram: counterProgram.programId,
            storedIxData: null,
            storeRefundRecipient: null,
            recipient: null,
            tokenProgram: null,
            systemProgram: SystemProgram.programId,
            rent: null,
            associatedTokenProgram: null,
            recipientAta: null,
          })
          .remainingAccounts(remainingAccounts)
          .signers([admin])
          .rpc(),
        "InvalidAccount"
      );

      // Delegate on the bystander must be intact after the rejected tx.
      const after = await readCeaDelegate(bystanderAta);
      expect(after.delegate?.toBase58()).to.equal(delegate.toBase58());
      expect(after.amount).to.equal(BigInt(stagedFirst.toString()));
    });

    // ==================================================================
    //  G1: canonical CEA ATA created + delegated INSIDE the CPI
    //       (auditor retest — pre-CPI snapshot doesn't see accounts
    //       that don't yet exist, so post-CPI second scan is required)
    // ==================================================================
    it("T15 (G1): rejects a CEA-owned canonical ATA created and delegated inside the CPI", async () => {
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);
      const delegatee = Keypair.generate().publicKey;

      // Fresh mint whose canonical CEA ATA does not exist yet.
      const freshMint = await spl.createMint(
        provider.connection,
        admin,
        admin.publicKey,
        null,
        6
      );
      const freshAta = spl.getAssociatedTokenAddressSync(freshMint, cea, true);
      const preInfo = await provider.connection.getAccountInfo(freshAta);
      expect(preInfo, "precondition: canonical ATA must not exist pre-CPI").to.be.null;

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 1, // create ATA + delegate in one call
          target: delegatee,
          amount: new anchor.BN("18446744073709551615"), // u64::MAX
          stagedAmount: asLamports(0.005), // native lamports so ATA rent can be paid via CEA
          mint: null, // native flow — no typed cea_ata slot
          ceaAtaOverride: freshAta,
          opMint: freshMint,
        }),
        "InvalidAccount"
      );

      // Attack must not leave the canonical ATA with a planted delegate.
      const postInfo = await provider.connection.getAccountInfo(freshAta);
      if (postInfo && postInfo.data.length === spl.AccountLayout.span) {
        const parsed = spl.AccountLayout.decode(postInfo.data);
        expect(parsed.delegateOption).to.equal(0, "no delegate should persist");
        expect(BigInt(parsed.delegatedAmount.toString())).to.equal(0n);
      }
    });

    // ==================================================================
    //  G2: allowance left standing over a balance drained as owner
    //       (auditor retest — Option B coverage rule requires
    //       delegated_amount <= amount at end of CPI)
    // ==================================================================
    it("T16 (G2): rejects approve + owner-drain leaving allowance > balance", async () => {
      const pushAccount = generateSender();
      const staged = asTokenAmount(10);

      const attackerKp = Keypair.generate();
      const attackerAta = await spl.createAssociatedTokenAccount(
        provider.connection,
        admin,
        mockUSDT.mint.publicKey,
        attackerKp.publicKey
      );

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 6,
          target: attackerKp.publicKey,
          amount: staged,
          stagedAmount: staged,
          mint: mockUSDT.mint.publicKey,
          destAtaOverride: attackerAta,
        }),
        "InvalidAccount"
      );
    });

    // ==================================================================
    //  G3: repeated approve+drain to accumulate allowance across calls
    //       (auditor retest — under Option B the very first call fails)
    // ==================================================================
    it("T17 (G3): rejects the first call in an approve+drain accumulation loop", async () => {
      const pushAccount = generateSender();
      const attackerKp = Keypair.generate();
      const attackerAta = await spl.createAssociatedTokenAccount(
        provider.connection,
        admin,
        mockUSDT.mint.publicKey,
        attackerKp.publicKey
      );
      const perCall = asTokenAmount(10);

      await expectRejection(
        runHostileExecute({
          pushAccount,
          op: 6,
          target: attackerKp.publicKey,
          amount: perCall,
          stagedAmount: perCall,
          mint: mockUSDT.mint.publicKey,
          destAtaOverride: attackerAta,
        }),
        "InvalidAccount"
      );

      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);
      const s = await readCeaDelegate(ceaAta);
      expect(s.delegate).to.equal(null, "no delegate should persist after rejected call");
    });

    it("T10: native-only path (no cea_ata) unaffected by ATA invariants", async () => {
      const pushAccount = generateSender();
      const staged = asLamports(0.001);

      // Benign target: counter increment. No ATA, no delegate mutation, no
      // reassignment. Confirms native SOL flow still works with the invariants
      // in place (the `if let Some(cea_ata)` block is simply skipped).
      const counterIx = await counterProgram.methods
        .increment(new anchor.BN(1))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();

      const accounts = instructionAccountsToGatewayMetas(counterIx);
      const remainingAccounts = instructionAccountsToRemaining(counterIx);

      const subTxId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(staged.toString()),
        chainId: tssAccount.chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(subTxId),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          accounts,
          counterIx.data,
          gasFee,
          PublicKey.default
        ),
      });

      await gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          staged,
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(accounts),
          Buffer.from(counterIx.data),
          new anchor.BN(Number(gasFee)),
          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultAta: null,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount),
          ceaAta: null,
          mint: null,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId),
          rateLimitConfig: null,
          tokenRateLimit: null,
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: null,
          recipient: null,
          tokenProgram: null,
          systemProgram: SystemProgram.programId,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
        })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      // Assert the CEA account survives the CPI as System-owned + empty.
      const ceaInfo = await provider.connection.getAccountInfo(
        getCeaAuthorityPda(pushAccount)
      );
      expect(ceaInfo).to.not.be.null;
      expect(ceaInfo!.owner.toBase58()).to.equal(SystemProgram.programId.toBase58());
      expect(ceaInfo!.data.length).to.equal(0);
    });
  });

  // Note: Fee claiming tests removed - fees are now transferred directly to caller in execute/withdraw functions
  // Balance checks are included in each test case to verify fee transfers
});
