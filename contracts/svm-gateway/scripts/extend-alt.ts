import {
  Connection,
  Keypair,
  PublicKey,
  AddressLookupTableProgram,
  Transaction,
} from "@solana/web3.js";
import fs from "fs";

/**
 * Extend an existing ALT with additional accounts
 *
 * Usage:
 *   npx ts-node scripts/extend-alt.ts \
 *     --alt <ALT_ADDRESS> \
 *     --accounts <PUBKEY1,PUBKEY2,...>
 *
 * Example:
 *   npx ts-node scripts/extend-alt.ts \
 *     --alt FkX... \
 *     --accounts 11111111111111111111111111111111,TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
 */

async function main() {
  const args = process.argv.slice(2);

  // Parse arguments
  const altIndex = args.indexOf("--alt");
  const accountsIndex = args.indexOf("--accounts");

  if (altIndex === -1 || accountsIndex === -1) {
    console.error("Usage: npx ts-node scripts/extend-alt.ts --alt <ADDRESS> --accounts <PUBKEY1,PUBKEY2>");
    process.exit(1);
  }

  const altAddress = new PublicKey(args[altIndex + 1]);
  const accountsStr = args[accountsIndex + 1];
  const accounts = accountsStr.split(",").map(addr => new PublicKey(addr.trim()));

  console.log("🔧 Extending ALT...");
  console.log("   ALT Address:", altAddress.toBase58());
  console.log("   Adding", accounts.length, "accounts:");
  accounts.forEach((acc, i) => console.log(`   ${i + 1}. ${acc.toBase58()}`));
  console.log();

  const connection = new Connection(
    process.env.ANCHOR_PROVIDER_URL || "https://api.devnet.solana.com",
    "confirmed"
  );

  const wallet = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
  );

  // Verify current ALT state
  const altAccount = await connection.getAddressLookupTable(altAddress);
  if (!altAccount.value) {
    console.error("❌ ALT not found on-chain:", altAddress.toBase58());
    process.exit(1);
  }

  console.log("📋 Current ALT state:");
  console.log("   Addresses:", altAccount.value.state.addresses.length);
  console.log("   Authority:", altAccount.value.state.authority?.toBase58());

  if (altAccount.value.state.authority?.toBase58() !== wallet.publicKey.toBase58()) {
    console.error("❌ Wallet is not the authority for this ALT");
    console.error(`   Expected: ${wallet.publicKey.toBase58()}`);
    console.error(`   Actual: ${altAccount.value.state.authority?.toBase58()}`);
    process.exit(1);
  }

  const ACTIVE_SENTINEL = BigInt("18446744073709551615"); // u64::MAX = active
  if (
    altAccount.value.state.deactivationSlot !== undefined &&
    BigInt(altAccount.value.state.deactivationSlot.toString()) !== ACTIVE_SENTINEL
  ) {
    console.error(`❌ ALT is deactivated at slot ${altAccount.value.state.deactivationSlot}`);
    console.error("   Cannot extend a deactivated ALT. Create a new one instead.");
    process.exit(1);
  }

  // Extend ALT
  const extendIx = AddressLookupTableProgram.extendLookupTable({
    lookupTable: altAddress,
    authority: wallet.publicKey,
    payer: wallet.publicKey,
    addresses: accounts,
  });

  const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

  const tx = new Transaction().add(extendIx);
  tx.recentBlockhash = blockhash;
  tx.feePayer = wallet.publicKey;

  const sig = await connection.sendTransaction(tx, [wallet]);
  await connection.confirmTransaction({
    signature: sig,
    blockhash,
    lastValidBlockHeight,
  });

  console.log("\n✅ ALT extended successfully!");
  console.log("   Signature:", sig);

  // Wait and verify
  console.log("⏳ Waiting for update to propagate...");
  await new Promise(resolve => setTimeout(resolve, 1000));

  const updatedAlt = await connection.getAddressLookupTable(altAddress);
  if (updatedAlt.value) {
    console.log("\n✅ Updated ALT state:");
    console.log("   Addresses:", updatedAlt.value.state.addresses.length);
    console.log(`   Added: ${updatedAlt.value.state.addresses.length - altAccount.value.state.addresses.length} new accounts`);
  }
}

main().catch(console.error);
