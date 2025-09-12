import * as anchor from "@coral-xyz/anchor";
import * as dotenv from "dotenv";
import {
    PublicKey,
    LAMPORTS_PER_SOL,
    Keypair,
    SystemProgram,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import type { Pushsolanagateway } from "../target/types/pushsolanagateway";
import * as spl from "@solana/spl-token";
import { keccak_256 } from "js-sha3";
import * as secp from "@noble/secp256k1";

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const WHITELIST_SEED = "whitelist";
const PRICE_ACCOUNT = new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE"); // Pyth SOL/USD price feed

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("../upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("../clean-user-keypair.json", "utf8")))
);

// Set up connection and provider
const connection = new anchor.web3.Connection("https://api.devnet.solana.com", "confirmed");
const adminProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
    commitment: "confirmed",
});
const userProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(userKeypair), {
    commitment: "confirmed",
});

anchor.setProvider(adminProvider);

// Load IDL
const idl = JSON.parse(fs.readFileSync("../target/idl/pushsolanagateway.json", "utf8"));
const program = new Program(idl as Pushsolanagateway, adminProvider);
const userProgram = new Program(idl as Pushsolanagateway, userProvider);

// Helper: parse and print program data logs (Anchor events) from a transaction
async function parseAndPrintEvents(txSignature: string, label: string) {
    try {
        const tx = await connection.getTransaction(txSignature, {
            commitment: "confirmed",
            maxSupportedTransactionVersion: 0,
        });
        if (!tx?.meta?.logMessages) {
            console.log(`${label}: No logs found`);
            return;
        }
        const dataLogs = tx.meta.logMessages.filter((log) => log.startsWith("Program data: "));
        if (dataLogs.length === 0) {
            console.log(`${label}: No program data logs (events) found`);
            return;
        }
        console.log(`${label}: Found ${dataLogs.length} event log(s)`);
        dataLogs.forEach((log, idx) => {
            const base64Data = log.replace("Program data: ", "");
            const buf = Buffer.from(base64Data, "base64");
            const disc = buf.slice(0, 8).toString("hex");
            const data = buf.slice(8);
            console.log(`  [${idx}] discriminator=${disc} data_len=${data.length}`);
        });
    } catch (e: any) {
        console.log(`${label}: Error parsing events: ${e.message}`);
    }
}

// Helper function to create SPL token
async function createSPLToken(
    provider: anchor.AnchorProvider,
    wallet: Keypair,
    decimals: number = 6
): Promise<{ mint: Keypair; tokenAccount: PublicKey }> {
    const mint = Keypair.generate();
    const mintRent = await spl.getMinimumBalanceForRentExemptMint(provider.connection as any);

    const tokenTransaction = new anchor.web3.Transaction();
    tokenTransaction.add(
        anchor.web3.SystemProgram.createAccount({
            fromPubkey: wallet.publicKey,
            newAccountPubkey: mint.publicKey,
            lamports: mintRent,
            space: spl.MINT_SIZE,
            programId: spl.TOKEN_PROGRAM_ID,
        }),
        spl.createInitializeMintInstruction(
            mint.publicKey,
            decimals,
            wallet.publicKey,
            null
        )
    );

    await anchor.web3.sendAndConfirmTransaction(
        provider.connection as any,
        tokenTransaction,
        [wallet, mint]
    );

    // Create associated token account for the wallet
    const tokenAccount = await spl.getOrCreateAssociatedTokenAccount(
        provider.connection as any,
        wallet,
        mint.publicKey,
        wallet.publicKey
    );

    // Mint some tokens to the account
    const mintToTransaction = new anchor.web3.Transaction().add(
        spl.createMintToInstruction(
            mint.publicKey,
            tokenAccount.address,
            wallet.publicKey,
            1_000_000 * Math.pow(10, decimals) // 1M tokens
        )
    );

    await anchor.web3.sendAndConfirmTransaction(
        provider.connection as any,
        mintToTransaction,
        [wallet]
    );

    return { mint, tokenAccount: tokenAccount.address };
}

