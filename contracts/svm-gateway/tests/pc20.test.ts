import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createAssociatedTokenAccountInstruction,
  createTransferInstruction,
  getAccount,
  getAssociatedTokenAddressSync,
  getMint,
  MINT_SIZE,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { AbiCoder } from "ethers";
import { randomBytes } from "crypto";
import pkg from "js-sha3";
import * as secp from "@noble/secp256k1";
import {
  encodeExecutePayload,
  instructionToPayloadFields,
} from "../app/execute-payload";
import * as sharedState from "./shared-state";
import { ensureTestSetup } from "./helpers/test-setup";
import { extractEventCpi } from "./helpers/test-utils";
import {
  buildExecuteAdditionalData,
  buildPc20FinalizeAdditionalData,
  buildRescueAdditionalData,
  buildRevertAdditionalData,
  generateUniversalTxId,
  signTssMessage,
  TssInstruction,
  DEFAULT_DEADLINE,
} from "./helpers/tss";
import {
  SIGNATURE_FEE_LAMPORTS,
  accountsToWritableFlagsOnly,
  computeDiscriminator,
  getCeaAuthorityPda,
  getCeaAta,
  getExecutedTxPda,
  getExecutedTxRent,
  getPc20MintPda,
  getPc20StatePda,
  getTokenAccountRent,
  getTokenRateLimitPda,
} from "./helpers/test-utils";

const { keccak_256 } = pkg;

const COMPUTE_BUFFER = BigInt(100_000);
const REF_FINALIZE_STORE_UPLOAD_FEE = SIGNATURE_FEE_LAMPORTS;

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

const encodeVec = (value: Buffer | Uint8Array): Buffer => {
  const bytes = Buffer.from(value);
  const len = Buffer.alloc(4);
  len.writeUInt32LE(bytes.length, 0);
  return Buffer.concat([len, bytes]);
};

const encodePc20EventPayload = (payload: Buffer | Uint8Array): Buffer =>
  Buffer.concat([Buffer.from("PC20", "ascii"), Buffer.from(payload)]);

const evmAddressAsPubkey = (address: Uint8Array | number[]): PublicKey =>
  new PublicKey(Buffer.concat([Buffer.alloc(12), Buffer.from(address)]));

const abiCoder = AbiCoder.defaultAbiCoder();
const PC20_DEST_CHAIN_NAMESPACE = "solana:localnet";

const encodePc20ExportIxData = (params: {
  sourceAsset: number[] | Uint8Array;
  destChainNamespace?: string;
  name: string;
  symbol: string;
  decimals: number;
  userData?: Buffer | Uint8Array;
}): Buffer =>
  Buffer.concat([
    Buffer.from("PC20", "ascii"),
    Buffer.from(params.sourceAsset),
    Buffer.from(
      abiCoder
        .encode(
          ["string", "string", "string", "uint8"],
          [
            params.destChainNamespace ?? PC20_DEST_CHAIN_NAMESPACE,
            params.name,
            params.symbol,
            params.decimals,
          ]
        )
        .slice(2),
      "hex"
    ),
    Buffer.from(params.userData ?? Buffer.alloc(0)),
  ]);

const hashIxData = (ixData: Buffer): Uint8Array =>
  new Uint8Array(keccak_256.arrayBuffer(ixData));

const asIxDataHashArg = (ixDataHash: Uint8Array): number[] =>
  Buffer.from(ixDataHash) as unknown as number[];

