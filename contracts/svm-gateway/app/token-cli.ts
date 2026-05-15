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
import {
    createCreateMetadataAccountV3Instruction,
    PROGRAM_ID as TOKEN_METADATA_PROGRAM_ID,
} from "@metaplex-foundation/mpl-token-metadata";
import { Command } from "commander";

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
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

// Helper function to create SPL token with metadata
async function createSPLToken(
    provider: anchor.AnchorProvider,
    wallet: Keypair,
    tokenName: string,
    tokenSymbol: string,
    tokenDescription: string,
    decimals: number = 6
): Promise<{ mint: Keypair; tokenAccount: PublicKey; metadataAccount: PublicKey }> {
    console.log(`🪙 Creating new SPL token: ${tokenName} (${tokenSymbol})...`);

    const mint = Keypair.generate();
    const mintRent = await spl.getMinimumBalanceForRentExemptMint(provider.connection as any);

    // Create metadata account PDA
    const [metadataAccount] = PublicKey.findProgramAddressSync(
        [
            Buffer.from("metadata"),
            TOKEN_METADATA_PROGRAM_ID.toBuffer(),
            mint.publicKey.toBuffer(),
        ],
        TOKEN_METADATA_PROGRAM_ID
    );

    const tokenTransaction = new anchor.web3.Transaction();

    // Create mint account
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

    // Create metadata account
    const createMetadataInstruction = createCreateMetadataAccountV3Instruction(
        {
            metadata: metadataAccount,
            mint: mint.publicKey,
            mintAuthority: wallet.publicKey,
            payer: wallet.publicKey,
            updateAuthority: wallet.publicKey,
        },
        {
            createMetadataAccountArgsV3: {
                data: {
                    name: tokenName,
                    symbol: tokenSymbol,
                    uri: "", // No URI for now, can be added later
                    sellerFeeBasisPoints: 0,
                    creators: null,
                    collection: null,
                    uses: null,
                },
                isMutable: true,
                collectionDetails: null,
            },
        }
    );

    tokenTransaction.add(createMetadataInstruction);

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

    console.log(`✅ SPL Token created with metadata:`);
    console.log(`   Name: ${tokenName}`);
    console.log(`   Symbol: ${tokenSymbol}`);
    console.log(`   Description: ${tokenDescription}`);
    console.log(`   Mint: ${mint.publicKey.toString()}`);
    console.log(`   Metadata Account: ${metadataAccount.toString()}`);
    console.log(`   Token Account: ${tokenAccount.address.toString()}`);
    console.log(`   Decimals: ${decimals}`);
    console.log(`   Initial Supply: 1,000,000 tokens\n`);

    return { mint, tokenAccount: tokenAccount.address, metadataAccount };
}

// Helper function to mint tokens to any address
async function mintTokensToAddress(
    provider: anchor.AnchorProvider,
    mintAuthority: Keypair,
    mintAddress: string,
    recipientAddress: string,
    amount: number,
    decimals: number = 6
): Promise<void> {
    console.log(`🪙 Minting ${amount} tokens to ${recipientAddress}...`);

    const mint = new PublicKey(mintAddress);
    const recipient = new PublicKey(recipientAddress);

    // Get or create associated token account for recipient
    const recipientTokenAccount = await spl.getOrCreateAssociatedTokenAccount(
        provider.connection as any,
        mintAuthority,
        mint,
        recipient
    );

    // Convert amount to proper units (considering decimals)
    const mintAmount = amount * Math.pow(10, decimals);

    // Mint tokens
    const mintToTransaction = new anchor.web3.Transaction().add(
        spl.createMintToInstruction(
            mint,
            recipientTokenAccount.address,
            mintAuthority.publicKey,
            mintAmount
        )
    );

    const signature = await anchor.web3.sendAndConfirmTransaction(
        provider.connection as any,
        mintToTransaction,
        [mintAuthority]
    );

    console.log(`✅ Successfully minted ${amount} tokens to ${recipientAddress}`);
    console.log(`   Recipient Token Account: ${recipientTokenAccount.address.toString()}`);
    console.log(`   Transaction Signature: ${signature}\n`);
}

