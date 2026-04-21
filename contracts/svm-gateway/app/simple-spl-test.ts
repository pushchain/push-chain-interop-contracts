#!/usr/bin/env node

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
import type { UniversalGateway } from "../target/types/universal_gateway";
import * as spl from "@solana/spl-token";
import { Command } from "commander";

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const FEE_VAULT_SEED = "fee_vault";
const RATE_LIMIT_CONFIG_SEED = "rate_limit_config";
const RATE_LIMIT_SEED = "rate_limit";

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./clean-user-keypair.json", "utf8")))
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
const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
const program = new Program(idl as UniversalGateway, adminProvider);
const userProgram = new Program(idl as UniversalGateway, userProvider);

// Helper function to load token info from file
function loadTokenInfo(tokenSymbol: string): any {
    const filename = `./tokens/${tokenSymbol.toLowerCase()}-token.json`;

    if (!fs.existsSync(filename)) {
        throw new Error(`Token file not found: ${filename}. Please create the token first using 'npm run token:create'`);
    }

    return JSON.parse(fs.readFileSync(filename, "utf8"));
}

// Helper function to test SPL token deposit
async function testDeposit(mintAddress: string, amount: number, tokenSymbol?: string): Promise<void> {
    console.log(`🧪 Testing SPL token deposit...`);

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
        [Buffer.from(FEE_VAULT_SEED)],
        PROGRAM_ID
    );
    const [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(RATE_LIMIT_CONFIG_SEED)],
        PROGRAM_ID
    );

    // Helper to get token rate limit PDA
    const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from(RATE_LIMIT_SEED), tokenMint.toBuffer()],
            PROGRAM_ID
        );
        return pda;
    };

    const admin = adminKeypair.publicKey;
    const user = userKeypair.publicKey;
    const mint = new PublicKey(mintAddress);

    // Get price feed from config (or use dummy if not set)
    let priceFeed: PublicKey;
    try {
        const config = await (program.account as any).config.fetch(configPda);
        priceFeed = config.pythPriceFeed;
    } catch {
        // If config doesn't exist or price feed not set, use a dummy
        priceFeed = Keypair.generate().publicKey;
    }

    console.log(`Program ID: ${PROGRAM_ID.toString()}`);
    console.log(`Admin: ${admin.toString()}`);
    console.log(`User: ${user.toString()}`);
    console.log(`Mint: ${mint.toString()}`);
    console.log(`Config PDA: ${configPda.toString()}`);
    console.log(`Vault PDA: ${vaultPda.toString()}`);
    console.log(`Fee Vault PDA: ${feeVaultPda.toString()}`);

    // Step 1: Get vault ATA
    console.log("1. Getting vault ATA...");
    const vaultAta = await spl.getAssociatedTokenAddress(
        mint,
        vaultPda,
        true
    );
    console.log(`✅ Vault ATA: ${vaultAta.toString()}\n`);

    // Step 2: Get or create user token account
    console.log("2. Getting user token account...");
    const userTokenAccount = await spl.getOrCreateAssociatedTokenAccount(
        userProvider.connection as any,
        userKeypair,
        mint,
        user
    );
    console.log(`✅ User token account: ${userTokenAccount.address.toString()}\n`);

    // Step 3: Test SPL token deposit
    console.log("3. Testing SPL token deposit...");

    // Get token decimals from token info (if tokenSymbol provided)
    let decimals = 6; // default
    if (tokenSymbol) {
        const tokenInfo = loadTokenInfo(tokenSymbol);
        decimals = tokenInfo.decimals || 6;
    }
    const depositAmount = new anchor.BN(amount * Math.pow(10, decimals)); // Convert to proper units
    const recipient = Keypair.generate().publicKey;

    // Get balances before
    const userTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, userTokenAccount.address)).amount;
    const vaultTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, vaultAta)).amount;

    console.log(`📊 User SPL balance BEFORE: ${userTokenBalanceBefore.toString()} tokens`);
    console.log(`📊 Vault SPL balance BEFORE: ${vaultTokenBalanceBefore.toString()} tokens`);
    console.log(`📤 Depositing ${amount} tokens to ${recipient.toString()}`);

    // Convert recipient to EVM address format (20 bytes)
    const recipientEvm = Array.from(Buffer.alloc(20));
    recipient.toBuffer().copy(Buffer.from(recipientEvm), 0, Math.min(32, recipient.toBuffer().length));

    // Create UniversalTxRequest for FUNDS route
    const fundsReq = {
        recipient: recipientEvm,
        token: mint,
        amount: depositAmount,
        payload: Buffer.from([]), // Empty payload for FUNDS route
        revertRecipient: user,
        signatureData: Buffer.from([]), // Empty for FUNDS route
    };

    // Get token rate limit PDA
    const splTokenRateLimitPda = getTokenRateLimitPda(mint);

    // Initialize token rate limit if needed (with very large threshold to effectively disable)
    try {
        await (program.account as any).tokenRateLimit.fetch(splTokenRateLimitPda);
    } catch {
        // Not initialized, create it
        const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // Effectively unlimited
        try {
            await program.methods
                .setTokenRateLimit(veryLargeThreshold, true, true)
                .accountsPartial({
                    config: configPda,
                    tokenRateLimit: splTokenRateLimitPda,
                    tokenMint: mint,
                    admin: admin,
                    systemProgram: SystemProgram.programId,
                })
                .rpc();
        } catch (error) {
            // If it fails, continue anyway - rate limit might already be set or config might not exist
            console.log(`⚠️  Could not initialize token rate limit (continuing anyway): ${error.message}`);
        }
    }

    // Perform the deposit using sendUniversalTx
    const depositTx = await userProgram.methods
        .sendUniversalTx(fundsReq, new anchor.BN(0)) // No native SOL for SPL funds
        .accountsPartial({
            config: configPda,
            vault: vaultPda,
            feeVault: feeVaultPda,
            user: user,
            userTokenAccount: userTokenAccount.address,
            gatewayTokenAccount: vaultAta,
            priceUpdate: priceFeed,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: splTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ SPL deposit transaction: ${depositTx}`);

    // Get balances after
    const userTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, userTokenAccount.address)).amount;
    const vaultTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, vaultAta)).amount;

    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfter.toString()} tokens`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfter.toString()} tokens`);

    // Verify the deposit worked
    const userBalanceDiff = userTokenBalanceBefore - userTokenBalanceAfter;
    const vaultBalanceDiff = vaultTokenBalanceAfter - vaultTokenBalanceBefore;

    console.log(`\n📈 Balance Changes:`);
    console.log(`   User lost: ${userBalanceDiff.toString()} tokens`);
    console.log(`   Vault gained: ${vaultBalanceDiff.toString()} tokens`);

    if (userBalanceDiff.toString() === depositAmount.toString() &&
        vaultBalanceDiff.toString() === depositAmount.toString()) {
        console.log(`✅ Deposit successful! Amounts match exactly.`);
    } else {
        console.log(`❌ Deposit amounts don't match. Expected: ${depositAmount.toString()}`);
    }

    console.log("\n=== Deposit test completed successfully! ===");
}

