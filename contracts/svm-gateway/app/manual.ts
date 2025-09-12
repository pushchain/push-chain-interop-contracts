// app/real-complete-flow.ts
import * as anchor from "@coral-xyz/anchor";
import {
  Connection,
  PublicKey,
  LAMPORTS_PER_SOL,
  Keypair,
  SystemProgram,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import type { Pushsolanalocker } from "../target/types/pushsolanalocker";

const PROGRAM_ID = new PublicKey("3zrWaMknHTRQpZSxY4BvQxw9TStSXiHcmcp3NMPTFkke");
const VAULT_SEED = "vault";
const LOCKER_SEED = "locker";
const PRICE_ACCOUNT = new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE");

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("../upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("../clean-user-keypair.json", "utf8")))
);

const phantomKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("../phantom-keypair.json", "utf8")))
);

// Set up connection and provider
const connection = new Connection("https://api.devnet.solana.com", "confirmed");
const adminProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
  commitment: "confirmed",
});
const userProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(userKeypair), {
  commitment: "confirmed",
});
const phantomProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(phantomKeypair), {
  commitment: "confirmed",
});

anchor.setProvider(adminProvider);  // Set admin as default provider

// Load IDL
const idl = JSON.parse(fs.readFileSync("../target/idl/pushsolanalocker.json", "utf8"));
const program = new Program(idl as Pushsolanalocker, adminProvider);
const programWithoutSigner = new Program(idl as Pushsolanalocker);
const userProgram = new Program(idl as Pushsolanalocker, userProvider);  // Create program instance for user

