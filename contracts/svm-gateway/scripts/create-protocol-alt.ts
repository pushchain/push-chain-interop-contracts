import {
  Connection,
  Keypair,
  PublicKey,
  AddressLookupTableProgram,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import { AnchorProvider, Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import idl from "../target/idl/universal_gateway.json";
import fs from "fs";

/**
 * Create Protocol Static ALT for finalize_universal_tx
 *
 * This ALT contains accounts that NEVER change across ANY transaction:
 * - gateway_config
 * - tss_pda
 * - vault_sol
 * - system_program
 * - token_program (SPL Token, constant across all tokens)
 * - associated_token_program (constant across all tokens)
 * - rent (sysvar, constant)
 *
 * Net savings: 7 accounts → (7×32) - (32+7) = 224 - 39 = 185 bytes per tx
 */

const PROGRAM_ID = new PublicKey(idl.address);
const CONFIG_SEED = Buffer.from("config");
const TSS_SEED = Buffer.from("tsspda_v2");
const VAULT_SEED = Buffer.from("vault");

const TOKEN_PROGRAM_ID = new PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const ASSOCIATED_TOKEN_PROGRAM_ID = new PublicKey("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
const RENT_SYSVAR = new PublicKey("SysvarRent111111111111111111111111111111111");

async function main() {
  const rpcUrl = process.env.ANCHOR_PROVIDER_URL || "https://api.devnet.solana.com";
  const connection = new Connection(rpcUrl, "confirmed");

  const wallet = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
  );

  const provider = new AnchorProvider(connection, wallet as any, {
    commitment: "confirmed",
  });

  const program = new Program(idl as any, provider) as Program<UniversalGateway>;

  console.log("🔧 Creating Protocol Static ALT for finalize_universal_tx...\n");

  // Derive PDAs
  const [configPda] = PublicKey.findProgramAddressSync(
    [CONFIG_SEED],
    PROGRAM_ID
  );
  const [tssPda] = PublicKey.findProgramAddressSync(
    [TSS_SEED],
    PROGRAM_ID
  );
  const [vaultSol] = PublicKey.findProgramAddressSync(
    [VAULT_SEED],
    PROGRAM_ID
  );

  // Static accounts that NEVER change (including SPL program constants)
  const staticAccounts = [
    configPda,
    tssPda,
    vaultSol,
    SystemProgram.programId,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID,
    RENT_SYSVAR,
  ];

  console.log("📋 Protocol Static Accounts:");
  console.log("  gateway_config:", configPda.toBase58());
  console.log("  tss_pda:", tssPda.toBase58());
  console.log("  vault_sol:", vaultSol.toBase58());
  console.log("  system_program:", SystemProgram.programId.toBase58());
  console.log("  token_program:", TOKEN_PROGRAM_ID.toBase58());
  console.log("  associated_token_program:", ASSOCIATED_TOKEN_PROGRAM_ID.toBase58());
  console.log("  rent:", RENT_SYSVAR.toBase58());
  console.log();

  // Create ALT with retry loop to handle stale slots
  let lookupTableAddress!: PublicKey;
  let sig: string | undefined;

  const maxAttempts = 5;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const slot = await connection.getSlot("confirmed");
      const [createIx, altAddress] = AddressLookupTableProgram.createLookupTable({
        authority: wallet.publicKey,
        payer: wallet.publicKey,
        recentSlot: slot,
      });

      const extendIx = AddressLookupTableProgram.extendLookupTable({
        lookupTable: altAddress,
        authority: wallet.publicKey,
        payer: wallet.publicKey,
        addresses: staticAccounts,
      });

      const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();
      const tx = new Transaction().add(createIx, extendIx);
      tx.recentBlockhash = blockhash;
      tx.feePayer = wallet.publicKey;

      sig = await connection.sendTransaction(tx, [wallet]);
      await connection.confirmTransaction({ signature: sig, blockhash, lastValidBlockHeight });

      lookupTableAddress = altAddress;
      if (attempt > 1) console.log(`✅ Succeeded on attempt ${attempt}`);
      break;
    } catch (error: any) {
      if (error.message?.includes("not a recent slot") && attempt < maxAttempts) {
        console.log(`⚠️  Slot became stale (attempt ${attempt}/${maxAttempts}), retrying...`);
        await new Promise(resolve => setTimeout(resolve, 100));
      } else if (attempt === maxAttempts) {
        throw new Error(`Failed to create ALT after ${maxAttempts} attempts: ${error.message}`);
      } else {
        throw error;
      }
    }
  }

  console.log("📍 ALT address:", lookupTableAddress.toBase58());
  console.log("✅ Protocol Static ALT created!");
  console.log("   Signature:", sig);
  console.log();

  // Wait for ALT to be active (poll up to 10 seconds)
  console.log("⏳ Waiting for ALT to become active...");
  let altAccount;
  for (let i = 0; i < 20; i++) {
    await new Promise(resolve => setTimeout(resolve, 500));
    const result = await connection.getAddressLookupTable(lookupTableAddress);
    if (result.value && result.value.state.addresses.length > 0) {
      altAccount = result;
      console.log(`✅ ALT active after ${(i + 1) * 500}ms`);
      break;
    }
    if (i === 19) {
      console.warn("⚠️  ALT not active after 10 seconds. May need more time.");
    }
  }

  // Verify ALT
  if (altAccount?.value) {
    console.log("✅ ALT verified:");
    console.log("   Addresses:", altAccount.value.state.addresses.length);
    console.log("   Authority:", altAccount.value.state.authority?.toBase58());
    console.log();
  } else {
    console.error("❌ Failed to verify ALT. Check manually:");
    console.error(`   solana address-lookup-table ${lookupTableAddress.toBase58()}`);
  }

  // Save to file — name by program so dummy and main don't overwrite each other
  const KNOWN: Record<string, string> = {
    "DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp": "dummy",
    "CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS": "main",
  };
  const label = KNOWN[PROGRAM_ID.toBase58()] ?? PROGRAM_ID.toBase58().slice(0, 8);

  const altConfig = {
    programId: PROGRAM_ID.toBase58(),
    programLabel: label,
    protocolStaticALT: lookupTableAddress.toBase58(),
    accounts: staticAccounts.map(acc => acc.toBase58()),
    network: rpcUrl.includes("devnet") ? "devnet" : "mainnet",
    createdAt: new Date().toISOString(),
  };

  const outputPath = `./alt-config-protocol-${label}.json`;
  fs.writeFileSync(outputPath, JSON.stringify(altConfig, null, 2));

  console.log("💾 ALT config saved to:", outputPath);
  console.log("   Program:", PROGRAM_ID.toBase58(), `(${label})`);
  console.log();
  console.log("🎉 Done! Use this ALT for ALL finalize_universal_tx transactions.");
  console.log("   Savings: 185 bytes per transaction (7×32 - ALT overhead of 32+7)");
}

main().catch(console.error);