// Initialize the CLI
const program_cli = new Command();

program_cli
    .name('gateway-test')
    .description('CLI tool for testing gateway functionality with SPL tokens')
    .version('1.0.0');

// Test deposit command
program_cli
    .command('test-deposit')
    .description('Test SPL token deposit functionality')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .requiredOption('-a, --amount <amount>', 'Amount to deposit (in human-readable units)')
    .action(async (options) => {
        try {
            console.log("=== TESTING SPL TOKEN DEPOSIT ===\n");

            let mintAddress: string;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
            } else {
                // It's a token symbol, load from file
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            const amount = parseFloat(options.amount);

            await testDeposit(mintAddress, amount, options.mint.length === 44 ? undefined : options.mint);

            console.log("🎉 Deposit test completed successfully!");

        } catch (error) {
            console.error("❌ Error testing deposit:", error.message);
            process.exit(1);
        }
    });

// Full test command (test deposit)
program_cli
    .command('full-test')
    .description('Run full test: test deposit')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .requiredOption('-a, --amount <amount>', 'Amount to deposit (in human-readable units)')
    .action(async (options) => {
        try {
            console.log("=== FULL GATEWAY TEST ===\n");

            let mintAddress: string;
            let tokenInfo: any = null;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
            } else {
                // It's a token symbol, load from file
                tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            // Step 1: Test deposit
            console.log("Step 1: Testing deposit...");
            const amount = parseFloat(options.amount);
            await testDeposit(mintAddress, amount, options.mint.length === 44 ? undefined : options.mint);

            console.log("Full test completed successfully!");

        } catch (error) {
            console.error("Error in full test:", error.message);
            process.exit(1);
        }
    });

// Load environment variables
dotenv.config({ path: "../.env" });
dotenv.config();

// Parse command line arguments
program_cli.parse();