const deriveStoredIxDataPda = (
  subTxId: number[] | Uint8Array,
  ixDataHash: Uint8Array,
  programId: PublicKey
): PublicKey => {
  const [pda] = PublicKey.findProgramAddressSync(
    [
      Buffer.from("stored_ix_data"),
      Buffer.from(subTxId),
      Buffer.from(ixDataHash),
    ],
    programId
  );
  return pda;
};

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
) => extractEventCpi(provider.connection, program, signature);

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
  let rateLimitConfigPda: PublicKey;
  let nativeSolTokenRateLimitPda: PublicKey;
  let mockPriceFeed: PublicKey;
  let counterPda: PublicKey;
  let wrappedMint: PublicKey;
  let pc20State: PublicKey;
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
    [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit_config")],
      gatewayProgram.programId
    );
    nativeSolTokenRateLimitPda = getTokenRateLimitPda(
      PublicKey.default,
      gatewayProgram.programId
    );
    mockPriceFeed = sharedState.getMockPriceFeed();
    [counterPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("counter")],
      counterProgram.programId
    );

    wrappedMint = getPc20MintPda(sourceAsset, gatewayProgram.programId);
    pc20State = getPc20StatePda(wrappedMint, gatewayProgram.programId);
    ceaAuthority = getCeaAuthorityPda(pushAccount, gatewayProgram.programId);

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

  const setInboundFee = async (feeLamports: number) => {
    await gatewayProgram.methods
      .setInboundFee(new anchor.BN(feeLamports))
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin])
      .rpc();
  };

  const pc20ExportViaFinalizeUniversalTx = (
    subTxId: number[] | Uint8Array,
    universalTxId: number[] | Uint8Array,
    exportSourceAsset: number[] | Uint8Array,
    amount: anchor.BN,
    exportPushAccount: number[] | Uint8Array,
    _recipient: PublicKey,
    exportName: string,
    exportSymbol: string,
    exportDecimals: number,
    userData: Buffer,
    gasFee: anchor.BN,
    deadline: anchor.BN,
    signature: number[],
    recoveryId: number,
    messageHash: number[]
  ) => {
    const ixData = encodePc20ExportIxData({
        sourceAsset: exportSourceAsset,
        name: exportName,
        symbol: exportSymbol,
        decimals: exportDecimals,
        userData,
      });
    const ixDataHash = hashIxData(ixData);
    const storedIxData = deriveStoredIxDataPda(
      subTxId,
      ixDataHash,
      gatewayProgram.programId
    );

    return {
      accountsPartial: (accounts: any) => ({
        remainingAccounts: (remainingAccounts: anchor.web3.AccountMeta[]) => ({
          signers: (signers: Keypair[]) => ({
            rpc: async () => {
              const storeSigner =
                signers.find((signer) => signer.publicKey.equals(accounts.caller)) ??
                relayer;

              await gatewayProgram.methods
                .storeExecuteIxData(
                  Array.from(subTxId),
                  asIxDataHashArg(ixDataHash),
                  ixData
                )
                .accountsPartial({
                  caller: accounts.caller,
                  storedIxData,
                  systemProgram: SystemProgram.programId,
                })
                .signers([storeSigner])
                .rpc();

              return gatewayProgram.methods
                .finalizeUniversalTxWithIxDataRef(
                  5,
                  Array.from(subTxId),
                  Array.from(universalTxId),
                  amount,
                  Array.from(exportPushAccount),
                  asIxDataHashArg(ixDataHash),
                  Buffer.alloc(0),
                  gasFee,
                  deadline,
                  signature,
                  recoveryId,
                  messageHash
                )
                .accountsPartial({
                  ...accounts,
                  storedIxData,
                  storeRefundRecipient: accounts.caller,
                })
                .remainingAccounts(remainingAccounts)
                .signers(signers)
                .rpc();
            },
          }),
        }),
      }),
    };
  };

  const pc20ExportRemaining = (
    _recipientAta: PublicKey | null,
    payloadAccounts: anchor.web3.AccountMeta[] = []
  ) => [
    { pubkey: pc20State, isWritable: true, isSigner: false },
    { pubkey: wrappedMint, isWritable: true, isSigner: false },
    ...payloadAccounts.map((account) => ({
      pubkey: account.pubkey,
      isWritable: account.isWritable,
      isSigner: false,
    })),
  ];

  const pc20BurnRemaining = () => [
    { pubkey: pc20State, isWritable: false, isSigner: false },
    { pubkey: wrappedMint, isWritable: true, isSigner: false },
  ];

  const pc20RemintRemaining = (recipientAta: PublicKey) => [
    { pubkey: pc20State, isWritable: false, isSigner: false },
    { pubkey: wrappedMint, isWritable: true, isSigner: false },
    { pubkey: recipientAta, isWritable: true, isSigner: false },
    {
      pubkey: ASSOCIATED_TOKEN_PROGRAM_ID,
      isWritable: false,
      isSigner: false,
    },
    { pubkey: anchor.web3.SYSVAR_RENT_PUBKEY, isWritable: false, isSigner: false },
  ];

  const sendPc20Tx = (params: {
    subTxId: number[] | Uint8Array;
    amount: number;
    recipient: number[] | Uint8Array;
    payload: Buffer;
    revertRecipient: PublicKey;
    caller?: Keypair;
    userAta: PublicKey;
    nativeAmount?: number;
    tokenRateLimit?: PublicKey | null;
    remainingAccounts?: anchor.web3.AccountMeta[];
  }) => {
    const caller = params.caller ?? directRecipient;
    return gatewayProgram.methods
      .sendUniversalTx(
        {
          recipient: Array.from(params.recipient),
          token: wrappedMint,
          amount: new anchor.BN(params.amount),
          payload: params.payload,
          revertRecipient: params.revertRecipient,
          signatureData: Buffer.from(params.subTxId),
        },
        new anchor.BN(params.nativeAmount ?? 0)
      )
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: params.userAta,
        gatewayTokenAccount: null,
        user: caller.publicKey,
        priceUpdate: mockPriceFeed,
        rateLimitConfig: rateLimitConfigPda,
        // A pure PC20 burn does not consume a per-token rate limit — pass null (no unused-account
        // hack). But if native value is also sent, the post-fee remainder routes as a native FUNDS
        // bridge, which IS rate-limited, so the native-SOL rate-limit PDA is required for that leg.
        tokenRateLimit:
          params.tokenRateLimit !== undefined
            ? params.tokenRateLimit
            : (params.nativeAmount ?? 0) > 0
              ? nativeSolTokenRateLimitPda
              : null,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .remainingAccounts(params.remainingAccounts ?? pc20BurnRemaining())
      .signers([caller])
      .rpc();
  };

  const revertPc20Tx = (params: {
    subTxId: number[] | Uint8Array;
    universalTxId: number[] | Uint8Array;
    amount: number;
    revertRecipient: PublicKey;
    recipientAta: PublicKey;
    gasFee: bigint;
    signature: number[];
    recoveryId: number;
    messageHash: number[];
  }) =>
    gatewayProgram.methods
      .revertUniversalTx(
        Array.from(params.subTxId),
        Array.from(params.universalTxId),
        new anchor.BN(params.amount),
        {
          revertRecipient: params.revertRecipient,
          revertMsg: Buffer.from([]),
        },
        new anchor.BN(params.gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        params.signature,
        params.recoveryId,
        params.messageHash
      )
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        tssPda,
        vault: vaultPda,
        recipient: params.revertRecipient,
        tokenVault: null,
        recipientTokenAccount: null,
        tokenMint: wrappedMint,
        tokenProgram: TOKEN_PROGRAM_ID,
        caller: relayer.publicKey,
        executedSubTx: getExecutedTxPda(
          Array.from(params.subTxId),
          gatewayProgram.programId
        ),
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(pc20RemintRemaining(params.recipientAta))
      .signers([relayer])
      .rpc();

  const rescuePc20Tx = (params: {
    subTxId: number[] | Uint8Array;
    universalTxId: number[] | Uint8Array;
    amount: number;
    recipient: PublicKey;
    recipientAta: PublicKey;
    gasFee: bigint;
    signature: number[];
    recoveryId: number;
    messageHash: number[];
  }) =>
    gatewayProgram.methods
      .rescueFunds(
        Array.from(params.subTxId),
        Array.from(params.universalTxId),
        new anchor.BN(params.amount),
        new anchor.BN(params.gasFee.toString()),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        params.signature,
        params.recoveryId,
        params.messageHash
      )
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        tssPda,
        vault: vaultPda,
        recipient: params.recipient,
        tokenVault: null,
        recipientTokenAccount: null,
        tokenMint: wrappedMint,
        tokenProgram: TOKEN_PROGRAM_ID,
        caller: relayer.publicKey,
        executedSubTx: getExecutedTxPda(
          Array.from(params.subTxId),
          gatewayProgram.programId
        ),
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(pc20RemintRemaining(params.recipientAta))
      .signers([relayer])
      .rpc();

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

  const ensureAta = async (
    ata: PublicKey,
    mint: PublicKey,
    owner: PublicKey,
    payer: Keypair = directRecipient
  ) => {
    if (await provider.connection.getAccountInfo(ata)) {
      return;
    }
    await provider.sendAndConfirm(
      new anchor.web3.Transaction().add(
        createAssociatedTokenAccountInstruction(
          payer.publicKey,
          ata,
          owner,
          mint,
          TOKEN_PROGRAM_ID,
          ASSOCIATED_TOKEN_PROGRAM_ID
        )
      ),
      [payer]
    );
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
    const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (ceaAtaInfo
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;
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

    const txSig = await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: pc20State, isWritable: true, isSigner: false },
        { pubkey: wrappedMint, isWritable: true, isSigner: false },
        ...noopReceiveIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        })),
      ])
      .signers([relayer])
      .rpc();

    return ceaAta;
  };

  const mintWrappedPc20ToUser = async (amount: number) => {
    const mintSubTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    await ensureAta(
      recipientAta,
      wrappedMint,
      directRecipient.publicKey,
      directRecipient
    );

    const transferIx = createTransferInstruction(
      ceaAta,
      recipientAta,
      ceaAuthority,
      amount,
      [],
      TOKEN_PROGRAM_ID
    );
    const userData = encodeExecutePayload(
      instructionToPayloadFields({
        instruction: transferIx,
        targetProgram: TOKEN_PROGRAM_ID,
        instructionId: 2,
      })
    );

    const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (ceaAtaInfo
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;
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
        userData,
      }),
    });

    await pc20ExportViaFinalizeUniversalTx(
        Array.from(mintSubTxId),
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: pc20State, isWritable: true, isSigner: false },
        { pubkey: wrappedMint, isWritable: true, isSigner: false },
        ...transferIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        })),
      ])
      .signers([relayer])
      .rpc();

    return recipientAta;
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
    const recipient = params.recipient ?? Array.from(pushAccount);
    const payload = params.payload ?? Buffer.from("cea-burn", "utf8");
    const revertRecipientKey =
      params.revertRecipient ?? revertRecipient.publicKey;
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );
    const burnIxData = Buffer.from(
      gatewayProgram.coder.instruction.encode("sendUniversalTx", {
        req: {
          recipient,
          token: wrappedMint,
          amount: new anchor.BN(params.amount),
          payload,
          revertRecipient: revertRecipientKey,
          signatureData: Buffer.from(params.burnSubTxId),
        },
        nativeAmount: new anchor.BN(0),
      })
    );
    const accounts = params.accounts ?? [
      { pubkey: pc20State, isWritable: false },
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

  it("creates the canonical wrapped mint and mints to the CEA", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 125_000_000;
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );

    const executedTxRent =
      await provider.connection.getMinimumBalanceForRentExemption(8);
    const mintRent = await getMintRent();
    const ataRent = await getTokenAccountRent(provider.connection);
    const pc20StateRent = BigInt(
      await provider.connection.getMinimumBalanceForRentExemption(62)
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent) +
      pc20StateRent;
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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

    const txSig = await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
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
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts(pc20ExportRemaining(null))
      .signers([relayer])
      .rpc();

    const mintInfo = await getMint(provider.connection, wrappedMint);
    expect(Number(mintInfo.supply)).to.equal(amount);
    expect(mintInfo.decimals).to.equal(decimals);

    const ceaAccount = await getAccount(provider.connection, ceaAta);
    expect(Number(ceaAccount.amount)).to.equal(amount);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const pc20Export = events.find(
      (event) => event.name === "universalTxFinalized"
    );
    expect(pc20Export, "UniversalTxFinalized event missing").to.exist;
    expect(Number(pc20Export!.data.amount)).to.equal(amount);
    expect(pc20Export!.data.target.toBase58()).to.equal(
      directRecipient.publicKey.toBase58()
    );
    expect(pc20Export!.data.wrapperAddress.toBase58()).to.equal(
      wrappedMint.toBase58()
    );
    expect(pc20Export!.data.token.toBase58()).to.equal(
      evmAddressAsPubkey(sourceAsset).toBase58()
    );
    expect(Buffer.from(pc20Export!.data.payload)).to.deep.equal(Buffer.alloc(0));
    expect(BigInt(pc20Export!.data.gasFee.toString())).to.equal(gasFee);
    expect(BigInt(pc20Export!.data.gasUsed.toString())).to.equal(
      gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE
    );
    expect(BigInt(pc20Export!.data.gasToRefund.toString())).to.equal(
      COMPUTE_BUFFER
    );
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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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

    await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
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
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts(pc20ExportRemaining(recipientAta))
      .signers([relayer])
      .rpc();

    const afterMint = await getMint(provider.connection, wrappedMint);
    expect(Number(afterMint.supply)).to.equal(
      Number(beforeMint.supply) + amount
    );

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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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
      pc20ExportViaFinalizeUniversalTx(
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
          recipient: mismatchedRecipient,
          recipientAta: null,
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
          vaultAta: null,
          mint: null,
          rateLimitConfig: null,
          tokenRateLimit: null,
          storedIxData: null,
          storeRefundRecipient: null,
        })
        .remainingAccounts(pc20ExportRemaining(mismatchedRecipientAta))
        .signers([relayer])
        .rpc(),
      "MessageHashMismatch"
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

  it("rejects PC20 finalize signatures bound to a different source asset", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;
    const wrongSourceAsset = Array.from(sourceAsset);
    wrongSourceAsset[0] ^= 1;
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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Pc20Finalize,
      amount: BigInt(amount),
      additional: buildPc20FinalizeAdditionalData({
        universalTxId,
        subTxId,
        sourceAsset: wrongSourceAsset,
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
      pc20ExportViaFinalizeUniversalTx(
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
          recipient: directRecipient.publicKey,
          recipientAta: null,
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
          vaultAta: null,
          mint: null,
          rateLimitConfig: null,
          tokenRateLimit: null,
          storedIxData: null,
          storeRefundRecipient: null,
        })
        .remainingAccounts(pc20ExportRemaining(recipientAta))
        .signers([relayer])
        .rpc(),
      "MessageHashMismatch"
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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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

    await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: pc20State, isWritable: true, isSigner: false },
        { pubkey: wrappedMint, isWritable: true, isSigner: false },
        ...transferIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        })),
      ])
      .signers([relayer])
      .rpc();

    const ceaAfter = await getAccount(provider.connection, ceaAta);
    expect(Number(ceaAfter.amount)).to.equal(ceaBefore + amount);
    const recipientLamportsAfter = await provider.connection.getBalance(
      directRecipient.publicKey
    );
    expect(recipientLamportsAfter).to.equal(recipientLamportsBefore + 1);

  });

  it("burns wrapped supply from a user wallet and emits the outbound PC20 event", async () => {
    const burnSubTxId = generate32Bytes();
    const burnAmount = 40_000_000;
    await mintWrappedPc20ToUser(burnAmount);
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
    const inboundFee = 12_345;

    await setInboundFee(inboundFee);
    const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);

    let txSig: string;
    try {
      txSig = await sendPc20Tx({
        subTxId: burnSubTxId,
        amount: burnAmount,
        recipient: pushRecipient,
        payload: pushPayload,
        revertRecipient: revertRecipient.publicKey,
        userAta: recipientAta,
        nativeAmount: inboundFee,
      });
    } finally {
      await setInboundFee(0);
    }

    const afterMint = await getMint(provider.connection, wrappedMint);
    const afterBalance = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
    expect(Number(afterMint.supply)).to.equal(
      Number(beforeMint.supply) - burnAmount
    );
    expect(afterBalance).to.equal(beforeBalance - burnAmount);
    expect(feeVaultAfter - feeVaultBefore).to.equal(inboundFee);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const burnEvent = events.find((event) => event.name === "universalTx");
    expect(burnEvent!.data.fromCea).to.equal(false);
    expect(Number(burnEvent!.data.amount)).to.equal(burnAmount);
    expect(burnEvent!.data.txType.fundsAndPayload !== undefined).to.equal(true);
    expect(Buffer.from(burnEvent!.data.payload)).to.deep.equal(
      encodePc20EventPayload(pushPayload)
    );
  });

  it("rejects generic PC20 burns with malformed remaining accounts before debiting user", async () => {
    const burnAmount = 1_000_000;
    await mintWrappedPc20ToUser(burnAmount);
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const malformedCases: Array<{
      label: string;
      remainingAccounts: anchor.web3.AccountMeta[];
    }> = [
      {
        label: "missing mint",
        remainingAccounts: [
          { pubkey: pc20State, isWritable: false, isSigner: false },
        ],
      },
      {
        label: "wrong mint",
        remainingAccounts: [
          { pubkey: pc20State, isWritable: false, isSigner: false },
          { pubkey: directRecipient.publicKey, isWritable: true, isSigner: false },
        ],
      },
      {
        label: "non-writable mint",
        remainingAccounts: [
          { pubkey: pc20State, isWritable: false, isSigner: false },
          { pubkey: wrappedMint, isWritable: false, isSigner: false },
        ],
      },
    ];

    const balanceBefore = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );

    for (const testCase of malformedCases) {
      await expectRejected(
        sendPc20Tx({
          subTxId: generate32Bytes(),
          amount: burnAmount,
          recipient: generate20Bytes(),
          payload: Buffer.from(testCase.label, "utf8"),
          revertRecipient: revertRecipient.publicKey,
          userAta: recipientAta,
          remainingAccounts: testCase.remainingAccounts,
        })
      );
    }

    const balanceAfter = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    expect(balanceAfter).to.equal(balanceBefore);
  });

  it("routes native value above the inbound fee as a native FUNDS transfer after PC20 burn", async () => {
    const burnAmount = 1_000_000;
    const inboundFee = 10;
    const nativeTopUp = 1_000_000;
    await mintWrappedPc20ToUser(burnAmount);
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const balanceBefore = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const vaultBefore = await provider.connection.getBalance(vaultPda);

    await setInboundFee(inboundFee);
    const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);
    let txSig: string;
    try {
      txSig = await sendPc20Tx({
        subTxId: generate32Bytes(),
        amount: burnAmount,
        recipient: generate20Bytes(),
        payload: Buffer.from("overpay", "utf8"),
        revertRecipient: revertRecipient.publicKey,
        userAta: recipientAta,
        nativeAmount: inboundFee + nativeTopUp,
      });
    } finally {
      await setInboundFee(0);
    }

    const balanceAfter = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
    const vaultAfter = await provider.connection.getBalance(vaultPda);
    expect(balanceAfter).to.equal(balanceBefore - burnAmount);
    expect(feeVaultAfter - feeVaultBefore).to.equal(inboundFee);
    expect(vaultAfter - vaultBefore).to.equal(nativeTopUp);

    const events = await decodeEvents(provider, gatewayProgram, txSig!);
    const universalEvents = events.filter((event) => event.name === "universalTx");
    expect(universalEvents.length).to.equal(2);
    expect(universalEvents[0].data.txType.fundsAndPayload !== undefined).to.equal(true);
    expect(universalEvents[1].data.txType.funds !== undefined).to.equal(true);
    expect(universalEvents[1].data.token.toBase58()).to.equal(
      PublicKey.default.toBase58()
    );
    expect(Number(universalEvents[1].data.amount)).to.equal(nativeTopUp);
  });

  it("rejects PC20 burn native excess without token rate-limit PDA and rolls back burn", async () => {
    const burnAmount = 1_000_000;
    const nativeTopUp = 1_000_000;
    await mintWrappedPc20ToUser(burnAmount);
    const recipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      directRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const balanceBefore = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const vaultBefore = await provider.connection.getBalance(vaultPda);

    await expectError(
      sendPc20Tx({
        subTxId: generate32Bytes(),
        amount: burnAmount,
        recipient: generate20Bytes(),
        payload: Buffer.from("missing-native-rate-limit", "utf8"),
        revertRecipient: revertRecipient.publicKey,
        userAta: recipientAta,
        nativeAmount: nativeTopUp,
        tokenRateLimit: null,
      }),
      "InvalidAccount"
    );

    const balanceAfter = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    const vaultAfter = await provider.connection.getBalance(vaultPda);
    expect(balanceAfter).to.equal(balanceBefore);
    expect(vaultAfter).to.equal(vaultBefore);
  });

  it("rejects legacy native FUNDS when token rate-limit PDA is omitted", async () => {
    const nativeAmount = 1_000_000;
    const vaultBefore = await provider.connection.getBalance(vaultPda);
    const req = {
      recipient: Array.from(generate20Bytes()),
      token: PublicKey.default,
      amount: new anchor.BN(nativeAmount),
      payload: Buffer.from([]),
      revertRecipient: revertRecipient.publicKey,
      signatureData: Buffer.from("missing_legacy_rate_limit"),
    };

    await expectError(
      gatewayProgram.methods
        .sendUniversalTx(req, new anchor.BN(nativeAmount))
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: null,
          gatewayTokenAccount: null,
          user: directRecipient.publicKey,
          priceUpdate: mockPriceFeed,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([directRecipient])
        .rpc(),
      "InvalidAccount"
    );

    const vaultAfter = await provider.connection.getBalance(vaultPda);
    expect(vaultAfter).to.equal(vaultBefore);
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
    const finalizeGasFee =
      finalizeGasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;
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

    await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: pc20State, isWritable: true, isSigner: false },
        { pubkey: wrappedMint, isWritable: true, isSigner: false },
        ...noopReceiveIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        })),
      ])
      .signers([relayer])
      .rpc();

    const ceaBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(ceaBefore).to.equal(ceaBalanceBeforeFinalize + amount);

    const pushPayload = Buffer.from("cea-burn", "utf8");
    const burnUniversalTxId = generateUniversalTxId();
    const burnIxData = Buffer.from(
      gatewayProgram.coder.instruction.encode("sendUniversalTx", {
        req: {
          recipient: Array.from(pushAccount),
          token: wrappedMint,
          amount: new anchor.BN(amount),
          payload: pushPayload,
          revertRecipient: revertRecipient.publicKey,
          signatureData: Buffer.from(burnSubTxId),
        },
        nativeAmount: new anchor.BN(0),
      })
    );
    const burnAccounts = [
      { pubkey: pc20State, isWritable: false },
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
      (event) => event.name === "universalTx"
    );
    expect(
      burnEvents.some((event) => event.name === "universalTxFinalized")
    ).to.equal(false);
    expect(burnEvent!.data.fromCea).to.equal(true);
    expect(Number(burnEvent!.data.amount)).to.equal(amount);
    expect(burnEvent!.data.txType.fundsAndPayload !== undefined).to.equal(true);
    expect(Buffer.from(burnEvent!.data.payload)).to.deep.equal(
      encodePc20EventPayload(pushPayload)
    );
  });

  it("burns wrapped supply from the CEA through the generic inner send_universal_tx route", async () => {
    const amount = 3_000_000;
    const burnSubTxId = generate32Bytes();
    const ceaAta = await mintWrappedPc20ToCea(amount);
    const ceaBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    const payload = Buffer.from("generic-cea-burn", "utf8");

    const { txSig } = await finalizeRoutedCeaPc20Burn({
      burnSubTxId,
      amount,
      payload,
    });

    const ceaAfter = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(ceaAfter).to.equal(ceaBefore - amount);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const burnEvent = events.find((event) => event.name === "universalTx");
    expect(burnEvent, "UniversalTx event missing").to.exist;
    expect(
      events.some((event) => event.name === "universalTxFinalized")
    ).to.equal(false);
    expect(burnEvent!.data.fromCea).to.equal(true);
    expect(Number(burnEvent!.data.amount)).to.equal(amount);
    expect(Buffer.from(burnEvent!.data.payload)).to.deep.equal(
      encodePc20EventPayload(payload)
    );
  });

  it("rejects finalize-routed CEA PC20 burns when recipient is not the mapped push account", async () => {
    const amount = 1_000_000;
    const burnSubTxId = generate32Bytes();
    const ceaAta = await mintWrappedPc20ToCea(amount);
    const wrongRecipient = Array.from(pushAccount);
    wrongRecipient[0] ^= 1;
    const ceaBefore = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );

    await expectError(
      finalizeRoutedCeaPc20Burn({
        burnSubTxId,
        amount,
        recipient: wrongRecipient,
      }),
      "InvalidRecipient"
    );

    const ceaAfter = Number(
      (await getAccount(provider.connection, ceaAta)).amount
    );
    expect(ceaAfter).to.equal(ceaBefore);
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

    const splStyleRevertSubTxId = generate32Bytes();
    const splStyleSig = await signWithCurrentTss({
      instruction: TssInstruction.Revert,
      amount: BigInt(amount),
      additional: buildRevertAdditionalData(
        splStyleRevertSubTxId,
        burnSubTxId,
        revertRecipient.publicKey,
        Buffer.from([]),
        gasFee,
        wrappedMint
      ),
    });
    await expectError(
      revertPc20Tx({
        subTxId: splStyleRevertSubTxId,
        universalTxId: burnSubTxId,
        amount,
        revertRecipient: revertRecipient.publicKey,
        recipientAta: revertRecipientAta,
        gasFee,
        signature: Array.from(splStyleSig.signature),
        recoveryId: splStyleSig.recoveryId,
        messageHash: Array.from(splStyleSig.messageHash),
      }),
      "MessageHashMismatch"
    );
    expect(
      Number((await getMint(provider.connection, wrappedMint)).supply)
    ).to.equal(supplyAfterMint - amount);
    const balanceAfterSplStyleAttempt = revertRecipientAtaBeforeInfo
      ? Number(
          (await getAccount(provider.connection, revertRecipientAta)).amount
        )
      : 0;
    expect(balanceAfterSplStyleAttempt).to.equal(revertRecipientBalanceBefore);

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Revert,
      amount: BigInt(amount),
      additional: buildRevertAdditionalData(
        revertSubTxId,
        burnSubTxId,
        revertRecipient.publicKey,
        Buffer.from([]),
        gasFee,
        wrappedMint,
        sourceAsset
      ),
    });

    await revertPc20Tx({
      subTxId: revertSubTxId,
      universalTxId: burnSubTxId,
      amount,
      revertRecipient: revertRecipient.publicKey,
      recipientAta: revertRecipientAta,
      gasFee,
      signature: Array.from(sig.signature),
      recoveryId: sig.recoveryId,
      messageHash: Array.from(sig.messageHash),
    });

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

    await mintWrappedPc20ToUser(burnAmount);
    await sendPc20Tx({
      subTxId: burnSubTxId,
      amount: burnAmount,
      recipient: pushRecipient,
      payload: Buffer.from("revert-me", "utf8"),
      revertRecipient: revertRecipient.publicKey,
      userAta: recipientAta,
    });

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
      instruction: TssInstruction.Revert,
      amount: BigInt(burnAmount),
      additional: buildRevertAdditionalData(
        revertSubTxId,
        burnSubTxId,
        revertRecipient.publicKey,
        Buffer.from([]),
        gasFee,
        wrappedMint,
        sourceAsset
      ),
    });

    const txSig = await revertPc20Tx({
      subTxId: revertSubTxId,
      universalTxId: burnSubTxId,
      amount: burnAmount,
      revertRecipient: revertRecipient.publicKey,
      recipientAta: revertRecipientAta,
      gasFee,
      signature: Array.from(sig.signature),
      recoveryId: sig.recoveryId,
      messageHash: Array.from(sig.messageHash),
    });

    const revertedAta = await getAccount(
      provider.connection,
      revertRecipientAta
    );
    expect(Number(revertedAta.amount)).to.equal(
      revertRecipientBalanceBefore + burnAmount
    );

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const revertEvent = events.find(
      (event) => event.name === "revertUniversalTx"
    );
    expect(Number(revertEvent!.data.amount)).to.equal(burnAmount);
  });

  it("remints wrapped supply through generic rescue_funds for PC20 rescue", async () => {
    const subTxId = generate32Bytes();
    const splStyleSubTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const rescueAmount = 3_000_000;
    const rescueRecipient = Keypair.generate();
    const rescueRecipientAta = getAssociatedTokenAddressSync(
      wrappedMint,
      rescueRecipient.publicKey,
      false,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    const rescueRecipientAtaBeforeInfo =
      await provider.connection.getAccountInfo(rescueRecipientAta);
    const rescueRecipientBalanceBefore = rescueRecipientAtaBeforeInfo
      ? Number(
          (await getAccount(provider.connection, rescueRecipientAta)).amount
        )
      : 0;
    const supplyBefore = Number(
      (await getMint(provider.connection, wrappedMint)).supply
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8)) +
      (rescueRecipientAtaBeforeInfo
        ? BigInt(0)
        : BigInt(await getTokenAccountRent(provider.connection)));
    const gasFee = gasUsed + COMPUTE_BUFFER;

    const splStyleSig = await signWithCurrentTss({
      instruction: TssInstruction.Rescue,
      amount: BigInt(rescueAmount),
      additional: buildRescueAdditionalData(
        splStyleSubTxId,
        universalTxId,
        rescueRecipient.publicKey,
        gasFee,
        wrappedMint
      ),
    });
    await expectError(
      rescuePc20Tx({
        subTxId: splStyleSubTxId,
        universalTxId,
        amount: rescueAmount,
        recipient: rescueRecipient.publicKey,
        recipientAta: rescueRecipientAta,
        gasFee,
        signature: Array.from(splStyleSig.signature),
        recoveryId: splStyleSig.recoveryId,
        messageHash: Array.from(splStyleSig.messageHash),
      }),
      "MessageHashMismatch"
    );
    expect(
      Number((await getMint(provider.connection, wrappedMint)).supply)
    ).to.equal(supplyBefore);

    const sig = await signWithCurrentTss({
      instruction: TssInstruction.Rescue,
      amount: BigInt(rescueAmount),
      additional: buildRescueAdditionalData(
        subTxId,
        universalTxId,
        rescueRecipient.publicKey,
        gasFee,
        wrappedMint,
        sourceAsset
      ),
    });
    const txSig = await rescuePc20Tx({
      subTxId,
      universalTxId,
      amount: rescueAmount,
      recipient: rescueRecipient.publicKey,
      recipientAta: rescueRecipientAta,
      gasFee,
      signature: Array.from(sig.signature),
      recoveryId: sig.recoveryId,
      messageHash: Array.from(sig.messageHash),
    });

    const rescueRecipientAtaAfter = await getAccount(
      provider.connection,
      rescueRecipientAta
    );
    expect(Number(rescueRecipientAtaAfter.amount)).to.equal(
      rescueRecipientBalanceBefore + rescueAmount
    );
    expect(
      Number((await getMint(provider.connection, wrappedMint)).supply)
    ).to.equal(supplyBefore + rescueAmount);

    const events = await decodeEvents(provider, gatewayProgram, txSig);
    const rescueEvent = events.find((event) => event.name === "fundsRescued");
    expect(rescueEvent).to.not.equal(undefined);
    expect(Number(rescueEvent!.data.amount)).to.equal(rescueAmount);
    expect(rescueEvent!.data.token.toBase58()).to.equal(wrappedMint.toBase58());
    expect(BigInt(rescueEvent!.data.gasUsed.toString())).to.equal(gasUsed);
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

    await mintWrappedPc20ToUser(burnAmount);
    await sendPc20Tx({
      subTxId: burnSubTxId,
      amount: burnAmount,
      recipient: pushRecipient,
      payload: Buffer.from("revert-once", "utf8"),
      revertRecipient: secondRevertRecipient.publicKey,
      userAta: recipientAta,
    });

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
      instruction: TssInstruction.Revert,
      amount: BigInt(burnAmount),
      additional: buildRevertAdditionalData(
        firstRevertSubTxId,
        burnSubTxId,
        secondRevertRecipient.publicKey,
        Buffer.from([]),
        gasFee,
        wrappedMint,
        sourceAsset
      ),
    });

    await revertPc20Tx({
      subTxId: firstRevertSubTxId,
      universalTxId: burnSubTxId,
      amount: burnAmount,
      revertRecipient: secondRevertRecipient.publicKey,
      recipientAta: secondRevertRecipientAta,
      gasFee,
      signature: Array.from(firstSig.signature),
      recoveryId: firstSig.recoveryId,
      messageHash: Array.from(firstSig.messageHash),
    });

    const balanceAfterFirst = Number(
      (await getAccount(provider.connection, secondRevertRecipientAta)).amount
    );
    expect(balanceAfterFirst).to.equal(burnAmount);

    const secondSig = await signWithCurrentTss({
      instruction: TssInstruction.Revert,
      amount: BigInt(burnAmount),
      additional: buildRevertAdditionalData(
        secondRevertSubTxId,
        burnSubTxId,
        secondRevertRecipient.publicKey,
        Buffer.from([]),
        gasFee,
        wrappedMint,
        sourceAsset
      ),
    });

    await revertPc20Tx({
      subTxId: secondRevertSubTxId,
      universalTxId: burnSubTxId,
      amount: burnAmount,
      revertRecipient: secondRevertRecipient.publicKey,
      recipientAta: secondRevertRecipientAta,
      gasFee,
      signature: Array.from(secondSig.signature),
      recoveryId: secondSig.recoveryId,
      messageHash: Array.from(secondSig.messageHash),
    });

    const balanceAfterSecond = Number(
      (await getAccount(provider.connection, secondRevertRecipientAta)).amount
    );
    expect(balanceAfterSecond).to.equal(burnAmount * 2);

    await expectRejected(
      revertPc20Tx({
        subTxId: secondRevertSubTxId,
        universalTxId: burnSubTxId,
        amount: burnAmount,
        revertRecipient: secondRevertRecipient.publicKey,
        recipientAta: secondRevertRecipientAta,
        gasFee,
        signature: Array.from(secondSig.signature),
        recoveryId: secondSig.recoveryId,
        messageHash: Array.from(secondSig.messageHash),
      })
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
    const pc20StateRent = BigInt(
      await provider.connection.getMinimumBalanceForRentExemption(62)
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent) +
      pc20StateRent;
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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

    const exportMint = getPc20MintPda(exportSourceAsset, gatewayProgram.programId);
    const exportState = getPc20StatePda(exportMint, gatewayProgram.programId);
    const exportCeaAuthority = getCeaAuthorityPda(
      exportPushAccount,
      gatewayProgram.programId
    );

    const ceaAta = await getCeaAta(
      exportPushAccount,
      exportMint,
      gatewayProgram.programId
    );

    await pc20ExportViaFinalizeUniversalTx(
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
        recipientAta: null,
        ceaAuthority: exportCeaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: exportState, isWritable: true, isSigner: false },
        { pubkey: exportMint, isWritable: true, isSigner: false },
      ])
      .signers([relayer])
      .rpc();

    const mintInfo = await getMint(provider.connection, exportMint);
    const ceaAccount = await getAccount(provider.connection, ceaAta);
    expect(mintInfo.decimals).to.equal(exportDecimals);
    expect(Number(mintInfo.supply)).to.equal(amount);
    expect(Number(ceaAccount.amount)).to.equal(amount);
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
    const pc20StateRent = BigInt(
      await provider.connection.getMinimumBalanceForRentExemption(62)
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent) +
      pc20StateRent;
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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

    const exportMint = getPc20MintPda(exportSourceAsset, gatewayProgram.programId);
    const exportState = getPc20StatePda(exportMint, gatewayProgram.programId);
    const exportCeaAuthority = getCeaAuthorityPda(
      exportPushAccount,
      gatewayProgram.programId
    );

    const preseedLamports =
      await provider.connection.getMinimumBalanceForRentExemption(0);

    await provider.sendAndConfirm(
      new anchor.web3.Transaction().add(
        SystemProgram.transfer({
          fromPubkey: relayer.publicKey,
          toPubkey: exportMint,
          lamports: preseedLamports,
        })
      ),
      [relayer]
    );

    const ceaAta = await getCeaAta(
      exportPushAccount,
      exportMint,
      gatewayProgram.programId
    );

    await pc20ExportViaFinalizeUniversalTx(
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
        recipientAta: null,
        ceaAuthority: exportCeaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: exportState, isWritable: true, isSigner: false },
        { pubkey: exportMint, isWritable: true, isSigner: false },
      ])
      .signers([relayer])
      .rpc();

    const mintInfo = await getMint(provider.connection, exportMint);
    const ceaAccount = await getAccount(provider.connection, ceaAta);
    expect(mintInfo.decimals).to.equal(exportDecimals);
    expect(Number(mintInfo.supply)).to.equal(amount);
    expect(Number(ceaAccount.amount)).to.equal(amount);
  });

  it("ignores later metadata drift after the canonical wrapped mint exists", async () => {
    const subTxId = generate32Bytes();
    const universalTxId = generateUniversalTxId();
    const amount = 1_000_000;
    const ceaAta = await getCeaAta(
      pushAccount,
      wrappedMint,
      gatewayProgram.programId
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(await provider.connection.getMinimumBalanceForRentExemption(8));
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;
    const mismatchedName = `${name} v2`;
    const mismatchedDecimals = decimals + 1;
    const before = Number((await getAccount(provider.connection, ceaAta)).amount);
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

    await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
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
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts(pc20ExportRemaining(null))
      .signers([relayer])
      .rpc();

    const ceaAfter = Number((await getAccount(provider.connection, ceaAta)).amount);
    const mintAfter = await getMint(provider.connection, wrappedMint);
    expect(ceaAfter).to.equal(before + amount);
    expect(Number(mintAfter.supply)).to.equal(supplyBefore + amount);
    expect(mintAfter.decimals).to.equal(decimals);
  });

  it("replay-protects PC20 export via finalize_universal_tx by sub_tx_id", async () => {
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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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

    await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
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
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts(pc20ExportRemaining(recipientAta))
      .signers([relayer])
      .rpc();

    await expectRejected(
      pc20ExportViaFinalizeUniversalTx(
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
          recipient: directRecipient.publicKey,
          recipientAta: null,
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
          vaultAta: null,
          mint: null,
          rateLimitConfig: null,
          tokenRateLimit: null,
          storedIxData: null,
          storeRefundRecipient: null,
        })
        .remainingAccounts(pc20ExportRemaining(recipientAta))
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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;

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
      pc20ExportViaFinalizeUniversalTx(
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
          recipient: directRecipient.publicKey,
          recipientAta: null,
          ceaAuthority,
          ceaAta,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: counterProgram.programId,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          vaultAta: null,
          mint: null,
          rateLimitConfig: null,
          tokenRateLimit: null,
          storedIxData: null,
          storeRefundRecipient: null,
        })
        .remainingAccounts([
          { pubkey: pc20State, isWritable: true, isSigner: false },
          { pubkey: wrappedMint, isWritable: true, isSigner: false },
          ...failingIx.keys.map((key) => ({
            pubkey: key.pubkey,
            isWritable: key.isWritable,
            isSigner: false,
          })),
        ])
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
      sendPc20Tx({
        subTxId: zeroAmountSubTxId,
        amount: 0,
        recipient: generate20Bytes(),
        payload: Buffer.from("payload"),
        revertRecipient: revertRecipient.publicKey,
        userAta: recipientAta,
      }),
      "InvalidAmount"
    );

    await expectError(
      sendPc20Tx({
        subTxId: zeroRecipientSubTxId,
        amount: 1,
        recipient: new Array(20).fill(0),
        payload: Buffer.from([]),
        revertRecipient: revertRecipient.publicKey,
        userAta: recipientAta,
      }),
      "InvalidRecipient"
    );

    await expectError(
      sendPc20Tx({
        subTxId: zeroRevertRecipientSubTxId,
        amount: 1,
        recipient: generate20Bytes(),
        payload: Buffer.from([]),
        revertRecipient: PublicKey.default,
        userAta: recipientAta,
      }),
      "InvalidRecipient"
    );
  });

  it("keeps direct PC20 burns event-only without SVM-only sub_tx_id replay state", async () => {
    const burnSubTxId = generate32Bytes();
    const burnAmount = 1_000_000;
    await mintWrappedPc20ToUser(burnAmount * 2);
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

    const firstTxSig = await sendPc20Tx({
      subTxId: burnSubTxId,
      amount: burnAmount,
      recipient: generate20Bytes(),
      payload: Buffer.from([]),
      revertRecipient: revertRecipient.publicKey,
      userAta: recipientAta,
    });

    await sendPc20Tx({
      subTxId: burnSubTxId,
      amount: burnAmount,
      recipient: generate20Bytes(),
      payload: Buffer.from([]),
      revertRecipient: revertRecipient.publicKey,
      userAta: recipientAta,
    });

    const afterBalance = Number(
      (await getAccount(provider.connection, recipientAta)).amount
    );
    expect(afterBalance).to.equal(beforeBalance - burnAmount * 2);

    const events = await decodeEvents(provider, gatewayProgram, firstTxSig);
    const burnEvent = events.find((event) => event.name === "universalTx");
    expect(burnEvent!.data.txType.fundsAndPayload !== undefined).to.equal(true);
    expect(Buffer.from(burnEvent!.data.payload)).to.deep.equal(
      encodePc20EventPayload(Buffer.from([]))
    );
  });

  it("rejects finalize-routed CEA PC20 burns with a mismatched mint account", async () => {
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
    const finalizeGasFee =
      finalizeGasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;
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

    await pc20ExportViaFinalizeUniversalTx(
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
        recipient: directRecipient.publicKey,
        recipientAta: null,
        ceaAuthority,
        ceaAta,
        tssPda,
        executedSubTx: getExecutedTxPda(mintSubTxId, gatewayProgram.programId),
        destinationProgram: SystemProgram.programId,
        systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        vaultAta: null,
        mint: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        storedIxData: null,
        storeRefundRecipient: null,
      })
      .remainingAccounts([
        { pubkey: pc20State, isWritable: true, isSigner: false },
        { pubkey: wrappedMint, isWritable: true, isSigner: false },
        ...noopReceiveIx.keys.map((key) => ({
          pubkey: key.pubkey,
          isWritable: key.isWritable,
          isSigner: false,
        })),
      ])
      .signers([relayer])
      .rpc();

    const pushPayload = Buffer.from("bad-cea-burn", "utf8");
    const burnUniversalTxId = generateUniversalTxId();
    const burnIxData = Buffer.from(
      gatewayProgram.coder.instruction.encode("sendUniversalTx", {
        req: {
          recipient: Array.from(pushAccount),
          token: wrappedMint,
          amount: new anchor.BN(amount),
          payload: pushPayload,
          revertRecipient: revertRecipient.publicKey,
          signatureData: Buffer.from(burnSubTxId),
        },
        nativeAmount: new anchor.BN(0),
      })
    );
    const badBurnAccounts = [
      { pubkey: pc20State, isWritable: false },
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
      "InvalidMint"
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
      { pubkey: pc20State, isWritable: false },
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
          accounts[2] = { pubkey: directRecipientAta, isWritable: true };
          return accounts;
        })(),
        expectedError: "InvalidAccount",
      },
      {
        label: "wrong token program",
        subTxId: wrongTokenProgramSubTxId,
        accounts: (() => {
          const accounts = makeCanonicalAccounts();
          accounts[3] = { pubkey: SystemProgram.programId, isWritable: false };
          return accounts;
        })(),
        expectedError: "InvalidAccount",
      },
      {
        label: "missing token program",
        subTxId: missingTokenProgramSubTxId,
        accounts: (() => {
          return makeCanonicalAccounts().slice(0, 3);
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
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE + COMPUTE_BUFFER;
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
        sendPc20Tx({
          subTxId: burnSubTxId,
          amount: 1,
          recipient: generate20Bytes(),
          payload: Buffer.from([]),
          revertRecipient: revertRecipient.publicKey,
          userAta: recipientAta,
        }),
        "Paused"
      );

      await expectError(
        pc20ExportViaFinalizeUniversalTx(
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
            recipient: directRecipient.publicKey,
            recipientAta: null,
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
            vaultAta: null,
            mint: null,
            rateLimitConfig: null,
            tokenRateLimit: null,
            storedIxData: null,
            storeRefundRecipient: null,
          })
          .remainingAccounts(pc20ExportRemaining(recipientAta))
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
    const pc20StateRent = BigInt(
      await provider.connection.getMinimumBalanceForRentExemption(62)
    );
    const gasUsed =
      SIGNATURE_FEE_LAMPORTS +
      BigInt(executedTxRent) +
      BigInt(mintRent) +
      BigInt(ataRent) +
      pc20StateRent;
    const gasFee = gasUsed + REF_FINALIZE_STORE_UPLOAD_FEE - BigInt(1);

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

    const badMint = getPc20MintPda(badSourceAsset, gatewayProgram.programId);
    const badState = getPc20StatePda(badMint, gatewayProgram.programId);
    const badCeaAuthority = getCeaAuthorityPda(
      badPushAccount,
      gatewayProgram.programId
    );

    const ceaAta = await getCeaAta(
      badPushAccount,
      badMint,
      gatewayProgram.programId
    );

    await expectError(
      pc20ExportViaFinalizeUniversalTx(
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
          recipientAta: null,
          ceaAuthority: badCeaAuthority,
          ceaAta,
          tssPda,
          executedSubTx: getExecutedTxPda(subTxId, gatewayProgram.programId),
          destinationProgram: SystemProgram.programId,
          systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          vaultAta: null,
          mint: null,
          rateLimitConfig: null,
          tokenRateLimit: null,
          storedIxData: null,
          storeRefundRecipient: null,
        })
        .remainingAccounts([
          { pubkey: badState, isWritable: true, isSigner: false },
          { pubkey: badMint, isWritable: true, isSigner: false },
        ])
        .signers([relayer])
        .rpc(),
      "InsufficientGasBudget"
    );
  });
});