// Helper function to save token info to file
function saveTokenInfo(mint: Keypair, tokenName: string, tokenSymbol: string, decimals: number) {
    // Public token info (safe to commit)
    const tokenInfo = {
        mint: mint.publicKey.toString(),
        name: tokenName,
        symbol: tokenSymbol,
        decimals: decimals,
        createdAt: new Date().toISOString()
    };

    // Secret key info (never commit)
    const secretInfo = {
        mint: mint.publicKey.toString(),
        mintSecretKey: Array.from(mint.secretKey),
        symbol: tokenSymbol,
        createdAt: new Date().toISOString()
    };

    // Create directories if they don't exist
    if (!fs.existsSync("./tokens")) {
        fs.mkdirSync("./tokens");
    }
    if (!fs.existsSync("./secrets")) {
        fs.mkdirSync("./secrets");
    }

    // Save public info
    const publicFilename = `./tokens/${tokenSymbol.toLowerCase()}-token.json`;
    fs.writeFileSync(publicFilename, JSON.stringify(tokenInfo, null, 2));
    console.log(`💾 Token info saved to: ${publicFilename}`);

    // Save secret info
    const secretFilename = `./secrets/${tokenSymbol.toLowerCase()}-secret.json`;
    fs.writeFileSync(secretFilename, JSON.stringify(secretInfo, null, 2));
    console.log(`🔐 Secret key saved to: ${secretFilename}`);
}

// Helper function to load token info from file
function loadTokenInfo(tokenSymbol: string): any {
    const filename = `./tokens/${tokenSymbol.toLowerCase()}-token.json`;

    if (!fs.existsSync(filename)) {
        throw new Error(`Token file not found: ${filename}`);
    }

    return JSON.parse(fs.readFileSync(filename, "utf8"));
}

// Helper function to load secret key from file
function loadSecretKey(tokenSymbol: string): Keypair {
    const filename = `./secrets/${tokenSymbol.toLowerCase()}-secret.json`;

    if (!fs.existsSync(filename)) {
        throw new Error(`Secret file not found: ${filename}. Please create the token first.`);
    }

    const secretInfo = JSON.parse(fs.readFileSync(filename, "utf8"));
    return Keypair.fromSecretKey(Uint8Array.from(secretInfo.mintSecretKey));
}

// Initialize the CLI
const program_cli = new Command();

program_cli
    .name('token-cli')
    .description('CLI tool for managing SPL tokens with metadata')
    .version('1.0.0');

// Create token command
program_cli
    .command('create')
    .description('Create a new SPL token with metadata')
    .requiredOption('-n, --name <name>', 'Token name (e.g., "USD Coin")')
    .requiredOption('-s, --symbol <symbol>', 'Token symbol (e.g., "USDC")')
    .option('-d, --description <description>', 'Token description', 'A custom SPL token')
    .option('--decimals <decimals>', 'Number of decimals', '6')
    .action(async (options) => {
        try {
            console.log("=== CREATING NEW SPL TOKEN ===\n");

            const decimals = parseInt(options.decimals);
            const { mint, tokenAccount, metadataAccount } = await createSPLToken(
                adminProvider,
                adminKeypair,
                options.name,
                options.symbol,
                options.description,
                decimals
            );

            // Save token info
            saveTokenInfo(mint, options.name, options.symbol, decimals);

            console.log("🎉 Token creation completed successfully!");

        } catch (error) {
            console.error("❌ Error creating token:", error.message);
            process.exit(1);
        }
    });

// Mint tokens command
program_cli
    .command('mint')
    .description('Mint tokens to any address')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .requiredOption('-r, --recipient <recipient>', 'Recipient address')
    .requiredOption('-a, --amount <amount>', 'Amount to mint')
    .option('--decimals <decimals>', 'Number of decimals (if using mint address)', '6')
    .action(async (options) => {
        try {
            console.log("=== MINTING TOKENS ===\n");

            let mintAddress: string;
            let decimals: number;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
                decimals = parseInt(options.decimals);
            } else {
                // It's a token symbol, load from file
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                decimals = tokenInfo.decimals || 6; // Use stored decimals or default to 6
            }

            const amount = parseFloat(options.amount);

            await mintTokensToAddress(
                adminProvider,
                adminKeypair,
                mintAddress,
                options.recipient,
                amount,
                decimals
            );

            console.log("🎉 Token minting completed successfully!");

        } catch (error) {
            console.error("❌ Error minting tokens:", error.message);
            process.exit(1);
        }
    });