async function run() {
    console.log("=== GATEWAY PROGRAM COMPREHENSIVE TEST ===\n");

    // Load env from parent and local (so either location works)
    dotenv.config({ path: "../.env" });
    dotenv.config();

    // Derive PDAs
    const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(CONFIG_SEED)],
        PROGRAM_ID
    );
    const [vaultPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(VAULT_SEED)],
        PROGRAM_ID
    );
    const [tssPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tss")],
        PROGRAM_ID
    );

    const admin = adminKeypair.publicKey;
    const user = userKeypair.publicKey;

    console.log(`Program ID: ${PROGRAM_ID.toString()}`);
    console.log(`Admin: ${admin.toString()}`);
    console.log(`User: ${user.toString()}`);
    console.log(`Config PDA: ${configPda.toString()}`);
    console.log(`Vault PDA: ${vaultPda.toString()}\n`);

    // Step 1: Initialize Gateway
    console.log("1. Initializing Gateway...");
    const configAccount = await connection.getAccountInfo(configPda);
    if (!configAccount) {
        const tx = await program.methods
            .initialize(
                admin, // admin
                admin, // pauser
                admin, // tss (using admin for simplicity)
                new anchor.BN(100_000_000), // min_cap_usd ($1 with 8 decimals = 1e8)
                new anchor.BN(1_000_000_000), // max_cap_usd ($10 with 8 decimals = 10e8)
                new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE") // pyth_price_feed (SOL/USD feed ID)
            )
            .accounts({
                config: configPda,
                vault: vaultPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .signers([adminKeypair])
            .rpc();
        console.log(`Gateway initialized: ${tx}\n`);
    } else {
        console.log("Gateway already initialized\n");
    }

    // Step 2: Test Admin Functions
    console.log("2. Testing Admin Functions...");

    // Check current caps
    try {
        const configData = await (program.account as any).config.fetch(configPda);
        const minCap = configData.minCapUniversalTxUsd ? configData.minCapUniversalTxUsd.toString() : 'N/A';
        const maxCap = configData.maxCapUniversalTxUsd ? configData.maxCapUniversalTxUsd.toString() : 'N/A';
        console.log(`Current caps - Min: ${minCap}, Max: ${maxCap}`);
    } catch (error) {
        console.log("Could not fetch config data, skipping caps display");
    }

    // Update caps
    const newMinCap = new anchor.BN(200_000_000); // $2 with 8 decimals = 2e8
    const newMaxCap = new anchor.BN(2_000_000_000); // $20 with 8 decimals = 20e8
    const capsTx = await program.methods
        .setCapsUsd(newMinCap, newMaxCap)
        .accounts({
            config: configPda,
            admin: admin,
        })
        .rpc();
    console.log(`✅ Caps updated: ${capsTx}`);

    // Verify caps update
    try {
        const updatedConfigData = await (program.account as any).config.fetch(configPda);
        const minCap = updatedConfigData.minCapUniversalTxUsd ? updatedConfigData.minCapUniversalTxUsd.toString() : 'N/A';
        const maxCap = updatedConfigData.maxCapUniversalTxUsd ? updatedConfigData.maxCapUniversalTxUsd.toString() : 'N/A';
        console.log(`📊 Updated caps - Min: ${minCap}, Max: ${maxCap}\n`);
    } catch (error) {
        console.log("📊 Could not fetch updated config data\n");
    }

    // Step 3: Use existing SPL Token or deploy new one
    console.log("3. Setting up SPL Token...");

    // Try to use an existing token first (you can replace this with your deployed token)
    let mint: Keypair;
    let tokenAccount: PublicKey;

    // Check if we have a saved token mint file
    const tokenMintPath = "../test-token-mint.json";
    try {
        const tokenMintData = JSON.parse(fs.readFileSync(tokenMintPath, "utf8"));
        mint = Keypair.fromSecretKey(Uint8Array.from(tokenMintData));

        // Get or create token account for this mint
        const tokenAccountInfo = await spl.getOrCreateAssociatedTokenAccount(
            userProvider.connection as any,
            userKeypair,
            mint.publicKey,
            userKeypair.publicKey
        );
        tokenAccount = tokenAccountInfo.address;

        console.log(`✅ Using existing SPL Token:`);
        console.log(`   Mint: ${mint.publicKey.toString()}`);
        console.log(`   Token Account: ${tokenAccount.toString()}\n`);
    } catch (error) {
        // Token doesn't exist, create a new one
        console.log("No existing token found, deploying new SPL Token...");
        const tokenInfo = await createSPLToken(userProvider, userKeypair, 6);
        mint = tokenInfo.mint;
        tokenAccount = tokenInfo.tokenAccount;

        // Save the mint keypair for future use
        fs.writeFileSync(tokenMintPath, JSON.stringify(Array.from(mint.secretKey)));

        console.log(`✅ SPL Token deployed:`);
        console.log(`   Mint: ${mint.publicKey.toString()}`);
        console.log(`   Token Account: ${tokenAccount.toString()}\n`);
    }

    // Step 4: Whitelist SPL Token
    console.log("4. Whitelisting SPL Token...");
    const [whitelistPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(WHITELIST_SEED)],
        PROGRAM_ID
    );

    try {
        const whitelistTx = await program.methods
            .whitelistToken(mint.publicKey)
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log(`✅ Token whitelisted: ${whitelistTx}\n`);
    } catch (error) {
        if (error.message.includes("TokenAlreadyWhitelisted")) {
            console.log(`✅ Token already whitelisted (skipping)\n`);
        } else {
            throw error;
        }
    }

    // Step 5: Test send_tx_with_gas (SOL deposit with payload)
    console.log("5. Testing send_tx_with_gas...");
    const userBalanceBefore = await connection.getBalance(user);
    const vaultBalanceBefore = await connection.getBalance(vaultPda);

    console.log(`💳 User balance BEFORE: ${userBalanceBefore / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance BEFORE: ${vaultBalanceBefore / LAMPORTS_PER_SOL} SOL`);

    // Create payload and revert settings
    const payload = {
        to: Keypair.generate().publicKey, // Target address on Push Chain
        value: new anchor.BN(0), // Value to send
        data: Buffer.from("test payload data"),
        gas_limit: new anchor.BN(100000),
        max_fee_per_gas: new anchor.BN(20000000000), // 20 gwei
        max_priority_fee_per_gas: new anchor.BN(1000000000), // 1 gwei
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Date.now() + 3600000), // 1 hour from now
        v_type: { signedVerification: {} }, // VerificationType enum
    };

    const revertSettings = {
        fundRecipient: user, // Use user as recipient for simplicity  
        revertMsg: Buffer.from("revert message"),
    };


    const gasAmount = new anchor.BN(0.01 * LAMPORTS_PER_SOL); // 0.01 SOL

    const gasTx = await userProgram.methods
        .sendTxWithGas(payload, revertSettings, gasAmount)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Gas transaction sent: ${gasTx}`);
    // Parse Anchor event logs from the transaction (manual.ts style)
    await parseAndPrintEvents(gasTx, "send_tx_with_gas events");

    const userBalanceAfter = await connection.getBalance(user);
    const vaultBalanceAfter = await connection.getBalance(vaultPda);
    console.log(`💳 User balance AFTER: ${userBalanceAfter / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance AFTER: ${vaultBalanceAfter / LAMPORTS_PER_SOL} SOL\n`);

    // Step 5a: Legacy add_funds (locker-compatible)
    console.log("5a. Legacy add_funds (locker-compatible)...");
    const legacyAmount = new anchor.BN(0.001 * LAMPORTS_PER_SOL); // 0.001 SOL
    const txHashLegacy: number[] = Array(32).fill(1); // 32-byte transaction hash (dummy)

    const legacyTx = await userProgram.methods
        .addFunds(legacyAmount, txHashLegacy)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Legacy add_funds sent: ${legacyTx}`);
    await parseAndPrintEvents(legacyTx, "legacy add_funds events");

    // Step 6: Test send_funds_native (Native SOL transfers)
    console.log("6. Testing send_funds_native...");
    const recipient = Keypair.generate().publicKey;
    const fundAmount = new anchor.BN(0.005 * LAMPORTS_PER_SOL); // 0.005 SOL

    const userBalanceBeforeFunds = await connection.getBalance(user);
    const vaultBalanceBeforeFunds = await connection.getBalance(vaultPda);

    console.log(`💳 User balance BEFORE send_funds_native: ${userBalanceBeforeFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance BEFORE send_funds_native: ${vaultBalanceBeforeFunds / LAMPORTS_PER_SOL} SOL`);

    const nativeFundsTx = await userProgram.methods
        .sendFundsNative(recipient, fundAmount, revertSettings)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Native SOL funds sent to ${recipient.toString()}: ${nativeFundsTx}`);

    // Parse events
    await parseAndPrintEvents(nativeFundsTx, "send_funds_native events");

    const userBalanceAfterFunds = await connection.getBalance(user);
    const vaultBalanceAfterFunds = await connection.getBalance(vaultPda);
    console.log(`💳 User balance AFTER send_funds_native: ${userBalanceAfterFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance AFTER send_funds_native: ${vaultBalanceAfterFunds / LAMPORTS_PER_SOL} SOL\n`);

    // Step 7: Test SPL token functions
    console.log("7. Testing SPL Token Functions...");

    // Create ATA for vault
    const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
        userProvider.connection as any,
        userKeypair,
        mint.publicKey,
        vaultPda,
        true
    );
    console.log(`✅ Vault ATA created: ${vaultAta.address.toString()}`);

    // Test send_funds with SPL token (SPL-only function)
    const splRecipient = Keypair.generate().publicKey;
    const splAmount = new anchor.BN(1000 * Math.pow(10, 6)); // 1000 tokens (6 decimals)

    console.log(`🪙 Testing SPL token send_funds...`);

    // Get SPL balances before
    const userTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`📊 User SPL balance BEFORE: ${userTokenBalanceBefore.toString()} tokens`);
    console.log(`📊 Vault SPL balance BEFORE: ${vaultTokenBalanceBefore.toString()} tokens`);
    console.log(`📤 Sending ${splAmount.toNumber() / Math.pow(10, 6)} tokens to ${splRecipient.toString()}`);

    const splFundsTx = await userProgram.methods
        .sendFunds(splRecipient, mint.publicKey, splAmount, revertSettings)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: tokenAccount,
            gatewayTokenAccount: vaultAta.address,
            bridgeToken: mint.publicKey,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ SPL funds sent: ${splFundsTx}`);

    // Parse events
    await parseAndPrintEvents(splFundsTx, "send_funds (SPL) events");

    // Get SPL balances after
    const userTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfter.toString()} tokens`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfter.toString()} tokens\n`);

    // Step 8: Test send_tx_with_funds (SPL + payload + gas)
    console.log("8. Testing send_tx_with_funds (SPL + payload + gas)...");

    const txWithFundsRecipient = Keypair.generate().publicKey;
    const txWithFundsSplAmount = new anchor.BN(500 * Math.pow(10, 6)); // 500 tokens
    const txWithFundsGasAmount = new anchor.BN(0.015 * LAMPORTS_PER_SOL); // 0.015 SOL for gas (meets USD min cap)

    // Create payload for this transaction
    const txWithFundsPayload = {
        to: Keypair.generate().publicKey, // Target address on Push Chain
        value: new anchor.BN(0), // Value to send
        data: Buffer.from("test payload for funds+gas"),
        gas_limit: new anchor.BN(120000),
        max_fee_per_gas: new anchor.BN(20000000000), // 20 gwei
        max_priority_fee_per_gas: new anchor.BN(1000000000), // 1 gwei
        nonce: new anchor.BN(1),
        deadline: new anchor.BN(Date.now() + 3600000), // 1 hour from now
        v_type: { signedVerification: {} }, // VerificationType enum
    };

    console.log(`🚀 Testing combined SPL + Gas transaction...`);
    console.log(`📤 SPL Amount: ${txWithFundsSplAmount.toNumber() / Math.pow(10, 6)} tokens`);
    console.log(`⛽ Gas Amount: ${txWithFundsGasAmount.toNumber() / LAMPORTS_PER_SOL} SOL`);

    const userBalanceBeforeTxWithFunds = await connection.getBalance(user);
    const vaultBalanceBeforeTxWithFunds = await connection.getBalance(vaultPda);
    const userTokenBalanceBeforeTx = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceBeforeTx = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`💳 User SOL balance BEFORE: ${userBalanceBeforeTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance BEFORE: ${vaultBalanceBeforeTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`📊 User SPL balance BEFORE: ${userTokenBalanceBeforeTx.toString()} tokens`);
    console.log(`📊 Vault SPL balance BEFORE: ${vaultTokenBalanceBeforeTx.toString()} tokens`);

    const txWithFundsTx = await userProgram.methods
        .sendTxWithFunds(
            mint.publicKey,
            txWithFundsSplAmount,
            txWithFundsPayload,
            revertSettings,
            txWithFundsGasAmount
        )
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: tokenAccount,
            gatewayTokenAccount: vaultAta.address,
            priceUpdate: PRICE_ACCOUNT,
            bridgeToken: mint.publicKey,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Combined SPL + Gas transaction sent: ${txWithFundsTx}`);

    // Parse events
    await parseAndPrintEvents(txWithFundsTx, "send_tx_with_funds events");

    const userBalanceAfterTxWithFunds = await connection.getBalance(user);
    const vaultBalanceAfterTxWithFunds = await connection.getBalance(vaultPda);
    const userTokenBalanceAfterTx = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceAfterTx = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`💳 User SOL balance AFTER: ${userBalanceAfterTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance AFTER: ${vaultBalanceAfterTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfterTx.toString()} tokens`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfterTx.toString()} tokens\n`);
    
    // Step 10: Test pause/unpause
    console.log("10. Testing pause/unpause...");

    try {
        const pauseTx = await program.methods
            .pause()
            .accounts({
                config: configPda,
                pauser: admin,
            })
            .rpc();
        console.log(`✅ Gateway paused: ${pauseTx}`);
    } catch (error) {
        if (error.message.includes("PausedError") || error.message.includes("already paused")) {
            console.log("✅ Gateway already paused (skipping)");
        } else {
            throw error;
        }
    }

    // Try to send funds while paused (should fail)
    try {
        await userProgram.methods
            .sendTxWithGas(payload, revertSettings, gasAmount)
            .accounts({
                config: configPda,
                vault: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log("❌ Transaction should have failed while paused!");
    } catch (error) {
        console.log("✅ Transaction correctly failed while paused");
    }

    try {
        const unpauseTx = await program.methods
            .unpause()
            .accounts({
                config: configPda,
                pauser: admin,
            })
            .rpc();
        console.log(`✅ Gateway unpaused: ${unpauseTx}\n`);
    } catch (error) {
        if (error.message.includes("not paused") || error.message.includes("already unpaused")) {
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
    const ethAddrHex = "0xEbf0Cfc34E07ED03c05615394E2292b387B63F12".toLowerCase().replace(/^0x/, "");
    const ethAddrBytes = Buffer.from(ethAddrHex, "hex");
    if (ethAddrBytes.length !== 20) throw new Error("Invalid ETH address length for TSS");

    try {
        const tssInfo = await connection.getAccountInfo(tssPda);
        if (!tssInfo) {
            const initTssTx = await program.methods
                .initTss(Array.from(ethAddrBytes) as any, new anchor.BN(1))
                .accounts({
                    tssPda: tssPda,
                    authority: admin,
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
            .initTss(Array.from(ethAddrBytes) as any, new anchor.BN(1))
            .accounts({
                tssPda: tssPda,
                authority: admin,
                systemProgram: SystemProgram.programId,
            })
            .signers([adminKeypair])
            .rpc();
        console.log(`✅ TSS initialized: ${initTssTx}`);
    }

    // 12.2 Build message for SOL withdraw to admin using instruction_id=1
    const withdrawAmountTss = new anchor.BN(0.0005 * LAMPORTS_PER_SOL).toNumber();
    const chainId = 1; // Ethereum mainnet id for domain separation
    // Fetch current nonce by reading TssPda account (optional). We'll pass a rolling nonce = 0 on first run.
    // For simplicity here, use a small local nonce and retry if mismatch.
    let nonce = 0; // default
    try {
        // Attempt to read current nonce from on-chain TSS PDA
        const tssAcc: any = await (program.account as any).tssPda.fetch(tssPda);
        if (tssAcc && typeof tssAcc.nonce !== "undefined") {
            nonce = Number(tssAcc.nonce);
        }
    } catch (e) {
        // If not initialized or IDL not exposed yet, keep default 0
    }

    const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
    const instructionId = Buffer.from([1]); // 1 = SOL withdraw
    const chainIdBE = Buffer.alloc(8);
    chainIdBE.writeBigUInt64BE(BigInt(chainId));
    const nonceBE = Buffer.alloc(8);
    nonceBE.writeBigUInt64BE(BigInt(nonce));
    const amountBE = Buffer.alloc(8);
    amountBE.writeBigUInt64BE(BigInt(withdrawAmountTss));
    const recipientBytes = admin.toBuffer();

    const concat = Buffer.concat([
        PREFIX,
        instructionId,
        chainIdBE,
        nonceBE,
        amountBE,
        recipientBytes,
    ]);
    const messageHashHex = keccak_256(concat);
    const messageHash = Buffer.from(messageHashHex, "hex");

    // 12.3 Sign with ETH private key from .env
    const priv = (process.env.TSS_PRIVKEY || process.env.ETH_PRIVATE_KEY || process.env.PRIVATE_KEY || "").replace(/^0x/, "");
    if (!priv) throw new Error("Missing TSS_PRIVKEY/PRIVATE_KEY in .env");
    const sig = await secp.sign(messageHash, priv, { recovered: true, der: false });
    const signature: Uint8Array = sig[0];
    let recoveryId: number = sig[1]; // 0 or 1

    // 12.4 Call withdraw_tss
    const tssWithdrawTx = await program.methods
        .withdrawTss(
            new anchor.BN(withdrawAmountTss),
            Array.from(signature) as any,
            recoveryId,
            Array.from(messageHash) as any,
            new anchor.BN(nonce),
        )
        .accounts({
            config: configPda,
            vault: vaultPda,
            tssPda: tssPda,
            recipient: admin,
            systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair])
        .rpc();
    console.log(`✅ TSS withdraw SOL completed: ${tssWithdrawTx}`);
    await parseAndPrintEvents(tssWithdrawTx, "withdraw_tss events");

    // 12.5 Test SPL token TSS withdrawal (instruction_id=2)
    console.log("\n=== Testing SPL Token TSS Withdrawal ===");

    // Check if we have SPL tokens in the vault to withdraw
    const vaultTokenBalance = await spl.getAccount(userProvider.connection as any, vaultAta.address);
    if (Number(vaultTokenBalance.amount) === 0) {
        console.log("⚠️  No SPL tokens in vault to withdraw, skipping SPL TSS test");
    } else {
        const splWithdrawAmount = Math.min(Number(vaultTokenBalance.amount), 1000); // Withdraw small amount

        // Create admin ATA for the token
        const adminAta = await spl.getOrCreateAssociatedTokenAccount(
            userProvider.connection as any,
            adminKeypair,
            mint.publicKey,
            admin
        );

        // Build message for SPL withdraw using instruction_id=2
        const PREFIX_SPL = Buffer.from("PUSH_CHAIN_SVM");
        const instructionIdSPL = Buffer.from([2]); // 2 = SPL withdraw
        const chainIdBE_SPL = Buffer.alloc(8);
        chainIdBE_SPL.writeBigUInt64BE(BigInt(chainId));
        const nonceBE_SPL = Buffer.alloc(8);
        nonceBE_SPL.writeBigUInt64BE(BigInt(nonce + 1)); // Increment nonce for SPL withdraw
        const amountBE_SPL = Buffer.alloc(8);
        amountBE_SPL.writeBigUInt64BE(BigInt(splWithdrawAmount));
        const recipientBytesSPL = admin.toBuffer();
        const mintBytes = mint.publicKey.toBuffer(); // 32 bytes for mint address

        const concatSPL = Buffer.concat([
            PREFIX_SPL,
            instructionIdSPL,
            chainIdBE_SPL,
            nonceBE_SPL,
            amountBE_SPL,
            mintBytes, // Additional data for SPL withdraw (only mint, not recipient)
        ]);
        const messageHashHexSPL = keccak_256(concatSPL);
        const messageHashSPL = Buffer.from(messageHashHexSPL, "hex");

        // Sign with ETH private key
        const sigSPL = await secp.sign(messageHashSPL, priv, { recovered: true, der: false });
        const signatureSPL: Uint8Array = sigSPL[0];
        let recoveryIdSPL: number = sigSPL[1];

        // Call withdraw_spl_token_tss
        const tssSplWithdrawTx = await program.methods
            .withdrawSplTokenTss(
                new anchor.BN(splWithdrawAmount),
                Array.from(signatureSPL) as any,
                recoveryIdSPL,
                Array.from(messageHashSPL) as any,
                new anchor.BN(nonce + 1),
            )
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                vault: vaultPda,
                tokenVault: vaultAta.address,
                tokenMint: mint.publicKey,
                tssPda: tssPda,
                recipientTokenAccount: adminAta.address,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
            })
            .signers([adminKeypair])
            .rpc();
        console.log(`✅ TSS withdraw SPL completed: ${tssSplWithdrawTx}`);
        await parseAndPrintEvents(tssSplWithdrawTx, "withdraw_spl_token_tss events");

        // Log final SPL balances
        const finalVaultBalance = await spl.getAccount(userProvider.connection as any, vaultAta.address);
        const finalAdminBalance = await spl.getAccount(userProvider.connection as any, adminAta.address);
        console.log(`Final vault SPL balance: ${finalVaultBalance.amount}`);
        console.log(`Final admin SPL balance: ${finalAdminBalance.amount}`);
    }

    // 13. Note: ATA creation is now handled off-chain by clients (standard practice)
    console.log("\n=== ATA Creation Note ===");
    console.log("✅ ATA creation is handled off-chain by clients (standard Solana practice)");
    console.log("✅ This avoids complex reimbursement logic and follows industry standards");

    // 14. Remove token from whitelist (moved after all tests)
    console.log("14. Testing remove whitelist...");
    try {
        const removeWhitelistTx = await program.methods
            .removeWhitelistToken(mint.publicKey)
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log(`✅ Token removed from whitelist: ${removeWhitelistTx}\n`);
    } catch (error) {
        if (error.message.includes("TokenNotWhitelisted") || error.message.includes("not whitelisted")) {
            console.log("✅ Token not in whitelist (skipping removal)\n");
        } else {
            throw error;
        }
    }
}

console.log("🎉 All tests completed successfully!");
run().catch((e) => {
    console.error("❌ Test failed:", e);
    process.exit(1);
});
