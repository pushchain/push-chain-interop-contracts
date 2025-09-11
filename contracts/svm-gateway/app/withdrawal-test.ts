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
import type { Pushsolanagateway } from "../target/types/pushsolanagateway";
import * as spl from "@solana/spl-token";

const PROGRAM_ID = new PublicKey("9nokRuXvtKyT32vvEQ1gkM3o8HzNooStpCuKuYD8BoX5");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const WHITELIST_SEED = "whitelist";

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("../upgrade-keypair.json", "utf8")))
);

// Set up connection and provider
const connection = new Connection("https://api.devnet.solana.com", "confirmed");
const adminProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
    commitment: "confirmed",
});

anchor.setProvider(adminProvider);

// Load IDL and create program instance
const idl = JSON.parse(fs.readFileSync("../target/idl/pushsolanagateway.json", "utf8"));
const program = new Program(idl as Pushsolanagateway, adminProvider);

async function testWithdrawals() {
    console.log("=== WITHDRAWAL TESTING ===\n");

    // Derive PDAs
    const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(CONFIG_SEED)],
        PROGRAM_ID
    );
    const [vaultPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(VAULT_SEED)],
        PROGRAM_ID
    );
    const [whitelistPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(WHITELIST_SEED)],
        PROGRAM_ID
    );

    const admin = adminKeypair.publicKey;

    console.log(`Program ID: ${PROGRAM_ID.toString()}`);
    console.log(`Admin/TSS: ${admin.toString()}`);
    console.log(`Config PDA: ${configPda.toString()}`);
    console.log(`Vault PDA: ${vaultPda.toString()}\n`);

    // Check current balances
    console.log("1. Checking current vault balances...");

    const vaultSolBalance = await adminProvider.connection.getBalance(vaultPda);
    console.log(`Vault SOL balance: ${vaultSolBalance / LAMPORTS_PER_SOL} SOL`);

    // Load existing SPL token mint from previous tests
    const tokenMintPath = "test-spl-token-mint.json";
    let mint: Keypair;

    try {
        const mintData = JSON.parse(fs.readFileSync(tokenMintPath, "utf8"));
        mint = Keypair.fromSecretKey(Uint8Array.from(mintData));
        console.log(`Found existing SPL token: ${mint.publicKey.toString()}`);

        // Check vault ATA balance
        try {
            const vaultAta = spl.getAssociatedTokenAddressSync(
                mint.publicKey,
                vaultPda,
                true // allowOwnerOffCurve
            );

            const vaultTokenAccount = await spl.getAccount(adminProvider.connection as any, vaultAta);
            console.log(`Vault SPL balance: ${vaultTokenAccount.amount.toString()} tokens`);
            console.log(`Vault ATA: ${vaultAta.toString()}\n`);
        } catch (error) {
            console.log("No SPL tokens in vault\n");
        }
    } catch (error) {
        console.log("No existing SPL token found\n");
    }

    // Test 1: SOL Withdrawal
    if (vaultSolBalance > 0) {
        console.log("2. Testing SOL withdrawal...");

        const withdrawAmount = new anchor.BN(Math.min(0.002 * LAMPORTS_PER_SOL, vaultSolBalance * 0.1)); // 0.002 SOL or 10% of vault
        const recipient = Keypair.generate().publicKey;

        console.log(`Withdrawing ${withdrawAmount.toNumber() / LAMPORTS_PER_SOL} SOL to ${recipient.toString()}`);

        try {
            const withdrawTx = await program.methods
                .withdrawFunds(recipient, withdrawAmount)
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    recipient: recipient,
                    tss: admin, // Admin acts as TSS in test setup
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ SOL withdrawal completed: ${withdrawTx}`);

            // Check recipient balance
            const recipientBalance = await adminProvider.connection.getBalance(recipient);
            console.log(`Recipient received: ${recipientBalance / LAMPORTS_PER_SOL} SOL\n`);

        } catch (error) {
            console.log(`❌ SOL withdrawal failed: ${error.message}\n`);
        }
    } else {
        console.log("2. Skipping SOL withdrawal - no funds in vault\n");
    }

    // Test 2: SPL Token Withdrawal
    if (mint) {
        console.log("3. Testing SPL token withdrawal...");

        try {
            const vaultAta = spl.getAssociatedTokenAddressSync(
                mint.publicKey,
                vaultPda,
                true
            );

            const vaultTokenAccount = await spl.getAccount(adminProvider.connection as any, vaultAta);

            if (vaultTokenAccount.amount > BigInt(0)) {
                // Create recipient token account
                const recipientKeypair = Keypair.generate();
                const recipientAta = await spl.getOrCreateAssociatedTokenAccount(
                    adminProvider.connection as any,
                    adminKeypair,
                    mint.publicKey,
                    recipientKeypair.publicKey
                );

                const withdrawAmount = new anchor.BN(Math.min(100 * Math.pow(10, 6), Number(vaultTokenAccount.amount) * 0.1)); // 100 tokens or 10% of vault

                console.log(`Withdrawing ${withdrawAmount.toNumber() / Math.pow(10, 6)} tokens to ${recipientKeypair.publicKey.toString()}`);
                console.log(`Recipient ATA: ${recipientAta.address.toString()}`);

                try {
                    const withdrawSplTx = await program.methods
                        .withdrawSplToken(withdrawAmount)
                        .accounts({
                            config: configPda,
                            whitelist: whitelistPda,
                            tokenVault: vaultAta,
                            tss: admin,
                            recipientTokenAccount: recipientAta.address,
                            tokenMint: mint.publicKey,
                            tokenProgram: spl.TOKEN_PROGRAM_ID,
                        })
                        .signers([adminKeypair])
                        .rpc();

                    console.log(`✅ SPL withdrawal completed: ${withdrawSplTx}`);

                    // Check recipient balance
                    const recipientTokenBalance = await spl.getAccount(adminProvider.connection as any, recipientAta.address);
                    console.log(`Recipient received: ${recipientTokenBalance.amount.toString()} tokens\n`);

                } catch (error) {
                    console.log(`❌ SPL withdrawal failed: ${error.message}\n`);
                }
            } else {
                console.log("No SPL tokens in vault to withdraw\n");
            }
        } catch (error) {
            console.log(`❌ Could not check SPL vault: ${error.message}\n`);
        }
    } else {
        console.log("3. Skipping SPL withdrawal - no token mint found\n");
    }

    // Test 3: Unauthorized withdrawal attempt
    console.log("4. Testing unauthorized withdrawal (should fail)...");

    const unauthorizedUser = Keypair.generate();
    const unauthorizedProvider = new anchor.AnchorProvider(
        adminProvider.connection,
        new anchor.Wallet(unauthorizedUser),
        { commitment: "confirmed" }
    );
    const unauthorizedProgram = new Program(idl as Pushsolanagateway, unauthorizedProvider);

    try {
        await unauthorizedProgram.methods
            .withdrawFunds(unauthorizedUser.publicKey, new anchor.BN(1000))
            .accounts({
                config: configPda,
                vault: vaultPda,
                recipient: unauthorizedUser.publicKey,
                tss: unauthorizedUser.publicKey, // Wrong TSS
                systemProgram: SystemProgram.programId,
            })
            .signers([unauthorizedUser])
            .rpc();

        console.log("❌ Unauthorized withdrawal should have failed!");
    } catch (error) {
        console.log("✅ Unauthorized withdrawal correctly failed (expected)");
        console.log(`   Error: ${error.message.split('.')[0]}\n`);
    }

    console.log("=== WITHDRAWAL TESTING COMPLETE ===");
}

// Run the test
testWithdrawals().catch(console.error);
