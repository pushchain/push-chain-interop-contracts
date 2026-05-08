// Load environment variables FIRST before any other imports that might use them
import * as dotenv from "dotenv";
dotenv.config({ path: "../.env" });
dotenv.config();

import * as anchor from "@coral-xyz/anchor";
import {
  PublicKey,
  LAMPORTS_PER_SOL,
  Keypair,
  SystemProgram,
  TransactionMessage,
  VersionedTransaction,
  Transaction,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { assert } from "chai";
import { AltHelper } from "./alt-helper";
import { signTssMessage, buildWithdrawAdditionalData, TssInstruction, generateUniversalTxId } from "../tests/helpers/tss";

/**
 * ALT Integration Test Script
 *
 * This script demonstrates and validates ALT usage for finalize_universal_tx on devnet.
 *
 * Prerequisites:
 * - ALTs must be created via scripts/create-protocol-alt.ts and scripts/create-token-alt.ts
 * - Config files: alt-config-protocol.json and alt-config-tokens.json
 * - Programs already deployed on devnet
 *
 * What this tests:
 * 1. Loading ALTs from config files
 * 2. Verifying ALT account contents
 * 3. Comparing transaction sizes (with vs without ALTs)
 * 4. Using AltHelper for simplified ALT management
 */

// Devnet program IDs (update these if redeployed)
const PROGRAM_ID = new PublicKey("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");

const CONFIG_SEED = Buffer.from("config");
const TSS_SEED = Buffer.from("final_tss_pda");
const VAULT_SEED = Buffer.from("vault");
const CEA_SEED = Buffer.from("push_identity");
const EXECUTED_SUB_TX_SEED = Buffer.from("executed_sub_tx");

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("./clean-user-keypair.json", "utf8")))
);

// Set up connection and provider (devnet)
const connection = new anchor.web3.Connection("https://api.devnet.solana.com", "confirmed");
const provider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
  commitment: "confirmed",
});
anchor.setProvider(provider);

// Load ALT config files
interface ProtocolAltConfig {
  protocolStaticALT: string;
  accounts: string[];
  network: string;
  createdAt: string;
}

interface TokenAltConfig {
  network: string;
  tokens: Array<{
    symbol: string;
    mint: string;
    altAddress: string;
    accounts: string[];
  }>;
  createdAt: string;
}

const TARGET_SPL_SYMBOL = "USDT";

let protocolAltConfig: ProtocolAltConfig;
let tokenAltConfig: TokenAltConfig;

try {
  protocolAltConfig = JSON.parse(fs.readFileSync("./alt-config-protocol.json", "utf8"));
  console.log("✅ Loaded Protocol ALT config:", protocolAltConfig.protocolStaticALT);
} catch (error) {
  console.error("❌ Failed to load alt-config-protocol.json");
  console.error("   Run: npx ts-node scripts/create-protocol-alt.ts");
  process.exit(1);
}

try {
  tokenAltConfig = JSON.parse(fs.readFileSync("./alt-config-tokens.json", "utf8"));
  console.log(`✅ Loaded Token ALT config: ${tokenAltConfig.tokens.length} tokens`);
} catch (error) {
  console.error("❌ Failed to load alt-config-tokens.json");
  console.error("   Run: npx ts-node scripts/create-token-alt.ts");
  process.exit(1);
}

const protocolAltAddress = new PublicKey(protocolAltConfig.protocolStaticALT);
const tokenAlts = new Map<string, PublicKey>();
const rpcNetwork = connection.rpcEndpoint.includes("devnet") ? "devnet" : "mainnet";
const selectedTokenConfigs = tokenAltConfig.tokens.filter(
  (token) => token.symbol.toUpperCase() === TARGET_SPL_SYMBOL
);

if (selectedTokenConfigs.length === 0) {
  const available = tokenAltConfig.tokens.map((t) => t.symbol).join(", ");
  throw new Error(
    `No '${TARGET_SPL_SYMBOL}' entry found in alt-config-tokens.json. Available: ${available || "none"}`
  );
}
if (selectedTokenConfigs.length > 1) {
  console.warn(
    `⚠️  Found ${selectedTokenConfigs.length} '${TARGET_SPL_SYMBOL}' entries, using all matching entries.`
  );
}

if (protocolAltConfig.network !== rpcNetwork) {
  console.warn(
    `⚠️  Protocol ALT config network is '${protocolAltConfig.network}' but RPC looks like '${rpcNetwork}'`
  );
}
if (tokenAltConfig.network !== rpcNetwork) {
  console.warn(
    `⚠️  Token ALT config network is '${tokenAltConfig.network}' but RPC looks like '${rpcNetwork}'`
  );
}

