// Load environment variables FIRST before any other imports that might use them
import * as dotenv from "dotenv";
dotenv.config({ path: "../.env" });
dotenv.config();
import { createHash } from "crypto";

import * as anchor from "@coral-xyz/anchor";
import {
  PublicKey,
  LAMPORTS_PER_SOL,
  Keypair,
  SystemProgram,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import * as spl from "@solana/spl-token";
import pkg from "js-sha3";
const { keccak_256 } = pkg;
import * as secp from "@noble/secp256k1";
import { assert } from "chai";
import {
  instructionToPayloadFields,
  encodeExecutePayload,
  decodeExecutePayload,
  accountsToWritableFlags,
} from "./execute-payload";
import {
  signTssMessage,
  buildExecuteAdditionalData,
  buildRevertAdditionalData,
  buildWithdrawAdditionalData,
  TssInstruction,
  generateUniversalTxId,
  DEFAULT_DEADLINE,
} from "../tests/helpers/tss";

const KNOWN_PROGRAMS: Record<string, string> = {
  main:  "CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS",
  dummy: "DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp",
};

const programArg = process.argv[2]; // "main", "dummy", or undefined
if (programArg && !(programArg in KNOWN_PROGRAMS)) {
  throw new Error(`Unknown program label "${programArg}". Use "main" or "dummy".`);
}

const programIdStr =
  (programArg && KNOWN_PROGRAMS[programArg]) ??
  KNOWN_PROGRAMS["dummy"];

const PROGRAM_ID = new PublicKey(
  programIdStr
);
const UPGRADEABLE_LOADER_PROGRAM_ID = new PublicKey(
  "BPFLoaderUpgradeab1e11111111111111111111111"
);
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const EXECUTED_SUB_TX_SEED = "executed_sub_tx";
const PRICE_ACCOUNT = new PublicKey(
  "7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE"
); // Pyth SOL/USD price feed

// Resolve ALT address from universal-alt.json based on the active program ID.
function resolveAltAddress(): PublicKey {
  const altFile = "./universal-alt.json";
  if (!fs.existsSync(altFile)) {
    throw new Error(`${altFile} not found — run create-universal-alt.ts first`);
  }
  const data = JSON.parse(fs.readFileSync(altFile, "utf8"));
  const label = Object.entries(KNOWN_PROGRAMS).find(
    ([, id]) => id === PROGRAM_ID.toBase58()
  )?.[0];
  const entry = label ? data[label] : undefined;
  if (!entry?.altAddress) {
    throw new Error(
      `No ALT entry found for program ${PROGRAM_ID.toBase58()} (label: ${label ?? "unknown"}) in ${altFile}. ` +
      `Run: npx ts-node app/create-universal-alt.ts ${label ?? ""}`
    );
  }
  console.log(`ALT: ${entry.altAddress} (${label})`);
  return new PublicKey(entry.altAddress);
}

const ALT_ADDRESS = resolveAltAddress();

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
  Uint8Array.from(
    JSON.parse(fs.readFileSync("./clean-user-keypair.json", "utf8"))
  )
);
// Load relayer keypair (user will fund it externally)
const relayerKeypair = loadOrCreateKeypair("./fresh-relayer-keypair.json");

// Set up connection and provider
const connection = new anchor.web3.Connection(
  "https://api.devnet.solana.com",
  "confirmed"
);
const adminProvider = new anchor.AnchorProvider(
  connection,
  new anchor.Wallet(adminKeypair),
  {
    commitment: "confirmed",
  }
);
const userProvider = new anchor.AnchorProvider(
  connection,
  new anchor.Wallet(userKeypair),
  {
    commitment: "confirmed",
  }
);

anchor.setProvider(adminProvider);

function loadOrCreateKeypair(filepath: string): Keypair {
  if (fs.existsSync(filepath)) {
    return Keypair.fromSecretKey(
      Uint8Array.from(JSON.parse(fs.readFileSync(filepath, "utf8")))
    );
  }
  const kp = Keypair.generate();
  fs.writeFileSync(filepath, JSON.stringify(Array.from(kp.secretKey)));
  return kp;
}

function getExecutedTxPda(txIdBytes: Uint8Array): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from(EXECUTED_SUB_TX_SEED), Buffer.from(txIdBytes)],
    PROGRAM_ID
  )[0];
}

function getCeaAuthorityPda(pushAccount: Uint8Array | number[]): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("push_identity"), Buffer.from(pushAccount)],
    PROGRAM_ID
  )[0];
}

function getStoredIxDataPda(
  subTxId: Uint8Array | number[],
  ixDataHash: Uint8Array | Buffer
): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("stored_ix_data"), Buffer.from(subTxId), Buffer.from(ixDataHash)],
    PROGRAM_ID
  )[0];
}

async function getCeaAta(
  pushAccount: Uint8Array | number[],
  mint: PublicKey
): Promise<PublicKey> {
  const ceaAuthority = getCeaAuthorityPda(pushAccount);
  return spl.getAssociatedTokenAddressSync(
    mint,
    ceaAuthority,
    true,
    spl.TOKEN_PROGRAM_ID,
    spl.ASSOCIATED_TOKEN_PROGRAM_ID
  );
}

// Fee calculation helpers (matching execute.test.ts / test-utils.ts)
const COMPUTE_BUFFER = BigInt(100_000); // 0.0001 SOL buffer for compute + tx fees
const SIGNATURE_FEE_LAMPORTS = BigInt(5_000); // Base Solana fee per signature — matches execute.rs

const getExecutedTxRent = async (
  connection: anchor.web3.Connection
): Promise<number> => {
  const rent = await connection.getMinimumBalanceForRentExemption(8);
  return rent;
};

const getTokenAccountRent = async (
  connection: anchor.web3.Connection
): Promise<number> => {
  const rent = await connection.getMinimumBalanceForRentExemption(165);
  return rent;
};

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
 * gasFee  = executed_sub_tx_rent + COMPUTE_BUFFER (COMPUTE_BUFFER - SIGNATURE_FEE = gas_to_refund)
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
 * gasFee  = executed_sub_tx_rent + cea_ata_rent + COMPUTE_BUFFER
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

// Load IDL and bind it to the explicit runtime target. The local IDL is baked
// from the current build, but this script supports selecting the destination
// program at runtime.
const idl = JSON.parse(
  fs.readFileSync("./target/idl/universal_gateway.json", "utf8")
);
idl.address = PROGRAM_ID.toBase58();
const program = new Program(idl, adminProvider);
const userProgram = new Program(idl, userProvider);

// Create relayer provider for execute transactions (to avoid admin being fee payer when it's also in remainingAccounts)
const relayerWallet = new anchor.Wallet(relayerKeypair);
const relayerProvider = new anchor.AnchorProvider(
  connection,
  relayerWallet,
  {}
);
const relayerProgram = new Program(idl, relayerProvider);

const counterIdl = JSON.parse(
  fs.readFileSync("./target/idl/test_counter.json", "utf8")
);
const counterProgram: any = new Program(counterIdl as any, adminProvider);

// Helper: Get dynamic gas amount based on current SOL price
async function getDynamicGasAmount(
  targetUsd: number,
  fallbackSol: number = 0.02
): Promise<anchor.BN> {
  try {
    const solPriceResult = await program.methods
      .getSolPrice()
      .accountsPartial({
        priceUpdate: PRICE_ACCOUNT,
      })
      .view();

    const solPriceUsd = solPriceResult.price / Math.pow(10, 8); // Pyth uses 8 decimals
    const gasAmountSol = targetUsd / solPriceUsd;
    const gasAmountLamports = Math.floor(gasAmountSol * LAMPORTS_PER_SOL);

    console.log(
      `💰 SOL price: $${solPriceUsd.toFixed(
        2
      )} | ⛽ Gas: ${gasAmountSol.toFixed(4)} SOL (~$${targetUsd})`
    );

    return new anchor.BN(gasAmountLamports);
  } catch (error) {
    console.log(
      `⚠️ Could not fetch SOL price, using fallback: ${fallbackSol} SOL`
    );
    return new anchor.BN(fallbackSol * LAMPORTS_PER_SOL);
  }
}