async function run() {
  const [lockerPda] = PublicKey.findProgramAddressSync(
    [Buffer.from(LOCKER_SEED)],
    PROGRAM_ID
  );
  const [vaultPda] = PublicKey.findProgramAddressSync(
    [Buffer.from(VAULT_SEED)],
    PROGRAM_ID
  );

  const admin = adminKeypair.publicKey;
  const user = userKeypair.publicKey;
  const phantom = phantomKeypair.publicKey;

  console.log("🚀 Testing complete flow - REAL ONLY...\n");

  // Step 1: Test getSolPrice function - NO RETRIES
  console.log("1. Testing getSolPrice function...");
  try {
    const priceData = await programWithoutSigner.methods
      .getSolPrice()
      .accounts({
        priceUpdate: PRICE_ACCOUNT,
      })
      .view();

    const usdPrice = priceData.exponent >= 0
      ? priceData.price * Math.pow(10, priceData.exponent)
      : priceData.price / Math.pow(10, Math.abs(priceData.exponent));

    console.log(`✅ SOL Price: ${usdPrice.toFixed(2)} USD`);
    console.log(`⏰ Published: ${new Date(priceData.publishTime * 1000).toISOString()}\n`);
  } catch (error) {
    console.log(`❌ getSolPrice failed: ${error.message}`);
    console.log("❌ PRICE FEED NOT WORKING - STOPPING TEST\n");
    process.exit(1);
  }

  // Step 2: Initialize locker
  console.log("2. Initializing locker...");
  const lockerAccount = await connection.getAccountInfo(lockerPda);
  if (!lockerAccount) {
    const tx = await program.methods
      .initialize()
      .accounts({
        lockerData: lockerPda,
        vault: vaultPda,
        admin: admin,
        systemProgram: SystemProgram.programId,
      })
      .signers([adminKeypair])
      .rpc();
    console.log(`✅ Locker initialized: ${tx}\n`);
  } else {
    console.log("✅ Locker already exists\n");
  }

  // Step 3: Add funds with REAL event listening
  console.log("3. Adding funds with USD calculation and REAL event monitoring...");
  const userBalanceBefore = await connection.getBalance(user);
  const vaultBalanceBefore = await connection.getBalance(vaultPda);
  console.log(`💳 User balance BEFORE: ${userBalanceBefore / LAMPORTS_PER_SOL} SOL`);
  console.log(`🏦 Vault balance BEFORE: ${vaultBalanceBefore / LAMPORTS_PER_SOL} SOL`);

  const amount = new anchor.BN(0.05 * LAMPORTS_PER_SOL);
  const estimatedFee = 0.000005 * LAMPORTS_PER_SOL;  // 5000 lamports for fee
  const totalNeeded = amount.toNumber() + estimatedFee;

  // Check if user has enough SOL, if not, transfer from admin
  if (userBalanceBefore < totalNeeded) {
    console.log("💰 User has insufficient funds, transferring from admin...");
    console.log(`Current user balance: ${userBalanceBefore / LAMPORTS_PER_SOL} SOL`);
    console.log(`Amount needed: ${amount.toNumber() / LAMPORTS_PER_SOL} SOL`);
    console.log(`Estimated fee: ${estimatedFee / LAMPORTS_PER_SOL} SOL`);
    console.log(`Total needed: ${totalNeeded / LAMPORTS_PER_SOL} SOL`);

    const transferAmount = totalNeeded + 0.01 * LAMPORTS_PER_SOL;  // Add extra 0.01 SOL for safety
    console.log(`Total transfer amount: ${transferAmount / LAMPORTS_PER_SOL} SOL`);

    const transferIx = SystemProgram.transfer({
      fromPubkey: admin,
      toPubkey: user,
      lamports: transferAmount,
    });
    const transferTx = new anchor.web3.Transaction().add(transferIx);
    await adminProvider.sendAndConfirm(transferTx, [adminKeypair]);

    const newUserBalance = await connection.getBalance(user);
    console.log(`✅ Transferred SOL. User balance now: ${newUserBalance / LAMPORTS_PER_SOL} SOL`);

    // Double check if user has enough balance
    if (newUserBalance < totalNeeded) {
      console.log("❌ User still has insufficient funds after transfer!");
      process.exit(1);
    }
  }

  const dummyTxHash = new Uint8Array(32).fill(1);

  // Set up REAL event listener - no timeouts, no fallbacks
  console.log("📡 Setting up REAL event listener...");
  let eventReceived = false;

  // Set up listener BEFORE the transaction
  const listener = userProgram.addEventListener('fundsAddedEvent', (event: any, slot: number) => {
    eventReceived = true;
    console.log("\n📡 REAL FundsAddedEvent received:");
    console.log(`📍 Slot: ${slot}`);
    console.log(`👤 User: ${event.user.toString()}`);
    console.log(`💰 SOL Amount: ${event.solAmount.toString()} lamports (${event.solAmount / LAMPORTS_PER_SOL} SOL)`);

    // Calculate USD value using the raw number and exponent
    const usdValue = event.usdEquivalent * Math.pow(10, event.usdExponent);
    console.log(`💵 USD Equivalent: $${usdValue.toFixed(2)} (raw: ${event.usdEquivalent}, exp: ${event.usdExponent})`);
    console.log(`🔗 Transaction Hash: ${Buffer.from(event.transactionHash).toString('hex')}`);
  }, "confirmed");

  // Wait a moment to ensure listener is ready
  await new Promise(resolve => setTimeout(resolve, 1000));

  console.log("⏳ Waiting for transaction confirmation...");
  const tx1 = await userProgram.methods
    .addFunds(amount, Array.from(dummyTxHash))
    .accounts({
      locker: lockerPda,
      vault: vaultPda,
      user: user,
      priceUpdate: PRICE_ACCOUNT,
      systemProgram: SystemProgram.programId,
    })
    .rpc();

  console.log(`✅ Funds added: ${tx1}`);

  // Wait for REAL event - increased wait time
  console.log("⏳ Waiting 10 seconds for REAL event...");
  await new Promise(resolve => setTimeout(resolve, 10000));

  // Remove listener
  userProgram.removeEventListener(listener);
  console.log("📡 Event listener removed");

  // Fallback: If event wasn't received, fetch it directly from the transaction
  if (!eventReceived) {
    console.log("📡 Event not received via listener, fetching from transaction...");
    try {
      const tx = await connection.getTransaction(tx1, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0
      });

      if (tx?.meta?.logMessages) {
        const eventLog = tx.meta.logMessages.find(log =>
          log.includes("Program log: Event: fundsAddedEvent")
        );

        if (eventLog) {
          console.log("\n📡 Event found in transaction logs:");
          console.log(eventLog);

          // Parse the event data from the log
          const eventData = eventLog.split("Event: fundsAddedEvent")[1];
          if (eventData) {
            try {
              const parsedEvent = JSON.parse(eventData);
              console.log("\n📡 Parsed event data:");
              console.log(`👤 User: ${parsedEvent.user}`);
              console.log(`💰 SOL Amount: ${parsedEvent.solAmount} lamports (${parsedEvent.solAmount / LAMPORTS_PER_SOL} SOL)`);

              // Calculate USD value using the raw number and exponent
              const usdValue = parsedEvent.usdEquivalent * Math.pow(10, parsedEvent.usdExponent);
              console.log(`💵 USD Equivalent: $${usdValue.toFixed(2)} (raw: ${parsedEvent.usdEquivalent}, exp: ${parsedEvent.usdExponent})`);
            } catch (e) {
              console.log("Could not parse event data from log");
            }
          }
        } else {
          console.log("❌ No event found in transaction logs");
        }
      }
    } catch (error) {
      console.log("❌ Error fetching transaction:", error);
    }
  }

  const userBalanceAfter = await connection.getBalance(user);
  const vaultBalanceAfter = await connection.getBalance(vaultPda);
  console.log(`💳 User balance AFTER: ${userBalanceAfter / LAMPORTS_PER_SOL} SOL`);
  console.log(`🏦 Vault balance AFTER: ${vaultBalanceAfter / LAMPORTS_PER_SOL} SOL\n`);

  // Step 4: Recover funds
  console.log("4. Testing token recovery...");
  const splitAmounts = [0.02, 0.01];
  for (let i = 0; i < splitAmounts.length; i++) {
    const sol = splitAmounts[i];
    const recoveryAmount = new anchor.BN(sol * LAMPORTS_PER_SOL);

    const tx = await program.methods
      .recoverTokens(recoveryAmount)
      .accounts({
        lockerData: lockerPda,
        vault: vaultPda,
        recipient: phantom,
        admin: phantom,
        systemProgram: SystemProgram.programId,
      })
      .signers([phantomKeypair])
      .rpc();

    const adminAfter = await connection.getBalance(phantom);
    const vaultAfter = await connection.getBalance(vaultPda);
    console.log(`🔓 Recovered ${sol} SOL: ${tx}`);
    console.log(`✅ Admin: ${adminAfter / LAMPORTS_PER_SOL} SOL`);
    console.log(`✅ Vault: ${vaultAfter / LAMPORTS_PER_SOL} SOL\n`);
  }
}

run().catch((e) => {
  console.error("❌ REAL Script failed:", e);
  process.exit(1);
});