for (const token of selectedTokenConfigs) {
  tokenAlts.set(token.mint, new PublicKey(token.altAddress));
}

// PDA helpers
function getCeaAuthorityPda(pushAccount: Uint8Array | number[]): PublicKey {
  return PublicKey.findProgramAddressSync(
    [CEA_SEED, Buffer.from(pushAccount)],
    PROGRAM_ID
  )[0];
}

function getExecutedTxPda(txIdBytes: Uint8Array): PublicKey {
  return PublicKey.findProgramAddressSync(
    [EXECUTED_SUB_TX_SEED, Buffer.from(txIdBytes)],
    PROGRAM_ID
  )[0];
}

async function main() {
  console.log("\n🔍 ALT Integration Test - Devnet\n");
  console.log("=".repeat(60));

  // Test 1: Verify Protocol ALT
  console.log("\n📋 Test 1: Verify Protocol ALT");
  console.log("-".repeat(60));
  const deactivationSentinel = 18446744073709551615n; // u64::MAX => active

  const protocolAlt = await connection.getAddressLookupTable(protocolAltAddress);

  if (!protocolAlt.value) {
    console.error("❌ Protocol ALT not found on-chain:", protocolAltAddress.toBase58());
    console.error("   Run: npx ts-node scripts/create-protocol-alt.ts");
    process.exit(1);
  }

  if (protocolAlt.value.state.deactivationSlot !== deactivationSentinel) {
    console.error(`❌ Protocol ALT is DEACTIVATED at slot ${protocolAlt.value.state.deactivationSlot}!`);
    console.error("   Create a new ALT and update alt-config-protocol.json");
    process.exit(1);
  }

  console.log("✅ Protocol ALT verified:");
  console.log(`   Address: ${protocolAltAddress.toBase58()}`);
  console.log(`   Accounts: ${protocolAlt.value.state.addresses.length}`);
  console.log(`   Authority: ${protocolAlt.value.state.authority?.toBase58()}`);

  // Verify expected accounts
  const [configPda] = PublicKey.findProgramAddressSync([CONFIG_SEED], PROGRAM_ID);
  const [tssPda] = PublicKey.findProgramAddressSync([TSS_SEED], PROGRAM_ID);
  const [vaultSol] = PublicKey.findProgramAddressSync([VAULT_SEED], PROGRAM_ID);

  const expectedProtocolAccounts = [
    configPda,
    tssPda,
    vaultSol,
    SystemProgram.programId,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID,
    anchor.web3.SYSVAR_RENT_PUBKEY,
  ];

  console.log("\n   Expected accounts:");
  for (let i = 0; i < expectedProtocolAccounts.length; i++) {
    const expected = expectedProtocolAccounts[i].toBase58();
    const actual = protocolAlt.value.state.addresses[i]?.toBase58();
    const match = expected === actual;
    console.log(`   ${i}. ${match ? "✅" : "❌"} ${expected}`);
    if (!match && actual) {
      console.log(`      (actual: ${actual})`);
    }
  }

  // Test 2: Verify Token ALTs
  console.log("\n📋 Test 2: Verify Token ALTs");
  console.log("-".repeat(60));

  for (const [mintStr, altAddress] of tokenAlts.entries()) {
    const tokenInfo = tokenAltConfig.tokens.find(t => t.mint === mintStr);
    if (!tokenInfo) continue;

    console.log(`\n   Token: ${tokenInfo.symbol}`);
    console.log(`   Mint: ${mintStr}`);
    console.log(`   ALT: ${altAddress.toBase58()}`);

    const tokenAlt = await connection.getAddressLookupTable(altAddress);

    if (!tokenAlt.value) {
      console.error(`   ❌ Token ALT not found on-chain`);
      continue;
    }

    if (tokenAlt.value.state.deactivationSlot !== deactivationSentinel) {
      console.error(`   ❌ Token ALT is DEACTIVATED at slot ${tokenAlt.value.state.deactivationSlot}`);
      continue;
    }

    console.log(`   ✅ ALT verified: ${tokenAlt.value.state.addresses.length} accounts`);

    // Verify expected accounts (mint + vault_ata)
    const mintPubkey = new PublicKey(mintStr);
    const vaultAta = getAssociatedTokenAddressSync(mintPubkey, vaultSol, true);

    const expectedTokenAccounts = [mintPubkey, vaultAta];

    for (let i = 0; i < expectedTokenAccounts.length; i++) {
      const expected = expectedTokenAccounts[i].toBase58();
      const actual = tokenAlt.value.state.addresses[i]?.toBase58();
      const match = expected === actual;
      console.log(`   ${i}. ${match ? "✅" : "❌"} ${expected}`);
      if (!match && actual) {
        console.log(`      (actual: ${actual})`);
      }
    }
  }

  // Test 3: SOL Withdraw — submit WITHOUT ALT then WITH ALT, compare real tx sizes
  console.log("\n📋 Test 3: SOL Withdraw — submit with and without ALT");
  console.log("-".repeat(60));

  // Load program
  const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
  const program = new Program(idl as anchor.Idl, provider);

  const pushAccount: number[] = Array(20).fill(1);
  const amountBn = new anchor.BN(0.001 * LAMPORTS_PER_SOL);
  const gasFeeBn = new anchor.BN(0.001 * LAMPORTS_PER_SOL);
  const amountBig = BigInt(amountBn.toString());
  const gasFeeBig = BigInt(gasFeeBn.toString());
  const recipient = provider.wallet.publicKey; // withdraw back to admin

  const [ceaAuthority] = PublicKey.findProgramAddressSync(
    [CEA_SEED, Buffer.from(pushAccount)],
    PROGRAM_ID
  );

  // Fetch TSS chainId once
  const tssAccount = await (program.account as any).tssPda.fetch(tssPda);
  const tssChainId: string = tssAccount.chainId;

  // Helper: build a fresh signed withdraw instruction (new txId each call)
  const buildWithdrawInstruction = async () => {
    const freshTxId = Array.from(Keypair.generate().publicKey.toBytes());
    const freshUniversalTxId = Array.from(Keypair.generate().publicKey.toBytes());
    const [freshExecutedTx] = PublicKey.findProgramAddressSync(
      [EXECUTED_SUB_TX_SEED, Buffer.from(freshTxId)],
      PROGRAM_ID
    );

    const additional = buildWithdrawAdditionalData(
      Buffer.from(freshUniversalTxId),
      Buffer.from(freshTxId),
      Buffer.from(pushAccount),
      PublicKey.default, // SOL
      recipient,
      gasFeeBig
    );

    const { signature, recoveryId, messageHash } = await signTssMessage({
      instruction: TssInstruction.Withdraw,
      amount: amountBig,
      additional,
      chainId: tssChainId,
    });

    const ix = await program.methods
      .finalizeUniversalTx(
        1,
        Array.from(freshTxId),
        Array.from(freshUniversalTxId),
        amountBn,
        pushAccount,
        Buffer.alloc(0),
        Buffer.alloc(0),
        gasFeeBn,

        Array.from(signature),
        recoveryId,
        Array.from(messageHash),
      )
      .accountsPartial({
        caller: provider.wallet.publicKey,
        config: configPda,
        vaultSol,
        ceaAuthority,
        tssPda,
        executedSubTx: freshExecutedTx,
        systemProgram: SystemProgram.programId,
        destinationProgram: SystemProgram.programId,
        recipient,
        vaultAta: null,
        ceaAta: null,
        mint: null,
        tokenProgram: null,
        rent: null,
        associatedTokenProgram: null,
        recipientAta: null,
        rateLimitConfig: null,
        tokenRateLimit: null,
      })
      .instruction();

    return ix;
  };

  let solNoAltSize = 0;
  let solAltSize = 0;

  // Submit WITHOUT ALT (legacy v0 with no lookup tables)
  {
    const ix = await buildWithdrawInstruction();
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

    const messageV0 = new TransactionMessage({
      payerKey: provider.wallet.publicKey,
      recentBlockhash: blockhash,
      instructions: [ix],
    }).compileToV0Message([]); // no ALTs

    const versionedTx = new VersionedTransaction(messageV0);
    (provider.wallet as any).signTransaction
      ? await (provider.wallet as any).signTransaction(versionedTx)
      : versionedTx.sign([adminKeypair]);

    solNoAltSize = versionedTx.serialize().length;

    const txSig = await connection.sendTransaction(versionedTx);
    await connection.confirmTransaction({ signature: txSig, blockhash, lastValidBlockHeight }, "confirmed");

    console.log(`\n✅ SOL Withdraw WITHOUT ALT confirmed: ${txSig}`);
    console.log(`   Serialized size: ${solNoAltSize} bytes`);
    console.log(`   Accounts in instruction: ${ix.keys.length}`);
  }

  // Submit WITH Protocol ALT (versioned v0)
  {
    const ix = await buildWithdrawInstruction();
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

    const messageV0 = new TransactionMessage({
      payerKey: provider.wallet.publicKey,
      recentBlockhash: blockhash,
      instructions: [ix],
    }).compileToV0Message([protocolAlt.value]);

    const versionedTx = new VersionedTransaction(messageV0);
    versionedTx.sign([adminKeypair]);

    solAltSize = versionedTx.serialize().length;

    const txSig = await connection.sendTransaction(versionedTx);
    await connection.confirmTransaction({ signature: txSig, blockhash, lastValidBlockHeight }, "confirmed");

    console.log(`\n✅ SOL Withdraw WITH ALT confirmed: ${txSig}`);
    console.log(`   Serialized size: ${solAltSize} bytes`);
    console.log(`   ALTs used: 1 (${protocolAlt.value.state.addresses.length} accounts)`);
  }

  const solSavings = solNoAltSize - solAltSize;
  console.log(`\n📊 SOL Withdraw savings: ${solSavings} bytes (${((solSavings / solNoAltSize) * 100).toFixed(1)}%)`);

  // Test 3b: SPL Withdraw — submit with and without ALT
  if (selectedTokenConfigs.length > 0) {
    console.log("\n📋 Test 3b: SPL Withdraw — submit with and without ALT");
    console.log("-".repeat(60));

    let tokenInfo: TokenAltConfig["tokens"][number] | null = null;
    for (const candidate of selectedTokenConfigs) {
      const candidateMint = new PublicKey(candidate.mint);
      const candidateMintInfo = await connection.getAccountInfo(candidateMint);
      if (candidateMintInfo && candidateMintInfo.owner.equals(TOKEN_PROGRAM_ID)) {
        tokenInfo = candidate;
        break;
      }
      console.warn(
        `⚠️  Skipping token ${candidate.symbol} (${candidate.mint}) - mint is not an SPL mint on this cluster`
      );
    }

    if (!tokenInfo) {
      console.warn("⚠️  Skipping SPL ALT submit test: no valid SPL mint found for current cluster.");
      console.warn("   Recreate token ALTs for this cluster (likely devnet) and retry.");
      console.warn("   Example:");
      console.warn("   ANCHOR_PROVIDER_URL=https://api.devnet.solana.com npx ts-node scripts/create-token-alt.ts");
    } else {
      const mintPubkey = new PublicKey(tokenInfo.mint);
      const vaultAta = getAssociatedTokenAddressSync(mintPubkey, vaultSol, true);
      const ceaAta = getAssociatedTokenAddressSync(mintPubkey, ceaAuthority, true);
      const recipientAta = getAssociatedTokenAddressSync(mintPubkey, recipient, true);

      const tokenAltAddress = tokenAlts.get(tokenInfo.mint);
      const tokenAlt = tokenAltAddress
        ? (await connection.getAddressLookupTable(tokenAltAddress)).value
        : null;

      const buildSplInstruction = async () => {
        const freshTxId = Array.from(Keypair.generate().publicKey.toBytes());
        const freshUniversalTxId = Array.from(Keypair.generate().publicKey.toBytes());
        const freshExecutedTx = getExecutedTxPda(Buffer.from(freshTxId));

        const splAdditional = buildWithdrawAdditionalData(
          Buffer.from(freshUniversalTxId),
          Buffer.from(freshTxId),
          Buffer.from(pushAccount),
          mintPubkey,
          recipient,
          gasFeeBig
        );

        const splSig = await signTssMessage({
          instruction: TssInstruction.Withdraw,
          amount: amountBig,
          additional: splAdditional,
          chainId: tssChainId,
        });

        return program.methods
          .finalizeUniversalTx(
            1,
            Array.from(freshTxId),
            Array.from(freshUniversalTxId),
            amountBn,
            pushAccount,
            Buffer.alloc(0),
            Buffer.alloc(0),
            gasFeeBn,

            Array.from(splSig.signature),
            splSig.recoveryId,
            Array.from(splSig.messageHash),
          )
          .accountsPartial({
            caller: provider.wallet.publicKey,
            config: configPda,
            vaultSol,
            ceaAuthority,
            tssPda,
            executedSubTx: freshExecutedTx,
            systemProgram: SystemProgram.programId,
            destinationProgram: SystemProgram.programId,
            recipient,
            vaultAta,
            ceaAta,
            mint: mintPubkey,
            tokenProgram: TOKEN_PROGRAM_ID,
            rent: anchor.web3.SYSVAR_RENT_PUBKEY,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            recipientAta,
            rateLimitConfig: null,
            tokenRateLimit: null,
          })
          .instruction();
      };

      let splNoAltSize = 0;
      let splAltSize = 0;

      // Submit WITHOUT ALT
      {
        const ix = await buildSplInstruction();
        const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

        const messageV0 = new TransactionMessage({
          payerKey: provider.wallet.publicKey,
          recentBlockhash: blockhash,
          instructions: [ix],
        }).compileToV0Message([]);

        const versionedTx = new VersionedTransaction(messageV0);
        versionedTx.sign([adminKeypair]);
        splNoAltSize = versionedTx.serialize().length;

        const txSig = await connection.sendTransaction(versionedTx);
        await connection.confirmTransaction({ signature: txSig, blockhash, lastValidBlockHeight }, "confirmed");

        console.log(`\n✅ SPL Withdraw WITHOUT ALT confirmed: ${txSig}`);
        console.log(`   Serialized size: ${splNoAltSize} bytes`);
      }

      // Submit WITH Protocol ALT + Token ALT
      {
        const ix = await buildSplInstruction();
        const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

        const alts = tokenAlt ? [protocolAlt.value, tokenAlt] : [protocolAlt.value];

        const messageV0 = new TransactionMessage({
          payerKey: provider.wallet.publicKey,
          recentBlockhash: blockhash,
          instructions: [ix],
        }).compileToV0Message(alts);

        const versionedTx = new VersionedTransaction(messageV0);
        versionedTx.sign([adminKeypair]);
        splAltSize = versionedTx.serialize().length;

        const txSig = await connection.sendTransaction(versionedTx);
        await connection.confirmTransaction({ signature: txSig, blockhash, lastValidBlockHeight }, "confirmed");

        console.log(`\n✅ SPL Withdraw WITH ALT confirmed: ${txSig}`);
        console.log(`   Serialized size: ${splAltSize} bytes`);
        console.log(`   ALTs used: ${alts.length}`);
      }

      const splSavings = splNoAltSize - splAltSize;
      console.log(`\n📊 SPL Withdraw savings: ${splSavings} bytes (${((splSavings / splNoAltSize) * 100).toFixed(1)}%)`);
    }
  }

  // Test 4: AltHelper Usage
  console.log("\n📋 Test 4: Test AltHelper");
  console.log("-".repeat(60));

  const altHelper = new AltHelper(connection);

  // Load ALTs from config files
  altHelper.loadFromConfigFiles("./alt-config-protocol.json", "./alt-config-tokens.json");

  console.log("✅ ALTs loaded into AltHelper");

  // Fetch ALT accounts
  await altHelper.fetchAltAccounts();

  console.log("✅ ALT accounts fetched");

  // Get ALTs for SOL transaction
  const solAlts = altHelper.getAltsForTransaction(null);
  console.log(`\n   SOL transaction: ${solAlts.length} ALT(s)`);

  // Get ALTs for SPL transaction (if we have token ALTs)
  if (selectedTokenConfigs.length > 0) {
    const firstToken = selectedTokenConfigs[0];
    const splAlts = altHelper.getAltsForTransaction(new PublicKey(firstToken.mint));
    console.log(`   SPL transaction (${firstToken.symbol}): ${splAlts.length} ALT(s)`);
  }

  // Estimate savings
  const estimatedSolSavings = altHelper.estimateSavings(null);
  console.log(`\n   Estimated savings:`);
  console.log(`   - SOL: ${estimatedSolSavings} bytes`);

  if (selectedTokenConfigs.length > 0) {
    const firstToken = selectedTokenConfigs[0];
    const estimatedSplSavings = altHelper.estimateSavings(new PublicKey(firstToken.mint));
    console.log(`   - SPL (${firstToken.symbol}): ${estimatedSplSavings} bytes`);
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("✅ ALT Integration Test Complete\n");
  console.log("Summary:");
  console.log(`  - Protocol ALT: ${protocolAlt.value.state.addresses.length} accounts`);
  console.log(`  - Token ALTs used: ${selectedTokenConfigs.length} (${TARGET_SPL_SYMBOL})`);
  console.log(`  - SOL tx savings: ${solNoAltSize - solAltSize} bytes per transaction`);
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Test failed:", error);
    process.exit(1);
  });