// Helper: parse and print emit_cpi events from a transaction's inner instructions.
// emit_cpi encodes the event as a self-CPI to the program's event_authority PDA;
// the encoded bytes live in the inner-instruction data (not in program logs).
// Layout: [EVENT_IX_TAG_LE: 8 bytes] || [event_discriminator: 8 bytes] || [borsh(event)].
async function parseAndPrintEvents(txSignature: string, label: string) {
  try {
    const tx = await connection.getTransaction(txSignature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (!tx?.meta) {
      console.log(`${label}: No tx metadata found`);
      return;
    }
    const accountKeys = tx.transaction.message
      .getAccountKeys({ accountKeysFromLookups: tx.meta.loadedAddresses })
      .keySegments()
      .flat();
    const programIdx = accountKeys.findIndex((k) => k.equals(PROGRAM_ID));
    if (programIdx === -1) {
      console.log(`${label}: gateway program not in tx account keys`);
      return;
    }
    const eventBufs: Buffer[] = [];
    for (const inner of tx.meta.innerInstructions ?? []) {
      for (const ix of inner.instructions) {
        if (ix.programIdIndex !== programIdx) continue;
        const raw = Buffer.from(anchor.utils.bytes.bs58.decode(ix.data));
        if (raw.length < 16) continue; // 8-byte tag + 8-byte event disc
        eventBufs.push(raw.slice(8));
      }
    }
    if (eventBufs.length === 0) {
      console.log(`${label}: No emit_cpi events found`);
      return;
    }
    console.log(`${label}: Found ${eventBufs.length} event(s)`);
    eventBufs.forEach((buf, idx) => {
      const disc = buf.slice(0, 8).toString("hex");
      const data = buf.slice(8);
      console.log(`  [${idx}] discriminator=${disc} data_len=${data.length}`);
    });
  } catch (e: any) {
    console.log(`${label}: Error parsing events: ${e.message}`);
  }
}

// Helper function to load token info from tokens folder
function loadTokenInfo(tokenSymbol: string): any {
  const filename = `./tokens/${tokenSymbol.toLowerCase()}-token.json`;

  if (!fs.existsSync(filename)) {
    throw new Error(
      `Token file not found: ${filename}. Please create the token first.`
    );
  }

  return JSON.parse(fs.readFileSync(filename, "utf8"));
}

async function run() {
  console.log("=== GATEWAY PROGRAM COMPREHENSIVE TEST ===\n");

  const tssPrivKeyHex = (
    process.env.TSS_PRIVKEY ||
    process.env.ETH_PRIVATE_KEY ||
    process.env.PRIVATE_KEY ||
    ""
  ).replace(/^0x/, "");
  if (!tssPrivKeyHex) {
    throw new Error(
      "Missing TSS_PRIVKEY / ETH_PRIVATE_KEY / PRIVATE_KEY env var for execute tests"
    );
  }

  // Derive PDAs
  const [configPda] = PublicKey.findProgramAddressSync(
    [Buffer.from(CONFIG_SEED)],
    PROGRAM_ID
  );
  const [vaultPda] = PublicKey.findProgramAddressSync(
    [Buffer.from(VAULT_SEED)],
    PROGRAM_ID
  );
  const [feeVaultPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("fee_vault")],
    PROGRAM_ID
  );
  const [tssPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("final_tss_pda")],
    PROGRAM_ID
  );
  const [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("rate_limit_config")],
    PROGRAM_ID
  );

  const admin = adminKeypair.publicKey;
  const user = userKeypair.publicKey;
  const relayer = relayerKeypair.publicKey;

  // Helper to get token rate limit PDA
  const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit"), tokenMint.toBuffer()],
      PROGRAM_ID
    );
    return pda;
  };

  // Helper to create payload
  const createPayload = (
    to: number,
    vType: any = { signedVerification: {} }
  ) => ({
    to: Array.from(Buffer.alloc(20, to)),
    value: new anchor.BN(0),
    data: Buffer.from([]),
    gasLimit: new anchor.BN(21000),
    maxFeePerGas: new anchor.BN(20000000000),
    maxPriorityFeePerGas: new anchor.BN(1000000000),
    nonce: new anchor.BN(0),
    deadline: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
    vType,
  });

  // Helper to serialize payload to bytes using Borsh (matching Rust's try_to_vec)
  // UniversalPayload structure: to: [u8; 20], value: u64, data: Vec<u8>, gasLimit: u64,
  // maxFeePerGas: u64, maxPriorityFeePerGas: u64, nonce: u64, deadline: i64, vType: VerificationType
  const serializePayload = (payload: any): Buffer => {
    // Helper to write u64 (little-endian)
    const writeU64 = (val: anchor.BN): Buffer => {
      const b = Buffer.alloc(8);
      b.writeBigUInt64LE(BigInt(val.toString()), 0);
      return b;
    };

    // Helper to write i64 (little-endian)
    const writeI64 = (val: anchor.BN): Buffer => {
      const b = Buffer.alloc(8);
      b.writeBigInt64LE(BigInt(val.toString()), 0);
      return b;
    };

    // Helper to write Vec<u8> (length as u32 LE, then bytes)
    const writeVecU8 = (val: Buffer | number[]): Buffer => {
      const bytes = Buffer.isBuffer(val) ? val : Buffer.from(val);
      const len = Buffer.alloc(4);
      len.writeUInt32LE(bytes.length, 0);
      return Buffer.concat([len, bytes]);
    };

    // Helper to write u8
    const writeU8 = (val: number): Buffer => {
      return Buffer.from([val]);
    };

    // Serialize UniversalPayload in Borsh format:
    // 1. to: [u8; 20] - 20 bytes
    const toBytes = Buffer.from(payload.to);
    // 2. value: u64 - 8 bytes
    const valueBytes = writeU64(payload.value);
    // 3. data: Vec<u8> - 4 bytes (length) + data
    const dataBytes = writeVecU8(payload.data);
    // 4. gasLimit: u64 - 8 bytes
    const gasLimitBytes = writeU64(payload.gasLimit);
    // 5. maxFeePerGas: u64 - 8 bytes
    const maxFeePerGasBytes = writeU64(payload.maxFeePerGas);
    // 6. maxPriorityFeePerGas: u64 - 8 bytes
    const maxPriorityFeePerGasBytes = writeU64(payload.maxPriorityFeePerGas);
    // 7. nonce: u64 - 8 bytes
    const nonceBytes = writeU64(payload.nonce);
    // 8. deadline: i64 - 8 bytes
    const deadlineBytes = writeI64(payload.deadline);
    // 9. vType: VerificationType enum - 1 byte (0 = SignedVerification, 1 = UniversalTxVerification)
    const vTypeVal = payload.vType.signedVerification !== undefined ? 0 : 1;
    const vTypeBytes = writeU8(vTypeVal);

    return Buffer.concat([
      toBytes,
      valueBytes,
      dataBytes,
      gasLimitBytes,
      maxFeePerGasBytes,
      maxPriorityFeePerGasBytes,
      nonceBytes,
      deadlineBytes,
      vTypeBytes,
    ]);
  };


  console.log(`Program ID: ${PROGRAM_ID.toString()}`);
  console.log(`Admin: ${admin.toString()}`);
  console.log(`User: ${user.toString()}`);
  console.log(`Config PDA: ${configPda.toString()}`);
  console.log(`Vault PDA: ${vaultPda.toString()}\n`);
  console.log(`Fee Vault PDA: ${feeVaultPda.toString()}\n`);

  // Step 1: Initialize Gateway
  console.log("1. Initializing Gateway...");
  const configAccount = await connection.getAccountInfo(configPda);
  if (!configAccount) {
    const [programData] = PublicKey.findProgramAddressSync(
      [program.programId.toBuffer()],
      UPGRADEABLE_LOADER_PROGRAM_ID
    );
    const tx = await program.methods
      .initialize(
        admin, // admin
        admin, // pauser
        admin, // operator (using admin for simplicity)
        new anchor.BN(100_000_000), // min_cap_usd ($1 with 8 decimals = 1e8)
        new anchor.BN(1_000_000_000), // max_cap_usd ($10 with 8 decimals = 10e8)
        new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE") // pyth_price_feed (SOL/USD feed ID)
      )
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        program: program.programId,
        programData,
        admin: admin,
        systemProgram: SystemProgram.programId,
      })
      .signers([adminKeypair])
      .rpc();
    console.log(`Gateway initialized: ${tx}\n`);
  } else {
    console.log("Gateway already initialized\n");
  }

  // Step 1.5: Initialize Rate Limit Config and Token Rate Limits
  console.log("1.5. Setting up Rate Limits...");
  const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // Effectively unlimited

  // Initialize rate limit config by calling setBlockUsdCap (uses init_if_needed)
  try {
    await (program.account as any).rateLimitConfig.fetch(rateLimitConfigPda);
    console.log("Rate limit config already initialized");
  } catch {
    // Initialize by setting block USD cap to 0 (disabled, but creates the account)
    await program.methods
      .setBlockUsdCap(new anchor.BN(0))
      .accountsPartial({
        admin: admin,
        config: configPda,
        rateLimitConfig: rateLimitConfigPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([adminKeypair])
      .rpc();
    console.log("✅ Rate limit config initialized");
  }

  // Initialize native SOL rate limit
  const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
  try {
    await (program.account as any).tokenRateLimit.fetch(
      nativeSolTokenRateLimitPda
    );
    console.log("Native SOL rate limit already initialized");
  } catch {
    await program.methods
      .setTokenRateLimit(veryLargeThreshold, false, false)
      .accountsPartial({
        admin: admin,
        config: configPda,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenMint: PublicKey.default,
        systemProgram: SystemProgram.programId,
      })
      .signers([adminKeypair])
      .rpc();
    console.log("✅ Native SOL rate limit initialized");
  }

  // Step 2: Test Admin Functions
  console.log("2. Testing Admin Functions...");

  // Check current caps
  try {
    const configData = await (program.account as any).config.fetch(configPda);
    const minCap = configData.minCapUniversalTxUsd
      ? configData.minCapUniversalTxUsd.toString()
      : "N/A";
    const maxCap = configData.maxCapUniversalTxUsd
      ? configData.maxCapUniversalTxUsd.toString()
      : "N/A";
    console.log(`Current caps - Min: ${minCap}, Max: ${maxCap}`);
  } catch (error) {
    console.log("Could not fetch config data, skipping caps display");
  }

  // Update caps
  const newMinCap = new anchor.BN(100_000_000); // $1 with 8 decimals = 1e8
  const newMaxCap = new anchor.BN(1_000_000_000); // $10 with 8 decimals = 10e8
  const capsTx = await program.methods
    .setCapsUsd(newMinCap, newMaxCap)
    .accountsPartial({
      config: configPda,
      admin: admin,
    })
    .rpc();
  console.log(`✅ Caps updated: ${capsTx}`);

  // Verify caps update
  try {
    const updatedConfigData = await (program.account as any).config.fetch(
      configPda
    );
    const minCap = updatedConfigData.minCapUniversalTxUsd
      ? updatedConfigData.minCapUniversalTxUsd.toString()
      : "N/A";
    const maxCap = updatedConfigData.maxCapUniversalTxUsd
      ? updatedConfigData.maxCapUniversalTxUsd.toString()
      : "N/A";
    console.log(`📊 Updated caps - Min: ${minCap}, Max: ${maxCap}\n`);
  } catch (error) {
    console.log("📊 Could not fetch updated config data\n");
  }

  // Step 3: Use existing SPL Token from tokens folder
  console.log("3. Setting up SPL Token...");

  // Load existing token from tokens folder
  let mint: PublicKey;
  let tokenAccount: PublicKey;
  let tokenInfo: any;

  // Try to load USDT token first, fallback to USDC if not available
  const tokenFiles = [
    "usdt-token.json",
    "official-usdc-token.json",
    "dai-token.json",
    "pepe-token.json",
  ];
  let tokenLoaded = false;

  for (const tokenFile of tokenFiles) {
    try {
      const tokenPath = `./tokens/${tokenFile}`;
      tokenInfo = JSON.parse(fs.readFileSync(tokenPath, "utf8"));
      mint = new PublicKey(tokenInfo.mint);

      // Get or create token account for this mint
      const tokenAccountInfo = await spl.getOrCreateAssociatedTokenAccount(
        userProvider.connection as any,
        userKeypair,
        mint,
        userKeypair.publicKey
      );
      tokenAccount = tokenAccountInfo.address;

      console.log(`✅ Using existing SPL Token from tokens folder:`);
      console.log(`   Name: ${tokenInfo.name}`);
      console.log(`   Symbol: ${tokenInfo.symbol}`);
      console.log(`   Mint: ${mint.toString()}`);
      console.log(`   Decimals: ${tokenInfo.decimals}`);
      console.log(`   Token Account: ${tokenAccount.toString()}\n`);
      tokenLoaded = true;
      break;
    } catch (error) {
      console.log(`Could not load ${tokenFile}, trying next...`);
      continue;
    }
  }

  if (!tokenLoaded) {
    throw new Error(
      "No valid tokens found in tokens folder. Please create tokens first using the token CLI."
    );
  }

  // Create vault ATA early if token is loaded (used in multiple places)
  let vaultAta: spl.Account | null = null;
  if (tokenLoaded) {
    vaultAta = await spl.getOrCreateAssociatedTokenAccount(
      adminProvider.connection as any,
      adminKeypair,
      mint,
      vaultPda,
      true
    );
  }

  // Initialize SPL token rate limit if needed
  if (tokenLoaded) {
    const splTokenRateLimitPda = getTokenRateLimitPda(mint);
    try {
      await (program.account as any).tokenRateLimit.fetch(splTokenRateLimitPda);
      console.log("SPL token rate limit already initialized");
    } catch {
      await program.methods
        .setTokenRateLimit(veryLargeThreshold, true, true)
        .accountsPartial({
          admin: admin,
          config: configPda,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: splTokenRateLimitPda,
          tokenMint: mint,
          systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair])
        .rpc();
      console.log("✅ SPL token rate limit initialized");
    }
  }

  // =========================
  // NEW: sendUniversalTx Tests
  // =========================
  console.log(
    "\n=== 4.5. Testing sendUniversalTx (New Universal Entrypoint) ===\n"
  );

  // Test 4.5.1: GAS Route (TxType.GAS)
  console.log("4.5.1. Testing GAS Route (TxType.GAS)...");
  const universalGasAmount = await getDynamicGasAmount(2.5, 0.01);
  const initialVaultBalanceGas = await connection.getBalance(vaultPda);

  const gasReq = {
    recipient: Array.from(Buffer.alloc(20, 0)),
    token: PublicKey.default,
    amount: new anchor.BN(0),
    payload: Buffer.from([]),
    revertRecipient: user,
    signatureData: Buffer.from("gas_sig"),
  };

  const gasUniversalTx = await userProgram.methods
    .sendUniversalTx(gasReq, universalGasAmount)
    .accountsPartial({
      config: configPda,
      vault: vaultPda,
      feeVault: feeVaultPda,
      userTokenAccount: null,
      gatewayTokenAccount: null,
      user: user,
      priceUpdate: PRICE_ACCOUNT,
      rateLimitConfig: rateLimitConfigPda,
      tokenRateLimit: nativeSolTokenRateLimitPda,
      tokenProgram: spl.TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .signers([userKeypair])
    .rpc();

  console.log(`✅ GAS route transaction: ${gasUniversalTx}`);
  await parseAndPrintEvents(gasUniversalTx, "GAS route events");
  const finalVaultBalanceGas = await connection.getBalance(vaultPda);
  const balanceIncrease = finalVaultBalanceGas - initialVaultBalanceGas;
  assert.equal(
    balanceIncrease,
    universalGasAmount.toNumber(),
    "Vault should receive exact gas amount"
  );
  console.log(
    `💰 Vault balance increased by: ${
      balanceIncrease / LAMPORTS_PER_SOL
    } SOL (verified)\n`
  );

  // Test 4.5.2: GAS_AND_PAYLOAD Route
  console.log("4.5.2. Testing GAS_AND_PAYLOAD Route...");
  const universalGasPayloadAmount = await getDynamicGasAmount(2.5, 0.01);
  const gasPayloadReq = {
    recipient: Array.from(Buffer.alloc(20, 0)),
    token: PublicKey.default,
    amount: new anchor.BN(0),
    payload: serializePayload(createPayload(1)),
    revertRecipient: user,
    signatureData: Buffer.from("gas_payload_sig"),
  };

  const initialVaultBalanceGasPayload = await connection.getBalance(vaultPda);
  const gasPayloadTx = await userProgram.methods
    .sendUniversalTx(gasPayloadReq, universalGasPayloadAmount)
    .accountsPartial({
      config: configPda,
      vault: vaultPda,
      feeVault: feeVaultPda,
      userTokenAccount: null,
      gatewayTokenAccount: null,
      user: user,
      priceUpdate: PRICE_ACCOUNT,
      rateLimitConfig: rateLimitConfigPda,
      tokenRateLimit: nativeSolTokenRateLimitPda,
      tokenProgram: spl.TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .signers([userKeypair])
    .rpc();

  console.log(`✅ GAS_AND_PAYLOAD route transaction: ${gasPayloadTx}`);
  await parseAndPrintEvents(gasPayloadTx, "GAS_AND_PAYLOAD route events");
  const finalVaultBalanceGasPayload = await connection.getBalance(vaultPda);
  const balanceIncreaseGasPayload =
    finalVaultBalanceGasPayload - initialVaultBalanceGasPayload;
  assert.equal(
    balanceIncreaseGasPayload,
    universalGasPayloadAmount.toNumber(),
    "Vault should receive exact gas amount"
  );
  console.log(
    `💰 Vault balance increased by: ${
      balanceIncreaseGasPayload / LAMPORTS_PER_SOL
    } SOL (verified)\n`
  );

  // Test 4.5.3: FUNDS Route (Native SOL)
  console.log("4.5.3. Testing FUNDS Route (Native SOL)...");
  const fundsAmount = new anchor.BN(0.005 * LAMPORTS_PER_SOL);
  const fundsRecipient = Array.from(
    Buffer.from("1111111111111111111111111111111111111111", "hex").subarray(
      0,
      20
    )
  );
  const initialVaultBalanceFunds = await connection.getBalance(vaultPda);

  const fundsReq = {
    recipient: fundsRecipient,
    token: PublicKey.default,
    amount: fundsAmount,
    payload: Buffer.from([]),
    revertRecipient: user,
    signatureData: Buffer.from("funds_sig"),
  };

  const fundsTx = await userProgram.methods
    .sendUniversalTx(fundsReq, fundsAmount) // native_amount == amount for native FUNDS
    .accountsPartial({
      config: configPda,
      vault: vaultPda,
      feeVault: feeVaultPda,
      userTokenAccount: null,
      gatewayTokenAccount: null,
      user: user,
      priceUpdate: PRICE_ACCOUNT,
      rateLimitConfig: rateLimitConfigPda,
      tokenRateLimit: nativeSolTokenRateLimitPda,
      tokenProgram: spl.TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .signers([userKeypair])
    .rpc();

  console.log(`✅ FUNDS route (native SOL) transaction: ${fundsTx}`);
  await parseAndPrintEvents(fundsTx, "FUNDS route events");
  const finalVaultBalanceFunds = await connection.getBalance(vaultPda);
  const balanceIncreaseFunds =
    finalVaultBalanceFunds - initialVaultBalanceFunds;
  assert.equal(
    balanceIncreaseFunds,
    fundsAmount.toNumber(),
    "Vault should receive exact funds amount"
  );
  console.log(
    `💰 Vault balance increased by: ${
      balanceIncreaseFunds / LAMPORTS_PER_SOL
    } SOL (verified)\n`
  );

  // Test 4.5.4: FUNDS Route (SPL Token) - if token is loaded
  if (tokenLoaded && vaultAta) {
    console.log("4.5.4. Testing FUNDS Route (SPL Token)...");
    // Vault ATA already created above

    const splFundsAmount = new anchor.BN(
      1000 * Math.pow(10, tokenInfo.decimals)
    );
    const splFundsRecipient = Array.from(
      Buffer.from("2222222222222222222222222222222222222222", "hex").subarray(
        0,
        20
      )
    );
    const userTokenBalanceBeforeSplFunds = (
      await spl.getAccount(userProvider.connection as any, tokenAccount)
    ).amount;
    const vaultTokenBalanceBeforeSplFunds = (
      await spl.getAccount(userProvider.connection as any, vaultAta.address)
    ).amount;

    const splFundsReq = {
      recipient: splFundsRecipient,
      token: mint,
      amount: splFundsAmount,
      payload: Buffer.from([]),
      revertRecipient: user,
      signatureData: Buffer.from("spl_funds_sig"),
    };

    const splTokenRateLimitPda = getTokenRateLimitPda(mint);
    const splFundsTx = await userProgram.methods
      .sendUniversalTx(splFundsReq, new anchor.BN(0)) // No native SOL for SPL funds
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: tokenAccount,
        gatewayTokenAccount: vaultAta.address,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: splTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([userKeypair])
      .rpc();

    console.log(`✅ FUNDS route (SPL token) transaction: ${splFundsTx}`);
    await parseAndPrintEvents(splFundsTx, "FUNDS route (SPL) events");
    const userTokenBalanceAfterSplFunds = (
      await spl.getAccount(userProvider.connection as any, tokenAccount)
    ).amount;
    const vaultTokenBalanceAfterSplFunds = (
      await spl.getAccount(userProvider.connection as any, vaultAta.address)
    ).amount;
    const userBalanceChange =
      Number(userTokenBalanceAfterSplFunds) -
      Number(userTokenBalanceBeforeSplFunds);
    const vaultBalanceChange =
      Number(vaultTokenBalanceAfterSplFunds) -
      Number(vaultTokenBalanceBeforeSplFunds);
    assert.equal(
      userBalanceChange,
      -splFundsAmount.toNumber(),
      "User should lose exact SPL amount"
    );
    assert.equal(
      vaultBalanceChange,
      splFundsAmount.toNumber(),
      "Vault should gain exact SPL amount"
    );
    console.log(
      `📊 User SPL balance: ${userTokenBalanceBeforeSplFunds.toString()} → ${userTokenBalanceAfterSplFunds.toString()} (verified)`
    );
    console.log(
      `📊 Vault SPL balance: ${vaultTokenBalanceBeforeSplFunds.toString()} → ${vaultTokenBalanceAfterSplFunds.toString()} (verified)\n`
    );
  }

  // Test 4.5.5: FUNDS_AND_PAYLOAD Route (Native SOL)
  console.log("4.5.5. Testing FUNDS_AND_PAYLOAD Route (Native SOL)...");
  const fundsPayloadBridgeAmount = new anchor.BN(0.01 * LAMPORTS_PER_SOL);
  const fundsPayloadGasAmount = await getDynamicGasAmount(1.5, 0.01);
  const totalNativeAmount = fundsPayloadBridgeAmount.add(fundsPayloadGasAmount);
  const fundsPayloadRecipient = Array.from(
    Buffer.from("3333333333333333333333333333333333333333", "hex").subarray(
      0,
      20
    )
  );

  const fundsPayloadReq = {
    recipient: fundsPayloadRecipient,
    token: PublicKey.default,
    amount: fundsPayloadBridgeAmount,
    payload: serializePayload(createPayload(2)),
    revertRecipient: user,
    signatureData: Buffer.from("funds_payload_sig"),
  };

  const initialVaultBalanceFundsPayload = await connection.getBalance(vaultPda);
  const fundsPayloadTx = await userProgram.methods
    .sendUniversalTx(fundsPayloadReq, totalNativeAmount) // native_amount = bridge + gas
    .accountsPartial({
      config: configPda,
      vault: vaultPda,
      feeVault: feeVaultPda,
      userTokenAccount: null,
      gatewayTokenAccount: null,
      user: user,
      priceUpdate: PRICE_ACCOUNT,
      rateLimitConfig: rateLimitConfigPda,
      tokenRateLimit: nativeSolTokenRateLimitPda,
      tokenProgram: spl.TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .signers([userKeypair])
    .rpc();

  console.log(
    `✅ FUNDS_AND_PAYLOAD route (native SOL) transaction: ${fundsPayloadTx}`
  );
  await parseAndPrintEvents(fundsPayloadTx, "FUNDS_AND_PAYLOAD route events");
  const finalVaultBalanceFundsPayload = await connection.getBalance(vaultPda);
  const balanceIncreaseFundsPayload =
    finalVaultBalanceFundsPayload - initialVaultBalanceFundsPayload;
  assert.equal(
    balanceIncreaseFundsPayload,
    totalNativeAmount.toNumber(),
    "Vault should receive bridge + gas amount"
  );
  console.log(
    `💰 Vault balance increased by: ${
      balanceIncreaseFundsPayload / LAMPORTS_PER_SOL
    } SOL (verified)\n`
  );

  // Test 4.5.6: FUNDS_AND_PAYLOAD Route (SPL Token) - if token is loaded
  if (tokenLoaded && vaultAta) {
    console.log("4.5.6. Testing FUNDS_AND_PAYLOAD Route (SPL Token)...");
    // Vault ATA already created above

    const splFundsPayloadBridgeAmount = new anchor.BN(
      500 * Math.pow(10, tokenInfo.decimals)
    );
    const splFundsPayloadGasAmount = await getDynamicGasAmount(1.5, 0.01);
    const splFundsPayloadRecipient = Array.from(
      Buffer.from("4444444444444444444444444444444444444444", "hex").subarray(
        0,
        20
      )
    );

    // Use a very large payload to intentionally stress Solana's 1232-byte tx limit
    // so we can observe the legacy (no ALT) transaction failing with "transaction too large".
    const largePayloadData = Buffer.alloc(600, 1); // 600 bytes of non-zero data
    const largePayloadStruct = {
      ...createPayload(3),
      data: largePayloadData,
    };

    const splFundsPayloadReq = {
      recipient: splFundsPayloadRecipient,
      token: mint,
      amount: splFundsPayloadBridgeAmount,
      payload: serializePayload(largePayloadStruct),
      revertRecipient: user,
      signatureData: Buffer.from("spl_funds_payload_sig"),
    };

    const initialVaultBalanceSplFundsPayload = await connection.getBalance(
      vaultPda
    );
    const userTokenBalanceBeforeSplFundsPayload = (
      await spl.getAccount(userProvider.connection as any, tokenAccount)
    ).amount;
    const vaultTokenBalanceBeforeSplFundsPayload = (
      await spl.getAccount(userProvider.connection as any, vaultAta.address)
    ).amount;
    const splTokenRateLimitPda = getTokenRateLimitPda(mint);

    // --- Legacy path (without ALT) would now fail with Transaction too large.
    // Instead, build a v0 tx using the ALT created by create-universal-alt.ts.
    const { value: alt } = await connection.getAddressLookupTable(ALT_ADDRESS);
    if (!alt) {
      throw new Error(
        `Lookup table ${ALT_ADDRESS.toBase58()} not found on chain`
      );
    }

    const ix = await userProgram.methods
      .sendUniversalTx(splFundsPayloadReq, splFundsPayloadGasAmount)
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: tokenAccount,
        gatewayTokenAccount: vaultAta.address,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: splTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .instruction();

    const recent = await connection.getLatestBlockhash();
    const message = new TransactionMessage({
      payerKey: user,
      recentBlockhash: recent.blockhash,
      instructions: [ix],
    }).compileToV0Message([alt]);

    const vtx = new VersionedTransaction(message);
    vtx.sign([userKeypair]);
    const vtxBytes = vtx.serialize().length;
    console.log(`  ALT v0 tx size: ${vtxBytes} bytes`);

    const splFundsPayloadTx = await connection.sendTransaction(vtx, {
      maxRetries: 3,
    });
    // Wait for confirmation so balances / events reflect this tx (sendTransaction alone is fire-and-forget).
    await connection.confirmTransaction(splFundsPayloadTx, "confirmed");

    console.log(
      `✅ FUNDS_AND_PAYLOAD route (SPL token, ALT v0) transaction: ${splFundsPayloadTx}`
    );
    await parseAndPrintEvents(
      splFundsPayloadTx,
      "FUNDS_AND_PAYLOAD route (SPL, ALT) events"
    );
    const finalVaultBalanceSplFundsPayload = await connection.getBalance(
      vaultPda
    );
    const userTokenBalanceAfterSplFundsPayload = (
      await spl.getAccount(userProvider.connection as any, tokenAccount)
    ).amount;
    const vaultTokenBalanceAfterSplFundsPayload = (
      await spl.getAccount(userProvider.connection as any, vaultAta.address)
    ).amount;
    const vaultSolIncrease =
      finalVaultBalanceSplFundsPayload - initialVaultBalanceSplFundsPayload;
    const userTokenChange =
      Number(userTokenBalanceAfterSplFundsPayload) -
      Number(userTokenBalanceBeforeSplFundsPayload);
    const vaultTokenChange =
      Number(vaultTokenBalanceAfterSplFundsPayload) -
      Number(vaultTokenBalanceBeforeSplFundsPayload);
    assert.equal(
      vaultSolIncrease,
      splFundsPayloadGasAmount.toNumber(),
      "Vault should receive exact gas amount"
    );
    assert.equal(
      userTokenChange,
      -splFundsPayloadBridgeAmount.toNumber(),
      "User should lose exact SPL bridge amount"
    );
    assert.equal(
      vaultTokenChange,
      splFundsPayloadBridgeAmount.toNumber(),
      "Vault should gain exact SPL bridge amount"
    );
    console.log(
      `💰 Vault SOL increased by: ${
        vaultSolIncrease / LAMPORTS_PER_SOL
      } SOL (verified)`
    );
    console.log(
      `📊 User SPL: ${userTokenBalanceBeforeSplFundsPayload.toString()} → ${userTokenBalanceAfterSplFundsPayload.toString()} (verified)`
    );
    console.log(
      `📊 Vault SPL: ${vaultTokenBalanceBeforeSplFundsPayload.toString()} → ${vaultTokenBalanceAfterSplFundsPayload.toString()} (verified)\n`
    );
  }

  // Test 4.5.7: Edge Cases and Negative Tests
  console.log("4.5.7. Testing Edge Cases and Negative Tests...");

  // Edge Case: Payload-only execution (GAS_AND_PAYLOAD with native_amount == 0)
  console.log(
    "  - Testing payload-only execution (GAS_AND_PAYLOAD with 0 gas)..."
  );
  const payloadOnlyReq = {
    recipient: Array.from(Buffer.alloc(20, 0)),
    token: PublicKey.default,
    amount: new anchor.BN(0),
    payload: serializePayload(createPayload(5)),
    revertRecipient: user,
    signatureData: Buffer.from("payload_only_sig"),
  };

  const initialVaultBalancePayloadOnly = await connection.getBalance(vaultPda);
  try {
    const payloadOnlyTx = await userProgram.methods
      .sendUniversalTx(payloadOnlyReq, new anchor.BN(0)) // 0 native amount
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: null,
        gatewayTokenAccount: null,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([userKeypair])
      .rpc();
    const finalVaultBalancePayloadOnly = await connection.getBalance(vaultPda);
    assert.equal(
      finalVaultBalancePayloadOnly,
      initialVaultBalancePayloadOnly,
      "Vault balance should not change for payload-only execution"
    );
    console.log(
      `  ✅ Payload-only execution succeeded: ${payloadOnlyTx} (no balance change verified)`
    );
  } catch (error: any) {
    console.log(`  ⚠️  Payload-only execution failed: ${error.message}`);
    throw error; // Re-throw to fail the script if this should succeed
  }

  // Negative Test: FUNDS native with mismatched amounts (should fail)
  console.log(
    "  - Testing negative case: FUNDS native with mismatched amounts (should fail)..."
  );
  const mismatchedFundsReq = {
    recipient: Array.from(
      Buffer.from("5555555555555555555555555555555555555555", "hex").subarray(
        0,
        20
      )
    ),
    token: PublicKey.default,
    amount: new anchor.BN(0.01 * LAMPORTS_PER_SOL),
    payload: Buffer.from([]),
    revertRecipient: user,
    signatureData: Buffer.from("mismatched_sig"),
  };

  try {
    await userProgram.methods
      .sendUniversalTx(
        mismatchedFundsReq,
        new anchor.BN(0.005 * LAMPORTS_PER_SOL)
      ) // Different amount
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: null,
        gatewayTokenAccount: null,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([userKeypair])
      .rpc();
    assert.fail("Should have rejected mismatched amounts");
  } catch (error: any) {
    const errorCode =
      error.error?.errorCode?.code || error.error?.errorCode || error.code;
    assert.equal(
      errorCode,
      "InvalidAmount",
      `Expected InvalidAmount but got: ${errorCode}`
    );
    console.log(
      `  ✅ Correctly rejected mismatched amounts with InvalidAmount error`
    );
  }

  // Negative Test: FUNDS SPL with native SOL provided (should fail)
  if (tokenLoaded && vaultAta) {
    console.log(
      "  - Testing negative case: FUNDS SPL with native SOL (should fail)..."
    );
    // Vault ATA already created above

    const invalidSplFundsReq = {
      recipient: Array.from(
        Buffer.from("6666666666666666666666666666666666666666", "hex").subarray(
          0,
          20
        )
      ),
      token: mint,
      amount: new anchor.BN(1000 * Math.pow(10, tokenInfo.decimals)),
      payload: Buffer.from([]),
      revertRecipient: user,
      signatureData: Buffer.from("invalid_spl_sig"),
    };

    try {
      await userProgram.methods
        .sendUniversalTx(
          invalidSplFundsReq,
          new anchor.BN(0.001 * LAMPORTS_PER_SOL)
        ) // Native SOL provided
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: tokenAccount,
          gatewayTokenAccount: vaultAta.address,
          user: user,
          priceUpdate: PRICE_ACCOUNT,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: getTokenRateLimitPda(mint),
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();
      assert.fail("Should have rejected SPL FUNDS with native SOL");
    } catch (error: any) {
      const errorCode =
        error.error?.errorCode?.code || error.error?.errorCode || error.code;
      assert.equal(
        errorCode,
        "InvalidAmount",
        `Expected InvalidAmount but got: ${errorCode}`
      );
      console.log(
        `  ✅ Correctly rejected SPL FUNDS with native SOL (InvalidAmount error)`
      );
    }
  }

  // Negative Test: Invalid revert recipient (should fail with InvalidRecipient)
  console.log(
    "  - Testing negative case: Invalid revert recipient (should fail)..."
  );
  const invalidRecipientReq = {
    recipient: Array.from(Buffer.alloc(20, 0)),
    token: PublicKey.default,
    amount: new anchor.BN(0),
    payload: Buffer.from([]),
    revertRecipient: PublicKey.default, // Invalid: default pubkey
    signatureData: Buffer.from("invalid_recipient_sig"),
  };

  try {
    await userProgram.methods
      .sendUniversalTx(
        invalidRecipientReq,
        await getDynamicGasAmount(2.5, 0.01)
      )
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: null,
        gatewayTokenAccount: null,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([userKeypair])
      .rpc();
    assert.fail("Should have rejected invalid revert recipient");
  } catch (error: any) {
    const errorCode =
      error.error?.errorCode?.code || error.error?.errorCode || error.code;
    assert.equal(
      errorCode,
      "InvalidRecipient",
      `Expected InvalidRecipient but got: ${errorCode}`
    );
    console.log(
      `  ✅ Correctly rejected invalid revert recipient (InvalidRecipient error)`
    );
  }

  // Negative Test: FUNDS with mismatched native amount (should fail with InvalidAmount)
  // NOTE: When payload is empty and amount > 0, fetchTxType routes to TxType::Funds (not FundsAndPayload)
  // The validation happens in fetchTxType before routing, so we get InvalidAmount, not InvalidInput
  console.log(
    "  - Testing negative case: FUNDS with mismatched native amount (should fail)..."
  );
  const mismatchedNativeReq = {
    recipient: Array.from(
      Buffer.from("7777777777777777777777777777777777777777", "hex").subarray(
        0,
        20
      )
    ),
    token: PublicKey.default,
    amount: new anchor.BN(0.01 * LAMPORTS_PER_SOL),
    payload: Buffer.from([]), // Empty payload routes to FUNDS, not FUNDS_AND_PAYLOAD
    revertRecipient: user,
    signatureData: Buffer.from("mismatched_native_sig"),
  };

  try {
    await userProgram.methods
      .sendUniversalTx(
        mismatchedNativeReq,
        new anchor.BN(0.02 * LAMPORTS_PER_SOL)
      ) // native != amount
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: null,
        gatewayTokenAccount: null,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([userKeypair])
      .rpc();
    assert.fail("Should have rejected FUNDS with mismatched native amount");
  } catch (error: any) {
    const errorCode =
      error.error?.errorCode?.code || error.error?.errorCode || error.code;
    assert.equal(
      errorCode,
      "InvalidAmount",
      `Expected InvalidAmount but got: ${errorCode}`
    );
    console.log(
      `  ✅ Correctly rejected FUNDS with mismatched native amount (InvalidAmount error)`
    );
  }

  // Negative Test: FUNDS_AND_PAYLOAD native with insufficient native amount (should fail)
  console.log(
    "  - Testing negative case: FUNDS_AND_PAYLOAD native with insufficient amount (should fail)..."
  );
  const insufficientNativeReq = {
    recipient: Array.from(
      Buffer.from("8888888888888888888888888888888888888888", "hex").subarray(
        0,
        20
      )
    ),
    token: PublicKey.default,
    amount: new anchor.BN(0.01 * LAMPORTS_PER_SOL),
    payload: serializePayload(createPayload(4)),
    revertRecipient: user,
    signatureData: Buffer.from("insufficient_native_sig"),
  };

  try {
    await userProgram.methods
      .sendUniversalTx(
        insufficientNativeReq,
        new anchor.BN(0.005 * LAMPORTS_PER_SOL)
      ) // native < amount
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: null,
        gatewayTokenAccount: null,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([userKeypair])
      .rpc();
    assert.fail("Should have rejected insufficient native amount");
  } catch (error: any) {
    const errorCode =
      error.error?.errorCode?.code || error.error?.errorCode || error.code;
    assert.equal(
      errorCode,
      "InvalidAmount",
      `Expected InvalidAmount but got: ${errorCode}`
    );
    console.log(
      `  ✅ Correctly rejected insufficient native amount (InvalidAmount error)`
    );
  }

  // Security Test: Attempt to redirect SPL tokens to user's own account (should fail)
  if (tokenLoaded && vaultAta) {
    console.log(
      "  - Testing SECURITY: Attempt to redirect SPL tokens to user's own account (should fail)..."
    );
    // Vault ATA already created above

    // Try to pass user's own token account as gateway_token_account (the attack vector)
    const maliciousSplFundsReq = {
      recipient: Array.from(
        Buffer.from("9999999999999999999999999999999999999999", "hex").subarray(
          0,
          20
        )
      ),
      token: mint,
      amount: new anchor.BN(1000 * Math.pow(10, tokenInfo.decimals)),
      payload: Buffer.from([]),
      revertRecipient: user,
      signatureData: Buffer.from("malicious_spl_sig"),
    };

    try {
      await userProgram.methods
        .sendUniversalTx(maliciousSplFundsReq, new anchor.BN(0))
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: tokenAccount,
          gatewayTokenAccount: tokenAccount, // ⚠️ ATTACK: User's own account instead of vault ATA
          user: user,
          priceUpdate: PRICE_ACCOUNT,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: getTokenRateLimitPda(mint),
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();
      assert.fail(
        "Should have rejected user's own token account as gateway_token_account"
      );
    } catch (error: any) {
      const errorCode =
        error.error?.errorCode?.code || error.error?.errorCode || error.code;
      assert(
        errorCode === "InvalidOwner" || errorCode === "InvalidAccount",
        `Expected InvalidOwner or InvalidAccount but got: ${errorCode}`
      );
      console.log(
        `  ✅ SECURITY: Correctly rejected user's own token account (${errorCode} error)`
      );
    }

    // Also test with FUNDS_AND_PAYLOAD route
    console.log(
      "  - Testing SECURITY: Attempt to redirect SPL tokens in FUNDS_AND_PAYLOAD route (should fail)..."
    );
    const maliciousSplFundsPayloadReq = {
      recipient: Array.from(
        Buffer.from("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "hex").subarray(
          0,
          20
        )
      ),
      token: mint,
      amount: new anchor.BN(500 * Math.pow(10, tokenInfo.decimals)),
      payload: serializePayload(createPayload(99)),
      revertRecipient: user,
      signatureData: Buffer.from("malicious_spl_payload_sig"),
    };

    try {
      await userProgram.methods
        .sendUniversalTx(
          maliciousSplFundsPayloadReq,
          await getDynamicGasAmount(1.5, 0.01)
        )
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: tokenAccount,
          gatewayTokenAccount: tokenAccount, // ⚠️ ATTACK: User's own account instead of vault ATA
          user: user,
          priceUpdate: PRICE_ACCOUNT,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: getTokenRateLimitPda(mint),
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();
      assert.fail(
        "Should have rejected user's own token account in FUNDS_AND_PAYLOAD route"
      );
    } catch (error: any) {
      const errorCode =
        error.error?.errorCode?.code || error.error?.errorCode || error.code;
      assert(
        errorCode === "InvalidOwner" || errorCode === "InvalidAccount",
        `Expected InvalidOwner or InvalidAccount but got: ${errorCode}`
      );
      console.log(
        `  ✅ SECURITY: Correctly rejected user's own token account in FUNDS_AND_PAYLOAD (${errorCode} error)`
      );
    }

    // Test with wrong mint (correct owner, wrong token)
    console.log(
      "  - Testing SECURITY: Attempt to use vault ATA with wrong mint (should fail)..."
    );
    // Create a different token for this test (or use a dummy mint)
    const wrongMint = Keypair.generate().publicKey; // Dummy mint that doesn't exist
    const wrongMintVaultAta = PublicKey.findProgramAddressSync(
      [
        vaultPda.toBuffer(),
        spl.TOKEN_PROGRAM_ID.toBuffer(),
        wrongMint.toBuffer(),
      ],
      spl.ASSOCIATED_TOKEN_PROGRAM_ID
    )[0];

    const wrongMintReq = {
      recipient: Array.from(
        Buffer.from("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "hex").subarray(
          0,
          20
        )
      ),
      token: mint, // Correct mint
      amount: new anchor.BN(1000 * Math.pow(10, tokenInfo.decimals)),
      payload: Buffer.from([]),
      revertRecipient: user,
      signatureData: Buffer.from("wrong_mint_sig"),
    };

    try {
      await userProgram.methods
        .sendUniversalTx(wrongMintReq, new anchor.BN(0))
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: tokenAccount,
          gatewayTokenAccount: wrongMintVaultAta, // ⚠️ ATTACK: Vault ATA but for wrong mint
          user: user,
          priceUpdate: PRICE_ACCOUNT,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: getTokenRateLimitPda(mint),
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();
      assert.fail("Should have rejected vault ATA with wrong mint");
    } catch (error: any) {
      const errorCode =
        error.error?.errorCode?.code || error.error?.errorCode || error.code;
      // This might fail earlier (account doesn't exist) or with InvalidMint
      assert(
        errorCode === "InvalidMint" ||
          errorCode === "InvalidAccount" ||
          error.message.includes("AccountNotInitialized"),
        `Expected InvalidMint, InvalidAccount, or AccountNotInitialized but got: ${errorCode}`
      );
      console.log(
        `  ✅ SECURITY: Correctly rejected vault ATA with wrong mint (${errorCode} error)`
      );
    }
  }

  console.log("✅ Edge cases and negative tests completed!\n");

  console.log("✅ All sendUniversalTx tests completed!\n");

  // Step 10: Test pause/unpause
  console.log("10. Testing pause/unpause...");

  try {
    const pauseTx = await program.methods
      .pause()
      .accountsPartial({
        config: configPda,
        pauser: admin,
      })
      .rpc();
    console.log(`✅ Gateway paused: ${pauseTx}`);
  } catch (error) {
    if (
      error.message.includes("Paused") ||
      error.message.includes("already paused")
    ) {
      console.log("✅ Gateway already paused (skipping)");
    } else {
      throw error;
    }
  }

  // Try to send funds while paused (should fail)
  const signatureNew = Buffer.from("test_signature_data_for_gas", "utf8");
  const gasAmountPaused = await getDynamicGasAmount(2.5, 0.01);
  const gasReqPaused = {
    recipient: Array.from(Buffer.alloc(20, 0)),
    token: PublicKey.default,
    amount: new anchor.BN(0),
    payload: Buffer.from([]), // Empty payload for GAS route
    revertRecipient: user,
    signatureData: signatureNew,
  };
  try {
    await userProgram.methods
      .sendUniversalTx(gasReqPaused, gasAmountPaused)
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        userTokenAccount: null,
        gatewayTokenAccount: null,
        user: user,
        priceUpdate: PRICE_ACCOUNT,
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .rpc();
    assert.fail("Transaction should have failed while paused");
  } catch (error: any) {
    const errorCode =
      error.error?.errorCode?.code || error.error?.errorCode || error.code;
    assert.equal(errorCode, "Paused", `Expected Paused but got: ${errorCode}`);
    console.log(
      "✅ Transaction correctly failed while paused (Paused error verified)"
    );
  }

  try {
    const unpauseTx = await program.methods
      .unpause()
      .accountsPartial({
        config: configPda,
        operator: admin,
      })
      .rpc();
    console.log(`✅ Gateway unpaused: ${unpauseTx}\n`);
  } catch (error) {
    if (
      error.message.includes("not paused") ||
      error.message.includes("already unpaused")
    ) {
      console.log("✅ Gateway already unpaused (skipping)\n");
    } else {
      throw error;
    }
  }

  // =========================
  //   12. TSS INIT & WITHDRAW
  // =========================
  console.log("12. TSS init and TSS-verified withdraw test...");

  // 12.1 init_tss (chain_id = 1, ETH address from user)
  const ethAddrHex = "0xEbf0Cfc34E07ED03c05615394E2292b387B63F12"
    .toLowerCase()
    .replace(/^0x/, "");
  const ethAddrBytes = Buffer.from(ethAddrHex, "hex");
  if (ethAddrBytes.length !== 20)
    throw new Error("Invalid ETH address length for TSS");

  try {
    const tssInfo = await connection.getAccountInfo(tssPda);
    if (!tssInfo) {
      const initTssTx = await program.methods
        .initTss(
          Array.from(ethAddrBytes) as any,
          "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
        ) // Devnet cluster pubkey
        .accountsPartial({
          tssPda: tssPda,
          authority: admin,
          config: configPda,
          systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair])
        .rpc();
      console.log(`✅ TSS initialized: ${initTssTx}`);
    } else {
      console.log("TSS PDA already initialized");
    }
  } catch (e) {
    console.log("TSS init check failed, attempting init anyway");
    const initTssTx = await program.methods
      .initTss(
        Array.from(ethAddrBytes) as any,
        "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
      )
      .accountsPartial({
        tssPda: tssPda,
        authority: admin,
        config: configPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([adminKeypair])
      .rpc();
    console.log(`✅ TSS initialized: ${initTssTx}`);
  }

  // 12.2 Build message for SOL withdraw to admin using instruction_id=1
  const withdrawAmountTss = new anchor.BN(0.0005 * LAMPORTS_PER_SOL).toNumber();
  const { gasFee: withdrawGasFeeBigInt } = await calculateSolExecuteFees(
    connection
  );
  const withdrawGasFee = Number(withdrawGasFeeBigInt);
  // Fetch chain_id from TSS account (chain_id is now a String - Solana cluster pubkey)
  let chainId = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"; // Default to Devnet cluster pubkey
  try {
    // Attempt to read chain_id from on-chain TSS PDA
    const tssAcc: any = await (program.account as any).tssPda.fetch(tssPda);
    if (tssAcc) {
      if (typeof tssAcc.chainId !== "undefined") {
        chainId = tssAcc.chainId; // String: Solana cluster pubkey
      }
    }
  } catch (e) {
    // If not initialized or IDL not exposed yet, keep defaults
  }

  // Generate sub_tx_id and push_account for withdraw (use crypto for proper randomness)
  // Keep generating until we get a unique sub_tx_id (account doesn't exist)
  let txId: number[];
  let executedTxPda: PublicKey;
  let attempts = 0;
  do {
    txId = Array.from(anchor.web3.Keypair.generate().publicKey.toBuffer());
    [executedTxPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("executed_sub_tx"), Buffer.from(txId)],
      program.programId
    );
    attempts++;
    if (attempts > 10) {
      throw new Error("Could not generate unique sub_tx_id after 10 attempts");
    }
  } while ((await connection.getAccountInfo(executedTxPda)) !== null);

  const pushAccount = Array.from(
    anchor.web3.Keypair.generate().publicKey.toBuffer().slice(0, 20)
  );
  const universalTxIdWithdraw = generateUniversalTxId();

  const withdrawAdditional = buildWithdrawAdditionalData(
    Buffer.from(universalTxIdWithdraw),
    Buffer.from(txId),
    Buffer.from(pushAccount),
    PublicKey.default, // SOL
    admin,
    BigInt(withdrawGasFee)
  );
  const { signature, recoveryId, messageHash } = await signTssMessage({
    instruction: TssInstruction.Withdraw,
    amount: BigInt(withdrawAmountTss),
    additional: withdrawAdditional,
    chainId,
  });

  // 12.4 Call withdraw
  const adminBalanceBefore = await connection.getBalance(admin);
  const vaultBalanceBefore = await connection.getBalance(vaultPda);
  const executedTxExistsBeforeWithdraw =
    (await connection.getAccountInfo(executedTxPda)) !== null;
  const executedTxRent = await getExecutedTxRent(connection);

  const tssWithdrawTx = await program.methods
    .finalizeUniversalTx(
      1, // instruction_id = withdraw
      txId,
      Array.from(universalTxIdWithdraw), // Use same universal_tx_id from message hash
      new anchor.BN(withdrawAmountTss), // amount
      pushAccount, // pushAccount [u8; 20]
      Buffer.alloc(0), // writable_flags (empty for withdraw)
      Buffer.from([]), // ix_data (empty for withdraw)
      new anchor.BN(withdrawGasFee), // gas_fee
      new anchor.BN(DEFAULT_DEADLINE.toString()), // deadline
      Array.from(signature) as any,
      recoveryId,
      Array.from(messageHash) as any
    )
    .accountsPartial({
      caller: admin, // The caller/relayer who pays for the transaction
      config: configPda,
      vaultSol: vaultPda,
      ceaAuthority: getCeaAuthorityPda(pushAccount),
      tssPda: tssPda,
      executedSubTx: executedTxPda,
      destinationProgram: SystemProgram.programId,
      storedIxData: null,
      storeRefundRecipient: null,
      recipient: admin, // THE ACTUAL RECIPIENT
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
    .signers([adminKeypair])
    .rpc();
  console.log(
    `✅ TSS finalizeUniversalTx (withdraw SOL) completed: ${tssWithdrawTx}`
  );
  await parseAndPrintEvents(
    tssWithdrawTx,
    "finalizeUniversalTx withdraw events"
  );

  // Verify withdraw results
  // Admin receives withdraw amount + gas_used (as caller/relayer reimbursement) and pays executed_sub_tx rent.
  const adminBalanceAfter = await connection.getBalance(admin);
  const vaultBalanceAfter = await connection.getBalance(vaultPda);
  const adminNetChange = adminBalanceAfter - adminBalanceBefore;
  const signatureFeeLamports = 5_000;
  const gasUsed = signatureFeeLamports + executedTxRent;
  // Net = withdrawAmount + gas_used - executedTxRent
  const expectedAdminNet = withdrawAmountTss + gasUsed - executedTxRent;

  // Allow small tolerance for transaction fees (compute units)
  const tolerance = 10000; // ~0.00001 SOL for tx fees
  assert.isAtLeast(
    adminNetChange,
    expectedAdminNet - tolerance,
    `Admin net should be ~${expectedAdminNet} (receives ${withdrawAmountTss} + ${gasUsed} gas_used, pays ${executedTxRent} rent)`
  );
  assert.equal(
    vaultBalanceBefore - vaultBalanceAfter,
    withdrawAmountTss + gasUsed,
    "Vault should lose withdraw amount + gas_used"
  );

  const executedTxExistsAfterWithdraw =
    (await connection.getAccountInfo(executedTxPda)) !== null;
  assert.isTrue(
    executedTxExistsAfterWithdraw && !executedTxExistsBeforeWithdraw,
    "executedSubTx PDA should be created"
  );

  // 12.5 Test SPL token TSS withdrawal (unified instruction_id=1)
  console.log("\n=== Testing SPL Token TSS Withdrawal ===");

  // Check if we have SPL tokens in the vault to withdraw
  if (!tokenLoaded || !vaultAta) {
    console.log("⚠️  No SPL token loaded, skipping SPL TSS test");
  } else {
    const vaultTokenBalance = await spl.getAccount(
      userProvider.connection as any,
      vaultAta.address
    );
    if (Number(vaultTokenBalance.amount) === 0) {
      console.log(
        "⚠️  No SPL tokens in vault to withdraw, skipping SPL TSS test"
      );
    } else {
      const splWithdrawAmount = Math.min(
        Number(vaultTokenBalance.amount),
        1000
      ); // Withdraw small amount

      // Create admin ATA for the token
      const adminAta = await spl.getOrCreateAssociatedTokenAccount(
        userProvider.connection as any,
        adminKeypair,
        mint,
        admin
      );

      // Generate sub_tx_id and push_account for SPL withdraw (use crypto for proper randomness)
      // Keep generating until we get a unique sub_tx_id (account doesn't exist)
      let txIdSPL: number[];
      let executedTxPdaSPL: PublicKey;
      let attempts = 0;
      do {
        txIdSPL = Array.from(
          anchor.web3.Keypair.generate().publicKey.toBuffer()
        );
        [executedTxPdaSPL] = PublicKey.findProgramAddressSync(
          [Buffer.from("executed_sub_tx"), Buffer.from(txIdSPL)],
          program.programId
        );
        attempts++;
        if (attempts > 10) {
          throw new Error(
            "Could not generate unique sub_tx_id after 10 attempts"
          );
        }
      } while ((await connection.getAccountInfo(executedTxPdaSPL)) !== null);

      const pushAccountSPL = Array.from(
        anchor.web3.Keypair.generate().publicKey.toBuffer().slice(0, 20)
      );
      const universalTxIdSplWithdraw = generateUniversalTxId();

      const ceaAuthoritySPL = getCeaAuthorityPda(pushAccountSPL);
      const ceaAtaSPL = await getCeaAta(pushAccountSPL, mint);

      // Withdraw gas accounting matches finalize gas settlement:
      // signature fee + ExecutedSubTx rent + optional CEA ATA rent.
      const { gasFee: splWithdrawGasFeeBigInt } =
        await calculateSplExecuteFees(connection, ceaAtaSPL);
      const splWithdrawGasFee = Number(splWithdrawGasFeeBigInt);
      const splWithdrawAdditional = buildWithdrawAdditionalData(
        Buffer.from(universalTxIdSplWithdraw),
        Buffer.from(txIdSPL),
        Buffer.from(pushAccountSPL),
        mint,
        adminKeypair.publicKey,
        BigInt(splWithdrawGasFee)
      );
      const {
        signature: signatureSPL,
        recoveryId: recoveryIdSPL,
        messageHash: messageHashSPL,
      } = await signTssMessage({
        instruction: TssInstruction.Withdraw,
        amount: BigInt(splWithdrawAmount),
        additional: splWithdrawAdditional,
        chainId,
      });

      // Call unified withdraw with SPL token
      const vaultTokenBalanceBefore = (
        await spl.getAccount(userProvider.connection as any, vaultAta.address)
      ).amount;
      const adminTokenBalanceBefore = (
        await spl.getAccount(userProvider.connection as any, adminAta.address)
      ).amount;
      const executedTxExistsBeforeSplWithdraw =
        (await connection.getAccountInfo(executedTxPdaSPL)) !== null;

      const tssSplWithdrawTx = await program.methods
        .finalizeUniversalTx(
          1, // instruction_id = withdraw
          txIdSPL,
          Array.from(universalTxIdSplWithdraw), // Use same universal_tx_id from message hash
          new anchor.BN(splWithdrawAmount), // amount
          pushAccountSPL, // pushAccount [u8; 20]
          Buffer.alloc(0), // writable_flags (empty for withdraw)
          Buffer.from([]), // ix_data (empty for withdraw)
          new anchor.BN(splWithdrawGasFee), // gas_fee
          new anchor.BN(DEFAULT_DEADLINE.toString()),
          Array.from(signatureSPL) as any,
          recoveryIdSPL,
          Array.from(messageHashSPL) as any
        )
        .accountsPartial({
          caller: admin, // The caller/relayer who pays for the transaction
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: ceaAuthoritySPL,
          tssPda: tssPda,
          executedSubTx: executedTxPdaSPL,
          destinationProgram: SystemProgram.programId,
      storedIxData: null,
      storeRefundRecipient: null,
          recipient: adminKeypair.publicKey, // SPL recipient (token account)
          vaultAta: vaultAta.address,
          ceaAta: ceaAtaSPL,
          mint: mint,
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
          recipientAta: adminAta.address,
          rateLimitConfig: null,
          tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair])
        .rpc();
      console.log(
        `✅ TSS finalizeUniversalTx (withdraw SPL) completed: ${tssSplWithdrawTx}`
      );
      await parseAndPrintEvents(
        tssSplWithdrawTx,
        "finalizeUniversalTx withdraw SPL events"
      );

      // Verify withdraw results
      const vaultTokenBalanceAfter = (
        await spl.getAccount(userProvider.connection as any, vaultAta.address)
      ).amount;
      const adminTokenBalanceAfter = (
        await spl.getAccount(userProvider.connection as any, adminAta.address)
      ).amount;
      assert.equal(
        Number(adminTokenBalanceAfter) - Number(adminTokenBalanceBefore),
        splWithdrawAmount,
        "Admin should receive exact SPL withdraw amount"
      );
      assert.equal(
        Number(vaultTokenBalanceBefore) - Number(vaultTokenBalanceAfter),
        splWithdrawAmount,
        "Vault should lose exact SPL withdraw amount"
      );

      const executedTxExistsAfterSplWithdraw =
        (await connection.getAccountInfo(executedTxPdaSPL)) !== null;
      assert.isTrue(
        executedTxExistsAfterSplWithdraw && !executedTxExistsBeforeSplWithdraw,
        "executedSubTx PDA should be created"
      );
    }
  }

  // 13. Note: ATA creation is now handled off-chain by clients (standard practice)
  console.log("\n=== ATA Creation Note ===");
  console.log(
    "✅ ATA creation is handled off-chain by clients (standard Solana practice)"
  );
  console.log(
    "✅ This avoids complex reimbursement logic and follows industry standards"
  );

  // 13.5 Execute tests via payload encode/decode pipeline
  console.log(
    "\n=== 13.5 Testing finalizeUniversalTx (execute mode) via payload encode/decode pipeline ==="
  );
  // Derive counter PDA
  const [counterPda, counterBump] = PublicKey.findProgramAddressSync(
    [Buffer.from("counter")],
    counterProgram.programId
  );

  try {
    await counterProgram.account.counter.fetch(counterPda);
    console.log("Counter account already initialized");
  } catch {
    const initCounterTx = await counterProgram.methods
      .initialize(new anchor.BN(0))
      .accountsPartial({
        counter: counterPda,
        authority: admin, // Operator signer (admin used as operator in this script), relayer signs execute txs
        systemProgram: SystemProgram.programId,
      })
      .signers([adminKeypair])
      .rpc();
    console.log(`✅ Counter initialized for execute tests: ${initCounterTx}`);
  }

  const tssAccount: any = await (program.account as any).tssPda.fetch(tssPda);

  // Verify TSS address matches the private key
  const testPubKey = secp.getPublicKey(tssPrivKeyHex, false).slice(1);
  const testEthAddressHex = keccak_256(testPubKey).slice(-40);
  const testEthAddress = Buffer.from(testEthAddressHex, "hex");
  const onChainTssAddress = Buffer.from(tssAccount.tssEthAddress);

  console.log("🔑 TSS Address on-chain:", onChainTssAddress.toString("hex"));
  console.log("🔑 TSS Address from privkey:", testEthAddress.toString("hex"));

  if (!testEthAddress.equals(onChainTssAddress)) {
    throw new Error(
      "TSS private key does not match on-chain TSS address! Check your .env"
    );
  }

  async function runExecuteSolTest() {
    console.log("👉 finalizeUniversalTx (execute SOL) via encoded payload");

    const solTxIdBytes = anchor.web3.Keypair.generate().publicKey.toBytes();

    // Check relayer account (used as caller/payer)
    const relayerInfo = await connection.getAccountInfo(relayer);
    console.log("🔍 relayer:", relayer.toBase58());
    console.log("🔍 relayer balance:", relayerInfo?.lamports || 0);
    console.log("🔍 relayer data.length:", relayerInfo?.data.length || 0);
    console.log("🔍 relayer owner:", relayerInfo?.owner.toBase58() || "none");
    const pushAccountBytes = Buffer.alloc(20, 0x11);
    const incrementIx = await counterProgram.methods
      .increment(new anchor.BN(3))
      .accountsPartial({
        counter: counterPda,
        authority: admin, // Operator signer (admin used as operator in this script), relayer signs the execute tx
      })
      .instruction();

    // Calculate fees dynamically for SOL execute (before encoding payload)
    const { gasFee } = await calculateSolExecuteFees(connection);

    // Encode payload with execution data (accounts, ixData, targetProgram)
    const payloadFields = instructionToPayloadFields({
      instruction: incrementIx,
      targetProgram: counterProgram.programId, // Canonical destination (source of truth)
    });

    const encoded = encodeExecutePayload(payloadFields);
    const decoded = decodeExecutePayload(encoded);

    // Get destination from decoded payload (canonical source of truth)
    const targetProgram = decoded.targetProgram;
    const amount = BigInt(0);
    const chainId = tssAccount.chainId;

    console.log(
      "🔍 Payload decoded - accounts:",
      decoded.accounts.length,
      "ixData:",
      decoded.ixData.length
    );
    console.log("🔍 Amount:", amount.toString());
    console.log("🔍 gasFee:", gasFee.toString());

    // Generate universal_tx_id for signing
    const universalTxIdForSigning = generateUniversalTxId();

    // Sign using the proven TSS helpers
    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: amount,
      chainId: chainId,
      additional: buildExecuteAdditionalData(
        universalTxIdForSigning,
        solTxIdBytes,
        targetProgram,
        pushAccountBytes,
        decoded.accounts,
        decoded.ixData,
        gasFee // From fee calculation
      ),
    });

    // Get CEA authority for SOL execute
    const ceaAuthority = getCeaAuthorityPda(Array.from(pushAccountBytes));
    const executedSubTx = getExecutedTxPda(solTxIdBytes);
    const remainingAccounts = decoded.accounts.map((meta) => ({
      pubkey: meta.pubkey,
      isWritable: meta.isWritable,
      isSigner: false,
    }));

    // Convert accounts to writable flags (use same universal_tx_id from signing)
    const writableFlags = accountsToWritableFlags(decoded.accounts);

    // Capture state before execution
    const counterBefore = await counterProgram.account.counter.fetch(
      counterPda
    );
    const ceaBalanceBefore = await connection.getBalance(ceaAuthority);
    const relayerBalanceBefore = await connection.getBalance(relayer);
    const executedTxExistsBefore =
      (await connection.getAccountInfo(executedSubTx)) !== null;
    const executedTxRent = await getExecutedTxRent(connection);

    const execTx = await relayerProgram.methods
      .finalizeUniversalTx(
        2, // instruction_id = execute
        Array.from(solTxIdBytes),
        Array.from(universalTxIdForSigning),
        new anchor.BN(amount.toString()),
        Array.from(pushAccountBytes),
        writableFlags,
        Buffer.from(decoded.ixData),
        new anchor.BN(Number(gasFee)),

        new anchor.BN(DEFAULT_DEADLINE.toString()),
        sig.signature,
        sig.recoveryId,
        sig.messageHash
      )
      .accountsPartial({
        caller: relayer, // Relayer is now both fee payer and caller
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority: ceaAuthority,
        tssPda,
        executedSubTx,
        destinationProgram: targetProgram,
      storedIxData: null,
      storeRefundRecipient: null,
        recipient: null, // null for execute mode
        vaultAta: null,
        ceaAta: null,
        mint: null,
        tokenProgram: null,
        rent: null,
        associatedTokenProgram: null,
        recipientAta: null, // null for execute mode
        rateLimitConfig: null,
        tokenRateLimit: null,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(remainingAccounts)
      .rpc();

    console.log(`✅ finalizeUniversalTx (execute SOL) succeeded: ${execTx}`);

    // Verify execution results
    const counterAfter = await counterProgram.account.counter.fetch(counterPda);
    assert.equal(
      counterAfter.value.toNumber(),
      counterBefore.value.toNumber() + 3,
      "Counter should increment by 3"
    );

    const ceaBalanceAfter = await connection.getBalance(ceaAuthority);
    assert.equal(
      ceaBalanceAfter - ceaBalanceBefore,
      0,
      "execute amount must not be transferred to CEA"
    );

    // Relayer pays executedSubTx rent upfront; receives gas_used = SIGNATURE_FEE + executedTxRent from vault.
    // Net ≈ SIGNATURE_FEE (5_000 lamports) minus network transaction fees.
    const relayerBalanceAfter = await connection.getBalance(relayer);
    const relayerNetChange = relayerBalanceAfter - relayerBalanceBefore;
    const gasUsedSol = Number(SIGNATURE_FEE_LAMPORTS) + executedTxRent;
    const expectedRelayerNet = gasUsedSol - executedTxRent; // = SIGNATURE_FEE = 5_000
    // Allow tolerance for compute fees (~50k-100k lamports)
    const computeFeeTolerance = 150000;
    assert.isAtLeast(
      relayerNetChange,
      expectedRelayerNet - computeFeeTolerance,
      `Relayer net should be ~${expectedRelayerNet} (receives gas_used=${gasUsedSol}, pays ${executedTxRent} rent + compute fees)`
    );

    const executedTxExistsAfter =
      (await connection.getAccountInfo(executedSubTx)) !== null;
    assert.isTrue(
      executedTxExistsAfter && !executedTxExistsBefore,
      "executedSubTx PDA should be created"
    );

    console.log(
      `Counter: ${counterBefore.value.toNumber()} → ${counterAfter.value.toNumber()} ✅`
    );
  }

  async function runExecuteSplTest() {
    console.log("👉 finalizeUniversalTx (execute SPL) via encoded payload");
    const tssAfterSol: any = await (program.account as any).tssPda.fetch(
      tssPda
    );
    const splTxIdBytes = anchor.web3.Keypair.generate().publicKey.toBytes();
    const pushAccountBytes = Buffer.alloc(20, 0x22);

    // Get CEA authority and ATA (needed for the instruction and execute accounts)
    const ceaAuthority = getCeaAuthorityPda(Array.from(pushAccountBytes));
    const ceaAtaForSpl = await getCeaAta(Array.from(pushAccountBytes), mint);

    const executeRecipient = Keypair.generate();
    const executeRecipientAta = await spl.getOrCreateAssociatedTokenAccount(
      userProvider.connection as any,
      userKeypair,
      mint,
      executeRecipient.publicKey
    );
    const executeAmount = new anchor.BN(200 * Math.pow(10, tokenInfo.decimals));

    const receiveSplIx = await counterProgram.methods
      .receiveSpl(executeAmount)
      .accountsPartial({
        counter: counterPda,
        ceaAta: ceaAtaForSpl, // CEA ATA
        recipientAta: executeRecipientAta.address,
        ceaAuthority: ceaAuthority, // CEA authority
        tokenProgram: spl.TOKEN_PROGRAM_ID,
      })
      .instruction();

    // Check CEA ATA existence BEFORE calculating fees (ceaAtaForSpl already calculated above)
    const { gasFee, gasUsed } = await calculateSplExecuteFees(
      connection,
      ceaAtaForSpl
    );

    // Encode payload with execution data (accounts, ixData, targetProgram)
    const payloadFields = instructionToPayloadFields({
      instruction: receiveSplIx,
      targetProgram: counterProgram.programId, // Canonical destination (source of truth)
    });

    const encoded = encodeExecutePayload(payloadFields);
    const decoded = decodeExecutePayload(encoded);

    // Get destination from decoded payload (canonical source of truth)
    const targetProgram = decoded.targetProgram;
    const amount = BigInt(executeAmount.toString());
    const chainId = tssAfterSol.chainId;

    console.log(
      "🔍 SPL Payload decoded - accounts:",
      decoded.accounts.length,
      "ixData:",
      decoded.ixData.length
    );
    console.log("🔍 gasFee:", gasFee.toString());

    // Generate universal_tx_id for signing
    const universalTxIdSplForSigning = generateUniversalTxId();

    // Sign using the proven TSS helpers
    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: amount,
      chainId: chainId,
      additional: buildExecuteAdditionalData(
        universalTxIdSplForSigning,
        splTxIdBytes,
        targetProgram,
        pushAccountBytes,
        decoded.accounts,
        decoded.ixData,
        gasFee, // From fee calculation
        mint
      ),
    });

    const executedSubTx = getExecutedTxPda(splTxIdBytes);
    const remainingAccounts = decoded.accounts.map((meta) => ({
      pubkey: meta.pubkey,
      isWritable: meta.isWritable,
      isSigner: false,
    }));

    // Convert accounts to writable flags (use same universal_tx_id from signing)
    const writableFlagsSpl = accountsToWritableFlags(decoded.accounts);

    // Capture state before execution
    const recipientTokenBefore = (
      await spl.getAccount(
        userProvider.connection as any,
        executeRecipientAta.address
      )
    ).amount;
    const vaultAtaBalanceBefore = (
      await spl.getAccount(userProvider.connection as any, vaultAta.address)
    ).amount;
    const relayerBalanceBeforeSpl = await connection.getBalance(relayer);
    const executedTxExistsBeforeSpl =
      (await connection.getAccountInfo(executedSubTx)) !== null;
    const executedTxRentSpl = await getExecutedTxRent(connection);

    const execSplTx = await relayerProgram.methods
      .finalizeUniversalTx(
        2, // instruction_id = execute
        Array.from(splTxIdBytes),
        Array.from(universalTxIdSplForSigning),
        new anchor.BN(amount.toString()),
        Array.from(pushAccountBytes),
        writableFlagsSpl,
        Buffer.from(decoded.ixData),
        new anchor.BN(Number(gasFee)),

        new anchor.BN(DEFAULT_DEADLINE.toString()),
        sig.signature,
        sig.recoveryId,
        sig.messageHash
      )
      .accountsPartial({
        caller: relayer, // Relayer is now both fee payer and caller
        config: configPda,
        vaultSol: vaultPda, // Vault SOL PDA for fee transfers
        ceaAuthority: ceaAuthority, // CEA authority PDA
        tssPda,
        executedSubTx,
        destinationProgram: targetProgram,
      storedIxData: null,
      storeRefundRecipient: null,
        recipient: null, // null for execute mode
        vaultAta: vaultAta.address,
        ceaAta: ceaAtaForSpl, // CEA ATA
        mint,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
        recipientAta: null, // null for execute mode
        rateLimitConfig: null,
        tokenRateLimit: null,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(remainingAccounts)
      .rpc();

    console.log(`✅ finalizeUniversalTx (execute SPL) succeeded: ${execSplTx}`);

    // Verify execution results
    const recipientTokenAfter = (
      await spl.getAccount(
        userProvider.connection as any,
        executeRecipientAta.address
      )
    ).amount;
    assert.equal(
      Number(recipientTokenAfter) - Number(recipientTokenBefore),
      executeAmount.toNumber(),
      "Recipient should receive exact SPL amount"
    );

    // Vault ATA should lose the amount (tokens flow: vault_ata → cea_ata → recipient_ata via target program)
    const vaultAtaBalanceAfter = (
      await spl.getAccount(userProvider.connection as any, vaultAta.address)
    ).amount;
    assert.equal(
      Number(vaultAtaBalanceBefore) - Number(vaultAtaBalanceAfter),
      executeAmount.toNumber(),
      "Vault ATA should lose exact SPL amount"
    );

    // Relayer pays executedSubTx rent (+ cea_ata_rent if created) upfront; receives gas_used from vault.
    // gas_used = SIGNATURE_FEE + executedTxRent [+ ataRent]. Net is always SIGNATURE_FEE regardless of ATA creation.
    const relayerBalanceAfterSpl = await connection.getBalance(relayer);
    const relayerNetChangeSpl =
      relayerBalanceAfterSpl - relayerBalanceBeforeSpl;
    const expectedRelayerNetSpl = Number(SIGNATURE_FEE_LAMPORTS); // always 5_000: gas_used - rents_paid = SIGNATURE_FEE
    // Allow tolerance for compute fees (~50k-100k lamports)
    const computeFeeToleranceSpl = 150000;
    assert.isAtLeast(
      relayerNetChangeSpl,
      expectedRelayerNetSpl - computeFeeToleranceSpl,
      `Relayer net should be ~${expectedRelayerNetSpl} (receives gas_used=${Number(
        gasUsed
      )}, pays ${executedTxRentSpl} rent + compute fees)`
    );

    const executedTxExistsAfterSpl =
      (await connection.getAccountInfo(executedSubTx)) !== null;
    assert.isTrue(
      executedTxExistsAfterSpl && !executedTxExistsBeforeSpl,
      "executedSubTx PDA should be created"
    );

    console.log(
      `Recipient SPL: ${recipientTokenBefore.toString()} → ${recipientTokenAfter.toString()} ✅`
    );
  }

  async function runCeaWithdrawSolTest() {
    console.log("👉 sendUniversalTxToUEA (CEA self-withdraw SOL → vault)");

    const pushAccountBytes = Buffer.alloc(20, 0x33); // arbitrary 20-byte Push Chain pushAccount
    const ceaAuthority = getCeaAuthorityPda(Array.from(pushAccountBytes));

    // Fund the CEA directly so it has lamports to withdraw
    const fundAmount = 5_000_000; // 0.005 SOL
    const fundTx = new anchor.web3.Transaction().add(
      anchor.web3.SystemProgram.transfer({
        fromPubkey: admin,
        toPubkey: ceaAuthority,
        lamports: fundAmount,
      })
    );
    await adminProvider.sendAndConfirm(fundTx, [adminKeypair]);
    const ceaBalBefore = await connection.getBalance(ceaAuthority);
    console.log(`CEA funded: ${ceaBalBefore} lamports`);

    const { gasFee } = await calculateSolExecuteFees(connection);

    // Build ix_data: discriminator(send_universal_tx_to_uea) + borsh(SendUniversalTxToUEAArgs)
    const discriminator = createHash("sha256")
      .update("global:send_universal_tx_to_uea")
      .digest()
      .slice(0, 8);
    const tokenBytes = Buffer.alloc(32, 0); // SOL = Pubkey::default()
    const amountBytes = Buffer.alloc(8);
    // Drain amount is current CEA balance.
    amountBytes.writeBigUInt64LE(BigInt(ceaBalBefore));
    const payloadLenBytes = Buffer.from([0, 0, 0, 0]); // empty Vec<u8>
    const revertRecipientBytes = ceaAuthority.toBuffer(); // revert_recipient = CEA itself
    const ixData = Buffer.concat([
      discriminator,
      tokenBytes,
      amountBytes,
      payloadLenBytes,
      revertRecipientBytes,
    ]);

    const txId = anchor.web3.Keypair.generate().publicKey.toBytes();
    const universalTxId = generateUniversalTxId();
    const chainId = (await (program.account as any).tssPda.fetch(tssPda))
      .chainId;

    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId,
      additional: buildExecuteAdditionalData(
        universalTxId,
        txId,
        program.programId, // destination_program = gateway itself
        pushAccountBytes,
        [], // no remaining accounts
        ixData,
        gasFee
        ),
    });

    const executedSubTx = getExecutedTxPda(txId);
    const vaultBalBefore = await connection.getBalance(vaultPda);
    const relayerBalBefore = await connection.getBalance(relayer);

    const txSig = await relayerProgram.methods
      .finalizeUniversalTx(
        2,
        Array.from(txId),
        Array.from(universalTxId),
        new anchor.BN(0),
        Array.from(pushAccountBytes),
        Buffer.from([]), // writable_flags: no remaining accounts
        ixData,
        new anchor.BN(Number(gasFee)),

        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(sig.signature),
        sig.recoveryId,
        Array.from(sig.messageHash)
      )
      .accountsPartial({
        caller: relayer,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority,
        tssPda,
        executedSubTx,
        destinationProgram: program.programId,
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
        rateLimitConfig: rateLimitConfigPda,
        tokenRateLimit: nativeSolTokenRateLimitPda,
        systemProgram: SystemProgram.programId,
      })
      .signers([relayerKeypair])
      .rpc();

    const ceaBalAfter = await connection.getBalance(ceaAuthority);
    const vaultBalAfter = await connection.getBalance(vaultPda);
    const relayerBalAfter = await connection.getBalance(relayer);

    assert.equal(ceaBalAfter, 0, "CEA should be fully drained");
    assert.isAbove(
      vaultBalAfter,
      vaultBalBefore,
      "Vault should receive CEA funds"
    );
    assert.isAbove(
      relayerBalAfter - relayerBalBefore,
      -200_000,
      "Relayer net loss should be minimal"
    );

    console.log(`CEA drained: ${ceaBalBefore} → ${ceaBalAfter} lamports ✅`);
    console.log(
      `Vault gained: ${vaultBalBefore} → ${vaultBalAfter} lamports ✅`
    );
    console.log(`Tx: ${txSig}`);
  }

  await runExecuteSolTest();
  await runExecuteSplTest();
  await runCeaWithdrawSolTest();

  // 13.6 Execute security validations (negative tests on devnet)
  console.log(
    "\n=== 13.6 Testing execute security validations (negative tests) ==="
  );

  /**
   * Helper to test that an execute call correctly reverts with expected error
   */
  async function expectExecuteRevertDevnet(
    testName: string,
    executeCall: () => Promise<any>,
    expectedErrorCode: string
  ): Promise<void> {
    try {
      await executeCall();
      throw new Error(`❌ ${testName}: Should have reverted but succeeded`);
    } catch (e: any) {
      const errorMsg = e.toString();
      const hasExpectedError = errorMsg.includes(expectedErrorCode);

      if (!hasExpectedError) {
        console.error(
          `❌ ${testName}: Expected error "${expectedErrorCode}" but got:`,
          errorMsg
        );
        throw new Error(
          `Expected error code "${expectedErrorCode}" not found. Got: ${errorMsg}`
        );
      }

      console.log(
        `✅ ${testName}: Correctly rejected with ${expectedErrorCode}`
      );
    }
  }

  // Test 1: Account substitution attack
  console.log("🔒 Testing: Account substitution attack...");
  const tssAccount1: any = await (program.account as any).tssPda.fetch(tssPda);
  const securityTxId1 = anchor.web3.Keypair.generate().publicKey.toBytes();
  const securitySender1 = Buffer.alloc(20, 0x33);

  const securityCounterIx = await counterProgram.methods
    .increment(new anchor.BN(1))
    .accountsPartial({
      counter: counterPda,
      authority: admin,
    })
    .instruction();

  // Calculate fees for security test
  const { gasFee: gasFee1 } = await calculateSolExecuteFees(connection);
  const correctPayloadFields = instructionToPayloadFields({
    instruction: securityCounterIx,
    targetProgram: counterProgram.programId,
  });
  const encoded1 = encodeExecutePayload(correctPayloadFields);
  const decoded1 = decodeExecutePayload(encoded1);
  const correctAccounts = decoded1.accounts;
  const universalTxId1 = generateUniversalTxId();

  const securitySig1 = await signTssMessage({
    instruction: TssInstruction.Execute,
    amount: BigInt(0),
    chainId: tssAccount1.chainId,
    additional: buildExecuteAdditionalData(
      universalTxId1,
      securityTxId1,
      decoded1.targetProgram, // From decoded payload (canonical)
      securitySender1,
      correctAccounts,
      decoded1.ixData,
      gasFee1
        ),
  });

  // ATTACK: Substitute account
  const attackerAccount = anchor.web3.Keypair.generate().publicKey;
  const substitutedRemaining = [
    { pubkey: attackerAccount, isWritable: true, isSigner: false }, // Wrong account!
    { pubkey: admin, isWritable: false, isSigner: false },
  ];
  const writableFlags1 = accountsToWritableFlags(correctAccounts);

  await expectExecuteRevertDevnet(
    "Account substitution",
    async () => {
      return await relayerProgram.methods
        .finalizeUniversalTx(
          2, // instruction_id = execute
          Array.from(securityTxId1),
          Array.from(universalTxId1),
          new anchor.BN(0),
          Array.from(securitySender1),
          writableFlags1,
          Buffer.from(securityCounterIx.data),
          new anchor.BN(Number(gasFee1)),

          new anchor.BN(DEFAULT_DEADLINE.toString()),
          securitySig1.signature,
          securitySig1.recoveryId,
          securitySig1.messageHash
        )
        .accountsPartial({
          caller: relayer,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(Array.from(securitySender1)),
          tssPda,
          executedSubTx: getExecutedTxPda(securityTxId1),
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
          rateLimitConfig: null,
          tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(substitutedRemaining)
        .rpc();
    },
    "MessageHashMismatch" // TSS validation catches account substitution first (correct security behavior)
  );

  // Test 2: Invalid signature
  console.log("🔒 Testing: Invalid signature...");
  const tssAccount2: any = await (program.account as any).tssPda.fetch(tssPda);
  const securityTxId2 = anchor.web3.Keypair.generate().publicKey.toBytes();
  const securitySender2 = Buffer.alloc(20, 0x44);

  const securityCounterIx2 = await counterProgram.methods
    .increment(new anchor.BN(1))
    .accountsPartial({
      counter: counterPda,
      authority: admin,
    })
    .instruction();

  // Calculate fees for security test
  const { gasFee: gasFee2 } = await calculateSolExecuteFees(connection);
  const securityPayloadFields2 = instructionToPayloadFields({
    instruction: securityCounterIx2,
    targetProgram: counterProgram.programId,
  });
  const encoded2 = encodeExecutePayload(securityPayloadFields2);
  const decoded2 = decodeExecutePayload(encoded2);
  const securityAccounts2 = decoded2.accounts;
  const universalTxId2 = generateUniversalTxId();

  const securitySig2 = await signTssMessage({
    instruction: TssInstruction.Execute,
    amount: BigInt(0),
    chainId: tssAccount2.chainId,
    additional: buildExecuteAdditionalData(
      universalTxId2,
      securityTxId2,
      decoded2.targetProgram, // From decoded payload (canonical)
      securitySender2,
      securityAccounts2,
      decoded2.ixData,
      gasFee2
        ),
  });

  // ATTACK: Corrupt signature
  const corruptedSig = Array.from(securitySig2.signature);
  corruptedSig[0] ^= 0xff;
  const writableFlags2 = accountsToWritableFlags(securityAccounts2);

  await expectExecuteRevertDevnet(
    "Invalid signature",
    async () => {
      return await relayerProgram.methods
        .finalizeUniversalTx(
          2, // instruction_id = execute
          Array.from(securityTxId2),
          Array.from(universalTxId2),
          new anchor.BN(0),
          Array.from(securitySender2),
          writableFlags2,
          Buffer.from(securityCounterIx2.data),
          new anchor.BN(Number(gasFee2)),

          new anchor.BN(DEFAULT_DEADLINE.toString()),
          corruptedSig,
          securitySig2.recoveryId,
          securitySig2.messageHash
        )
        .accountsPartial({
          caller: relayer,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(Array.from(securitySender2)),
          tssPda,
          executedSubTx: getExecutedTxPda(securityTxId2),
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
          rateLimitConfig: null,
          tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(
          securityAccounts2.map((a) => ({
            pubkey: a.pubkey,
            isWritable: a.isWritable,
            isSigner: false,
          }))
        )
        .rpc();
    },
    "TssAuthFailed"
  );

  // Test 3: Account count mismatch
  console.log("🔒 Testing: Account count mismatch...");
  const tssAccount4: any = await (program.account as any).tssPda.fetch(tssPda);
  const securityTxId4 = anchor.web3.Keypair.generate().publicKey.toBytes();
  const securitySender4 = Buffer.alloc(20, 0x66);

  const securityCounterIx4 = await counterProgram.methods
    .increment(new anchor.BN(1))
    .accountsPartial({
      counter: counterPda,
      authority: admin,
    })
    .instruction();

  // Calculate fees for security test
  const { gasFee: gasFee4 } = await calculateSolExecuteFees(connection);
  const securityPayloadFields4 = instructionToPayloadFields({
    instruction: securityCounterIx4,
    targetProgram: counterProgram.programId,
  });
  const encoded4 = encodeExecutePayload(securityPayloadFields4);
  const decoded4 = decodeExecutePayload(encoded4);
  const securityAccounts4 = decoded4.accounts;
  const universalTxId4 = generateUniversalTxId();

  const securitySig4 = await signTssMessage({
    instruction: TssInstruction.Execute,
    amount: BigInt(0),
    chainId: tssAccount4.chainId,
    additional: buildExecuteAdditionalData(
      universalTxId4,
      securityTxId4,
      decoded4.targetProgram, // From decoded payload (canonical)
      securitySender4,
      securityAccounts4,
      decoded4.ixData,
      gasFee4
        ),
  });

  // ATTACK: Pass fewer accounts
  const fewerRemaining = [
    { pubkey: counterPda, isWritable: true, isSigner: false },
    // Missing admin/authority!
  ];
  // Use writable flags for the fewer accounts (1 account = 1 byte)
  const fewerWritableFlags = accountsToWritableFlags(
    fewerRemaining.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable }))
  );

  await expectExecuteRevertDevnet(
    "Account count mismatch",
    async () => {
      return await relayerProgram.methods
        .finalizeUniversalTx(
          2, // instruction_id = execute
          Array.from(securityTxId4),
          Array.from(universalTxId4),
          new anchor.BN(0),
          Array.from(securitySender4),
          fewerWritableFlags, // Use flags for fewer accounts
          Buffer.from(securityCounterIx4.data),
          new anchor.BN(Number(gasFee4)),

          new anchor.BN(DEFAULT_DEADLINE.toString()),
          securitySig4.signature,
          securitySig4.recoveryId,
          securitySig4.messageHash
        )
        .accountsPartial({
          caller: relayer,
          config: configPda,
          vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(Array.from(securitySender4)),
          tssPda,
          executedSubTx: getExecutedTxPda(securityTxId4),
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
          rateLimitConfig: null,
          tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(fewerRemaining)
        .rpc();
    },
    "MessageHashMismatch" // TSS validation catches account count mismatch (signed hash has 2 accounts, reconstructed has 1)
  );

  console.log("✅ All execute security validations passed on devnet!\n");

  // 13.7 Transaction size limits analysis
  console.log("\n=== 13.7 Transaction Size Limits Analysis ===");

  /**
   * Build and measure transaction size (pure function, no RPC send)
   * Uses VersionedTransaction.serialize().length as the authoritative sizing oracle
   */
  const buildAndMeasureTxSize = async (
    desiredTargetAccounts: number,
    desiredFullIxDataSize: number,
    isSpl: boolean = false
  ): Promise<{
    txSize: number;
    dummyAccounts: number;
    actualTargetAccounts: number;
    rawDataSize: number;
    fullIxDataSize: number;
  }> => {
    // Build target instruction (batchOperation)
    const dummyAccounts = Array.from(
      { length: Math.max(0, desiredTargetAccounts - 2) },
      () => Keypair.generate()
    );
    const rawDataSize = Math.max(desiredFullIxDataSize - 20, 0); // 20 = Anchor overhead (8 discriminator + 8 u64 + 4 vec length)
    const testData = Buffer.alloc(rawDataSize, 0xaa);

    const batchIx = await counterProgram.methods
      .batchOperation(new anchor.BN(12345), testData)
      .accountsPartial({
        counter: counterPda,
        authority: admin,
      })
      .remainingAccounts(
        dummyAccounts.map((acc) => ({
          pubkey: acc.publicKey,
          isWritable: false,
          isSigner: false,
        }))
      )
      .instruction();

    // Measure actual sizes from built instruction (do NOT assume)
    const { gasFee } = await calculateSolExecuteFees(connection);
    const payloadFields = instructionToPayloadFields({
      instruction: batchIx,
      targetProgram: counterProgram.programId,
    });
    const encodedPayload = encodeExecutePayload(payloadFields);
    const decodedPayload = decodeExecutePayload(encodedPayload);
    const accounts = decodedPayload.accounts;
    const actualTargetAccounts = accounts.length;
    const fullIxDataSize = batchIx.data.length;

    // Build gateway instruction
    const testTxId = anchor.web3.Keypair.generate().publicKey.toBytes();
    const testSender = Buffer.alloc(20, 0xaa);
    const testCea = getCeaAuthorityPda(Array.from(testSender));
    const universalTxId = generateUniversalTxId();

    const sig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: (await (program.account as any).tssPda.fetch(tssPda)).chainId,
      additional: buildExecuteAdditionalData(
        universalTxId,
        testTxId,
        decodedPayload.targetProgram, // From decoded payload (canonical)
        testSender,
        accounts,
        decodedPayload.ixData,
        gasFee,
          isSpl ? mint : PublicKey.default
      ),
    });

    const writableFlags = accountsToWritableFlags(accounts);
    const baseAccounts = {
      caller: relayer,
      config: configPda,
      vaultSol: vaultPda,
      ceaAuthority: testCea,
      tssPda,
      executedSubTx: getExecutedTxPda(testTxId),
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
      rateLimitConfig: null,
      tokenRateLimit: null,
      systemProgram: SystemProgram.programId,
    };

    let gatewayIx;
    if (isSpl) {
      const ceaAta = spl.getAssociatedTokenAddressSync(
        mint,
        testCea,
        true,
        spl.TOKEN_PROGRAM_ID,
        spl.ASSOCIATED_TOKEN_PROGRAM_ID
      );
      gatewayIx = await relayerProgram.methods
        .finalizeUniversalTx(
          2, // instruction_id = execute
          Array.from(testTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(testSender),
          writableFlags,
          Buffer.from(batchIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(DEFAULT_DEADLINE.toString()),
          sig.signature,
          sig.recoveryId,
          sig.messageHash
        )
        .accountsPartial({
          ...baseAccounts,
          vaultAta: vaultAta.address,
          ceaAta: ceaAta,
          mint,
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          rent: anchor.web3.SYSVAR_RENT_PUBKEY,
          associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
        })
        .remainingAccounts(
          accounts.map((a) => ({
            pubkey: a.pubkey,
            isWritable: a.isWritable,
            isSigner: false,
          }))
        )
        .instruction();
    } else {
      gatewayIx = await relayerProgram.methods
        .finalizeUniversalTx(
          2, // instruction_id = execute
          Array.from(testTxId),
          Array.from(universalTxId),
          new anchor.BN(0),
          Array.from(testSender),
          writableFlags,
          Buffer.from(batchIx.data),
          new anchor.BN(Number(gasFee)),

          new anchor.BN(DEFAULT_DEADLINE.toString()),
          sig.signature,
          sig.recoveryId,
          sig.messageHash
        )
        .accountsPartial(baseAccounts)
        .remainingAccounts(
          accounts.map((a) => ({
            pubkey: a.pubkey,
            isWritable: a.isWritable,
            isSigner: false,
          }))
        )
        .instruction();
    }

    // Build legacy Transaction (matching doc formulas, not v0/ALTs)
    const { blockhash } = await connection.getLatestBlockhash();
    const tx = new anchor.web3.Transaction();
    tx.recentBlockhash = blockhash;
    tx.feePayer = relayer;
    tx.add(gatewayIx);
    tx.partialSign(relayerKeypair);

    // Serialize and measure size (authoritative sizing oracle)
    // If serialization fails due to size, return a size > 1232 to indicate it's over limit
    let txSize: number;
    try {
      txSize = tx.serialize().length;
    } catch (error: any) {
      // If transaction is too large, serialize() throws an error
      // Return a size > 1232 to indicate it's over the limit
      if (
        error.message?.includes("too large") ||
        error.message?.includes("Transaction too large")
      ) {
        // Extract the size from error message if possible, otherwise use a large number
        const sizeMatch = error.message.match(/(\d+)\s*>\s*1232/);
        txSize = sizeMatch ? parseInt(sizeMatch[1], 10) : 1233;
      } else {
        // Some other error - rethrow
        throw error;
      }
    }

    // Return measured values (authoritative sizing oracle)
    return {
      txSize,
      dummyAccounts: dummyAccounts.length,
      actualTargetAccounts,
      rawDataSize,
      fullIxDataSize,
    };
  };

  // Removed deprecated functions:
  // - measureActualTxSize (replaced by buildAndMeasureTxSize)
  // - trySendTransaction (no longer used - binary search uses serialize().length only)

  /**
   * Binary search to find maximum target accounts using serialize().length as oracle
   * @param fixedFullIxDataSize - Fixed full instruction data size to use
   * @param isSpl - Whether this is SPL execute
   */
  const findMaxTargetAccounts = async (
    fixedFullIxDataSize: number,
    isSpl: boolean = false
  ): Promise<{
    dummyAccounts: number;
    actualTargetAccounts: number;
    rawDataSize: number;
    fullIxDataSize: number;
    txSize: number;
  }> => {
    let left = 3; // Minimum: counter + authority + 1 dummy = 3 actual
    let right = 40; // Search up to 40 actual target accounts
    let maxValid = {
      dummyAccounts: 0,
      actualTargetAccounts: 0,
      rawDataSize: 0,
      fullIxDataSize: 0,
      txSize: 0,
    };

    while (left <= right) {
      const mid = Math.floor((left + right) / 2);
      const result = await buildAndMeasureTxSize(
        mid,
        fixedFullIxDataSize,
        isSpl
      );
      if (result.txSize <= 1232) {
        maxValid = result;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return maxValid;
  };

  /**
   * Binary search to find maximum ixData size using serialize().length as oracle
   * @param fixedTargetAccounts - Fixed target account count to use
   * @param isSpl - Whether this is SPL execute
   */
  const findMaxIxDataSize = async (
    fixedTargetAccounts: number,
    isSpl: boolean = false
  ): Promise<{
    dummyAccounts: number;
    actualTargetAccounts: number;
    rawDataSize: number;
    fullIxDataSize: number;
    txSize: number;
  }> => {
    let left = 0; // Start from 0 (raw data can be 0, full = 20)
    let right = 600; // Search up to 600 bytes full instruction
    let maxValid = {
      dummyAccounts: 0,
      actualTargetAccounts: 0,
      rawDataSize: 0,
      fullIxDataSize: 0,
      txSize: 0,
    };

    while (left <= right) {
      const mid = Math.floor((left + right) / 2);
      const result = await buildAndMeasureTxSize(
        fixedTargetAccounts,
        mid,
        isSpl
      );
      if (result.txSize <= 1232) {
        maxValid = result;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return maxValid;
  };

  // Test SOL execute limits (using serialize().length as authoritative oracle)
  console.log(
    `\n📊 SOL Execute (finalizeUniversalTx) - Finding maximum capacity...`
  );

  // First find max accounts with a reasonable ix_data size (70 bytes = 50 raw + 20 overhead)
  const maxSolByAccounts = await findMaxTargetAccounts(70, false);
  // Then find max ix_data with that account count
  const maxSolByIxData = await findMaxIxDataSize(
    maxSolByAccounts.actualTargetAccounts,
    false
  );

  // Use the combination that gives the best result
  const maxSolResult =
    maxSolByIxData.txSize <= 1232 ? maxSolByIxData : maxSolByAccounts;

  console.log(
    `   ✅ SOL MAX: dummy=${maxSolResult.dummyAccounts} targetN=${maxSolResult.actualTargetAccounts} raw=${maxSolResult.rawDataSize} full=${maxSolResult.fullIxDataSize} txSize=${maxSolResult.txSize}`
  );

  // Test SPL execute limits (using serialize().length as authoritative oracle)
  console.log(
    `\n📊 SPL Execute (finalizeUniversalTx) - Finding maximum capacity...`
  );

  // First find max accounts with a reasonable ix_data size (70 bytes = 50 raw + 20 overhead)
  const maxSplByAccounts = await findMaxTargetAccounts(70, true);
  // Then find max ix_data with that account count
  const maxSplByIxData = await findMaxIxDataSize(
    maxSplByAccounts.actualTargetAccounts,
    true
  );

  // Use the combination that gives the best result
  const maxSplResult =
    maxSplByIxData.txSize <= 1232 ? maxSplByIxData : maxSplByAccounts;

  console.log(
    `   ✅ SPL MAX: dummy=${maxSplResult.dummyAccounts} targetN=${maxSplResult.actualTargetAccounts} raw=${maxSplResult.rawDataSize} full=${maxSplResult.fullIxDataSize} txSize=${maxSplResult.txSize}`
  );

  // Confirmation: Send real transactions (max-fit and first-over-limit)
  console.log(
    `\n🧪 Confirmation: Sending real transactions to verify limits...`
  );

  // Test 1: Send max-fit SOL transaction (should succeed)
  console.log(
    `\n   Test 1: SOL max-fit (dummy=${maxSolResult.dummyAccounts} targetN=${maxSolResult.actualTargetAccounts} full=${maxSolResult.fullIxDataSize} txSize=${maxSolResult.txSize}) - should succeed`
  );
  const tssAccountHeavy: any = await (program.account as any).tssPda.fetch(
    tssPda
  );
  const heavyTxId = anchor.web3.Keypair.generate().publicKey.toBytes();
  const heavySender = Buffer.alloc(20, 0xaa);
  const heavyCea = getCeaAuthorityPda(Array.from(heavySender));

  // Create dummy accounts using measured count
  const dummyAccounts = Array.from({ length: maxSolResult.dummyAccounts }, () =>
    Keypair.generate()
  );
  const operationId = 999999;
  // Use measured rawDataSize from maxSolResult
  const largeData = Buffer.alloc(maxSolResult.rawDataSize, 0xaa);

  const batchIx = await counterProgram.methods
    .batchOperation(new anchor.BN(operationId), largeData)
    .accountsPartial({
      counter: counterPda,
      authority: admin,
    })
    .remainingAccounts(
      dummyAccounts.map((acc) => ({
        pubkey: acc.publicKey,
        isWritable: false, // Dummy accounts - no real requirement, but consistent
        isSigner: false,
      }))
    )
    .instruction();

  const { gasFee: gasFeeHeavy } = await calculateSolExecuteFees(connection);
  const heavyPayloadFields = instructionToPayloadFields({
    instruction: batchIx,
    targetProgram: counterProgram.programId,
  });
  const encodedHeavy = encodeExecutePayload(heavyPayloadFields);
  const decodedHeavy = decodeExecutePayload(encodedHeavy);
  // Use the actual writable flags from the instruction (authentic)
  const heavyAccounts = decodedHeavy.accounts;
  const universalTxIdHeavy = generateUniversalTxId();

  const heavySig = await signTssMessage({
    instruction: TssInstruction.Execute,
    amount: BigInt(0),
    chainId: tssAccountHeavy.chainId,
    additional: buildExecuteAdditionalData(
      universalTxIdHeavy,
      heavyTxId,
      decodedHeavy.targetProgram, // From decoded payload (canonical)
      heavySender,
      heavyAccounts,
      decodedHeavy.ixData,
      gasFeeHeavy
        ),
  });

  const heavyWritableFlags = accountsToWritableFlags(heavyAccounts);
  const counterBeforeHeavy = await counterProgram.account.counter.fetch(
    counterPda
  );

  try {
    const heavyExecTx = await relayerProgram.methods
      .finalizeUniversalTx(
        2, // instruction_id = execute
        Array.from(heavyTxId),
        Array.from(universalTxIdHeavy),
        new anchor.BN(0),
        Array.from(heavySender),
        heavyWritableFlags,
        Buffer.from(batchIx.data),
        new anchor.BN(Number(gasFeeHeavy)),

        new anchor.BN(DEFAULT_DEADLINE.toString()),
        heavySig.signature,
        heavySig.recoveryId,
        heavySig.messageHash
      )
      .accountsPartial({
        caller: relayer,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority: heavyCea,
        tssPda,
        executedSubTx: getExecutedTxPda(heavyTxId),
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
        rateLimitConfig: null,
        tokenRateLimit: null,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(
        heavyAccounts.map((a) => ({
          pubkey: a.pubkey,
          isWritable: a.isWritable,
          isSigner: false,
        }))
      )
      .rpc();

    const counterAfterHeavy = await counterProgram.account.counter.fetch(
      counterPda
    );
    assert.equal(
      counterAfterHeavy.value.toNumber(),
      counterBeforeHeavy.value.toNumber() + operationId,
      "Counter should increment by operation_id"
    );

    console.log(
      `   ✅ Succeeded! Counter: ${counterBeforeHeavy.value.toNumber()} → ${counterAfterHeavy.value.toNumber()}`
    );
  } catch (error: any) {
    console.log(`   ❌ Failed: ${error.message}`);
    throw error;
  }

  // Test 2: Send max-fit SPL transaction (should succeed)
  console.log(
    `\n   Test 2: SPL max-fit (dummy=${maxSplResult.dummyAccounts} targetN=${maxSplResult.actualTargetAccounts} full=${maxSplResult.fullIxDataSize} txSize=${maxSplResult.txSize}) - should succeed`
  );
  const heavyTxIdSpl = anchor.web3.Keypair.generate().publicKey.toBytes();
  const heavySenderSpl = Buffer.alloc(20, 0xbb);
  const heavyCeaSpl = getCeaAuthorityPda(Array.from(heavySenderSpl));
  const heavyCeaAtaSpl = spl.getAssociatedTokenAddressSync(
    mint,
    heavyCeaSpl,
    true,
    spl.TOKEN_PROGRAM_ID,
    spl.ASSOCIATED_TOKEN_PROGRAM_ID
  );

  // Create dummy accounts using measured count
  const dummyAccountsSpl = Array.from(
    { length: maxSplResult.dummyAccounts },
    () => Keypair.generate()
  );
  const operationIdSpl = 888888;
  // Use measured rawDataSize from maxSplResult
  const largeDataSpl = Buffer.alloc(maxSplResult.rawDataSize, 0xbb);

  const batchIxSpl = await counterProgram.methods
    .batchOperation(new anchor.BN(operationIdSpl), largeDataSpl)
    .accountsPartial({
      counter: counterPda,
      authority: admin,
    })
    .remainingAccounts(
      dummyAccountsSpl.map((acc) => ({
        pubkey: acc.publicKey,
        isWritable: false,
        isSigner: false,
      }))
    )
    .instruction();

  const { gasFee: gasFeeHeavySpl } = await calculateSolExecuteFees(connection);
  const heavyPayloadFieldsSpl = instructionToPayloadFields({
    instruction: batchIxSpl,
    targetProgram: counterProgram.programId,
  });
  const encodedHeavySpl = encodeExecutePayload(heavyPayloadFieldsSpl);
  const decodedHeavySpl = decodeExecutePayload(encodedHeavySpl);
  const heavyAccountsSpl = decodedHeavySpl.accounts;
  const universalTxIdHeavySpl = generateUniversalTxId();

  const heavySigSpl = await signTssMessage({
    instruction: TssInstruction.Execute,
    amount: BigInt(0),
    chainId: (await (program.account as any).tssPda.fetch(tssPda)).chainId,
    additional: buildExecuteAdditionalData(
      universalTxIdHeavySpl,
      heavyTxIdSpl,
      decodedHeavySpl.targetProgram, // From decoded payload (canonical)
      heavySenderSpl,
      heavyAccountsSpl,
      decodedHeavySpl.ixData,
      gasFeeHeavySpl,
          mint
    ),
  });

  const heavyWritableFlagsSpl = accountsToWritableFlags(heavyAccountsSpl);
  const counterBeforeHeavySpl = await counterProgram.account.counter.fetch(
    counterPda
  );

  try {
    await relayerProgram.methods
      .finalizeUniversalTx(
        2, // instruction_id = execute
        Array.from(heavyTxIdSpl),
        Array.from(universalTxIdHeavySpl),
        new anchor.BN(0),
        Array.from(heavySenderSpl),
        heavyWritableFlagsSpl,
        Buffer.from(batchIxSpl.data),
        new anchor.BN(Number(gasFeeHeavySpl)),

        new anchor.BN(DEFAULT_DEADLINE.toString()),
        heavySigSpl.signature,
        heavySigSpl.recoveryId,
        heavySigSpl.messageHash
      )
      .accountsPartial({
        caller: relayer,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority: heavyCeaSpl,
        tssPda,
        executedSubTx: getExecutedTxPda(heavyTxIdSpl),
        destinationProgram: counterProgram.programId,
      storedIxData: null,
      storeRefundRecipient: null,
        recipient: null,
        vaultAta: vaultAta.address,
        ceaAta: heavyCeaAtaSpl,
        mint,
        tokenProgram: spl.TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
        recipientAta: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(
        heavyAccountsSpl.map((a) => ({
          pubkey: a.pubkey,
          isWritable: a.isWritable,
          isSigner: false,
        }))
      )
      .rpc();

    const counterAfterHeavySpl = await counterProgram.account.counter.fetch(
      counterPda
    );
    assert.equal(
      counterAfterHeavySpl.value.toNumber(),
      counterBeforeHeavySpl.value.toNumber() + operationIdSpl,
      "Counter should increment by operation_id"
    );
    console.log(
      `   ✅ Succeeded! Counter: ${counterBeforeHeavySpl.value.toNumber()} → ${counterAfterHeavySpl.value.toNumber()}`
    );
  } catch (error: any) {
    console.log(`   ❌ Failed: ${error.message}`);
    throw error;
  }

  // Test 3: Send first-over-limit SOL transaction (should fail)
  const overLimitSol = await buildAndMeasureTxSize(
    maxSolResult.actualTargetAccounts + 1,
    70,
    false
  );
  console.log(
    `\n   Test 3: SOL first-over-limit (dummy=${overLimitSol.dummyAccounts} targetN=${overLimitSol.actualTargetAccounts} full=${overLimitSol.fullIxDataSize} txSize=${overLimitSol.txSize}) - should fail`
  );
  if (overLimitSol.txSize > 1232) {
    console.log(
      `   ✅ Correctly detected over limit (${overLimitSol.txSize} > 1232)`
    );
  } else {
    console.log(
      `   ⚠️  Size is within limit, but transaction building may still fail`
    );
  }

  // Test 4: Send first-over-limit SPL transaction (should fail)
  const overLimitSpl = await buildAndMeasureTxSize(
    maxSplResult.actualTargetAccounts + 1,
    70,
    true
  );
  console.log(
    `\n   Test 4: SPL first-over-limit (dummy=${overLimitSpl.dummyAccounts} targetN=${overLimitSpl.actualTargetAccounts} full=${overLimitSpl.fullIxDataSize} txSize=${overLimitSpl.txSize}) - should fail`
  );
  if (overLimitSpl.txSize > 1232) {
    console.log(
      `   ✅ Correctly detected over limit (${overLimitSpl.txSize} > 1232)`
    );
  } else {
    console.log(
      `   ⚠️  Size is within limit, but transaction building may still fail`
    );
  }

  console.log(`\n✅ Transaction size limit tests completed!\n`);

  // 14. Ref-finalize route: store + finalize-by-reference + close
  console.log("14. Testing ref-finalize route (store + finalize-by-reference + close)...");
  try {
    const tssAccountRef: any = await (program.account as any).tssPda.fetch(tssPda);

    const refSubTxId = anchor.web3.Keypair.generate().publicKey.toBytes();
    const refPushAccount = Buffer.alloc(20, 0x44);
    const refCeaAuthority = getCeaAuthorityPda(Array.from(refPushAccount));
    const refExecutedSubTx = getExecutedTxPda(refSubTxId);

    // Build ix_data: counter increment
    const refCounterIx = await counterProgram.methods
      .increment(new anchor.BN(7))
      .accountsPartial({ counter: counterPda, authority: admin })
      .instruction();
    const refIxData = Buffer.from(refCounterIx.data);
    const refIxDataHash = Buffer.from(keccak_256(refIxData), "hex");
    const refStoredIxDataPda = getStoredIxDataPda(refSubTxId, refIxDataHash);

    // Step 1: store_execute_ix_data
    const storeTx = await relayerProgram.methods
      .storeExecuteIxData(
        Array.from(refSubTxId),
        refIxDataHash as unknown as number[],
        refIxData
      )
      .accountsPartial({
        caller: relayer,
        storedIxData: refStoredIxDataPda,
        systemProgram: SystemProgram.programId,
      })
      .rpc();
    console.log(`  ✅ store_execute_ix_data: ${storeTx}`);

    const stored = await (program.account as any).storedIxData.fetch(refStoredIxDataPda);
    assert.equal(
      stored.storeRefundRecipient.toString(),
      relayer.toString(),
      "storeRefundRecipient must be the store caller"
    );
    assert.equal(
      Buffer.from(stored.ixData).toString("hex"),
      refIxData.toString("hex"),
      "Stored ix_data must match"
    );
    console.log("  ✅ StoredIxData PDA verified: storeRefundRecipient and ix_data correct");

    // Step 2: finalize_universal_tx_with_ix_data_ref
    const { gasFee: refGasFee } = await calculateSolExecuteFees(connection);
    const universalTxIdRef = generateUniversalTxId();

    const refRemainingAccounts = [
      { pubkey: counterPda, isWritable: true, isSigner: false },
      { pubkey: admin, isWritable: false, isSigner: false },
    ];
    const refWritableFlags = accountsToWritableFlags(
      refRemainingAccounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable }))
    );

    const refSig = await signTssMessage({
      instruction: TssInstruction.Execute,
      amount: BigInt(0),
      chainId: tssAccountRef.chainId,
      additional: buildExecuteAdditionalData(
        universalTxIdRef,
        refSubTxId,
        counterProgram.programId,
        refPushAccount,
        refRemainingAccounts.map((a) => ({
          pubkey: a.pubkey,
          isWritable: a.isWritable,
        })),
        refIxData,
        refGasFee
      ),
    });

    const pdaLamports = (await connection.getAccountInfo(refStoredIxDataPda))!.lamports;
    const counterBeforeRef = await counterProgram.account.counter.fetch(counterPda);
    const relayerBalBeforeRef = await connection.getBalance(relayer);

    const refFinalizeTx = await relayerProgram.methods
      .finalizeUniversalTxWithIxDataRef(
        2,
        Array.from(refSubTxId),
        Array.from(universalTxIdRef),
        new anchor.BN(0),
        Array.from(refPushAccount),
        refIxDataHash as unknown as number[],
        refWritableFlags,
        new anchor.BN(Number(refGasFee)),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        refSig.signature,
        refSig.recoveryId,
        refSig.messageHash
      )
      .accountsPartial({
        caller: relayer,
        config: configPda,
        vaultSol: vaultPda,
        ceaAuthority: refCeaAuthority,
        tssPda,
        executedSubTx: refExecutedSubTx,
        destinationProgram: counterProgram.programId,
        storedIxData: refStoredIxDataPda,
        storeRefundRecipient: relayer,
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
      .remainingAccounts(refRemainingAccounts)
      .rpc();
    console.log(`  ✅ finalize_universal_tx_with_ix_data_ref: ${refFinalizeTx}`);

    const counterAfterRef = await counterProgram.account.counter.fetch(counterPda);
    assert.equal(
      counterAfterRef.value.toNumber(),
      counterBeforeRef.value.toNumber() + 7,
      "Counter must increment by 7"
    );
    console.log(
      `  ✅ Counter incremented: ${counterBeforeRef.value.toNumber()} → ${counterAfterRef.value.toNumber()}`
    );

    const executedSubTxInfo = await connection.getAccountInfo(refExecutedSubTx);
    assert.isNotNull(executedSubTxInfo, "ExecutedSubTx PDA must exist (replay protection)");
    console.log("  ✅ ExecutedSubTx PDA exists (replay protection active)");

    // StoredIxData PDA is auto-closed by finalize
    const storedAfterFinalize = await connection.getAccountInfo(refStoredIxDataPda);
    assert.isNull(storedAfterFinalize, "StoredIxData PDA must be auto-closed by finalize");
    console.log("  ✅ StoredIxData PDA auto-closed by finalize, rent returned to storeRefundRecipient");

    // Relayer (same account for store + finalize) receives: SIGNATURE_FEE + PDA rent.
    // Allow compute fee tolerance of ~0.001 SOL.
    const relayerBalAfterRef = await connection.getBalance(relayer);
    const relayerNet = relayerBalAfterRef - relayerBalBeforeRef;
    const expectedMin = Number(SIGNATURE_FEE_LAMPORTS) + pdaLamports - 100_000;
    assert.isAtLeast(relayerNet, expectedMin, `Relayer net (${relayerNet}) should be at least SIGNATURE_FEE + PDA rent - compute buffer`);
    console.log(`  ✅ Relayer net change: ${relayerNet} lamports (SIGNATURE_FEE=${SIGNATURE_FEE_LAMPORTS} + PDA rent=${pdaLamports})`);

    await parseAndPrintEvents(refFinalizeTx, "finalize_universal_tx_with_ix_data_ref events");

    // 14.4 Orphan recovery — simulate UV crash, recover PDA via getProgramAccounts
    console.log("  14.4 Testing orphan PDA recovery via getProgramAccounts...");
    const orphanSubTxId = anchor.web3.Keypair.generate().publicKey.toBytes();
    const orphanCounterIx = await counterProgram.methods
      .increment(new anchor.BN(1))
      .accountsPartial({ counter: counterPda, authority: admin })
      .instruction();
    const orphanIxData = Buffer.from(orphanCounterIx.data);
    const orphanIxDataHash = Buffer.from(keccak_256(orphanIxData), "hex");
    const orphanStoredPda = getStoredIxDataPda(orphanSubTxId, orphanIxDataHash);

    await relayerProgram.methods
      .storeExecuteIxData(
        Array.from(orphanSubTxId),
        orphanIxDataHash as unknown as number[],
        orphanIxData
      )
      .accountsPartial({
        caller: relayer,
        storedIxData: orphanStoredPda,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // UV "crashes" — sub_tx_id lost. Recover by scanning chain.
    const discriminatorHex = require("crypto")
      .createHash("sha256")
      .update("account:StoredIxData")
      .digest("hex")
      .slice(0, 16);
    const discriminator = Buffer.from(discriminatorHex, "hex").slice(0, 8);
    const STORE_REFUND_RECIPIENT_OFFSET = 8 + 1 + 32; // disc + bump + sub_tx_id

    const discovered = await connection.getProgramAccounts(PROGRAM_ID, {
      filters: [
        { memcmp: { offset: 0, bytes: anchor.utils.bytes.bs58.encode(discriminator) } },
        { memcmp: { offset: STORE_REFUND_RECIPIENT_OFFSET, bytes: relayer.toBase58() } },
      ],
    });
    assert.isAtLeast(discovered.length, 1, "Must discover at least one orphaned PDA");
    const orphan = discovered.find((a) => a.pubkey.equals(orphanStoredPda));
    assert.isNotNull(orphan, "Orphaned PDA must be discoverable on-chain");
    console.log(`  ✅ Discovered ${discovered.length} orphaned PDA(s) via getProgramAccounts`);

    await relayerProgram.methods
      .closeStoredIxData()
      .accountsPartial({
        caller: relayer,
        storedIxData: orphan!.pubkey,
        storeRefundRecipient: relayer,
        executedSubTx: null,
      })
      .rpc();

    assert.isNull(
      await connection.getAccountInfo(orphanStoredPda),
      "Orphaned PDA must be closed"
    );
    console.log("  ✅ Orphaned PDA recovered and closed without local state");
  } catch (error: any) {
    console.log(`❌ Ref-finalize route test failed: ${error.message}`);
    throw error;
  }
  console.log("✅ Ref-finalize route test completed!\n");

  // 15. Test revert function with real TSS signature
  console.log("15. Testing revert function with real TSS signature...");

  // Test revert function with real TSS signature
  try {
    // Get TSS account info
    const tssAccount: any = await (program.account as any).tssPda.fetch(tssPda);
    console.log(`TSS chain ID: ${tssAccount.chainId}`);

    // Generate sub_tx_id for revert (use crypto for proper randomness)
    // Keep generating until we get a unique sub_tx_id (account doesn't exist)
    let txIdRevert: number[];
    let executedTxPdaRevert: PublicKey;
    let attempts = 0;
    do {
      txIdRevert = Array.from(
        anchor.web3.Keypair.generate().publicKey.toBuffer()
      );
      [executedTxPdaRevert] = PublicKey.findProgramAddressSync(
        [Buffer.from("executed_sub_tx"), Buffer.from(txIdRevert)],
        program.programId
      );
      attempts++;
      if (attempts > 10) {
        throw new Error(
          "Could not generate unique sub_tx_id for revert after 10 attempts"
        );
      }
    } while ((await connection.getAccountInfo(executedTxPdaRevert)) !== null);

    // Create real message hash for revert withdraw (instruction_id = 3)
    const instructionId = 3;
    const amount = 1000000; // 0.001 SOL
    const revertGasFee = 1000000; // 0.001 SOL gas fee for revert
    const chainIdString = tssAccount.chainId; // String: Solana cluster pubkey

    // Generate universal_tx_id for revert
    const universalTxIdRevert = generateUniversalTxId();

    // Build message: PUSH_CHAIN_SVM + instruction_id + chain_id + amount + sub_tx_id + universal_tx_id + recipient + gas_fee
    // No push_account for revert functions
    const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
    const instructionIdBE = Buffer.from([instructionId]);
    const chainIdBytes = Buffer.from(chainIdString, "utf8"); // UTF-8 bytes of cluster pubkey string
    const amountBE = Buffer.alloc(8);
    amountBE.writeBigUInt64BE(BigInt(amount));
    const revertMsg = Buffer.from("test_revert");
    const revertAdditional = buildRevertAdditionalData(
      new Uint8Array(txIdRevert),
      new Uint8Array(universalTxIdRevert),
      admin,
      revertMsg,
      BigInt(revertGasFee)
    );

    // Order matches revert_universal_tx.rs: PREFIX || instruction_id || chain_id || deadline (i64 BE) || amount || additional_data
    const deadlineBuf = Buffer.alloc(8);
    deadlineBuf.writeBigInt64BE(DEFAULT_DEADLINE);
    const messageData = Buffer.concat([
      PREFIX,
      instructionIdBE,
      chainIdBytes,
      deadlineBuf,
      amountBE,
      ...revertAdditional.map((item) => Buffer.from(item)),
    ]);

    // Hash with keccak (same as program)
    const messageHashHex = keccak_256(messageData);
    const messageHash = Buffer.from(messageHashHex, "hex");
    console.log(`Message data: ${messageData.toString("hex")}`);
    console.log(`Message hash: ${messageHashHex}`);

    // Sign with ETH private key (same as other TSS functions)
    const priv = (
      process.env.TSS_PRIVKEY ||
      process.env.ETH_PRIVATE_KEY ||
      process.env.PRIVATE_KEY ||
      ""
    ).replace(/^0x/, "");
    if (!priv) throw new Error("Missing TSS_PRIVKEY/PRIVATE_KEY in .env");

    const sig = await secp.sign(messageHash, priv, {
      recovered: true,
      der: false,
    });
    const signature: Uint8Array = sig[0];
    let recoveryId: number = sig[1]; // 0 or 1

    await program.methods
      .revertUniversalTx(
        txIdRevert,
        Array.from(universalTxIdRevert), // Use same universal_tx_id from message hash
        new anchor.BN(amount),
        {
          revertRecipient: admin,
          revertMsg,
        },
        new anchor.BN(revertGasFee),
        new anchor.BN(DEFAULT_DEADLINE.toString()),
        Array.from(signature),
        recoveryId,
        Array.from(messageHash)
      )
      .accountsPartial({
        config: configPda,
        vault: vaultPda,
        feeVault: feeVaultPda,
        tssPda: tssPda,
        recipient: admin,
        executedSubTx: executedTxPdaRevert,
        caller: admin, // The caller/relayer who pays for the transaction
        systemProgram: SystemProgram.programId,
        tokenVault: null,
        recipientTokenAccount: null,
        tokenMint: null,
        tokenProgram: null,
        associatedTokenProgram: null,
        rent: null,
      })
      .signers([adminKeypair])
      .rpc();

    console.log("✅ revertWithdraw function working with real TSS signature!");
  } catch (error) {
    console.log(`❌ revertWithdraw failed: ${error.message}`);
  }

  // ===========================================================================
  // 16. Deadline enforcement tests
  // ===========================================================================
  console.log("\n16. Testing deadline enforcement on devnet...");

  const PAST_DEADLINE = BigInt(1); // Unix epoch 1970 — always expired

  // ── 16.1 finalize_universal_tx: expired deadline → SignatureExpired ────────
  {
    const subTxId16a = Array.from(anchor.web3.Keypair.generate().publicKey.toBuffer());
    const universalTxId16a = generateUniversalTxId();
    const pushAccount16a = Array.from(anchor.web3.Keypair.generate().publicKey.toBuffer()).slice(0, 20);
    const tssAccount16: any = await (program.account as any).tssPda.fetch(tssPda);

    const sig16a = await signTssMessage({
      instruction: TssInstruction.Withdraw,
      amount: BigInt(LAMPORTS_PER_SOL),
      chainId: tssAccount16.chainId,
      deadline: PAST_DEADLINE,
      additional: buildWithdrawAdditionalData(
        new Uint8Array(universalTxId16a),
        new Uint8Array(subTxId16a),
        new Uint8Array(pushAccount16a),
        PublicKey.default,
        adminKeypair.publicKey,
        BigInt(1_000_000)
      ),
    });

    const [executedSubTx16a] = PublicKey.findProgramAddressSync(
      [Buffer.from("executed_sub_tx"), Buffer.from(subTxId16a)],
      program.programId
    );

    try {
      await program.methods
        .finalizeUniversalTx(
          1, subTxId16a, Array.from(universalTxId16a),
          new anchor.BN(LAMPORTS_PER_SOL), pushAccount16a,
          Buffer.alloc(0), Buffer.from([]),
          new anchor.BN(1_000_000),
          new anchor.BN(PAST_DEADLINE.toString()),
          Array.from(sig16a.signature), sig16a.recoveryId, Array.from(sig16a.messageHash)
        )
        .accountsPartial({
          caller: admin, config: configPda, vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount16a), tssPda,
          executedSubTx: executedSubTx16a,
          destinationProgram: SystemProgram.programId,
          storedIxData: null, storeRefundRecipient: null,
          recipient: admin,
          vaultAta: null, ceaAta: null, mint: null, tokenProgram: null,
          rent: null, associatedTokenProgram: null, recipientAta: null,
          rateLimitConfig: null, tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair]).rpc();
      throw new Error("Should have been rejected");
    } catch (e: any) {
      if (e.message?.includes("SignatureExpired")) {
        console.log("  ✅ 16.1 Expired finalize deadline rejected (SignatureExpired)");
      } else {
        throw new Error(`16.1 FAILED — expected SignatureExpired, got: ${e.message}`);
      }
    }
  }

  // ── 16.2 finalize_universal_tx: tampered deadline → MessageHashMismatch ────
  {
    const subTxId16b = Array.from(anchor.web3.Keypair.generate().publicKey.toBuffer());
    const universalTxId16b = generateUniversalTxId();
    const pushAccount16b = Array.from(anchor.web3.Keypair.generate().publicKey.toBuffer()).slice(0, 20);
    const tssAccount16: any = await (program.account as any).tssPda.fetch(tssPda);

    // Sign with DEFAULT_DEADLINE
    const sig16b = await signTssMessage({
      instruction: TssInstruction.Withdraw,
      amount: BigInt(LAMPORTS_PER_SOL),
      chainId: tssAccount16.chainId,
      additional: buildWithdrawAdditionalData(
        new Uint8Array(universalTxId16b),
        new Uint8Array(subTxId16b),
        new Uint8Array(pushAccount16b),
        PublicKey.default,
        adminKeypair.publicKey,
        BigInt(1_000_000)
      ),
    });

    const [executedSubTx16b] = PublicKey.findProgramAddressSync(
      [Buffer.from("executed_sub_tx"), Buffer.from(subTxId16b)],
      program.programId
    );

    // Submit with a different (still future) deadline — hash won't match
    const WRONG_DEADLINE = DEFAULT_DEADLINE + BigInt(1);
    try {
      await program.methods
        .finalizeUniversalTx(
          1, subTxId16b, Array.from(universalTxId16b),
          new anchor.BN(LAMPORTS_PER_SOL), pushAccount16b,
          Buffer.alloc(0), Buffer.from([]),
          new anchor.BN(1_000_000),
          new anchor.BN(WRONG_DEADLINE.toString()),
          Array.from(sig16b.signature), sig16b.recoveryId, Array.from(sig16b.messageHash)
        )
        .accountsPartial({
          caller: admin, config: configPda, vaultSol: vaultPda,
          ceaAuthority: getCeaAuthorityPda(pushAccount16b), tssPda,
          executedSubTx: executedSubTx16b,
          destinationProgram: SystemProgram.programId,
          storedIxData: null, storeRefundRecipient: null,
          recipient: admin,
          vaultAta: null, ceaAta: null, mint: null, tokenProgram: null,
          rent: null, associatedTokenProgram: null, recipientAta: null,
          rateLimitConfig: null, tokenRateLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair]).rpc();
      throw new Error("Should have been rejected");
    } catch (e: any) {
      if (e.message?.includes("MessageHashMismatch")) {
        console.log("  ✅ 16.2 Tampered deadline rejected (MessageHashMismatch)");
      } else {
        throw new Error(`16.2 FAILED — expected MessageHashMismatch, got: ${e.message}`);
      }
    }
  }

  // ── 16.3 revert_universal_tx: expired deadline → SignatureExpired ──────────
  {
    const subTxId16c = Array.from(anchor.web3.Keypair.generate().publicKey.toBuffer());
    const universalTxId16c = generateUniversalTxId();
    const tssAccount16: any = await (program.account as any).tssPda.fetch(tssPda);
    const revertMsg16c = Buffer.from("deadline-test-revert");

    const sig16c = await signTssMessage({
      instruction: TssInstruction.Revert,
      amount: BigInt(1_000_000),
      chainId: tssAccount16.chainId,
      deadline: PAST_DEADLINE,
      additional: buildRevertAdditionalData(
        new Uint8Array(subTxId16c),
        new Uint8Array(universalTxId16c),
        adminKeypair.publicKey,
        revertMsg16c,
        BigInt(1_000_000)
      ),
    });

    const [executedSubTx16c] = PublicKey.findProgramAddressSync(
      [Buffer.from("executed_sub_tx"), Buffer.from(subTxId16c)],
      program.programId
    );

    try {
      await program.methods
        .revertUniversalTx(
          subTxId16c, Array.from(universalTxId16c),
          new anchor.BN(1_000_000),
          { revertRecipient: adminKeypair.publicKey, revertMsg: revertMsg16c },
          new anchor.BN(1_000_000),
          new anchor.BN(PAST_DEADLINE.toString()),
          Array.from(sig16c.signature), sig16c.recoveryId, Array.from(sig16c.messageHash)
        )
        .accountsPartial({
          config: configPda, vault: vaultPda, feeVault: feeVaultPda, tssPda,
          recipient: admin, executedSubTx: executedSubTx16c,
          caller: admin, systemProgram: SystemProgram.programId,
          tokenVault: null, recipientTokenAccount: null, tokenMint: null, tokenProgram: null,
          associatedTokenProgram: null, rent: null,
        })
        .signers([adminKeypair]).rpc();
      throw new Error("Should have been rejected");
    } catch (e: any) {
      if (e.message?.includes("SignatureExpired")) {
        console.log("  ✅ 16.3 Expired revert deadline rejected (SignatureExpired)");
      } else {
        throw new Error(`16.3 FAILED — expected SignatureExpired, got: ${e.message}`);
      }
    }
  }

  console.log("✅ All deadline enforcement checks passed on devnet!\n");

  console.log("All tests completed successfully!");
}

run().catch((e) => {
  console.error("Test failed:", e);
  process.exit(1);
});
