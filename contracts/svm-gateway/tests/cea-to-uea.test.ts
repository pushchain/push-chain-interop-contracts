import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import {
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddress,
  createAssociatedTokenAccountInstruction,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import * as spl from "@solana/spl-token";
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
import {
  USDT_DECIMALS,
  TOKEN_MULTIPLIER,
  COMPUTE_BUFFER,
  SIGNATURE_FEE_LAMPORTS,
  asLamports,
  asTokenAmount,
  computeDiscriminator,
  makeTxIdGenerator,
  generateSender,
  getExecutedTxPda as _getExecutedTxPda,
  getCeaAuthorityPda as _getCeaAuthorityPda,
  getCeaAta as _getCeaAta,
  getExecutedTxRent,
  getTokenAccountRent,
  ceaAtaExists,
  calculateSolExecuteFees,
  calculateSplExecuteFees,
  instructionAccountsToGatewayMetas,
  instructionAccountsToRemaining,
  accountsToWritableFlagsOnly,
} from "./helpers/test-utils";
import {
  makeFinalizeUniversalTxBuilder,
  FinalizeUniversalTxArgs,
} from "./helpers/builders";

describe("Universal Gateway - CEA to UEA Tests", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const provider = anchor.getProvider() as anchor.AnchorProvider;
  const gatewayProgram = anchor.workspace
    .UniversalGateway as Program<UniversalGateway>;
  const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

  before(async () => {
    await ensureTestSetup();
  });

  let admin: Keypair;

  let configPda: PublicKey;
  let vaultPda: PublicKey;
  let tssPda: PublicKey;
  let rateLimitConfigPda: PublicKey;
  let nativeSolTokenRateLimitPda: PublicKey;
  let usdtTokenRateLimitPda: PublicKey;

  let mockUSDT: any;
  let vaultUsdtAccount: PublicKey;

  let counterPda: PublicKey;
  let counterAuthority: Keypair;

  let finalizeUniversalTx: ReturnType<typeof makeFinalizeUniversalTxBuilder>;

  const generateTxId = makeTxIdGenerator();
  const getExecutedTxPda = (subTxId: number[]) =>
    _getExecutedTxPda(subTxId, gatewayProgram.programId);
  const getCeaAuthorityPda = (pushAccount: number[]) =>
    _getCeaAuthorityPda(pushAccount, gatewayProgram.programId);
  const getCeaAta = (pushAccount: number[], mint: PublicKey) =>
    _getCeaAta(pushAccount, mint, gatewayProgram.programId);

  before(async () => {
    admin = sharedState.getAdmin();
    mockUSDT = sharedState.getMockUSDT();
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

    // Normalize token rate limits so this suite doesn't inherit stale 0-threshold state.
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

    // Get vault ATA and create if needed
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

    // Fund vault with SOL (needed for execute operations in these tests)
    const vaultSolTx = new anchor.web3.Transaction().add(
      anchor.web3.SystemProgram.transfer({
        fromPubkey: admin.publicKey,
        toPubkey: vaultPda,
        lamports: asLamports(100).toNumber(),
      })
    );
    await provider.sendAndConfirm(vaultSolTx, [admin]);

    // Fund vault with USDT tokens (needed for SPL execute tests)
    await mockUSDT.mintTo(vaultUsdtAccount, 1000);

    // Initialize test counter with dedicated authority
    [counterPda] = PublicKey.findProgramAddressSync(
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
    } catch {
      // Already initialized — fine
    }

    finalizeUniversalTx = makeFinalizeUniversalTxBuilder(
      gatewayProgram,
      configPda,
      vaultPda,
      tssPda
    );
  });

  describe("CEA → UEA: SOL", () => {
    it("should allow gateway self-call to withdraw SOL from CEA", async () => {
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      // 1) Fund CEA via execute (amount > 0, target = counterProgram)
      const txIdFund = generateTxId();
      const universalTxIdFund = generateUniversalTxId();
      const fundAmount = asLamports(1);
      const counterIx = await counterProgram.methods
        .increment(new anchor.BN(0))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();
      // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
      const remainingAccounts = instructionAccountsToRemaining(counterIx);
      const fundAccounts = remainingAccounts.map((acc) => ({
        pubkey: acc.pubkey,
        isWritable: acc.isWritable,
      }));

      // Calculate fees dynamically for fund operation
      const { gasFee: gasFeeFund } = await calculateSolExecuteFees(
        provider.connection
      );
      const legacyTopupFund = BigInt(0);

      const sigFund = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(fundAmount.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxIdFund),
          new Uint8Array(txIdFund),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          fundAccounts,
          counterIx.data,
          gasFeeFund
        ),
      });

      const fundWritableFlags = accountsToWritableFlagsOnly(fundAccounts);
      await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txIdFund,
        universalTxId: universalTxIdFund,
        amount: fundAmount,
        pushAccount,
        writableFlags: fundWritableFlags,
        ixData: Buffer.from(counterIx.data),
        gasFee: new anchor.BN(Number(gasFeeFund)),
        sig: sigFund,
        caller: admin.publicKey,
        destinationProgram: counterProgram.programId,
      })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      const ceaBalBefore = await provider.connection.getBalance(cea);
      expect(ceaBalBefore).to.be.greaterThan(0);

      // 2) Withdraw all SOL from CEA via gateway self-call (target = gateway)
      const txIdWithdraw = generateTxId();
      const universalTxIdWithdraw = generateUniversalTxId();
      const withdrawDiscr = computeDiscriminator(
        "global:send_universal_tx_to_uea"
      );

      // Drain full CEA balance.
      const { gasFee: gasFeeWithdraw } = await calculateSolExecuteFees(
        provider.connection
      );
      const ceaDrainAmount = BigInt(ceaBalBefore);

      const withdrawArgs = Buffer.concat([
        Buffer.alloc(32, 0), // token = Pubkey::default()
        (() => {
          const b = Buffer.alloc(8);
          b.writeBigUInt64LE(ceaDrainAmount);
          return b;
        })(),
        Buffer.from([0, 0, 0, 0]), // payload = empty Vec<u8> (Borsh: 4-byte LE length = 0)
        cea.toBuffer(), // revert_recipient = CEA itself
      ]);
      const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

      const sigW = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxIdWithdraw),
          new Uint8Array(txIdWithdraw),
          gatewayProgram.programId,
          new Uint8Array(pushAccount),
          [],
          withdrawIxData,
          gasFeeWithdraw
        ),
      });

      const callerBalanceBeforeWithdraw = await provider.connection.getBalance(
        admin.publicKey
      );
      const withdrawWritableFlags = accountsToWritableFlagsOnly([]);
      await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txIdWithdraw,
        universalTxId: universalTxIdWithdraw,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags: withdrawWritableFlags,
        ixData: withdrawIxData,
        gasFee: new anchor.BN(Number(gasFeeWithdraw)),
        sig: sigW,
        caller: admin.publicKey,
        destinationProgram: gatewayProgram.programId,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
      })
        .signers([admin])
        .rpc();

      const callerBalanceAfterWithdraw = await provider.connection.getBalance(
        admin.publicKey
      );
      const actualBalanceChangeWithdraw =
        callerBalanceAfterWithdraw - callerBalanceBeforeWithdraw;
      // Relayer pays sub_tx_rent upfront; receives gas_used back from vault.
      // gas_used = SIGNATURE_FEE + sub_tx_rent (SOL path, no ATA).
      // Net change for relayer ≈ SIGNATURE_FEE - tx_fees ≈ 0.
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const gasUsedWithdraw = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx;
      const expectedBalanceChangeWithdraw =
        -actualRentForExecutedTx + gasUsedWithdraw;
      expect(actualBalanceChangeWithdraw).to.be.closeTo(
        expectedBalanceChangeWithdraw,
        50000
      );

      const ceaBalAfter = await provider.connection.getBalance(cea);
      expect(ceaBalAfter).to.equal(0);
    });

    it("should emit FundsAndPayload + from_cea when CEA withdrawal has non-empty payload", async () => {
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      // 1) Fund CEA via execute
      const txIdFund = generateTxId();
      const universalTxIdFund = generateUniversalTxId();
      const fundAmount = asLamports(1);
      const counterIx = await counterProgram.methods
        .increment(new anchor.BN(0))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();
      const remainingAccounts = instructionAccountsToRemaining(counterIx);
      const fundAccounts = remainingAccounts.map((acc) => ({
        pubkey: acc.pubkey,
        isWritable: acc.isWritable,
      }));

      const { gasFee: gasFeeFund } = await calculateSolExecuteFees(
        provider.connection
      );
      const legacyTopupFund = BigInt(0);

      const sigFund = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(fundAmount.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxIdFund),
          new Uint8Array(txIdFund),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          fundAccounts,
          counterIx.data,
          gasFeeFund
        ),
      });

      await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txIdFund,
        universalTxId: universalTxIdFund,
        amount: fundAmount,
        pushAccount,
        writableFlags: accountsToWritableFlagsOnly(fundAccounts),
        ixData: Buffer.from(counterIx.data),
        gasFee: new anchor.BN(Number(gasFeeFund)),
        sig: sigFund,
        caller: admin.publicKey,
        destinationProgram: counterProgram.programId,
      })
        .remainingAccounts(remainingAccounts)
        .signers([admin])
        .rpc();

      // 2) Withdraw from CEA with a non-empty payload → FundsAndPayload + from_cea
      const txIdWithdraw = generateTxId();
      const universalTxIdWithdraw = generateUniversalTxId();
      const withdrawDiscr = computeDiscriminator(
        "global:send_universal_tx_to_uea"
      );
      const ceaPayload = Buffer.from([0x42, 0x00, 0x01]); // arbitrary non-empty payload

      // Read CEA balance and calculate fees before building args.
      const ceaBalBeforeP2 = await provider.connection.getBalance(cea);
      const { gasFee: gasFeeWithdraw, gasUsed: gasUsedWithdrawEvent } = await calculateSolExecuteFees(
        provider.connection
      );
      const legacyTopupWithdraw = BigInt(0);
      const ceaDrainAmountP2 = BigInt(ceaBalBeforeP2) + legacyTopupWithdraw;

      const withdrawArgs = Buffer.concat([
        Buffer.alloc(32, 0), // token = Pubkey::default() (SOL)
        (() => {
          const b = Buffer.alloc(8);
          b.writeBigUInt64LE(ceaDrainAmountP2);
          return b;
        })(),
        // payload = Vec<u8> (Borsh: 4-byte LE length + bytes)
        (() => {
          const lenBuf = Buffer.alloc(4);
          lenBuf.writeUInt32LE(ceaPayload.length, 0);
          return Buffer.concat([lenBuf, ceaPayload]);
        })(),
        cea.toBuffer(), // revert_recipient = CEA itself
      ]);
      const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

      const sigW = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxIdWithdraw),
          new Uint8Array(txIdWithdraw),
          gatewayProgram.programId,
          new Uint8Array(pushAccount),
          [],
          withdrawIxData,
          gasFeeWithdraw
        ),
      });

      const tx = await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txIdWithdraw,
        universalTxId: universalTxIdWithdraw,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags: accountsToWritableFlagsOnly([]),
        ixData: withdrawIxData,
        gasFee: new anchor.BN(Number(gasFeeWithdraw)),
        sig: sigW,
        caller: admin.publicKey,
        destinationProgram: gatewayProgram.programId,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
      })
        .signers([admin])
        .rpc();

      const events = await extractEventCpi(provider.connection, gatewayProgram, tx);

      // UniversalTx: FundsAndPayload + from_cea
      // Note: Anchor TS IDL converts PascalCase event names to camelCase (UniversalTx → universalTx)
      const universalTxEvent = events.find((e) => e.name === "universalTx");
      expect(universalTxEvent, "UniversalTx event not found").to.exist;
      expect(
        universalTxEvent.data.txType.fundsAndPayload !== undefined,
        "txType should be FundsAndPayload"
      ).to.be.true;
      expect(universalTxEvent.data.fromCea, "from_cea should be true").to.be
        .true;
      expect(
        Buffer.from(universalTxEvent.data.payload).toString("hex")
      ).to.equal(ceaPayload.toString("hex"));

      // UniversalTxFinalized should also be emitted for CEA→UEA path
      const finalizedEvent = events.find(
        (e) => e.name === "universalTxFinalized"
      );
      expect(
        finalizedEvent,
        "UniversalTxFinalized should be emitted for CEA→UEA path"
      ).to.exist;
      expect(finalizedEvent.data.target.toString()).to.equal(
        gatewayProgram.programId.toString()
      );
      expect(finalizedEvent.data.token.toString()).to.equal(
        new anchor.web3.PublicKey(new Uint8Array(32)).toString()
      );
      expect(finalizedEvent.data.amount.toString()).to.equal("0");
      expect(finalizedEvent.data.gasFee.toString()).to.equal(
        Number(gasFeeWithdraw).toString()
      );
      // New accounting fields: verify gas_used, gas_to_refund, ata_created
      expect(finalizedEvent.data.gasUsed.toString()).to.equal(
        gasUsedWithdrawEvent.toString()
      );
      expect(finalizedEvent.data.gasToRefund.toString()).to.equal(
        (gasFeeWithdraw - gasUsedWithdrawEvent).toString()
      );
      expect(finalizedEvent.data.ataCreated).to.equal(false); // SOL path — no ATA
      expect(Buffer.from(finalizedEvent.data.subTxId).toString("hex")).to.equal(
        Buffer.from(txIdWithdraw).toString("hex")
      );
      expect(
        Buffer.from(finalizedEvent.data.universalTxId).toString("hex")
      ).to.equal(Buffer.from(universalTxIdWithdraw).toString("hex"));
      expect(
        Buffer.from(finalizedEvent.data.pushAccount).toString("hex")
      ).to.equal(Buffer.from(pushAccount).toString("hex"));
      expect(Buffer.from(finalizedEvent.data.payload).toString("hex")).to.equal(
        withdrawIxData.toString("hex")
      );
    });

    it("should emit GasAndPayload when amount=0 but payload is non-empty", async () => {
      const pushAccount = generateSender();
      // No CEA funding needed — amount=0 means no vault→CEA and no CEA→vault transfer

      const txId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const ceaPayload = Buffer.from("deadbeef", "hex");
      const payloadBuf = Buffer.concat([
        (() => { const b = Buffer.alloc(4); b.writeUInt32LE(ceaPayload.length); return b; })(),
        ceaPayload,
      ]);
      const revertRecipient = anchor.web3.Keypair.generate().publicKey;

      const withdrawArgs = Buffer.concat([
        Buffer.alloc(32, 0),        // token = Pubkey::default()
        Buffer.alloc(8, 0),         // amount = 0
        payloadBuf,                 // non-empty payload
        revertRecipient.toBuffer(), // revert_recipient
      ]);
      const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(txId),
          gatewayProgram.programId,
          new Uint8Array(pushAccount),
          [],
          withdrawIxData,
          gasFee,
        ),
      });

      const tx = await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txId,
        universalTxId,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags: accountsToWritableFlagsOnly([]),
        ixData: withdrawIxData,
        gasFee: new anchor.BN(Number(gasFee)),
        sig,
        caller: admin.publicKey,
        destinationProgram: gatewayProgram.programId,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
      })
        .signers([admin])
        .rpc();

      const events = await extractEventCpi(provider.connection, gatewayProgram, tx);

      const universalTxEvent = events.find((e) => e.name === "universalTx");
      expect(universalTxEvent, "UniversalTx event not found").to.exist;
      expect(
        universalTxEvent.data.txType.gasAndPayload !== undefined,
        "txType should be GasAndPayload"
      ).to.be.true;
      expect(universalTxEvent.data.amount.toString()).to.equal("0");
      expect(universalTxEvent.data.fromCea, "from_cea should be true").to.be.true;
      expect(Buffer.from(universalTxEvent.data.payload).toString("hex")).to.equal(
        ceaPayload.toString("hex")
      );
    });

    it("rejects CEA → UEA self-call when both amount=0 and payload empty", async () => {
      const pushAccount = generateSender();
      const txId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");
      const { gasFee } = await calculateSolExecuteFees(provider.connection);

      const withdrawArgs = Buffer.concat([
        Buffer.alloc(32, 0),                                      // token = Pubkey::default()
        Buffer.alloc(8, 0),                                       // amount = 0
        Buffer.from([0, 0, 0, 0]),                                // empty payload
        anchor.web3.Keypair.generate().publicKey.toBuffer(),      // valid revert_recipient
      ]);
      const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(txId),
          gatewayProgram.programId,
          new Uint8Array(pushAccount),
          [],
          withdrawIxData,
          gasFee,
        ),
      });

      try {
        await finalizeUniversalTx({
          instructionId: 2,
          subTxId: txId,
          universalTxId,
          amount: new anchor.BN(0),
          pushAccount,
          writableFlags: accountsToWritableFlagsOnly([]),
          ixData: withdrawIxData,
          gasFee: new anchor.BN(Number(gasFee)),
          sig,
          caller: admin.publicKey,
          destinationProgram: gatewayProgram.programId,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
        })
          .signers([admin])
          .rpc();
        expect.fail("Should have thrown InvalidInput for zero amount and empty payload");
      } catch (err: any) {
        expect(err.toString()).to.include("InvalidInput");
      }
    });

    it("rejects CEA → UEA self-call with zero revert_recipient", async () => {
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);

      // Fund CEA with a small amount so the balance check passes before the recipient check
      const fundTx = new anchor.web3.Transaction().add(
        anchor.web3.SystemProgram.transfer({
          fromPubkey: admin.publicKey,
          toPubkey: cea,
          lamports: asLamports(0.1).toNumber(),
        })
      );
      await provider.sendAndConfirm(fundTx, [admin]);

      const txId = generateTxId();
      const universalTxId = generateUniversalTxId();
      const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");
      const { gasFee } = await calculateSolExecuteFees(provider.connection);
      const drainAmount = BigInt(await provider.connection.getBalance(cea));

      // Build args with zero (default) revert_recipient — should be rejected
      const withdrawArgs = Buffer.concat([
        Buffer.alloc(32, 0), // token = Pubkey::default()
        (() => { const b = Buffer.alloc(8); b.writeBigUInt64LE(drainAmount); return b; })(),
        Buffer.from([0, 0, 0, 0]), // empty payload
        Buffer.alloc(32, 0),       // revert_recipient = Pubkey::default() ← invalid
      ]);
      const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

      const sig = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxId),
          new Uint8Array(txId),
          gatewayProgram.programId,
          new Uint8Array(pushAccount),
          [],
          withdrawIxData,
          gasFee,
        ),
      });

      try {
        await finalizeUniversalTx({
          instructionId: 2,
          subTxId: txId,
          universalTxId,
          amount: new anchor.BN(0),
          pushAccount,
          writableFlags: accountsToWritableFlagsOnly([]),
          ixData: withdrawIxData,
          gasFee: new anchor.BN(Number(gasFee)),
          sig,
          caller: admin.publicKey,
          destinationProgram: gatewayProgram.programId,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
        })
          .signers([admin])
          .rpc();
        expect.fail("Should have thrown InvalidRecipient for zero revert_recipient");
      } catch (err: any) {
        expect(err.toString()).to.include("InvalidRecipient");
      }
    });
  });

  describe("CEA → UEA: SPL", () => {
    it("should allow gateway self-call to withdraw SPL from CEA", async () => {
      const pushAccount = generateSender();
      const cea = getCeaAuthorityPda(pushAccount);
      const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);

      // Fund CEA ATA via execute (amount > 0, target = counterProgram)
      const txIdFund = generateTxId();
      const universalTxIdFund = generateUniversalTxId();
      const fundAmount = asTokenAmount(25);

      // Calculate gas_fee dynamically (includes CEA ATA rent if needed)
      const ceaAtaExistedBefore = await ceaAtaExists(
        provider.connection,
        ceaAta
      );
      const { gasFee: gasFeeLamports } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );
      const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

      const counterIx = await counterProgram.methods
        .increment(new anchor.BN(0))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
        })
        .instruction();
      const fundAccounts = instructionAccountsToGatewayMetas(counterIx);
      const sigFund = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(fundAmount.toString()),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxIdFund),
          new Uint8Array(txIdFund),
          counterProgram.programId,
          new Uint8Array(pushAccount),
          fundAccounts,
          counterIx.data,
          gasFeeLamports,
          mockUSDT.mint.publicKey
        ),
      });

      const callerBalanceBeforeFund = await provider.connection.getBalance(
        admin.publicKey
      );
      const fundWritableFlagsSpl = accountsToWritableFlagsOnly(fundAccounts);
      await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txIdFund,
        universalTxId: universalTxIdFund,
        amount: fundAmount,
        pushAccount,
        writableFlags: fundWritableFlagsSpl,
        ixData: Buffer.from(counterIx.data),
        gasFee: gasFeeBn,
        sig: sigFund,
        caller: admin.publicKey,
        destinationProgram: counterProgram.programId,
        vaultAta: vaultUsdtAccount,
        ceaAta,
        mint: mockUSDT.mint.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
      })
        .remainingAccounts(instructionAccountsToRemaining(counterIx))
        .signers([admin])
        .rpc();
      console.log("finalizeUniversalTx (execute SPL) succeeded");
      // Verify caller received relayer_fee reimbursement
      const callerBalanceAfterFund = await provider.connection.getBalance(
        admin.publicKey
      );
      const callerBalanceChangeFund =
        callerBalanceAfterFund - callerBalanceBeforeFund;
      // Relayer pays sub_tx_rent + ata_rent (if created) upfront; receives gas_used back.
      // gas_used = SIGNATURE_FEE + sub_tx_rent + ata_rent; net ≈ SIGNATURE_FEE - tx_fees.
      const actualRentForExecutedTx = await getExecutedTxRent(
        provider.connection
      );
      const actualRentForCeaAta = ceaAtaExistedBefore
        ? 0
        : await getTokenAccountRent(provider.connection);
      const gasUsedFund = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx + actualRentForCeaAta;
      const expectedBalanceChangeFund =
        -actualRentForExecutedTx - actualRentForCeaAta + gasUsedFund;
      expect(callerBalanceChangeFund).to.be.closeTo(
        expectedBalanceChangeFund,
        100000
      ); // Allow for transaction fees (SPL txs are larger)

      const ceaAtaBefore = await provider.connection.getTokenAccountBalance(
        ceaAta
      );
      expect(Number(ceaAtaBefore.value.amount)).to.be.greaterThan(0);

      // Withdraw all SPL from CEA via gateway self-call (target = gateway)
      const txIdWithdraw = generateTxId();
      const universalTxIdWithdraw = generateUniversalTxId();
      const withdrawDiscr = computeDiscriminator(
        "global:send_universal_tx_to_uea"
      );
      const withdrawArgs = Buffer.concat([
        mockUSDT.mint.publicKey.toBuffer(),
        (() => {
          const b = Buffer.alloc(8);
          b.writeBigUInt64LE(BigInt(ceaAtaBefore.value.amount)); // full token balance
          return b;
        })(),
        Buffer.from([0, 0, 0, 0]), // payload = empty Vec<u8> (Borsh: 4-byte LE length = 0)
        cea.toBuffer(), // revert_recipient = CEA itself
      ]);
      const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

      // Calculate fees dynamically for withdraw operation (CEA ATA already exists)
      const { gasFee: gasFeeWithdrawSpl } = await calculateSplExecuteFees(
        provider.connection,
        ceaAta
      );

      const sigW = await signTssMessage({
        instruction: TssInstruction.Execute,
        amount: BigInt(0),
        chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
        additional: buildExecuteAdditionalData(
          new Uint8Array(universalTxIdWithdraw),
          new Uint8Array(txIdWithdraw),
          gatewayProgram.programId,
          new Uint8Array(pushAccount),
          [],
          withdrawIxData,
          gasFeeWithdrawSpl,
          mockUSDT.mint.publicKey
        ),
      });

      const callerBalanceBeforeWithdrawSpl =
        await provider.connection.getBalance(admin.publicKey);
      const withdrawWritableFlagsSpl = accountsToWritableFlagsOnly([]);
      console.log("finalizeUniversalTx (execute SPL) start");
      await finalizeUniversalTx({
        instructionId: 2,
        subTxId: txIdWithdraw,
        universalTxId: universalTxIdWithdraw,
        amount: new anchor.BN(0),
        pushAccount,
        writableFlags: withdrawWritableFlagsSpl,
        ixData: withdrawIxData,
        gasFee: new anchor.BN(Number(gasFeeWithdrawSpl)),
        sig: sigW,
        caller: admin.publicKey,
        destinationProgram: gatewayProgram.programId,
        vaultAta: vaultUsdtAccount,
        ceaAta,
        mint: mockUSDT.mint.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: usdtTokenRateLimitPda,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
      })
        .signers([admin])
        .rpc();
      console.log("finalizeUniversalTx (execute SPL) succeeded");
      // Verify caller received relayer_fee reimbursement (self-withdraw should also pay the caller)
      const callerBalanceAfterWithdrawSpl =
        await provider.connection.getBalance(admin.publicKey);
      const callerBalanceChangeWithdrawSpl =
        callerBalanceAfterWithdrawSpl - callerBalanceBeforeWithdrawSpl;
      // Relayer pays sub_tx_rent upfront; receives gas_used back (ATA already exists).
      // gas_used = SIGNATURE_FEE + sub_tx_rent; net ≈ SIGNATURE_FEE - tx_fees.
      // Reuse actualRentForExecutedTx from above (same test scope).
      const gasUsedWithdrawSpl = Number(SIGNATURE_FEE_LAMPORTS) + actualRentForExecutedTx;
      const expectedBalanceChangeWithdrawSpl =
        -actualRentForExecutedTx + gasUsedWithdrawSpl;
      expect(callerBalanceChangeWithdrawSpl).to.be.closeTo(
        expectedBalanceChangeWithdrawSpl,
        15000
      ); // Allow for transaction fees

      const ceaAtaAfter = await provider.connection.getTokenAccountBalance(
        ceaAta
      );
      expect(Number(ceaAtaAfter.value.amount)).to.equal(0);
    });
  });
});