// List tokens command
program_cli
    .command('list')
    .description('List all created tokens')
    .action(() => {
        try {
            console.log("=== CREATED TOKENS ===\n");

            if (!fs.existsSync("./tokens")) {
                console.log("No tokens created yet.");
                return;
            }

            const files = fs.readdirSync("./tokens");
            const tokenFiles = files.filter(file => file.endsWith('-token.json'));

            if (tokenFiles.length === 0) {
                console.log("No tokens created yet.");
                return;
            }

            tokenFiles.forEach(file => {
                const tokenInfo = JSON.parse(fs.readFileSync(`./tokens/${file}`, "utf8"));
                console.log(`📄 ${tokenInfo.symbol} (${tokenInfo.name})`);
                console.log(`   Mint: ${tokenInfo.mint}`);
                console.log(`   Created: ${tokenInfo.createdAt}`);
                console.log("");
            });

        } catch (error) {
            console.error("❌ Error listing tokens:", error.message);
            process.exit(1);
        }
    });

// Whitelist token command (sets threshold to non-zero + creates vault ATA)
program_cli
    .command('whitelist')
    .description('Whitelist a token by setting its rate limit threshold to non-zero and creating its vault ATA')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .option('-t, --threshold <threshold>', 'Rate limit threshold in token natural units (default: max u64)', '18446744073709551615')
    .option('--trusted-mint-authority', 'Acknowledge that this token retains mint authority')
    .option('--trusted-freeze-authority', 'Acknowledge that this token retains freeze authority')
    .action(async (options) => {
        try {
            console.log("=== WHITELISTING TOKEN ===\n");

            let mintAddress: string;
            if (options.mint.length >= 32 && options.mint.length <= 44) {
                mintAddress = options.mint;
            } else {
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            const mintPubkey = new PublicKey(mintAddress);
            const admin = adminKeypair.publicKey;
            const threshold = BigInt(options.threshold);

            if (threshold === BigInt(0)) {
                console.error("❌ Threshold must be non-zero to whitelist. Use 'unwhitelist' to set threshold to 0.");
                process.exit(1);
            }

            const [configPda] = PublicKey.findProgramAddressSync([Buffer.from(CONFIG_SEED)], PROGRAM_ID);
            const [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from(VAULT_SEED)], PROGRAM_ID);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from(RATE_LIMIT_SEED), mintPubkey.toBuffer()], PROGRAM_ID
            );

            // Step 1: Set token rate limit threshold
            console.log(`Setting rate limit threshold to ${threshold.toString()}...`);
            const veryLargeThreshold = new anchor.BN(threshold.toString());
            await program.methods
                .setTokenRateLimit(
                    veryLargeThreshold,
                    Boolean(options.trustedMintAuthority),
                    Boolean(options.trustedFreezeAuthority),
                )
                .accountsPartial({
                    admin,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mintPubkey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();
            console.log(`✅ Token rate limit set\n`);

            // Step 2: Create vault ATA (so the vault can hold this token)
            console.log("Creating vault ATA...");
            const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
                adminProvider.connection as any,
                adminKeypair,
                mintPubkey,
                vaultPda,
                true // allowOwnerOffCurve (PDA)
            );
            console.log(`✅ Vault ATA: ${vaultAta.address.toString()}\n`);

            console.log(`🎉 Token ${mintAddress} whitelisted successfully!`);

        } catch (error) {
            console.error("❌ Error whitelisting token:", error.message);
            process.exit(1);
        }
    });

