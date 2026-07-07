import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  getAccount,
  getAssociatedTokenAddressSync,
  getMint,
  MINT_SIZE,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { randomBytes } from "crypto";
import pkg from "js-sha3";
import * as secp from "@noble/secp256k1";
import {
  encodeExecutePayload,
  instructionToPayloadFields,
} from "../app/execute-payload";
import * as sharedState from "./shared-state";
import { ensureTestSetup } from "./helpers/test-setup";
import {
  buildPc20BurnRevertAdditionalData,
  buildExecuteAdditionalData,
  buildPc20FinalizeAdditionalData,
  generateUniversalTxId,
  signTssMessage,
  TssInstruction,
  DEFAULT_DEADLINE,
} from "./helpers/tss";
import {
  SIGNATURE_FEE_LAMPORTS,
  accountsToWritableFlagsOnly,
  computeDiscriminator,
  getCeaAta,
  getExecutedTxPda,
  getExecutedTxRent,
  getTokenAccountRent,
} from "./helpers/test-utils";

const { keccak_256 } = pkg;

const COMPUTE_BUFFER = BigInt(100_000);

type BurnAccountMeta = {
  pubkey: PublicKey;
  isWritable: boolean;
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const generate20Bytes = (): number[] => {
  const value = Buffer.from(randomBytes(20));
  if (value.every((b) => b === 0)) {
    value[0] = 1;
  }
  return Array.from(value);
};

const generate32Bytes = (): number[] => Array.from(randomBytes(32));

const encodeU64Le = (value: bigint): Buffer => {
  const out = Buffer.alloc(8);
  out.writeBigUInt64LE(value);
  return out;
};

const encodeVec = (value: Buffer | Uint8Array): Buffer => {
  const bytes = Buffer.from(value);
  const len = Buffer.alloc(4);
  len.writeUInt32LE(bytes.length, 0);
  return Buffer.concat([len, bytes]);
};

const encodePc20BurnIxData = (params: {
  subTxId: number[] | Uint8Array;
  sourceAsset: number[] | Uint8Array;
  amount: bigint;
  recipient: number[] | Uint8Array;
  payload: Buffer | Uint8Array;
  revertRecipient: PublicKey;
}): Buffer =>
  Buffer.concat([
    computeDiscriminator("global:send_pc20_universal_tx"),
    Buffer.from(params.subTxId),
    Buffer.from(params.sourceAsset),
    encodeU64Le(params.amount),
    Buffer.from(params.recipient),
    encodeVec(params.payload),
    params.revertRecipient.toBuffer(),
  ]);

const makeEvmSigner = () => {
  const privateKey = randomBytes(32);
  const publicKey = secp.getPublicKey(privateKey, false).slice(1);
  const address = Buffer.from(keccak_256(publicKey).slice(-40), "hex");
  return {
    privateKeyHex: privateKey.toString("hex"),
    address: Array.from(address),
  };
};

const decodeEvents = async (
  provider: anchor.AnchorProvider,
  program: Program<UniversalGateway>,
  signature: string
) => {
  let txDetails: Awaited<
    ReturnType<typeof provider.connection.getTransaction>
  > | null = null;
  for (let attempt = 0; attempt < 10; attempt++) {
    txDetails = await provider.connection.getTransaction(signature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (txDetails?.meta?.logMessages?.length) {
      break;
    }
    await sleep(500);
  }

  if (!txDetails?.meta?.logMessages) {
    throw new Error(`Missing transaction metadata for ${signature}`);
  }

  const eventCoder = new anchor.BorshEventCoder(program.idl);
  return txDetails.meta.logMessages
    .map((log) => {
      if (!log.startsWith("Program data: ")) {
        return null;
      }
      try {
        return eventCoder.decode(log.split("Program data: ")[1]);
      } catch {
        return null;
      }
    })
    .filter((event): event is NonNullable<typeof event> => event !== null);
};

const airdropAndConfirm = async (
  provider: anchor.AnchorProvider,
  pubkey: PublicKey,
  lamports: number
) => {
  const sig = await provider.connection.requestAirdrop(pubkey, lamports);
  await provider.connection.confirmTransaction(sig, "confirmed");
};

describe("Universal Gateway - PC20", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const provider = anchor.getProvider() as anchor.AnchorProvider;
  const gatewayProgram = anchor.workspace
    .UniversalGateway as Program<UniversalGateway>;
  const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

  let admin: Keypair;
  let operator: Keypair;
  let pauser: Keypair;
  let counterAuthority: Keypair;
  let relayer: Keypair;
  let directRecipient: Keypair;
  let revertRecipient: Keypair;

  let configPda: PublicKey;
  let vaultPda: PublicKey;
  let feeVaultPda: PublicKey;
  let tssPda: PublicKey;
  let counterPda: PublicKey;
  let wrappedMint: PublicKey;
  let ceaAuthority: PublicKey;

  const sourceAsset = generate20Bytes();
  const pushAccountSigner = makeEvmSigner();
  const pushAccount = pushAccountSigner.address;
  const name = "PC Push Gold";
  const symbol = "pPGLD";
  const decimals = 6;

  before(async () => {
    await ensureTestSetup();

    admin = sharedState.getAdmin();
    operator = sharedState.getOperator();
    pauser = sharedState.getPauser();
    counterAuthority = sharedState.getCounterAuthority();
    relayer = Keypair.generate();
    directRecipient = Keypair.generate();
    revertRecipient = Keypair.generate();

    [configPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("config")],
      gatewayProgram.programId
    );
    [vaultPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("vault")],
      gatewayProgram.programId
    );
    [feeVaultPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("fee_vault")],
      gatewayProgram.programId
    );
    [tssPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("final_tss_pda")],
      gatewayProgram.programId
    );
    [counterPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("counter")],
      counterProgram.programId
    );

    const resolved = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(generate32Bytes()),
        Array.from(generateUniversalTxId()),
        Array.from(sourceAsset),
        new anchor.BN(1),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        Buffer.from([]),
        new anchor.BN(1),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        new Array(64).fill(0),
        0,
        new Array(32).fill(0)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        recipient: directRecipient.publicKey,
        recipientAta: directRecipient.publicKey,
        ceaAta: directRecipient.publicKey,
        tssPda,
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .pubkeys();

    wrappedMint = resolved.pc20Mint!;
    ceaAuthority = resolved.ceaAuthority!;

    await Promise.all([
      airdropAndConfirm(
        provider,
        relayer.publicKey,
        5 * anchor.web3.LAMPORTS_PER_SOL
      ),
      airdropAndConfirm(
        provider,
        directRecipient.publicKey,
        2 * anchor.web3.LAMPORTS_PER_SOL
      ),
      airdropAndConfirm(
        provider,
        revertRecipient.publicKey,
        2 * anchor.web3.LAMPORTS_PER_SOL
      ),
      airdropAndConfirm(provider, vaultPda, 5 * anchor.web3.LAMPORTS_PER_SOL),
      airdropAndConfirm(
        provider,
        feeVaultPda,
        2 * anchor.web3.LAMPORTS_PER_SOL
      ),
      airdropAndConfirm(
        provider,
        counterAuthority.publicKey,
        2 * anchor.web3.LAMPORTS_PER_SOL
      ),
      airdropAndConfirm(provider, ceaAuthority, anchor.web3.LAMPORTS_PER_SOL),
    ]);

    const existingCounter = await provider.connection.getAccountInfo(
      counterPda
    );
    if (!existingCounter) {
      await counterProgram.methods
        .initialize(new anchor.BN(0))
        .accountsPartial({
          counter: counterPda,
          authority: counterAuthority.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([counterAuthority])
        .rpc();
    }
  });

  const signWithCurrentTss = async (params: {
    instruction: TssInstruction;
    amount?: bigint;
    additional: (Uint8Array | number[])[];
  }) => {
    const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
    return signTssMessage({
      ...params,
      chainId: tssAccount.chainId,
    });
  };

  const getMintRent = async () =>
    provider.connection.getMinimumBalanceForRentExemption(MINT_SIZE);

  const expectError = async (promise: Promise<unknown>, expected: string) => {
    let matched = false;
    try {
      await promise;
    } catch (error: any) {
      const text = `${error?.message ?? ""} ${
        error?.error?.errorMessage ?? ""
      } ${error?.error?.errorCode?.code ?? ""} ${error?.toString?.() ?? ""}`;
      matched = text.includes(expected);
    }
    expect(matched, `Expected error containing "${expected}"`).to.equal(true);
  };

  const expectRejected = async (promise: Promise<unknown>) => {
    let rejected = false;
    try {
      await promise;
    } catch {
      rejected = true;
    }
    expect(rejected, "Expected promise to reject").to.equal(true);
  };

  const mintWrappedPc20ToCea = async (amount: number) => {
    const mintSubTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );
    const noopReceiveIx = SystemProgram.transfer({
      fromPubkey: ceaAuthority,
      toPubkey: directRecipient.publicKey,
      lamports: 1,
    });
    const noopFields = instructionToPayloadFields({
      instruction: noopReceiveIx,
      targetProgram: SystemProgram.programId,
      instructionId: 2,
    });
    const noopUserData = encodeExecutePayload(noopFields);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const gasFee = gasUsed + COMPUTE_BUFFER;
    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId: mintSubTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
        userData: noopUserData,
      }),
    });

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(mintSubTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        noopUserData,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta: getAssociatedTokenAddressSync(
          wrappedMint,
          directRecipient.publicKey,
          false,
          TOKEN_PROGRAM_ID,
          ASSOCIATED_TOKEN_PROGRAM_ID
        ),
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .remainingAccounts(
        noopReceiveIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        }))
      )
      .signers([relayer])
      .rpc();

    return ceaAta;
  };

  const finalizeRoutedCeaPc20Burn = async (params: {
    burnSubTxId: number[];
    amount: number;
    recipient?: number[];
    payload?: Buffer;
    revertRecipient?: PublicKey;
    accounts?: BurnAccountMeta[];
  }) => {
    const burnUniversalTxId = generateUniversalTxId();
    const recipient = params.recipient ?? generate20Bytes();
    const payload = params.payload ?? Buffer.from("cea-burn", "utf8");
    const revertRecipientKey =
      params.revertRecipient ?? revertRecipient.publicKey;
    const burnIxData = encodePc20BurnIxData({
      subTxId: params.burnSubTxId,
      sourceAsset,
      amount: BigInt(params.amount),
      recipient,
      payload,
      revertRecipient: revertRecipientKey,
    });
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );
    const accounts = params.accounts ?? [
      { pubkey: wrappedMint, isWritable: true },
      { pubkey: ceaAta, isWritable: true },
      { pubkey: TOKEN_PROGRAM_ID, isWritable: false },
    ];
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await getExecutedTxRent(provider.connection));
    const gasFee = gasUsed + COMPUTE_BUFFER;
    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      additional: buildExecuteAdditionalData(
        new Uint8Array(burnUniversalTxId),
        new Uint8Array(params.burnSubTxId),
        gatewayProgram.programId,
        new Uint8Array(pushAccount),
        accounts,
        burnIxData,
        gasFee
      ),
    });

    const txSig = await gatewayProgram.methods
      .finalizeUniversalTx(
        2,
        Array.from(params.burnSubTxId),
        Array.from(burnUniversalTxId),
        new anchor.BN(0),
        Array.from(pushAccount),
        accountsToWritableFlagsOnly(accounts),
        burnIxData,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority,
        tssPda,
        executedSubTx: getExecutedTxPda(
          params.burnSubTxId,
          gatewayProgram.programId
        ),
        destinationProgram: gatewayProgram.programId,
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
        storedIxData: null,
        storeRefundRecipient: null,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(
        accounts.map((account) => ({
          pubkey: account.pubkey,
          isWritable: account.isWritable,
          isSigner: false,
        }))
      )
      .signers([relayer])
      .rpc();

    return { txSig, ceaAta };
  };

  const pauseGateway = async () =>
    gatewayProgram.methods
      .pause()
      .accountsPartial({
        pauser: pauser.publicKey,
        config: configPda,
      })
      .signers([pauser])
      .rpc();

  const unpauseGateway = async () =>
    gatewayProgram.methods
      .unpause()
      .accountsPartial({
        operator: operator.publicKey,
        config: configPda,
      })
      .signers([operator])
      .rpc();

  it("creates the canonical wrapped mint and mints to the direct recipient", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 125_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );

    const executedTxRent =
      await provider.connection.getMinimumBalanceForRentExemption(8);
    const mintRent = await getMintRent();
    const ataRent = await getTokenAccountRent(provider.connection);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent);
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
      }),
    });

    const txSig = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta: await getCeaAta(
          pushAccount,
          wrappedMint,
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const mintInfo = await getMint(provider.connection, wrappedMint);
    expect(Number(mintInfo.supply)).to.equal(amount);
    expect(mintInfo.decimals).to.equal(decimals);

    const recipientAccount = await getAccount(
      provider.connection,
      recipientAta
    );
    expect(Number(recipientAccount.amount)).to.equal(amount);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const finalized = events.find(
      (event) => event.name === "pc20ExportFinalized"
    );
    expect(finalized, "Pc20ExportFinalized event missing").to.exist;
    expect(Number(finalized!.data.amount)).to.equal(amount);
    expect(finalized!.data.mintCreated).to.equal(true);
    expect(finalized!.data.recipientAtaCreated).to.equal(true);
    expect(finalized!.data.ceaAtaCreated).to.equal(false);
  });

  it("reuses the existing wrapped mint on later direct exports", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 50_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );

    const beforeMint = await getMint(provider.connection, wrappedMint);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
      }),
    });

    const txSig = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta: await getCeaAta(
          pushAccount,
          wrappedMint,
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const afterMint = await getMint(provider.connection, wrappedMint);
    expect(Number(afterMint.supply)).to.equal(
      Number(beforeMint.supply) + amount
    );

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const finalized = events.find(
      (event) => event.name === "pc20ExportFinalized"
    );
    expect(finalized!.data.mintCreated).to.equal(false);
    expect(finalized!.data.recipientAtaCreated).to.equal(false);
    expect(finalized!.data.ceaAtaCreated).to.equal(false);
  });

  it("rejects direct exports when signed recipient and recipient account differ", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;
    const mismatchedRecipient = revertRecipient.publicKey;
    const mismatchedRecipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      mismatchedRecipient,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const mismatchedAtaExists =
      (await provider.connection.getAccountInfo(mismatchedRecipientAta)) !== null;
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (mismatchedAtaExists
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
      }),
    });

    const supplyBefore = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );

    await expectError(
      gatewayProgram.methods
        .finalizePc20Export(
          Array.from(subTxId),
          Array.from(universalTxId),
          Array.from(sourceAsset),
          new anchor.BN(amount),
          Array.from(pushAccount),
          directRecipient.publicKey,
          name,
          symbol,
          decimals,
          Buffer.from([]),
          new anchor.BN(gasFee.toString()),
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: relayer.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          pc20Mint: wrappedMint,
          recipient: mismatchedRecipient,
          recipientAta: mismatchedRecipientAta,
          ceaAuthority,
          ceaAta: await getCeaAta(
            pushAccount,
            wrappedMint,
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: SystemProgram.programId,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        })
        .signers([relayer])
        .rpc(),
      "InvalidRecipient"
    );

    const supplyAfter = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );
    const executedMarker = await provider.connection.getAccountInfo(
      getExecutedTxPda(subTxId, gatewayProgram.programId)
    );
    expect(supplyAfter).to.equal(supplyBefore);
    expect(executedMarker).to.equal(null);
  });

  it("mints to the CEA and executes a payload using the existing SVM execute-payload format", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 30_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );

    const transferIx = SystemProgram.transfer({
      fromPubkey: ceaAuthority,
      toPubkey: directRecipient.publicKey,
      lamports: 1,
    });

    const payloadFields = instructionToPayloadFields({
      instruction: transferIx,
      targetProgram: SystemProgram.programId,
      instructionId: 2,
    });
    const userData = encodeExecutePayload(payloadFields);

    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      BigInt(await getTokenAccountRent(provider.connection));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
        userData,
      }),
    });

    const recipientLamportsBefore = await provider.connection.getBalance(
      directRecipient.publicKey
    );
    const ceaBeforeInfo = await provider.connection.getAccountInfo(ceaAta);
    const ceaBefore = ceaBeforeInfo
      ? Number((await getAccount(provider.connection, ceaAta)).amount)
      : 0;

    const txSig = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        userData,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .remainingAccounts(
        transferIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        }))
      )
      .signers([relayer])
      .rpc();

    const ceaAfter = await getAccount(provider.connection, ceaAta);
    expect(Number(ceaAfter.amount)).to.equal(ceaBefore + amount);
    const recipientLamportsAfter = await provider.connection.getBalance(
      directRecipient.publicKey
    );
    expect(recipientLamportsAfter).to.equal(recipientLamportsBefore + 1);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const finalized = events.find(
      (event) => event.name === "pc20ExportFinalized"
    );
    expect(finalized!.data.payloadExecuted).to.equal(true);
    expect(finalized!.data.ceaAtaCreated).to.equal(true);
  });

  it("burns wrapped supply from a user wallet and emits the outbound PC20 event", async () => {
    const burnSubTxId = generate32Bytes();
    const burnAmount = 40_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const beforeMint = await getMint(provider.connection, wrappedMint);
    const beforeBalance = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const pushRecipient = generate20Bytes();
    const pushPayload = Buffer.from("push-unlock", "utf8");

    const txSig = await gatewayProgram.methods
      .sendPc20UniversalTx(
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        Array.from(pushRecipient),
        pushPayload,
        revertRecipient.publicKey
      )
      .accountsPartial({
        config: configPda,
        caller: directRecipient.publicKey,
        pc20Mint: wrappedMint,
        userAta: recipientAta,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([directRecipient])
      .rpc();

    const afterMint = await getMint(provider.connection, wrappedMint);
    const afterBalance = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    expect(Number(afterMint.supply)).to.equal(
      Number(beforeMint.supply) - burnAmount
    );
    expect(afterBalance).to.equal(beforeBalance - burnAmount);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const burnEvent = events.find((event) => event.name === "pc20UniversalTx");
    expect(burnEvent!.data.fromCea).to.equal(false);
    expect(Number(burnEvent!.data.amount)).to.equal(burnAmount);
  });

  it("burns wrapped supply from the CEA after an EVM-key-authorized request", async () => {
    const mintSubTxId = generate32Bytes();
    const burnSubTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 20_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );
    const ceaBalanceBeforeFinalizeInfo =
      await provider.connection.getAccountInfo(ceaAta);
    const ceaBalanceBeforeFinalize = ceaBalanceBeforeFinalizeInfo
      ? Number((await getAccount(provider.connection, ceaAta)).amount)
      : 0;

    const noopReceiveIx = SystemProgram.transfer({
      fromPubkey: ceaAuthority,
      toPubkey: directRecipient.publicKey,
      lamports: 1,
    });
    const noopFields = instructionToPayloadFields({
      instruction: noopReceiveIx,
      targetProgram: SystemProgram.programId,
      instructionId: 2,
    });
    const noopUserData = encodeExecutePayload(noopFields);

    const finalizeGasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const finalizeGasFee = finalizeGasUsed + COMPUTE_BUFFER;
    const finalizeSig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId: mintSubTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee: finalizeGasFee,
        userData: noopUserData,
      }),
    });

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(mintSubTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        noopUserData,
        new anchor.BN(finalizeGasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(finalizeSig.signature),
        finalizeSig.recoveryId,
        Array.from(finalizeSig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .remainingAccounts(
        noopReceiveIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        }))
      )
      .signers([relayer])
      .rpc();

    const ceaBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(ceaBefore).to.equal(ceaBalanceBeforeFinalize + amount);

    const pushRecipient = generate20Bytes();
    const pushPayload = Buffer.from("cea-burn", "utf8");
    const burnUniversalTxId = generateUniversalTxId();
    const burnIxData = encodePc20BurnIxData({
      subTxId: burnSubTxId,
      sourceAsset,
      amount: BigInt(amount),
      recipient: pushRecipient,
      payload: pushPayload,
      revertRecipient: revertRecipient.publicKey,
    });
    const burnAccounts = [
      { pubkey: wrappedMint, isWritable: true },
      { pubkey: ceaAta, isWritable: true },
      { pubkey: TOKEN_PROGRAM_ID, isWritable: false },
    ];
    const burnWritableFlags = accountsToWritableFlagsOnly(burnAccounts);
    const burnGasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await getExecutedTxRent(provider.connection));
    const burnGasFee = burnGasUsed + COMPUTE_BUFFER;
    const burnSig = await signWithCurrentTss({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      additional: buildExecuteAdditionalData(
        new Uint8Array(burnUniversalTxId),
        new Uint8Array(burnSubTxId),
        gatewayProgram.programId,
        new Uint8Array(pushAccount),
        burnAccounts,
        burnIxData,
        burnGasFee
      ),
    });

    const burnTxSig = await gatewayProgram.methods
      .finalizeUniversalTx(
        2,
        Array.from(burnSubTxId),
        Array.from(burnUniversalTxId),
        new anchor.BN(0),
        Array.from(pushAccount),
        burnWritableFlags,
        burnIxData,
        new anchor.BN(burnGasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(burnSig.signature),
        burnSig.recoveryId,
        Array.from(burnSig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority,
        tssPda,
        executedSubTx: getExecutedTxPda(burnSubTxId, gatewayProgram.programId),
        destinationProgram: gatewayProgram.programId,
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
        storedIxData: null,
        storeRefundRecipient: null,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(
        burnAccounts.map((account) => ({
          pubkey: account.pubkey,
          isWritable: account.isWritable,
          isSigner: false,
        }))
      )
      .signers([relayer])
      .rpc();

    const ceaAfter = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(ceaAfter).to.equal(ceaBalanceBeforeFinalize);

    const burnEvents = await decodeEvents(provider, gatewayProgram, burnTxSig);
    const burnEvent = burnEvents.find(
      (event) => event.name === "pc20UniversalTx"
    );
    expect(burnEvent!.data.fromCea).to.equal(true);
    expect(Number(burnEvent!.data.amount)).to.equal(amount);
  });

  it("remints wrapped supply after a finalize-routed CEA PC20 burn revert", async () => {
    const amount = 4_000_000;
    const burnSubTxId = generate32Bytes();
    const revertSubTxId = generate32Bytes();
    const ceaAta = await mintWrappedPc20ToCea(amount);
    const supplyAfterMint = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );
    const ceaBalanceBeforeBurn = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    const revertRecipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      revertRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const revertRecipientAtaBeforeInfo =
      await provider.connection.getAccountInfo(revertRecipientAta);
    const revertRecipientBalanceBefore = revertRecipientAtaBeforeInfo
      ? Number(
          (await getAccount(provider.connection, revertRecipientAta)).amount
        )
      : 0;

    await finalizeRoutedCeaPc20Burn({
      burnSubTxId,
      amount,
      payload: Buffer.from("cea-revert", "utf8"),
      revertRecipient: revertRecipient.publicKey,
    });

    expect(
      Number((await getAccount(provider.connection, ceaAta)).amount)
    ).to.equal(ceaBalanceBeforeBurn - amount);
    expect(
      Number((await getMint(provider.connection, wrappedMint)).supply)
    ).to.equal(supplyAfterMint - amount);

    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (revertRecipientAtaBeforeInfo
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + COMPUTE_BUFFER;
    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20BurnRevert,
      amount: BigInt(amount),
      additional: buildPc20BurnRevertAdditionalData(
        revertSubTxId,
        burnSubTxId,
        sourceAsset,
        revertRecipient.publicKey,
        gasFee
      ),
    });

    await gatewayProgram.methods
      .revertPc20Burn(
        Array.from(revertSubTxId),
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        revertRecipient.publicKey,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        tssPda,
        caller: relayer.publicKey,
        pc20Mint: wrappedMint,
        revertRecipient: revertRecipient.publicKey,
        recipientAta: revertRecipientAta,
        executedSubTx: getExecutedTxPda(
          revertSubTxId,
          gatewayProgram.programId
        ),
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    expect(
      Number((await getAccount(provider.connection, revertRecipientAta)).amount)
    ).to.equal(revertRecipientBalanceBefore + amount);
    expect(
      Number((await getMint(provider.connection, wrappedMint)).supply)
    ).to.equal(supplyAfterMint);
  });

  it("remints wrapped supply on Solana when Push-side unlock fails after a burn", async () => {
    const burnSubTxId = generate32Bytes();
    const revertSubTxId = generate32Bytes();
    const burnAmount = 10_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const pushRecipient = generate20Bytes();

    await gatewayProgram.methods
      .sendPc20UniversalTx(
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        Array.from(pushRecipient),
        Buffer.from("revert-me", "utf8"),
        revertRecipient.publicKey
      )
      .accountsPartial({
        config: configPda,
        caller: directRecipient.publicKey,
        pc20Mint: wrappedMint,
        userAta: recipientAta,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([directRecipient])
      .rpc();

    const revertRecipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      revertRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const revertRecipientAtaBeforeInfo =
      await provider.connection.getAccountInfo(revertRecipientAta);
    const revertRecipientBalanceBefore = revertRecipientAtaBeforeInfo
      ? Number(
          (await getAccount(provider.connection, revertRecipientAta)).amount
        )
      : 0;
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (revertRecipientAtaBeforeInfo
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + COMPUTE_BUFFER;
    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20BurnRevert,
      amount: BigInt(burnAmount),
      additional: buildPc20BurnRevertAdditionalData(
        revertSubTxId,
        burnSubTxId,
        sourceAsset,
        revertRecipient.publicKey,
        gasFee
      ),
    });

    const txSig = await gatewayProgram.methods
      .revertPc20Burn(
        Array.from(revertSubTxId),
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        revertRecipient.publicKey,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        tssPda,
        caller: relayer.publicKey,
        pc20Mint: wrappedMint,
        revertRecipient: revertRecipient.publicKey,
        recipientAta: revertRecipientAta,
        executedSubTx: getExecutedTxPda(
          revertSubTxId,
          gatewayProgram.programId
        ),
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const revertedAta = await getAccount(
      provider.connection,
      revertRecipientAta
    );
    expect(Number(revertedAta.amount)).to.equal(
      revertRecipientBalanceBefore + burnAmount
    );

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const revertEvent = events.find(
      (event) => event.name === "pc20BurnReverted"
    );
    expect(Number(revertEvent!.data.amount)).to.equal(burnAmount);
    expect(revertEvent!.data.recipientAtaCreated).to.equal(
      revertRecipientAtaBeforeInfo === null
    );
  });

  it("allows a second TSS-signed revert for the same burn with a fresh revert sub_tx_id", async () => {
    const burnSubTxId = generate32Bytes();
    const firstRevertSubTxId = generate32Bytes();
    const secondRevertSubTxId = generate32Bytes();
    const burnAmount = 2_000_000;
    const secondRevertRecipient = Keypair.generate();
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const pushRecipient = generate20Bytes();

    await gatewayProgram.methods
      .sendPc20UniversalTx(
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        Array.from(pushRecipient),
        Buffer.from("revert-once", "utf8"),
        secondRevertRecipient.publicKey
      )
      .accountsPartial({
        config: configPda,
        caller: directRecipient.publicKey,
        pc20Mint: wrappedMint,
        userAta: recipientAta,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([directRecipient])
      .rpc();

    const secondRevertRecipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      secondRevertRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      BigInt(await getTokenAccountRent(provider.connection));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const firstSig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20BurnRevert,
      amount: BigInt(burnAmount),
      additional: buildPc20BurnRevertAdditionalData(
        firstRevertSubTxId,
        burnSubTxId,
        sourceAsset,
        secondRevertRecipient.publicKey,
        gasFee
      ),
    });

    await gatewayProgram.methods
      .revertPc20Burn(
        Array.from(firstRevertSubTxId),
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        secondRevertRecipient.publicKey,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(firstSig.signature),
        firstSig.recoveryId,
        Array.from(firstSig.messageHash)
      )
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        tssPda,
        caller: relayer.publicKey,
        pc20Mint: wrappedMint,
        revertRecipient: secondRevertRecipient.publicKey,
        recipientAta: secondRevertRecipientAta,
        executedSubTx: getExecutedTxPda(
          firstRevertSubTxId,
          gatewayProgram.programId
        ),
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const balanceAfterFirst = Number(
      (await getAccount(provider.connection, secondRevertRecipientAta)).amount
    );
    expect(balanceAfterFirst).to.equal(burnAmount);

    const secondSig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20BurnRevert,
      amount: BigInt(burnAmount),
      additional: buildPc20BurnRevertAdditionalData(
        secondRevertSubTxId,
        burnSubTxId,
        sourceAsset,
        secondRevertRecipient.publicKey,
        gasFee
      ),
    });

    await gatewayProgram.methods
      .revertPc20Burn(
        Array.from(secondRevertSubTxId),
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        secondRevertRecipient.publicKey,
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(secondSig.signature),
        secondSig.recoveryId,
        Array.from(secondSig.messageHash)
      )
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        tssPda,
        caller: relayer.publicKey,
        pc20Mint: wrappedMint,
        revertRecipient: secondRevertRecipient.publicKey,
        recipientAta: secondRevertRecipientAta,
        executedSubTx: getExecutedTxPda(
          secondRevertSubTxId,
          gatewayProgram.programId
        ),
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const balanceAfterSecond = Number(
      (await getAccount(provider.connection, secondRevertRecipientAta)).amount
    );
    expect(balanceAfterSecond).to.equal(burnAmount * 2);

    await expectRejected(
      gatewayProgram.methods
        .revertPc20Burn(
          Array.from(secondRevertSubTxId),
          Array.from(burnSubTxId),
          Array.from(sourceAsset),
          new anchor.BN(burnAmount),
          secondRevertRecipient.publicKey,
          new anchor.BN(gasFee.toString()),
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(secondSig.signature),
          secondSig.recoveryId,
          Array.from(secondSig.messageHash)
        )
        .accountsPartial({
          config: configPda,
          feeVault: feeVaultPda,
          tssPda,
          caller: relayer.publicKey,
          pc20Mint: wrappedMint,
          revertRecipient: secondRevertRecipient.publicKey,
          recipientAta: secondRevertRecipientAta,
          executedSubTx: getExecutedTxPda(
            secondRevertSubTxId,
            gatewayProgram.programId
          ),
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        })
        .signers([relayer])
        .rpc()
    );

    const balanceAfterReplay = Number(
      (await getAccount(provider.connection, secondRevertRecipientAta)).amount
    );
    expect(balanceAfterReplay).to.equal(balanceAfterSecond);
  });

  it("supports zero-decimal exports with EVM-compatible 32-byte symbols", async () => {
    const exportSourceAsset = generate20Bytes();
    const exportPushAccount = generate20Bytes();
    const exportName = "Push Integer";
    const exportSymbol = "S".repeat(32);
    const exportDecimals = 0;
    const amount = 100;
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();

    const executedTxRent =
      await provider.connection.getMinimumBalanceForRentExemption(8);
    const mintRent = await getMintRent();
    const ataRent = await getTokenAccountRent(provider.connection);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent);
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset: exportSourceAsset,
        pushAccount: exportPushAccount,
        recipient: directRecipient.publicKey,
        name: exportName,
        symbol: exportSymbol,
        decimals: exportDecimals,
        gasFee,
      }),
    });

    const resolved = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(exportSourceAsset),
        new anchor.BN(amount),
        Array.from(exportPushAccount),
        directRecipient.publicKey,
        exportName,
        exportSymbol,
        exportDecimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        recipient: directRecipient.publicKey,
        recipientAta: directRecipient.publicKey,
        ceaAta: directRecipient.publicKey,
        tssPda,
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .pubkeys();

    const recipientAta = getAssociatedTokenAddressSync(
      resolved.pc20Mint!,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      exportPushAccount,
      resolved.pc20Mint!,
      gatewayProgram.programId
    );

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(exportSourceAsset),
        new anchor.BN(amount),
        Array.from(exportPushAccount),
        directRecipient.publicKey,
        exportName,
        exportSymbol,
        exportDecimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: resolved.pc20Mint!,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority: resolved.ceaAuthority!,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const mintInfo = await getMint(provider.connection, resolved.pc20Mint!);
    const recipientAccount = await getAccount(
      provider.connection,
      recipientAta
    );
    expect(mintInfo.decimals).to.equal(exportDecimals);
    expect(Number(mintInfo.supply)).to.equal(amount);
    expect(Number(recipientAccount.amount)).to.equal(amount);
  });

  it("creates the wrapped mint successfully even if the mint PDA was prefunded before first export", async () => {
    const exportSourceAsset = generate20Bytes();
    const exportPushAccount = generate20Bytes();
    const exportName = "Prefunded Push Silver";
    const exportSymbol = "pPSLV";
    const exportDecimals = 9;
    const amount = 1_234_567;
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();

    const executedTxRent =
      await provider.connection.getMinimumBalanceForRentExemption(8);
    const mintRent = await getMintRent();
    const ataRent = await getTokenAccountRent(provider.connection);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent);
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset: exportSourceAsset,
        pushAccount: exportPushAccount,
        recipient: directRecipient.publicKey,
        name: exportName,
        symbol: exportSymbol,
        decimals: exportDecimals,
        gasFee,
      }),
    });

    const resolved = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(exportSourceAsset),
        new anchor.BN(amount),
        Array.from(exportPushAccount),
        directRecipient.publicKey,
        exportName,
        exportSymbol,
        exportDecimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        recipient: directRecipient.publicKey,
        recipientAta: directRecipient.publicKey,
        ceaAta: directRecipient.publicKey,
        tssPda,
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .pubkeys();

    const preseedLamports =
      await provider.connection.getMinimumBalanceForRentExemption(0);

    await provider.sendAndConfirm(
      new anchor.web3.Transaction().add(
        SystemProgram.transfer({
          fromPubkey: relayer.publicKey,
          toPubkey: resolved.pc20Mint!,
          lamports: preseedLamports,
        })
      ),
      [relayer]
    );

    const recipientAta = getAssociatedTokenAddressSync(
      resolved.pc20Mint!,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      exportPushAccount,
      resolved.pc20Mint!,
      gatewayProgram.programId
    );

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(exportSourceAsset),
        new anchor.BN(amount),
        Array.from(exportPushAccount),
        directRecipient.publicKey,
        exportName,
        exportSymbol,
        exportDecimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: resolved.pc20Mint!,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority: resolved.ceaAuthority!,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const mintInfo = await getMint(provider.connection, resolved.pc20Mint!);
    const recipientAccount = await getAccount(
      provider.connection,
      recipientAta
    );
    expect(mintInfo.decimals).to.equal(exportDecimals);
    expect(Number(mintInfo.supply)).to.equal(amount);
    expect(Number(recipientAccount.amount)).to.equal(amount);
  });

  it("ignores later metadata drift after the canonical wrapped mint exists", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const gasFee = gasUsed + COMPUTE_BUFFER;
    const mismatchedName = `${name} v2`;
    const mismatchedDecimals = decimals + 1;
    const before = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const supplyBefore = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name: mismatchedName,
        symbol,
        decimals: mismatchedDecimals,
        gasFee,
      }),
    });

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        mismatchedName,
        symbol,
        mismatchedDecimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta: await getCeaAta(
          pushAccount,
          wrappedMint,
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    const recipientAfter = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const mintAfter = await getMint(provider.connection, wrappedMint);
    expect(recipientAfter).to.equal(before + amount);
    expect(Number(mintAfter.supply)).to.equal(supplyBefore + amount);
    expect(mintAfter.decimals).to.equal(decimals);
  });

  it("replay-protects finalize_pc20_export by sub_tx_id", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
      }),
    });

    const supplyBefore = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta: await getCeaAta(
          pushAccount,
          wrappedMint,
          gatewayProgram.programId
        ),
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .signers([relayer])
      .rpc();

    await expectRejected(
      gatewayProgram.methods
        .finalizePc20Export(
          Array.from(subTxId),
          Array.from(universalTxId),
          Array.from(sourceAsset),
          new anchor.BN(amount),
          Array.from(pushAccount),
          directRecipient.publicKey,
          name,
          symbol,
          decimals,
          Buffer.from([]),
          new anchor.BN(gasFee.toString()),
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: relayer.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          pc20Mint: wrappedMint,
          recipient: directRecipient.publicKey,
          recipientAta,
          ceaAuthority,
          ceaAta: await getCeaAta(
            pushAccount,
            wrappedMint,
            gatewayProgram.programId
          ),
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: SystemProgram.programId,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        })
        .signers([relayer])
        .rpc()
    );

    const supplyAfter = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );
    expect(supplyAfter).to.equal(supplyBefore + amount);
  });

  it("rolls back payload-path mints when downstream CPI execution fails", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 4_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );

    const failingIx = await counterProgram.methods
      .batchOperation(new anchor.BN(1), Buffer.from("tiny", "utf8"))
      .accountsPartial({
        counter: counterPda,
        authority: ceaAuthority,
      })
      .instruction();
    const payloadFields = instructionToPayloadFields({
      instruction: failingIx,
      targetProgram: counterProgram.programId,
      instructionId: 2,
    });
    const userData = encodeExecutePayload(payloadFields);

    const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (ceaAtaInfo
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
        userData,
      }),
    });

    const supplyBefore = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );
    const ceaBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );

    await expectRejected(
      gatewayProgram.methods
        .finalizePc20Export(
          Array.from(subTxId),
          Array.from(universalTxId),
          Array.from(sourceAsset),
          new anchor.BN(amount),
          Array.from(pushAccount),
          directRecipient.publicKey,
          name,
          symbol,
          decimals,
          userData,
          new anchor.BN(gasFee.toString()),
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: relayer.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          pc20Mint: wrappedMint,
          recipient: directRecipient.publicKey,
          recipientAta,
          ceaAuthority,
          ceaAta,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        })
        .remainingAccounts(
          failingIx.keys.map((key) => ({
            pubkey: key.pubkey,
            isWritable: key.isWritable,
            isSigner: false,
          }))
        )
        .signers([relayer])
        .rpc()
    );

    const supplyAfter = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );
    const ceaAfter = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    const executedMarker = await provider.connection.getAccountInfo(
      getExecutedTxPda(subTxId, gatewayProgram.programId)
    );
    expect(supplyAfter).to.equal(supplyBefore);
    expect(ceaAfter).to.equal(ceaBefore);
    expect(executedMarker).to.equal(null);
  });

  it("rejects malformed direct-burn requests before any supply change", async () => {
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const zeroAmountSubTxId = generate32Bytes();
    const zeroRecipientSubTxId = generate32Bytes();
    const zeroRevertRecipientSubTxId = generate32Bytes();

    await expectError(
      gatewayProgram.methods
        .sendPc20UniversalTx(
          Array.from(zeroAmountSubTxId),
          Array.from(sourceAsset),
          new anchor.BN(0),
          Array.from(generate20Bytes()),
          Buffer.from([]),
          revertRecipient.publicKey
        )
        .accountsPartial({
          config: configPda,
          caller: directRecipient.publicKey,
          pc20Mint: wrappedMint,
          userAta: recipientAta,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([directRecipient])
        .rpc(),
      "InvalidAmount"
    );

    await expectError(
      gatewayProgram.methods
        .sendPc20UniversalTx(
          Array.from(zeroRecipientSubTxId),
          Array.from(sourceAsset),
          new anchor.BN(1),
          new Array(20).fill(0),
          Buffer.from([]),
          revertRecipient.publicKey
        )
        .accountsPartial({
          config: configPda,
          caller: directRecipient.publicKey,
          pc20Mint: wrappedMint,
          userAta: recipientAta,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([directRecipient])
        .rpc(),
      "InvalidRecipient"
    );

    await expectError(
      gatewayProgram.methods
        .sendPc20UniversalTx(
          Array.from(zeroRevertRecipientSubTxId),
          Array.from(sourceAsset),
          new anchor.BN(1),
          Array.from(generate20Bytes()),
          Buffer.from([]),
          PublicKey.default
        )
        .accountsPartial({
          config: configPda,
          caller: directRecipient.publicKey,
          pc20Mint: wrappedMint,
          userAta: recipientAta,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([directRecipient])
        .rpc(),
      "InvalidRecipient"
    );
  });

  it("keeps direct PC20 burns event-only without SVM-only sub_tx_id replay state", async () => {
    const burnSubTxId = generate32Bytes();
    const burnAmount = 1_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const beforeBalance = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );

    await gatewayProgram.methods
      .sendPc20UniversalTx(
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        Array.from(generate20Bytes()),
        Buffer.from([]),
        revertRecipient.publicKey
      )
      .accountsPartial({
        config: configPda,
        caller: directRecipient.publicKey,
        pc20Mint: wrappedMint,
        userAta: recipientAta,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([directRecipient])
      .rpc();

    await gatewayProgram.methods
      .sendPc20UniversalTx(
        Array.from(burnSubTxId),
        Array.from(sourceAsset),
        new anchor.BN(burnAmount),
        Array.from(generate20Bytes()),
        Buffer.from([]),
        revertRecipient.publicKey
      )
      .accountsPartial({
        config: configPda,
        caller: directRecipient.publicKey,
        pc20Mint: wrappedMint,
        userAta: recipientAta,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([directRecipient])
      .rpc();

    const afterBalance = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    expect(afterBalance).to.equal(beforeBalance - burnAmount * 2);
  });

  it("rejects finalize-routed CEA PC20 burns with a non-canonical mint account", async () => {
    const mintSubTxId = generate32Bytes();
    const burnSubTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 3_000_000;
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );

    const noopReceiveIx = SystemProgram.transfer({
      fromPubkey: ceaAuthority,
      toPubkey: directRecipient.publicKey,
      lamports: 1,
    });
    const noopFields = instructionToPayloadFields({
      instruction: noopReceiveIx,
      targetProgram: SystemProgram.programId,
      instructionId: 2,
    });
    const noopUserData = encodeExecutePayload(noopFields);

    const finalizeGasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const finalizeGasFee = finalizeGasUsed + COMPUTE_BUFFER;
    const finalizeSig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId: mintSubTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee: finalizeGasFee,
        userData: noopUserData,
      }),
    });

    await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(mintSubTxId),
        Array.from(universalTxId),
        Array.from(sourceAsset),
        new anchor.BN(amount),
        Array.from(pushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        noopUserData,
        new anchor.BN(finalizeGasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(finalizeSig.signature),
        finalizeSig.recoveryId,
        Array.from(finalizeSig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        pc20Mint: wrappedMint,
        recipient: directRecipient.publicKey,
        recipientAta,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .remainingAccounts(
        noopReceiveIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        }))
      )
      .signers([relayer])
      .rpc();

    const pushRecipient = generate20Bytes();
    const pushPayload = Buffer.from("bad-cea-burn", "utf8");
    const burnUniversalTxId = generateUniversalTxId();
    const burnIxData = encodePc20BurnIxData({
      subTxId: burnSubTxId,
      sourceAsset,
      amount: BigInt(amount),
      recipient: pushRecipient,
      payload: pushPayload,
      revertRecipient: revertRecipient.publicKey,
    });
    const badBurnAccounts = [
      { pubkey: directRecipient.publicKey, isWritable: true },
      { pubkey: ceaAta, isWritable: true },
      { pubkey: TOKEN_PROGRAM_ID, isWritable: false },
    ];
    const burnGasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await getExecutedTxRent(provider.connection));
    const burnGasFee = burnGasUsed + COMPUTE_BUFFER;
    const badBurnSig = await signWithCurrentTss({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      additional: buildExecuteAdditionalData(
        new Uint8Array(burnUniversalTxId),
        new Uint8Array(burnSubTxId),
        gatewayProgram.programId,
        new Uint8Array(pushAccount),
        badBurnAccounts,
        burnIxData,
        burnGasFee
      ),
    });
    const ceaBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );

    await expectError(
      gatewayProgram.methods
        .finalizeUniversalTx(
          2,
          Array.from(burnSubTxId),
          Array.from(burnUniversalTxId),
          new anchor.BN(0),
          Array.from(pushAccount),
          accountsToWritableFlagsOnly(badBurnAccounts),
          burnIxData,
          new anchor.BN(burnGasFee.toString()),
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(badBurnSig.signature),
          badBurnSig.recoveryId,
          Array.from(badBurnSig.messageHash)
        )
        .accountsPartial({
          caller: relayer.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority,
          tssPda,
          executedSubTx: getExecutedTxPda(
            burnSubTxId,
            gatewayProgram.programId
          ),
          destinationProgram: gatewayProgram.programId,
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
          storedIxData: null,
          storeRefundRecipient: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(
          badBurnAccounts.map((account) => ({
            pubkey: account.pubkey,
            isWritable: account.isWritable,
            isSigner: false,
          }))
        )
        .signers([relayer])
        .rpc(),
      "InvalidPc20Mint"
    );

    const ceaAfter = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(ceaAfter).to.equal(ceaBefore);
  });

  it("rejects malformed finalize-routed CEA PC20 burn remaining accounts", async () => {
    const amount = 1_000_000;
    const ceaAta = await mintWrappedPc20ToCea(amount);
    const directRecipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const makeCanonicalAccounts = (): BurnAccountMeta[] => [
      { pubkey: wrappedMint, isWritable: true },
      { pubkey: ceaAta, isWritable: true },
      { pubkey: TOKEN_PROGRAM_ID, isWritable: false },
    ];
    const wrongCeaAtaSubTxId = generate32Bytes();
    const wrongTokenProgramSubTxId = generate32Bytes();
    const missingTokenProgramSubTxId = generate32Bytes();
    const cases: Array<{
      label: string;
      subTxId: number[];
      accounts: BurnAccountMeta[];
      expectedError: string;
    }> = [
      {
        label: "wrong CEA ATA",
        subTxId: wrongCeaAtaSubTxId,
        accounts: (() => {
          const accounts = makeCanonicalAccounts();
          accounts[1] = { pubkey: directRecipientAta, isWritable: true };
          return accounts;
        })(),
        expectedError: "InvalidAccount",
      },
      {
        label: "wrong token program",
        subTxId: wrongTokenProgramSubTxId,
        accounts: (() => {
          const accounts = makeCanonicalAccounts();
          accounts[2] = { pubkey: SystemProgram.programId, isWritable: false };
          return accounts;
        })(),
        expectedError: "InvalidAccount",
      },
      {
        label: "missing token program",
        subTxId: missingTokenProgramSubTxId,
        accounts: (() => {
          return makeCanonicalAccounts().slice(0, 2);
        })(),
        expectedError: "AccountListLengthMismatch",
      },
    ];

    const balanceBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    for (const testCase of cases) {
      await expectError(
        finalizeRoutedCeaPc20Burn({
          burnSubTxId: testCase.subTxId,
          amount,
          payload: Buffer.from(testCase.label, "utf8"),
          accounts: testCase.accounts,
        }),
        testCase.expectedError
      );
    }
    const balanceAfter = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(balanceAfter).to.equal(balanceBefore);
  });

  it("rejects PC20 exports and burns while the gateway is paused", async () => {
    const burnSubTxId = generate32Bytes();
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );

    const finalizeSubTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const gasFee = gasUsed + COMPUTE_BUFFER;
    const finalizeSig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId: finalizeSubTxId,
        sourceAsset,
        pushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
      }),
    });

    await pauseGateway();
    try {
      await expectError(
        gatewayProgram.methods
          .sendPc20UniversalTx(
            Array.from(burnSubTxId),
            Array.from(sourceAsset),
            new anchor.BN(1),
            Array.from(generate20Bytes()),
            Buffer.from([]),
            revertRecipient.publicKey
          )
          .accountsPartial({
            config: configPda,
            caller: directRecipient.publicKey,
            pc20Mint: wrappedMint,
            userAta: recipientAta,
            tokenProgram: TOKEN_PROGRAM_ID,
          })
          .signers([directRecipient])
          .rpc(),
        "Paused"
      );

      await expectError(
        gatewayProgram.methods
          .finalizePc20Export(
            Array.from(finalizeSubTxId),
            Array.from(universalTxId),
            Array.from(sourceAsset),
            new anchor.BN(amount),
            Array.from(pushAccount),
            directRecipient.publicKey,
            name,
            symbol,
            decimals,
            Buffer.from([]),
            new anchor.BN(gasFee.toString()),
            new anchor.BN(DEFAULT_DEADLINE.toString()),
            Array.from(finalizeSig.signature),
            finalizeSig.recoveryId,
            Array.from(finalizeSig.messageHash)
          )
          .accountsPartial({
            caller: relayer.publicKey,
            config: configPda,
            vaultSol: vaultPda,
            pc20Mint: wrappedMint,
            recipient: directRecipient.publicKey,
            recipientAta,
            ceaAuthority,
            ceaAta: await getCeaAta(
              pushAccount,
              wrappedMint,
              gatewayProgram.programId
            ),
            tssPda,
            executedSubTx: getExecutedTxPda(
              finalizeSubTxId,
              gatewayProgram.programId
            ),
            destinationProgram: SystemProgram.programId,
            systemProgram: SystemProgram.programId,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          })
          .signers([relayer])
          .rpc(),
        "Paused"
      );
    } finally {
      await unpauseGateway();
    }
  });

  it("rejects underfunded gas budgets on first export", async () => {
    const badSourceAsset = generate20Bytes();
    const badPushAccount = generate20Bytes();
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;

    const executedTxRent =
      await provider.connection.getMinimumBalanceForRentExemption(8);
    const mintRent = await getMintRent();
    const ataRent = await getTokenAccountRent(provider.connection);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent);
    const gasFee = gasUsed - BigInt(1);

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset: badSourceAsset,
        pushAccount: badPushAccount,
        recipient: directRecipient.publicKey,
        name,
        symbol,
        decimals,
        gasFee,
      }),
    });

    const resolvedBad = await gatewayProgram.methods
      .finalizePc20Export(
        Array.from(subTxId),
        Array.from(universalTxId),
        Array.from(badSourceAsset),
        new anchor.BN(amount),
        Array.from(badPushAccount),
        directRecipient.publicKey,
        name,
        symbol,
        decimals,
        Buffer.from([]),
        new anchor.BN(gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer.publicKey,
        config: configPda,
        vaultSol: vaultPda,
        recipient: directRecipient.publicKey,
        recipientAta: directRecipient.publicKey,
        ceaAta: directRecipient.publicKey,
        tssPda,
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
      })
      .pubkeys();

    const recipientAta = getAssociatedTokenAddressSync(
      resolvedBad.pc20Mint!,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const ceaAta = await getCeaAta(
      badPushAccount,
      resolvedBad.pc20Mint!,
      gatewayProgram.programId
    );

    await expectError(
      gatewayProgram.methods
        .finalizePc20Export(
          Array.from(subTxId),
          Array.from(universalTxId),
          Array.from(badSourceAsset),
          new anchor.BN(amount),
          Array.from(badPushAccount),
          directRecipient.publicKey,
          name,
          symbol,
          decimals,
          Buffer.from([]),
          new anchor.BN(gasFee.toString()),
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(sig.signature),
          sig.recoveryId,
          Array.from(sig.messageHash)
        )
        .accountsPartial({
          caller: relayer.publicKey,
          config: configPda,
          vaultSol: vaultPda,
          pc20Mint: resolvedBad.pc20Mint!,
          recipient: directRecipient.publicKey,
          recipientAta,
          ceaAuthority: resolvedBad.ceaAuthority!,
          ceaAta,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: SystemProgram.programId,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        })
        .signers([relayer])
        .rpc(),
      "InsufficientGasBudget"
    );
  });
});
