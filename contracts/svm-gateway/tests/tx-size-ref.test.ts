import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import {
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import {
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  getAssociatedTokenAddress,
  createAssociatedTokenAccountInstruction,
} from "@solana/spl-token";
import { expect } from "chai";
import pkg from "js-sha3";
import * as sharedState from "./shared-state";
import { ensureTestSetup } from "./helpers/test-setup";
import {
  buildExecuteAdditionalData,
  generateUniversalTxId,
  GatewayAccountMeta,
  signTssMessage,
  TssInstruction,
} from "./helpers/tss";
import { makeFinalizeUniversalTxBuilder } from "./helpers/builders";
import { extractEventCpi } from "./helpers/test-utils";
import {
  accountsToWritableFlagsOnly,
  calculateSplExecuteFees,
  calculateSolExecuteFees,
  computeDiscriminator,
  getCeaAta,
  getCeaAuthorityPda,
  getExecutedTxPda,
  getTokenRateLimitPda,
  instructionAccountsToGatewayMetas,
  instructionAccountsToRemaining,
  SIGNATURE_FEE_LAMPORTS,
  USDT_DECIMALS,
} from "./helpers/test-utils";

const { keccak_256 } = pkg;

describe("Universal Gateway - Tx Size Ref Finalize Tests", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const provider = anchor.getProvider() as anchor.AnchorProvider;
  const gatewayProgram = anchor.workspace
    .UniversalGateway as Program<UniversalGateway>;
  const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

  const getErrorCode = (error: any): string | undefined =>
    error?.error?.errorCode?.code ||
    error?.errorCode?.code ||
    error?.error?.errorCode ||
    error?.code ||
    /Error Code: ([A-Za-z0-9_]+)/.exec(String(error))?.[1];

  const expectRejection = async (promise: Promise<unknown>, message: string) => {
    let rejected = false;
    try {
      await promise;
    } catch (error: any) {
      rejected = true;
      const errorCode = getErrorCode(error);
      const errorStr = String(error);
      const matches =
        errorCode === message ||
        errorStr.includes(message) ||
        error?.error?.errorMessage?.includes?.(message);
      expect(matches, `Expected error "${message}", got ${errorStr}`).to.be.true;
    }
    expect(rejected, `Expected rejection with "${message}" but call succeeded`).to.be.true;
  };

  const deriveStoredIxDataPda = (
    subTxId: number[],
    ixDataHash: Uint8Array
  ): PublicKey => {
    const [pda] = PublicKey.findProgramAddressSync(
      [
        Buffer.from("stored_ix_data"),
        Buffer.from(subTxId),
        Buffer.from(ixDataHash),
      ],
      gatewayProgram.programId
    );
    return pda;
  };

  const decodeGatewayEvents = (signature: string) =>
    extractEventCpi(provider.connection, gatewayProgram, signature);

  const generateTxId = (): number[] => {
    const buffer = Buffer.alloc(32);
    buffer.writeUInt32BE(Math.floor(Math.random() * 0xffffffff), 0);
    buffer.writeUInt32BE(Date.now() % 0xffffffff, 4);
    for (let i = 8; i < 32; i++) buffer[i] = Math.floor(Math.random() * 256);
    return Array.from(buffer);
  };

  const generateSender = (): number[] => {
    const buffer = Buffer.alloc(20);
    for (let i = 0; i < 20; i++) buffer[i] = Math.floor(Math.random() * 256);
    if (buffer.every((b) => b === 0)) buffer[0] = 1;
    return Array.from(buffer);
  };

  const hashIxData = (ixData: Buffer): Uint8Array =>
    new Uint8Array(keccak_256.arrayBuffer(ixData));

  const asIxDataHashArg = (ixDataHash: Uint8Array): number[] =>
    Buffer.from(ixDataHash) as unknown as number[];

  before(async () => {
    await ensureTestSetup();
  });

  let admin: Keypair;
  let operator: Keypair;
  let storeRelayer: Keypair;
  let closeRelayer: Keypair;
  let counterAuthority: Keypair;
  let mockUSDT: any;

  let configPda: PublicKey;
  let vaultPda: PublicKey;
  let tssPda: PublicKey;
  let rateLimitConfigPda: PublicKey;
  let nativeSolTokenRateLimitPda: PublicKey;
  let usdtTokenRateLimitPda: PublicKey;
  let counterPda: PublicKey;
  let vaultUsdtAccount: PublicKey;
  let recipientUsdtAccount: PublicKey;
  let finalizeUniversalTx: ReturnType<typeof makeFinalizeUniversalTxBuilder>;

  before(async () => {
    admin = sharedState.getAdmin();
    operator = sharedState.getOperator();
    storeRelayer = sharedState.getUser1();
    closeRelayer = sharedState.getUser2();
    counterAuthority = sharedState.getCounterAuthority();
    mockUSDT = sharedState.getMockUSDT();

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
    [counterPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("counter")],
      counterProgram.programId
    );

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

    vaultUsdtAccount = await getAssociatedTokenAddress(
      mockUSDT.mint.publicKey,
      vaultPda,
      true,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const vaultAtaInfo = await provider.connection.getAccountInfo(vaultUsdtAccount);
    if (!vaultAtaInfo) {
      const createVaultAtaIx = createAssociatedTokenAccountInstruction(
        admin.publicKey,
        vaultUsdtAccount,
        vaultPda,
        mockUSDT.mint.publicKey,
        TOKEN_PROGRAM_ID,
        ASSOCIATED_TOKEN_PROGRAM_ID
      );
      await provider.sendAndConfirm(new Transaction().add(createVaultAtaIx), [admin]);
    }

    recipientUsdtAccount = await getAssociatedTokenAddress(
      mockUSDT.mint.publicKey,
      closeRelayer.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const recipientAtaInfo = await provider.connection.getAccountInfo(recipientUsdtAccount);
    if (!recipientAtaInfo) {
      const createRecipientAtaIx = createAssociatedTokenAccountInstruction(
        admin.publicKey,
        recipientUsdtAccount,
        closeRelayer.publicKey,
        mockUSDT.mint.publicKey,
        TOKEN_PROGRAM_ID,
        ASSOCIATED_TOKEN_PROGRAM_ID
      );
      await provider.sendAndConfirm(
        new Transaction().add(createRecipientAtaIx),
        [admin]
      );
    }

    const vaultUsdtBalance = await mockUSDT.getBalance(vaultUsdtAccount);
    if (vaultUsdtBalance < 5_000) {
      await mockUSDT.mintTo(vaultUsdtAccount, 5_000 - vaultUsdtBalance);
    }

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
    } catch (error: any) {
      if (!String(error).includes("already in use")) throw error;
    }
    const existingCounter = await counterProgram.account.counter.fetch(counterPda);
    counterAuthority = { publicKey: existingCounter.authority } as Keypair;

    const minVaultLamports = 10 * anchor.web3.LAMPORTS_PER_SOL;
    const vaultBalance = await provider.connection.getBalance(vaultPda);
    if (vaultBalance < minVaultLamports) {
      const topUp = new Transaction().add(
        SystemProgram.transfer({
          fromPubkey: admin.publicKey,
          toPubkey: vaultPda,
          lamports: minVaultLamports - vaultBalance,
        })
      );
      await provider.sendAndConfirm(topUp, [admin]);
    }

    finalizeUniversalTx = makeFinalizeUniversalTxBuilder(
      gatewayProgram,
      configPda,
      vaultPda,
      tssPda
    );
  });

  const buildCounterIncrementRoute = async (
    pushAccount: number[],
    incrementBy: number
  ): Promise<{
    counterIx: anchor.web3.TransactionInstruction;
    remainingAccounts: ReturnType<typeof instructionAccountsToRemaining>;
    accounts: GatewayAccountMeta[];
    writableFlags: Buffer;
  }> => {
    const counterIx = await counterProgram.methods
      .increment(new anchor.BN(incrementBy))
      .accountsPartial({
        counter: counterPda,
        authority: counterAuthority.publicKey,
      })
      .instruction();

    const remainingAccounts = instructionAccountsToRemaining(counterIx);
    const accounts = instructionAccountsToGatewayMetas(counterIx);
    const writableFlags = accountsToWritableFlagsOnly(accounts);

    return { counterIx, remainingAccounts, accounts, writableFlags };
  };

  const closeStoredIxDataAs = async ({
    caller,
    storeRefundRecipient,
    subTxId,
    ixDataHash,
    executedSubTx,
  }: {
    caller: Keypair;
    storeRefundRecipient: PublicKey;
    subTxId: number[];
    ixDataHash: Uint8Array;
    executedSubTx: PublicKey | null;
  }) =>
    gatewayProgram.methods
      .closeStoredIxData()
      .accountsPartial({
        caller: caller.publicKey,
        storedIxData: deriveStoredIxDataPda(subTxId, ixDataHash),
        storeRefundRecipient,
        executedSubTx,
      })
      .signers([caller])
      .rpc();

  const storeIxData = async ({
    subTxId,
    ixDataHash,
    ixData,
    caller = storeRelayer,
  }: {
    subTxId: number[];
    ixDataHash: Uint8Array;
    ixData: Buffer;
    caller?: Keypair;
  }) =>
    gatewayProgram.methods
      .storeExecuteIxData(Array.from(subTxId), asIxDataHashArg(ixDataHash), ixData)
      .accountsPartial({
        caller: caller.publicKey,
        storedIxData: deriveStoredIxDataPda(subTxId, ixDataHash),
        systemProgram: SystemProgram.programId,
      })
      .signers([caller])
      .rpc();

  const finalizeByRef = async ({
    instructionId = 2,
    subTxId,
    universalTxId,
    amount,
    pushAccount,
    ixDataHash,
    writableFlags,
    gasFee,
    sig,
    destinationProgram,
    remainingAccounts = [],
    recipient = null,
    vaultAta = null,
    ceaAta = null,
    mint = null,
    tokenProgram = null,
    rent = null,
    associatedTokenProgram = null,
    recipientAta = null,
    rateLimitConfig = rateLimitConfigPda,
    tokenRateLimit = nativeSolTokenRateLimitPda,
    storeRefundRecipient = storeRelayer.publicKey,
  }: {
    instructionId?: number;
    subTxId: number[];
    universalTxId: number[] | Uint8Array;
    amount: anchor.BN;
    pushAccount: number[];
    ixDataHash: Uint8Array;
    writableFlags: Buffer;
    gasFee: bigint;
    sig: {
      signature: ArrayLike<number>;
      recoveryId: number;
      messageHash: ArrayLike<number>;
    };
    destinationProgram: PublicKey;
    remainingAccounts?: { pubkey: PublicKey; isWritable: boolean; isSigner: boolean }[];
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
    storeRefundRecipient?: PublicKey;
  }) =>
    gatewayProgram.methods
      .finalizeUniversalTxWithIxDataRef(
        instructionId,
        Array.from(subTxId),
        Array.from(universalTxId),
        amount,
        Array.from(pushAccount),
        asIxDataHashArg(ixDataHash),
        writableFlags,
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
        ceaAuthority: getCeaAuthorityPda(
          Array.from(pushAccount),
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram,
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
        storedIxData: deriveStoredIxDataPda(subTxId, ixDataHash),
        storeRefundRecipient,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(remainingAccounts)
      .signers([admin])
      .rpc();

  it("stores raw ix_data and preserves refund recipient", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx } = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const stored = await gatewayProgram.account.storedIxData.fetch(
      storedIxDataPda
    );
    expect(stored.storeRefundRecipient.toString()).to.equal(
      storeRelayer.publicKey.toString()
    );
    expect(Buffer.from(stored.ixData).toString("hex")).to.equal(
      Buffer.from(counterIx.data).toString("hex")
    );

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });

    const accountInfo = await provider.connection.getAccountInfo(storedIxDataPda);
    expect(accountInfo).to.equal(null);
  });

  it("rejects empty ix_data", async () => {
    const subTxId = generateTxId();
    const emptyHash = new Uint8Array(32);

    try {
      await gatewayProgram.methods
        .storeExecuteIxData(Array.from(subTxId), Array.from(emptyHash), Buffer.alloc(0))
        .accountsPartial({
          caller: storeRelayer.publicKey,
          storedIxData: deriveStoredIxDataPda(subTxId, emptyHash),
          systemProgram: SystemProgram.programId,
        })
        .signers([storeRelayer])
        .rpc();
      expect.fail("expected empty ix_data to fail");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("EmptyIxData");
    }
  });

  it("rejects mismatched ix_data hash", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx } = await buildCounterIncrementRoute(pushAccount, 2);
    const wrongHash = new Uint8Array(32);

    try {
      await gatewayProgram.methods
        .storeExecuteIxData(
          Array.from(subTxId),
          Array.from(wrongHash),
          Buffer.from(counterIx.data)
        )
        .accountsPartial({
          caller: storeRelayer.publicKey,
          storedIxData: deriveStoredIxDataPda(subTxId, wrongHash),
          systemProgram: SystemProgram.programId,
        })
        .signers([storeRelayer])
        .rpc();
      expect.fail("expected wrong ix_data hash to fail");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InvalidIxDataHash");
    }
  });

  it("rejects duplicate store for the same (sub_tx_id, ix_data_hash)", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx } = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    try {
      await gatewayProgram.methods
        .storeExecuteIxData(
          Array.from(subTxId),
          asIxDataHashArg(ixDataHash),
          Buffer.from(counterIx.data)
        )
        .accountsPartial({
          caller: storeRelayer.publicKey,
          storedIxData: storedIxDataPda,
          systemProgram: SystemProgram.programId,
        })
        .signers([storeRelayer])
        .rpc();
      expect.fail("expected duplicate store to fail");
    } catch (error) {
      expect(String(error)).to.include("already in use");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("rejects ref finalize when ix_data_hash arg does not match the stored bytes", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const wrongIxDataHash = hashIxData(Buffer.concat([Buffer.from(route.counterIx.data), Buffer.from([1])]));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
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
        route.accounts,
        route.counterIx.data,
        refGasFee
      ),
    });

    try {
      await gatewayProgram.methods
        .finalizeUniversalTxWithIxDataRef(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          asIxDataHashArg(wrongIxDataHash),
          route.writableFlags,
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
          ceaAuthority: getCeaAuthorityPda(
            Array.from(pushAccount),
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
          storedIxData: storedIxDataPda,
          storeRefundRecipient: storeRelayer.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(route.remainingAccounts)
        .signers([admin])
        .rpc();
      expect.fail("expected ref finalize to reject a mismatched ix_data_hash arg");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InvalidIxDataHash");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("keeps direct finalize behavior and ref route adds exactly 5000 gas_used", async () => {
    const counterBefore = await counterProgram.account.counter.fetch(counterPda);

    const directSubTxId = generateTxId();
    const directUniversalTxId = generateUniversalTxId();
    const directPushAccount = generateSender();
    const directRoute = await buildCounterIncrementRoute(directPushAccount, 3);
    const { gasFee: directGasFee } = await calculateSolExecuteFees(
      provider.connection
    );

    const directSig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        new Uint8Array(directUniversalTxId),
        new Uint8Array(directSubTxId),
        counterProgram.programId,
        new Uint8Array(directPushAccount),
        directRoute.accounts,
        directRoute.counterIx.data,
        directGasFee
      ),
    });

    const directTx = await finalizeUniversalTx({
      instructionId: 2,
      subTxId: directSubTxId,
      universalTxId: directUniversalTxId,
      amount: new anchor.BN(0),
      pushAccount: directPushAccount,
      writableFlags: directRoute.writableFlags,
      ixData: Buffer.from(directRoute.counterIx.data),
      gasFee: new anchor.BN(Number(directGasFee)),
      sig: directSig,
      caller: admin.publicKey,
      destinationProgram: counterProgram.programId,
      rateLimitConfig: rateLimitConfigPda,
      tokenRateLimit: nativeSolTokenRateLimitPda,
    })
      .remainingAccounts(directRoute.remainingAccounts)
      .signers([admin])
      .rpc();

    const directEvents = await decodeGatewayEvents(directTx);
    const directFinalized = directEvents.find(
      (event) => event.name === "universalTxFinalized"
    );
    expect(directFinalized, "normal finalize event missing").to.exist;

    const refSubTxId = generateTxId();
    const refUniversalTxId = generateUniversalTxId();
    const refPushAccount = generateSender();
    const refRoute = await buildCounterIncrementRoute(refPushAccount, 3);
    const ixDataHash = hashIxData(Buffer.from(refRoute.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(refSubTxId, ixDataHash);
    const refGasFee = directGasFee + SIGNATURE_FEE_LAMPORTS;

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(refSubTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(refRoute.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const pdaLamports = (await provider.connection.getAccountInfo(storedIxDataPda))!.lamports;
    const refundBefore = await provider.connection.getBalance(
      storeRelayer.publicKey
    );

    const refSig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        new Uint8Array(refUniversalTxId),
        new Uint8Array(refSubTxId),
        counterProgram.programId,
        new Uint8Array(refPushAccount),
        refRoute.accounts,
        refRoute.counterIx.data,
        refGasFee
      ),
    });

    const refTx = await gatewayProgram.methods
      .finalizeUniversalTxWithIxDataRef(
        2,
        Array.from(refSubTxId),
        Array.from(refUniversalTxId),
        new anchor.BN(0),
        Array.from(refPushAccount),
        asIxDataHashArg(ixDataHash),
        refRoute.writableFlags,
        new anchor.BN(Number(refGasFee)),
        new anchor.BN(4102444800),
        Array.from(refSig.signature),
        refSig.recoveryId,
        Array.from(refSig.messageHash)
      )
      .accountsPartial({
        caller: admin.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority: getCeaAuthorityPda(
          Array.from(refPushAccount),
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(refSubTxId, gatewayProgram.programId),
        destinationProgram: counterProgram.programId,
        recipient: null,
        vaultAta: null,
        ceaAta: null,
        mint: null,
        tokenProgram: null,
        rent: null,
        associatedTokenProgram: null,
        recipientAta: null,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        storedIxData: storedIxDataPda,
        storeRefundRecipient: storeRelayer.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(refRoute.remainingAccounts)
      .signers([admin])
      .rpc();

    const refundAfter = await provider.connection.getBalance(
      storeRelayer.publicKey
    );
    // storeRelayer receives SIGNATURE_FEE_LAMPORTS reimbursement + PDA rent (auto-close)
    expect(refundAfter - refundBefore).to.equal(Number(SIGNATURE_FEE_LAMPORTS) + pdaLamports);

    const refEvents = await decodeGatewayEvents(refTx);
    const refFinalized = refEvents.find(
      (event) => event.name === "universalTxFinalized"
    );
    expect(refFinalized, "ref finalize event missing").to.exist;

    expect(
      Number(refFinalized!.data.gasUsed) - Number(directFinalized!.data.gasUsed)
    ).to.equal(Number(SIGNATURE_FEE_LAMPORTS));
    expect(refFinalized!.data.ataCreated).to.equal(false);

    const counterAfter = await counterProgram.account.counter.fetch(counterPda);
    expect(counterAfter.value.toNumber() - counterBefore.value.toNumber()).to.equal(6);

    // PDA is auto-closed by ref-finalize
    expect(await provider.connection.getAccountInfo(deriveStoredIxDataPda(refSubTxId, ixDataHash))).to.equal(null);
  });

  it("requires an extra 5000 lamports of gas budget for ref finalize", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasUsed: insufficientGasFee } = await calculateSolExecuteFees(provider.connection);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
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
        route.accounts,
        route.counterIx.data,
        insufficientGasFee
      ),
    });

    try {
      await gatewayProgram.methods
        .finalizeUniversalTxWithIxDataRef(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          asIxDataHashArg(ixDataHash),
          route.writableFlags,
          new anchor.BN(Number(insufficientGasFee)),
          new anchor.BN(4102444800),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(
            Array.from(pushAccount),
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
          storedIxData: storedIxDataPda,
          storeRefundRecipient: storeRelayer.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(route.remainingAccounts)
        .signers([admin])
        .rpc();
      expect.fail("expected ref finalize to fail when gas_fee omits the extra 5000");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InsufficientGasBudget");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("rejects a mismatched refund recipient on ref finalize", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
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
        route.accounts,
        route.counterIx.data,
        refGasFee
      ),
    });

    try {
      await gatewayProgram.methods
        .finalizeUniversalTxWithIxDataRef(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          asIxDataHashArg(ixDataHash),
          route.writableFlags,
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
          ceaAuthority: getCeaAuthorityPda(
            Array.from(pushAccount),
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
          storedIxData: storedIxDataPda,
          storeRefundRecipient: closeRelayer.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(route.remainingAccounts)
        .signers([admin])
        .rpc();
      expect.fail("expected ref finalize to reject a mismatched refund recipient");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InvalidAccount");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("allows only the refund recipient to close before successful finalize", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx } = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    try {
      await closeStoredIxDataAs({
        caller: closeRelayer,
        storeRefundRecipient: storeRelayer.publicKey,
        subTxId,
        ixDataHash,
        executedSubTx: null,
      });
      expect.fail("expected pre-success close by non-recipient to fail");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("StoredIxDataNotClosable");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });

    const accountInfo = await provider.connection.getAccountInfo(storedIxDataPda);
    expect(accountInfo).to.equal(null);
  });

  it("auto-closes StoredIxData PDA on ref-finalize success and refunds rent to store_refund_recipient", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const pdaLamports = (await provider.connection.getAccountInfo(storedIxDataPda))!.lamports;
    const refundBefore = await provider.connection.getBalance(storeRelayer.publicKey);

    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        new Uint8Array(universalTxId),
        new Uint8Array(subTxId),
        counterProgram.programId,
        new Uint8Array(pushAccount),
        route.accounts,
        route.counterIx.data,
        refGasFee
      ),
    });

    await gatewayProgram.methods
      .finalizeUniversalTxWithIxDataRef(
        2,
        Array.from(subTxId),
        Array.from(universalTxId),
        new anchor.BN(0),
        Array.from(pushAccount),
        asIxDataHashArg(ixDataHash),
        route.writableFlags,
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
        ceaAuthority: getCeaAuthorityPda(
          Array.from(pushAccount),
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: counterProgram.programId,
        recipient: null,
        vaultAta: null,
        ceaAta: null,
        mint: null,
        tokenProgram: null,
        rent: null,
        associatedTokenProgram: null,
        recipientAta: null,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        storedIxData: storedIxDataPda,
        storeRefundRecipient: storeRelayer.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(route.remainingAccounts)
      .signers([admin])
      .rpc();

    // PDA auto-closed — account must be gone
    expect(await provider.connection.getAccountInfo(storedIxDataPda)).to.equal(null);

    // storeRelayer receives SIGNATURE_FEE_LAMPORTS reimbursement + PDA rent (auto-close)
    const refundAfter = await provider.connection.getBalance(storeRelayer.publicKey);
    expect(refundAfter - refundBefore).to.equal(Number(SIGNATURE_FEE_LAMPORTS) + pdaLamports);
  });

  it("allows normal finalize after store, ignores stored optional accounts, and still allows anyone to close", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 2);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasFee, gasUsed } = await calculateSolExecuteFees(provider.connection);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const refundBeforeFinalize = await provider.connection.getBalance(
      storeRelayer.publicKey
    );

    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        new Uint8Array(universalTxId),
        new Uint8Array(subTxId),
        counterProgram.programId,
        new Uint8Array(pushAccount),
        route.accounts,
        route.counterIx.data,
        gasFee
      ),
    });

    const finalizeSig = await gatewayProgram.methods
      .finalizeUniversalTx(
        2,
        Array.from(subTxId),
        Array.from(universalTxId),
        new anchor.BN(0),
        Array.from(pushAccount),
        route.writableFlags,
        Buffer.from(route.counterIx.data),
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
        ceaAuthority: getCeaAuthorityPda(
          Array.from(pushAccount),
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: counterProgram.programId,
        recipient: null,
        vaultAta: null,
        ceaAta: null,
        mint: null,
        tokenProgram: null,
        rent: null,
        associatedTokenProgram: null,
        recipientAta: null,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        storedIxData: storedIxDataPda,
        storeRefundRecipient: storeRelayer.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(route.remainingAccounts)
      .signers([admin])
      .rpc();

    const refundAfterFinalize = await provider.connection.getBalance(
      storeRelayer.publicKey
    );
    expect(refundAfterFinalize).to.equal(refundBeforeFinalize);

    const events = await decodeGatewayEvents(finalizeSig);
    const finalized = events.find(
      (event) => event.name === "universalTxFinalized"
    );
    expect(finalized, "normal finalize event missing").to.exist;
    expect(Number(finalized!.data.gasUsed)).to.equal(Number(gasUsed));

    const storedBeforeClose = await provider.connection.getAccountInfo(storedIxDataPda);
    expect(storedBeforeClose).to.not.equal(null);

    const refundBeforeClose = await provider.connection.getBalance(
      storeRelayer.publicKey
    );

    await closeStoredIxDataAs({
      caller: closeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
    });

    const refundAfterClose = await provider.connection.getBalance(
      storeRelayer.publicKey
    );
    expect(refundAfterClose - refundBeforeClose).to.equal(
      storedBeforeClose!.lamports
    );

    const storedAfterClose = await provider.connection.getAccountInfo(storedIxDataPda);
    expect(storedAfterClose).to.equal(null);
  });

  it("ref-finalizes SPL execute, creates the CEA ATA, and reimburses the extra 5000", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const amount = new anchor.BN(100 * 10 ** USDT_DECIMALS);
    const ceaAta = await getCeaAta(
      pushAccount,
      mockUSDT.mint.publicKey,
      gatewayProgram.programId
    );
    const routeIx = await counterProgram.methods
      .receiveSpl(amount)
      .accountsPartial({
        counter: counterPda,
        ceaAta,
        recipientAta: recipientUsdtAccount,
        ceaAuthority: getCeaAuthorityPda(pushAccount, gatewayProgram.programId),
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .instruction();
    const accounts = instructionAccountsToGatewayMetas(routeIx);
    const remainingAccounts = instructionAccountsToRemaining(routeIx);
    const writableFlags = accountsToWritableFlagsOnly(accounts);
    const ixData = Buffer.from(routeIx.data);
    const ixDataHash = hashIxData(ixData);
    const { gasFee, gasUsed } = await calculateSplExecuteFees(
      provider.connection,
      ceaAta
    );
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

    await storeIxData({ subTxId, ixDataHash, ixData });

    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const pdaLamports = (await provider.connection.getAccountInfo(storedIxDataPda))!.lamports;
    const refundBefore = await provider.connection.getBalance(storeRelayer.publicKey);
    const recipientBefore = await mockUSDT.getBalance(recipientUsdtAccount);

    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(amount.toString()),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        new Uint8Array(universalTxId),
        new Uint8Array(subTxId),
        counterProgram.programId,
        new Uint8Array(pushAccount),
        accounts,
        ixData,
        refGasFee,
        mockUSDT.mint.publicKey
      ),
    });

    const txSig = await finalizeByRef({
      subTxId,
      universalTxId,
      amount,
      pushAccount,
      ixDataHash,
      writableFlags,
      gasFee: refGasFee,
      sig,
      destinationProgram: counterProgram.programId,
      remainingAccounts,
      vaultAta: vaultUsdtAccount,
      ceaAta,
      mint: mockUSDT.mint.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID,
      rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      rateLimitConfig: null,
      tokenRateLimit: null,
    });

    // storeRelayer receives SIGNATURE_FEE_LAMPORTS reimbursement + PDA rent (auto-close)
    const refundAfter = await provider.connection.getBalance(storeRelayer.publicKey);
    expect(refundAfter - refundBefore).to.equal(Number(SIGNATURE_FEE_LAMPORTS) + pdaLamports);

    const events = await decodeGatewayEvents(txSig);
    const finalized = events.find((event) => event.name === "universalTxFinalized");
    expect(finalized, "SPL ref finalize event missing").to.exist;
    expect(finalized!.data.ataCreated).to.equal(true);
    expect(Number(finalized!.data.gasUsed)).to.equal(
      Number(gasUsed + SIGNATURE_FEE_LAMPORTS)
    );

    const recipientAfter = await mockUSDT.getBalance(recipientUsdtAccount);
    expect(recipientAfter - recipientBefore).to.equal(
      amount.toNumber() / 10 ** USDT_DECIMALS
    );
    expect(await provider.connection.getAccountInfo(ceaAta)).to.not.equal(null);

    // PDA auto-closed by finalize
    expect(await provider.connection.getAccountInfo(storedIxDataPda)).to.equal(null);
  });

  it("ref-finalizes the self-route (CEA -> UEA) and preserves the emitted semantics", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");
    const ceaPayload = Buffer.from("cafe1234", "hex");
    const payloadBuf = Buffer.concat([
      (() => {
        const lenBuf = Buffer.alloc(4);
        lenBuf.writeUInt32LE(ceaPayload.length, 0);
        return lenBuf;
      })(),
      ceaPayload,
    ]);
    const withdrawArgs = Buffer.concat([
      Buffer.alloc(32, 0),
      Buffer.alloc(8, 0),
      payloadBuf,
      storeRelayer.publicKey.toBuffer(),
    ]);
    const ixData = Buffer.concat([withdrawDiscr, withdrawArgs]);
    const ixDataHash = hashIxData(ixData);
    const writableFlags = accountsToWritableFlagsOnly([]);
    const { gasFee, gasUsed } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

    await storeIxData({ subTxId, ixDataHash, ixData });

    const ceaSelfStoredIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const ceaPdaLamports = (await provider.connection.getAccountInfo(ceaSelfStoredIxDataPda))!.lamports;
    const refundBefore = await provider.connection.getBalance(storeRelayer.publicKey);
    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        new Uint8Array(universalTxId),
        new Uint8Array(subTxId),
        gatewayProgram.programId,
        new Uint8Array(pushAccount),
        [],
        ixData,
        refGasFee
      ),
    });

    const txSig = await finalizeByRef({
      subTxId,
      universalTxId,
      amount: new anchor.BN(0),
      pushAccount,
      ixDataHash,
      writableFlags,
      gasFee: refGasFee,
      sig,
      destinationProgram: gatewayProgram.programId,
      rateLimitConfig: rateLimitConfigPda,
      tokenRateLimit: nativeSolTokenRateLimitPda,
    });

    // storeRelayer receives SIGNATURE_FEE_LAMPORTS reimbursement + PDA rent (auto-close)
    const refundAfter = await provider.connection.getBalance(storeRelayer.publicKey);
    expect(refundAfter - refundBefore).to.equal(Number(SIGNATURE_FEE_LAMPORTS) + ceaPdaLamports);

    const events = await decodeGatewayEvents(txSig);
    const universalTxEvent = events.find((event) => event.name === "universalTx");
    const finalized = events.find((event) => event.name === "universalTxFinalized");
    expect(universalTxEvent, "UniversalTx event missing on self-route").to.exist;
    expect(finalized, "UniversalTxFinalized event missing on self-route").to.exist;
    expect(universalTxEvent!.data.fromCea).to.equal(true);
    expect(universalTxEvent!.data.txType.gasAndPayload !== undefined).to.equal(true);
    expect(Buffer.from(universalTxEvent!.data.payload).toString("hex")).to.equal(
      ceaPayload.toString("hex")
    );
    expect(finalized!.data.target.toString()).to.equal(gatewayProgram.programId.toString());
    expect(Number(finalized!.data.gasUsed)).to.equal(
      Number(gasUsed + SIGNATURE_FEE_LAMPORTS)
    );

    // PDA auto-closed by finalize
    expect(await provider.connection.getAccountInfo(ceaSelfStoredIxDataPda)).to.equal(null);
  });

  it("rejects close_stored_ix_data with a non-canonical executed_sub_tx key", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx } = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    try {
      await closeStoredIxDataAs({
        caller: closeRelayer,
        storeRefundRecipient: storeRelayer.publicKey,
        subTxId,
        ixDataHash,
        executedSubTx: configPda,
      });
      expect.fail("expected wrong executed_sub_tx key to fail");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InvalidAccount");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("rejects ref finalize while paused", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
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
        route.accounts,
        route.counterIx.data,
        refGasFee
      ),
    });

    await gatewayProgram.methods
      .pause()
      .accountsPartial({ pauser: admin.publicKey, config: configPda })
      .signers([admin])
      .rpc();

    try {
      await gatewayProgram.methods
        .finalizeUniversalTxWithIxDataRef(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          asIxDataHashArg(ixDataHash),
          route.writableFlags,
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
          ceaAuthority: getCeaAuthorityPda(
            Array.from(pushAccount),
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
          storedIxData: storedIxDataPda,
          storeRefundRecipient: storeRelayer.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(route.remainingAccounts)
        .signers([admin])
        .rpc();
      expect.fail("expected paused ref finalize to fail");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("Paused");
    } finally {
      await gatewayProgram.methods
        .unpause()
        .accountsPartial({ operator: operator.publicKey, config: configPda })
        .signers([operator])
        .rpc();
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("rejects ref-finalize when stored_ix_data account is null", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx, accounts, writableFlags } =
      await buildCounterIncrementRoute(pushAccount, 1);
    const ixData = Buffer.from(counterIx.data);
    const ixDataHash = hashIxData(ixData);
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(Array.from(subTxId), asIxDataHashArg(ixDataHash), ixData)
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;
    const universalTxId = generateUniversalTxId();
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

    try {
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
          ceaAuthority: getCeaAuthorityPda(Array.from(pushAccount), gatewayProgram.programId),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          storedIxData: null,
          storeRefundRecipient: storeRelayer.publicKey,
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
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(counterIx))
        .signers([admin])
        .rpc();
      expect.fail("expected InvalidAccount");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InvalidAccount");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("rejects ref-finalize when store_refund_recipient account is null", async () => {
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx, accounts, writableFlags } =
      await buildCounterIncrementRoute(pushAccount, 1);
    const ixData = Buffer.from(counterIx.data);
    const ixDataHash = hashIxData(ixData);
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(Array.from(subTxId), asIxDataHashArg(ixDataHash), ixData)
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;
    const universalTxId = generateUniversalTxId();
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

    try {
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
          ceaAuthority: getCeaAuthorityPda(Array.from(pushAccount), gatewayProgram.programId),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          storedIxData: storedIxDataPda,
          storeRefundRecipient: null,
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
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(counterIx))
        .signers([admin])
        .rpc();
      expect.fail("expected InvalidAccount");
    } catch (error) {
      expect(getErrorCode(error)).to.equal("InvalidAccount");
    }

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });

  it("recovers orphaned PDAs via getProgramAccounts without local state", async () => {
    // Simulates a UV that stored ix_data, crashed (lost sub_tx_id from memory),
    // and later recovers via on-chain discovery.
    const subTxId = generateTxId();
    const pushAccount = generateSender();
    const { counterIx } = await buildCounterIncrementRoute(pushAccount, 1);
    const ixData = Buffer.from(counterIx.data);
    const ixDataHash = hashIxData(ixData);
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);

    await gatewayProgram.methods
      .storeExecuteIxData(Array.from(subTxId), asIxDataHashArg(ixDataHash), ixData)
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    // UV "crashes" — sub_tx_id and ix_data_hash are gone from local state.
    // Recovery: scan chain for all StoredIxData PDAs belonging to this relayer.
    const discriminator = Buffer.from(
      anchor.utils.sha256.hash("account:StoredIxData").slice(0, 16),
      "hex"
    ).slice(0, 8);
    // Offset: 8 (disc) + 1 (bump) + 32 (sub_tx_id) = 41
    const storeRefundRecipientOffset = 8 + 1 + 32;

    const discovered = await provider.connection.getProgramAccounts(
      gatewayProgram.programId,
      {
        filters: [
          { memcmp: { offset: 0, bytes: anchor.utils.bytes.bs58.encode(discriminator) } },
          { memcmp: { offset: storeRefundRecipientOffset, bytes: storeRelayer.publicKey.toBase58() } },
        ],
      }
    );

    expect(discovered.length).to.be.at.least(1);
    const orphaned = discovered.find((a) => a.pubkey.equals(storedIxDataPda));
    expect(orphaned, "orphaned PDA must be discoverable").to.exist;

    // Close using only the discovered account address — no sub_tx_id arg needed.
    await gatewayProgram.methods
      .closeStoredIxData()
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: orphaned!.pubkey,
        storeRefundRecipient: storeRelayer.publicKey,
        executedSubTx: null,
      })
      .signers([storeRelayer])
      .rpc();

    expect(await provider.connection.getAccountInfo(storedIxDataPda)).to.equal(null);
  });

  it("rejects ref-finalize with an expired deadline (SignatureExpired)", async () => {
    const subTxId = generateTxId();
    const universalTxId = generateUniversalTxId();
    const pushAccount = generateSender();
    const route = await buildCounterIncrementRoute(pushAccount, 1);
    const ixDataHash = hashIxData(Buffer.from(route.counterIx.data));
    const storedIxDataPda = deriveStoredIxDataPda(subTxId, ixDataHash);
    const { gasFee } = await calculateSolExecuteFees(provider.connection);
    const refGasFee = gasFee + SIGNATURE_FEE_LAMPORTS;
    const pastDeadline = BigInt(1);

    await gatewayProgram.methods
      .storeExecuteIxData(
        Array.from(subTxId),
        asIxDataHashArg(ixDataHash),
        Buffer.from(route.counterIx.data)
      )
      .accountsPartial({
        caller: storeRelayer.publicKey,
        storedIxData: storedIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([storeRelayer])
      .rpc();

    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
      deadline: pastDeadline,
      additional: buildExecuteAdditionalData(
        new Uint8Array(universalTxId),
        new Uint8Array(subTxId),
        counterProgram.programId,
        new Uint8Array(pushAccount),
        route.accounts,
        route.counterIx.data,
        refGasFee
      ),
    });

    await expectRejection(
      gatewayProgram.methods
        .finalizeUniversalTxWithIxDataRef(
          2,
          Array.from(subTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          asIxDataHashArg(ixDataHash),
          route.writableFlags,
          new anchor.BN(Number(refGasFee)),
          new anchor.BN(pastDeadline.toString()),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: admin.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(
            Array.from(pushAccount),
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          recipient: null,
          vaultAta: null,
          ceaAta: null,
          mint: null,
          tokenProgram: null,
          rent: null,
          associatedTokenProgram: null,
          recipientAta: null,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: nativeSolTokenRateLimitPda,
          storedIxData: storedIxDataPda,
          storeRefundRecipient: storeRelayer.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(instructionAccountsToRemaining(route.counterIx))
        .signers([admin])
        .rpc(),
      "SignatureExpired"
    );

    await closeStoredIxDataAs({
      caller: storeRelayer,
      storeRefundRecipient: storeRelayer.publicKey,
      subTxId,
      ixDataHash,
      executedSubTx: null,
    });
  });
});