// Unwhitelist token command (sets threshold to 0)
program_cli
    .command('unwhitelist')
    .description('Unwhitelist a token by setting its rate limit threshold to 0')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .action(async (options) => {
        try {
            console.log("=== UNWHITELISTING TOKEN ===\n");

            let mintAddress: string;
            if (options.mint.length >= 32 && options.mint.length <= 44) {
                mintAddress = options.mint;
            } else {
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            const mintPubkey = new PublicKey(mintAddress);
            const admin = adminKeypair.publicKey;

            const [configPda] = PublicKey.findProgramAddressSync([Buffer.from(CONFIG_SEED)], PROGRAM_ID);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from(RATE_LIMIT_SEED), mintPubkey.toBuffer()], PROGRAM_ID
            );

            console.log(`Setting rate limit threshold to 0...`);
            await program.methods
                .setTokenRateLimit(new anchor.BN(0), false, false)
                .accountsPartial({
                    admin,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mintPubkey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`🎉 Token ${mintAddress} unwhitelisted (threshold set to 0)!`);

        } catch (error) {
            console.error("❌ Error unwhitelisting token:", error.message);
            process.exit(1);
        }
    });

// Transfer mint authority command
program_cli
    .command('transfer-mint-authority')
    .description('Transfer mint authority of a token from clean-user-keypair to upgrade-keypair (admin)')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .action(async (options) => {
        try {
            console.log("=== TRANSFERRING MINT AUTHORITY ===\n");

            let mintAddress: string;
            if (options.mint.length >= 32 && options.mint.length <= 44) {
                mintAddress = options.mint;
            } else {
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            const mintPubkey = new PublicKey(mintAddress);

            console.log(`Current authority: ${userKeypair.publicKey.toString()}`);
            console.log(`New authority:     ${adminKeypair.publicKey.toString()}`);

            const tx = new anchor.web3.Transaction().add(
                spl.createSetAuthorityInstruction(
                    mintPubkey,
                    userKeypair.publicKey,
                    spl.AuthorityType.MintTokens,
                    adminKeypair.publicKey,
                )
            );

            const sig = await anchor.web3.sendAndConfirmTransaction(
                userProvider.connection as any,
                tx,
                [userKeypair]
            );

            console.log(`✅ Mint authority transferred`);
            console.log(`   Tx: ${sig}\n`);

        } catch (error) {
            console.error("❌ Error transferring mint authority:", error.message);
            process.exit(1);
        }
    });

// Check whitelist status command
program_cli
    .command('check-whitelist')
    .description('Check if a token is whitelisted (has non-zero rate limit threshold)')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .action(async (options) => {
        try {
            console.log("=== CHECK TOKEN WHITELIST STATUS ===\n");

            let mintAddress: string;
            let tokenSymbol: string | null = null;
            if (options.mint.length >= 32 && options.mint.length <= 44) {
                mintAddress = options.mint;
            } else {
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                tokenSymbol = tokenInfo.symbol;
            }

            const mintPubkey = new PublicKey(mintAddress);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from(RATE_LIMIT_SEED), mintPubkey.toBuffer()], PROGRAM_ID
            );

            try {
                const rateLimitAccount = await (program.account as any).tokenRateLimit.fetch(tokenRateLimitPda);
                const threshold = BigInt(rateLimitAccount.limitThreshold.toString());
                const isWhitelisted = threshold > BigInt(0);

                const label = tokenSymbol ? `${tokenSymbol} (${mintAddress})` : mintAddress;
                console.log(`Token: ${label}`);
                console.log(`Rate Limit PDA: ${tokenRateLimitPda.toString()}`);
                console.log(`Threshold: ${threshold.toString()}`);
                console.log(`Status: ${isWhitelisted ? "✅ WHITELISTED" : "❌ NOT WHITELISTED (threshold is 0)"}`);
            } catch {
                console.log(`Token: ${mintAddress}`);
                console.log(`Status: ❌ NOT WHITELISTED (no rate limit account found)`);
            }

        } catch (error) {
            console.error("❌ Error checking whitelist status:", error.message);
            process.exit(1);
        }
    });

// Load environment variables
dotenv.config({ path: "../.env" });
dotenv.config();

// Parse command line arguments
program_cli.parse();
