#!/usr/bin/env node

import * as anchor from "@coral-xyz/anchor";
import * as dotenv from "dotenv";
import {
    PublicKey,
    Keypair,
    SystemProgram,
    ComputeBudgetProgram,
    TransactionInstruction,
    TransactionMessage,
    VersionedTransaction,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import type { UniversalGateway } from "../target/types/universal_gateway";
import { Command } from "commander";
import * as multisig from "@sqds/multisig";

// Program ID from gateway-test.ts
const PROGRAM_ID = new PublicKey("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");

// PDA Seeds
const CONFIG_SEED = "config";
const TSS_SEED = "tsspda_v2";
const VAULT_SEED = "vault";
const FEE_VAULT_SEED = "fee_vault";
const RATE_LIMIT_CONFIG_SEED = "rate_limit_config";
const RATE_LIMIT_SEED = "rate_limit";
const MAX_PROTOCOL_FEE_LAMPORTS = 2_000_000n;

// Load keypairs (same style as token-cli.ts)
function loadKeypair(path: string): Keypair {
    return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(fs.readFileSync(path, "utf8"))));
}

// Pre-parse role keypair paths and RPC from argv before Commander runs its
// command dispatch — Commander actions fire during parse(), so module-level
// setup must happen before that.
function preParseArg(flag: string, defaultVal: string): string {
    const prefix = flag + "=";
    for (let i = 0; i < process.argv.length; i++) {
        if (process.argv[i] === flag && i + 1 < process.argv.length) {
            return process.argv[i + 1];      // --flag value
        }
        if (process.argv[i].startsWith(prefix)) {
            return process.argv[i].slice(prefix.length); // --flag=value
        }
    }
    return defaultVal;
}

const adminKeypairPath    = preParseArg("--admin-keypair",    "./upgrade-keypair.json");
const operatorKeypairPath = preParseArg("--operator-keypair", "./upgrade-keypair.json");
const pauserKeypairPath   = preParseArg("--pauser-keypair",   "./upgrade-keypair.json");
const rpcUrl              = preParseArg("--rpc",              "https://api.devnet.solana.com");
const multisigPdaArg      = preParseArg("--multisig",         "");
const memberKeypairPath   = preParseArg("--member-keypair",   "");
const vaultIndexArg       = preParseArg("--vault-index",      "0");

const connection = new anchor.web3.Connection(rpcUrl, "confirmed");

let cachedIdl: UniversalGateway | null = null;
let cachedAdminKeypair: Keypair | null = null;
let cachedOperatorKeypair: Keypair | null = null;
let cachedPauserKeypair: Keypair | null = null;
let cachedMemberKeypair: Keypair | null = null;

function getIdl(): UniversalGateway {
    if (!cachedIdl) {
        cachedIdl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8")) as UniversalGateway;
    }
    return cachedIdl;
}

function getAdminKeypair(): Keypair {
    if (!cachedAdminKeypair) {
        cachedAdminKeypair = loadKeypair(adminKeypairPath);
    }
    return cachedAdminKeypair;
}

function getOperatorKeypair(): Keypair {
    if (!cachedOperatorKeypair) {
        cachedOperatorKeypair = loadKeypair(operatorKeypairPath);
    }
    return cachedOperatorKeypair;
}

function getPauserKeypair(): Keypair {
    if (!cachedPauserKeypair) {
        cachedPauserKeypair = loadKeypair(pauserKeypairPath);
    }
    return cachedPauserKeypair;
}

function getMemberKeypair(): Keypair {
    if (!memberKeypairPath) {
        throw new Error("Squads flow requires --member-keypair <path>");
    }
    if (!cachedMemberKeypair) {
        cachedMemberKeypair = loadKeypair(memberKeypairPath);
    }
    return cachedMemberKeypair;
}

function createProgramForKeypair(keypair: Keypair): Program<UniversalGateway> {
    const provider = new anchor.AnchorProvider(connection, new anchor.Wallet(keypair), {
        commitment: "confirmed",
    });
    return new Program(getIdl(), provider);
}

function createReadOnlyProgram(): Program<UniversalGateway> {
    const provider = new anchor.AnchorProvider(connection, new anchor.Wallet(Keypair.generate()), {
        commitment: "confirmed",
    });
    return new Program(getIdl(), provider);
}

function getMultisigPda(): PublicKey | null {
    if (!multisigPdaArg) {
        return null;
    }
    return new PublicKey(multisigPdaArg);
}

function getVaultIndex(): number {
    const parsed = Number.parseInt(vaultIndexArg, 10);
    if (!Number.isInteger(parsed) || parsed < 0) {
        throw new Error("--vault-index must be a non-negative integer");
    }
    return parsed;
}

function getVaultPdaForMultisig(multisigPda: PublicKey): PublicKey {
    const [vaultPda] = multisig.getVaultPda({
        multisigPda,
        index: getVaultIndex(),
    });
    return vaultPda;
}

async function sendInstructions(label: string, signer: Keypair, instructions: TransactionInstruction[]): Promise<string> {
    const { blockhash } = await connection.getLatestBlockhash();
    const message = new TransactionMessage({
        payerKey: signer.publicKey,
        recentBlockhash: blockhash,
        instructions,
    }).compileToV0Message();
    const tx = new VersionedTransaction(message);
    tx.sign([signer]);
    const sig = await connection.sendTransaction(tx);
    await connection.confirmTransaction(sig, "confirmed");
    console.log(`✅ ${label} successfully!`);
    console.log(`   Transaction: ${sig}\n`);
    return sig;
}

async function proposeVaultTransaction(
    member: Keypair,
    multisigPda: PublicKey,
    innerInstruction: TransactionInstruction,
    label: string,
): Promise<bigint> {
    const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, multisigPda);
    const txIndex = BigInt(msState.transactionIndex.toString()) + 1n;
    const vaultPda = getVaultPdaForMultisig(multisigPda);
    const { blockhash } = await connection.getLatestBlockhash();
    const innerMessage = new TransactionMessage({
        payerKey: vaultPda,
        recentBlockhash: blockhash,
        instructions: [innerInstruction],
    });

    const createIx = multisig.instructions.vaultTransactionCreate({
        multisigPda,
        transactionIndex: txIndex,
        creator: member.publicKey,
        rentPayer: member.publicKey,
        vaultIndex: getVaultIndex(),
        ephemeralSigners: 0,
        transactionMessage: innerMessage,
    });
    const proposalIx = multisig.instructions.proposalCreate({
        multisigPda,
        transactionIndex: txIndex,
        creator: member.publicKey,
        rentPayer: member.publicKey,
        isDraft: false,
    });

    await sendInstructions(`${label} proposal created`, member, [createIx, proposalIx]);

    console.log(`   Multisig: ${multisigPda.toBase58()}`);
    console.log(`   Vault PDA: ${vaultPda.toBase58()}`);
    console.log(`   Transaction Index: ${txIndex.toString()}`);
    console.log("   Next steps:");
    console.log(`   1. Approve: npm run config -- squads:approve --multisig ${multisigPda.toBase58()} --tx-index ${txIndex.toString()} --member-keypair <path>`);
    console.log(`   2. Execute: npm run config -- squads:execute --multisig ${multisigPda.toBase58()} --tx-index ${txIndex.toString()} --member-keypair <path>\n`);

    return txIndex;
}

async function runAuthorityAction(
    label: string,
    directSigner: () => Keypair,
    buildInstruction: (program: Program<UniversalGateway>, authority: PublicKey) => Promise<TransactionInstruction>,
): Promise<void> {
    const multisigPda = getMultisigPda();
    if (multisigPda) {
        const member = getMemberKeypair();
        const vaultPda = getVaultPdaForMultisig(multisigPda);
        const program = createProgramForKeypair(member);
        const ix = await buildInstruction(program, vaultPda);
        await proposeVaultTransaction(member, multisigPda, ix, label);
        return;
    }

    const signer = directSigner();
    const program = createProgramForKeypair(signer);
    const ix = await buildInstruction(program, signer.publicKey);
    await sendInstructions(label, signer, [ix]);
}

async function showProposal(multisigPda: PublicKey, txIndex: bigint): Promise<void> {
    const [proposalPda] = multisig.getProposalPda({ multisigPda, transactionIndex: txIndex });
    const proposal = await multisig.accounts.Proposal.fromAccountAddress(connection, proposalPda);
    const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, multisigPda);
    console.log(`Proposal ${txIndex.toString()}:`);
    console.log(`   Status: ${proposal.status.__kind}`);
    console.log(`   Approvals: ${proposal.approved.length} / ${msState.threshold}`);
    if (proposal.approved.length > 0) {
        console.log("   Approved by:");
        for (const approver of proposal.approved) {
            console.log(`   - ${approver.toBase58()}`);
        }
    }
}

async function approveProposal(multisigPda: PublicKey, member: Keypair, txIndex: bigint): Promise<void> {
    const approveIx = multisig.instructions.proposalApprove({
        multisigPda,
        transactionIndex: txIndex,
        member: member.publicKey,
    });
    await sendInstructions(`proposal ${txIndex.toString()} approved`, member, [approveIx]);
}

async function executeVaultTransaction(multisigPda: PublicKey, member: Keypair, txIndex: bigint): Promise<void> {
    const { instruction, lookupTableAccounts } = await multisig.instructions.vaultTransactionExecute({
        connection,
        multisigPda,
        transactionIndex: txIndex,
        member: member.publicKey,
    });
    const { blockhash } = await connection.getLatestBlockhash();
    const message = new TransactionMessage({
        payerKey: member.publicKey,
        recentBlockhash: blockhash,
        instructions: [instruction],
    }).compileToV0Message(lookupTableAccounts);
    const tx = new VersionedTransaction(message);
    tx.sign([member]);
    const sig = await connection.sendTransaction(tx, { skipPreflight: true });
    await connection.confirmTransaction(sig, "confirmed");
    console.log(`✅ proposal ${txIndex.toString()} executed successfully!`);
    console.log(`   Transaction: ${sig}\n`);
}

// Helper: Derive PDAs
function deriveConfigPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(CONFIG_SEED)], PROGRAM_ID);
    return pda;
}

function deriveTssPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(TSS_SEED)], PROGRAM_ID);
    return pda;
}

function deriveVaultPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(VAULT_SEED)], PROGRAM_ID);
    return pda;
}

function deriveFeeVaultPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(FEE_VAULT_SEED)], PROGRAM_ID);
    return pda;
}

function deriveRateLimitConfigPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(RATE_LIMIT_CONFIG_SEED)], PROGRAM_ID);
    return pda;
}

function deriveTokenRateLimitPda(mint: PublicKey): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync(
        [Buffer.from(RATE_LIMIT_SEED), mint.toBuffer()],
        PROGRAM_ID
    );
    return pda;
}

// Helper: Parse hex address (20 bytes for ETH address)
function parseEthAddress(hex: string): number[] {
    const cleaned = hex.startsWith("0x") ? hex.slice(2) : hex;
    if (cleaned.length !== 40) {
        throw new Error("ETH address must be 40 hex chars (20 bytes)");
    }
    const bytes = Buffer.from(cleaned, "hex");
    return Array.from(bytes);
}

// Helper: Format account display
function formatAccount(label: string, data: any, indent = "   ") {
    console.log(`${indent}${label}:`);
    for (const [key, value] of Object.entries(data)) {
        if (value instanceof PublicKey) {
            console.log(`${indent}  ${key}: ${value.toBase58()}`);
        } else if (Array.isArray(value) && value.length === 20) {
            // ETH address
            console.log(`${indent}  ${key}: 0x${Buffer.from(value).toString("hex")}`);
        } else if (typeof value === "object" && value !== null && "toNumber" in value) {
            // BN or similar
            console.log(`${indent}  ${key}: ${value.toString()}`);
        } else if (typeof value === "boolean") {
            console.log(`${indent}  ${key}: ${value ? "✅ true" : "❌ false"}`);
        } else {
            console.log(`${indent}  ${key}: ${JSON.stringify(value)}`);
        }
    }
}

// Initialize the CLI
const program_cli = new Command();

program_cli
    .name("config-cli")
    .description("CLI tool for managing gateway admin/config/TSS actions")
    .version("1.0.0")
    // Global keypair flags — each role must use its own key in production.
    // On devnet all three default to ./upgrade-keypair.json for convenience.
    .option("--admin-keypair <path>",    "Admin keypair JSON path",    "./upgrade-keypair.json")
    .option("--operator-keypair <path>", "Operator keypair JSON path", "./upgrade-keypair.json")
    .option("--pauser-keypair <path>",   "Pauser keypair JSON path",   "./upgrade-keypair.json")
    .option("--multisig <pda>",          "If set, create a Squads vault-transaction proposal instead of executing directly")
    .option("--member-keypair <path>",   "Squads member keypair JSON path used to create/approve/execute proposals")
    .option("--vault-index <n>",         "Squads vault index for the authority PDA", "0")
    .option("--rpc <url>",               "RPC endpoint URL",           "https://api.devnet.solana.com");

// ============================================
//               TSS COMMANDS
// ============================================

program_cli
    .command("tss:init")
    .description("Initialize TSS with ETH address and chain ID")
    .requiredOption("--eth <address>", "TSS ETH address (hex, 20 bytes)")
    .requiredOption("--chain-id <id>", "Chain ID string (e.g., Solana cluster pubkey)")
    .action(async (options) => {
        try {
            console.log("=== INITIALIZING TSS ===\n");

            const ethAddress = parseEthAddress(options.eth);
            const chainId = options.chainId;

            const configPda = deriveConfigPda();
            const tssPda = deriveTssPda();

            console.log(`TSS ETH Address: 0x${Buffer.from(ethAddress).toString("hex")}`);
            console.log(`Chain ID: ${chainId}`);
            console.log(`TSS PDA: ${tssPda.toBase58()}\n`);

            await runAuthorityAction(
                "TSS initialized",
                getAdminKeypair,
                (program, authority) => program.methods
                    .initTss(ethAddress, chainId)
                    .accountsPartial({
                        tssPda: tssPda,
                        config: configPda,
                        authority,
                        systemProgram: SystemProgram.programId,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error initializing TSS: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("tss:update")
    .description("Update TSS ETH address and/or chain ID (operator-only)")
    .requiredOption("--eth <address>", "New TSS ETH address (hex, 20 bytes)")
    .requiredOption("--chain-id <id>", "New chain ID string")
    .action(async (options) => {
        try {
            console.log("=== UPDATING TSS ===\n");

            const ethAddress = parseEthAddress(options.eth);
            const chainId = options.chainId;

            const configPda = deriveConfigPda();
            const tssPda = deriveTssPda();

            console.log(`New TSS ETH Address: 0x${Buffer.from(ethAddress).toString("hex")}`);
            console.log(`New Chain ID: ${chainId}`);
            console.log(`TSS PDA: ${tssPda.toBase58()}\n`);

            await runAuthorityAction(
                "TSS updated",
                getOperatorKeypair,
                (program, authority) => program.methods
                    .updateTss(ethAddress, chainId)
                    .accountsPartial({
                        tssPda: tssPda,
                        config: configPda,
                        authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error updating TSS: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             PAUSE COMMANDS
// ============================================

program_cli
    .command("pause")
    .description("Pause the gateway (emergency stop)")
    .action(async () => {
        try {
            console.log("=== PAUSING GATEWAY ===\n");

            const configPda = deriveConfigPda();

            await runAuthorityAction(
                "Gateway paused",
                getPauserKeypair,
                (program, authority) => program.methods
                    .pause()
                    .accountsPartial({
                        config: configPda,
                        pauser: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error pausing gateway: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("unpause")
    .description("Unpause the gateway (operator-only)")
    .action(async () => {
        try {
            console.log("=== UNPAUSING GATEWAY ===\n");

            const configPda = deriveConfigPda();
            await runAuthorityAction(
                "Gateway unpaused",
                getOperatorKeypair,
                (program, authority) => program.methods
                    .unpause()
                    .accountsPartial({
                        config: configPda,
                        operator: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error unpausing gateway: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("operator:set")
    .description("Set operator authority (admin-only, immediate)")
    .requiredOption("--new-operator <pubkey>", "New operator public key")
    .action(async (options) => {
        try {
            console.log("=== SETTING OPERATOR ===\n");
            const newOperator = new PublicKey(options.newOperator);
            const configPda = deriveConfigPda();
            console.log(`New operator: ${newOperator.toBase58()}`);
            console.log(`Config PDA: ${configPda.toBase58()}\n`);

            await runAuthorityAction(
                "Operator updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setOperator(newOperator)
                    .accountsPartial({
                        config: configPda,
                        admin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting operator: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//           AUTHORITY COMMANDS
// ============================================

program_cli
    .command("authority:propose")
    .description("Propose new admin and/or pauser authority")
    .option("--new-admin <pubkey>", "New admin public key")
    .option("--new-pauser <pubkey>", "New pauser public key")
    .action(async (options) => {
        try {
            if (!options.newAdmin && !options.newPauser) {
                throw new Error("Provide at least one of --new-admin or --new-pauser");
            }

            console.log("=== PROPOSING AUTHORITIES ===\n");

            const newAdmin = options.newAdmin ? new PublicKey(options.newAdmin) : null;
            const newPauser = options.newPauser ? new PublicKey(options.newPauser) : null;
            const configPda = deriveConfigPda();

            if (newAdmin) {
                console.log(`Proposed admin: ${newAdmin.toBase58()}`);
            }
            if (newPauser) {
                console.log(`Proposed pauser: ${newPauser.toBase58()}`);
            }
            console.log(`Config PDA: ${configPda.toBase58()}`);
            console.log();

            await runAuthorityAction(
                "Authorities proposed",
                getAdminKeypair,
                (program, authority) => program.methods
                    .proposeAuthorities(newAdmin, newPauser)
                    .accountsPartial({
                        config: configPda,
                        admin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error proposing authorities: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("authority:accept-admin")
    .description("Accept pending admin authority using the proposed admin signer or a Squads vault")
    .option("--keypair <path>", "Path to the proposed admin keypair JSON")
    .action(async (options) => {
        try {
            console.log("=== ACCEPTING ADMIN AUTHORITY ===\n");
            const configPda = deriveConfigPda();
            console.log(`Config PDA: ${configPda.toBase58()}`);
            console.log();

            const multisigPda = getMultisigPda();
            if (!multisigPda && !options.keypair) {
                throw new Error("EOA flow requires --keypair <path>; Squads flow requires --multisig and --member-keypair");
            }

            await runAuthorityAction(
                "Admin authority accepted",
                () => loadKeypair(options.keypair),
                (program, authority) => program.methods
                    .acceptAdmin()
                    .accountsPartial({
                        config: configPda,
                        pendingAdmin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error accepting admin authority: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("authority:accept-pauser")
    .description("Accept pending pauser authority using the proposed pauser signer or a Squads vault")
    .option("--keypair <path>", "Path to the proposed pauser keypair JSON")
    .action(async (options) => {
        try {
            console.log("=== ACCEPTING PAUSER AUTHORITY ===\n");
            const configPda = deriveConfigPda();
            console.log(`Config PDA: ${configPda.toBase58()}`);
            console.log();

            const multisigPda = getMultisigPda();
            if (!multisigPda && !options.keypair) {
                throw new Error("EOA flow requires --keypair <path>; Squads flow requires --multisig and --member-keypair");
            }

            await runAuthorityAction(
                "Pauser authority accepted",
                () => loadKeypair(options.keypair),
                (program, authority) => program.methods
                    .acceptPauser()
                    .accountsPartial({
                        config: configPda,
                        pendingPauser: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error accepting pauser authority: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             PROTOCOL FEE COMMANDS
// ============================================

program_cli
    .command("fee:init")
    .description("Initialize fee vault PDA (idempotent); optionally set initial protocol fee")
    .option("--fee <lamports>", "Initial protocol fee in lamports (u64)", "0")
    .action(async (options) => {
        try {
            console.log("=== INITIALIZING FEE VAULT ===\n");

            const feeLamports = BigInt(options.fee);
            if (feeLamports > MAX_PROTOCOL_FEE_LAMPORTS) {
                throw new Error(`Protocol fee must be <= ${MAX_PROTOCOL_FEE_LAMPORTS.toString()} lamports`);
            }
            const configPda = deriveConfigPda();
            const feeVaultPda = deriveFeeVaultPda();

            console.log(`Config PDA: ${configPda.toBase58()}`);
            console.log(`Fee Vault PDA: ${feeVaultPda.toBase58()}`);
            console.log(`Protocol Fee (lamports): ${feeLamports}\n`);

            await runAuthorityAction(
                "Fee vault initialized/updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setProtocolFee(new anchor.BN(feeLamports.toString()))
                    .accountsPartial({
                        config: configPda,
                        feeVault: feeVaultPda,
                        admin: authority,
                        systemProgram: SystemProgram.programId,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error initializing fee vault: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             CAPS COMMANDS
// ============================================

program_cli
    .command("caps:set")
    .description("Set min/max USD caps for universal transactions")
    .requiredOption("--min <value>", "Min cap in USD (u128, Pyth format: 1e8 = $1)")
    .requiredOption("--max <value>", "Max cap in USD (u128, Pyth format: 1e8 = $1)")
    .action(async (options) => {
        try {
            console.log("=== SETTING USD CAPS ===\n");

            const minCap = BigInt(options.min);
            const maxCap = BigInt(options.max);

            if (minCap > maxCap) {
                throw new Error("Min cap must not exceed max cap");
            }

            const configPda = deriveConfigPda();

            console.log(`Min Cap: ${minCap} (${Number(minCap) / 1e8} USD)`);
            console.log(`Max Cap: ${maxCap} (${Number(maxCap) / 1e8} USD)\n`);

            await runAuthorityAction(
                "USD caps updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setCapsUsd(
                        new anchor.BN(minCap.toString()),
                        new anchor.BN(maxCap.toString())
                    )
                    .accountsPartial({
                        config: configPda,
                        admin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting caps: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             PYTH COMMANDS
// ============================================

program_cli
    .command("pyth:set-feed")
    .description("Set Pyth price feed address")
    .requiredOption("--feed <pubkey>", "Pyth price feed public key")
    .action(async (options) => {
        try {
            console.log("=== SETTING PYTH PRICE FEED ===\n");

            const feed = new PublicKey(options.feed);
            const configPda = deriveConfigPda();

            console.log(`Pyth Feed: ${feed.toBase58()}\n`);

            await runAuthorityAction(
                "Pyth price feed updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setPythPriceFeed(feed)
                    .accountsPartial({
                        config: configPda,
                        admin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting Pyth feed: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("pyth:set-max-age")
    .description("Set Pyth price staleness window for inbound gas-route cap enforcement")
    .requiredOption("--seconds <value>", "Max age in seconds (u64); recommended: 60–90")
    .action(async (options) => {
        try {
            console.log("=== SETTING PYTH MAX AGE SECONDS ===\n");

            const maxAge = BigInt(options.seconds);
            const configPda = deriveConfigPda();

            console.log(`Max Age: ${maxAge} seconds\n`);

            await runAuthorityAction(
                "Pyth max age updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setPythMaxAgeSeconds(new anchor.BN(maxAge.toString()))
                    .accountsPartial({
                        config: configPda,
                        admin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting Pyth max age: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("pyth:set-conf")
    .description("Set Pyth confidence threshold")
    .requiredOption("--threshold <value>", "Confidence threshold (u64)")
    .action(async (options) => {
        try {
            console.log("=== SETTING PYTH CONFIDENCE THRESHOLD ===\n");

            const threshold = BigInt(options.threshold);
            const configPda = deriveConfigPda();

            console.log(`Confidence Threshold: ${threshold}\n`);

            await runAuthorityAction(
                "Pyth confidence threshold updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setPythConfidenceThreshold(new anchor.BN(threshold.toString()))
                    .accountsPartial({
                        config: configPda,
                        admin: authority,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting Pyth confidence: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//          RATE LIMIT COMMANDS
// ============================================

program_cli
    .command("rate:set-block-usd-cap")
    .description("Set block-level USD cap for rate limiting")
    .requiredOption("--cap <value>", "Block USD cap (u128, 8 decimals)")
    .action(async (options) => {
        try {
            console.log("=== SETTING BLOCK USD CAP ===\n");

            const cap = BigInt(options.cap);
            const configPda = deriveConfigPda();
            const rateLimitConfigPda = deriveRateLimitConfigPda();

            console.log(`Block USD Cap: ${cap} (${Number(cap) / 1e8} USD)\n`);

            await runAuthorityAction(
                "Block USD cap updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setBlockUsdCap(new anchor.BN(cap.toString()))
                    .accountsPartial({
                        config: configPda,
                        rateLimitConfig: rateLimitConfigPda,
                        admin: authority,
                        systemProgram: SystemProgram.programId,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting block USD cap: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("rate:set-epoch")
    .description("Set epoch duration for rate limiting")
    .requiredOption("--seconds <value>", "Epoch duration in seconds (u64)")
    .action(async (options) => {
        try {
            console.log("=== SETTING EPOCH DURATION ===\n");

            const seconds = BigInt(options.seconds);
            const configPda = deriveConfigPda();
            const rateLimitConfigPda = deriveRateLimitConfigPda();

            console.log(`Epoch Duration: ${seconds} seconds (${Number(seconds) / 60} minutes)\n`);

            await runAuthorityAction(
                "Epoch duration updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .updateEpochDuration(new anchor.BN(seconds.toString()))
                    .accountsPartial({
                        config: configPda,
                        rateLimitConfig: rateLimitConfigPda,
                        admin: authority,
                        systemProgram: SystemProgram.programId,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting epoch duration: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("rate:set-token")
    .description("Set rate limit threshold for a specific token")
    .requiredOption("--mint <pubkey>", "Token mint address (use Pubkey::default() for SOL)")
    .requiredOption("--threshold <value>", "Rate limit threshold (u128, token natural units)")
    .option("--trusted-mint-authority", "Acknowledge that this token retains mint authority")
    .option("--trusted-freeze-authority", "Acknowledge that this token retains freeze authority")
    .action(async (options) => {
        try {
            console.log("=== SETTING TOKEN RATE LIMIT ===\n");

            const mint = options.mint === "default" || options.mint === "11111111111111111111111111111111"
                ? PublicKey.default
                : new PublicKey(options.mint);
            const threshold = BigInt(options.threshold);

            const configPda = deriveConfigPda();
            const tokenRateLimitPda = deriveTokenRateLimitPda(mint);

            console.log(`Token Mint: ${mint.toBase58()}`);
            console.log(`Threshold: ${threshold}`);
            console.log(`Trusted Mint Authority: ${Boolean(options.trustedMintAuthority)}`);
            console.log(`Trusted Freeze Authority: ${Boolean(options.trustedFreezeAuthority)}`);
            console.log(`Token Rate Limit PDA: ${tokenRateLimitPda.toBase58()}\n`);

            await runAuthorityAction(
                "Token rate limit updated",
                getAdminKeypair,
                (program, authority) => program.methods
                    .setTokenRateLimit(
                        new anchor.BN(threshold.toString()),
                        Boolean(options.trustedMintAuthority),
                        Boolean(options.trustedFreezeAuthority),
                    )
                    .accountsPartial({
                        config: configPda,
                        tokenRateLimit: tokenRateLimitPda,
                        tokenMint: mint,
                        admin: authority,
                        systemProgram: SystemProgram.programId,
                    })
                    .instruction()
            );
        } catch (error: any) {
            console.error(`❌ Error setting token rate limit: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//           SQUADS HELPER COMMANDS
// ============================================

program_cli
    .command("squads:show")
    .description("Show Squads proposal status for a previously created vault transaction")
    .requiredOption("--tx-index <index>", "Squads transaction index")
    .action(async (options) => {
        try {
            const multisigPda = getMultisigPda();
            if (!multisigPda) {
                throw new Error("This command requires --multisig <pda>");
            }
            await showProposal(multisigPda, BigInt(options.txIndex));
        } catch (error: any) {
            console.error(`❌ Error showing proposal: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("squads:approve")
    .description("Approve a Squads proposal with the provided member signer")
    .requiredOption("--tx-index <index>", "Squads transaction index")
    .action(async (options) => {
        try {
            const multisigPda = getMultisigPda();
            if (!multisigPda) {
                throw new Error("This command requires --multisig <pda>");
            }
            const member = getMemberKeypair();
            await approveProposal(multisigPda, member, BigInt(options.txIndex));
        } catch (error: any) {
            console.error(`❌ Error approving proposal: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("squads:execute")
    .description("Execute an approved Squads vault transaction")
    .requiredOption("--tx-index <index>", "Squads transaction index")
    .action(async (options) => {
        try {
            const multisigPda = getMultisigPda();
            if (!multisigPda) {
                throw new Error("This command requires --multisig <pda>");
            }
            const member = getMemberKeypair();
            await executeVaultTransaction(multisigPda, member, BigInt(options.txIndex));
        } catch (error: any) {
            console.error(`❌ Error executing proposal: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//          CONFIG SHOW COMMAND
// ============================================

program_cli
    .command("config:show")
    .description("Show current gateway configuration (config + tss + rate_limit + fee_vault)")
    .action(async () => {
        try {
            const program = createReadOnlyProgram();
            console.log("=== GATEWAY CONFIGURATION ===\n");

            const configPda = deriveConfigPda();
            const tssPda = deriveTssPda();
            const rateLimitConfigPda = deriveRateLimitConfigPda();
            const feeVaultPda = deriveFeeVaultPda();

            // Fetch Config
            console.log("📋 Config Account");
            console.log(`   PDA: ${configPda.toBase58()}`);
            try {
                const config = await (program.account as any).config.fetch(configPda);
                formatAccount("Data", config);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            // Fetch TSS
            console.log("🔐 TSS Account");
            console.log(`   PDA: ${tssPda.toBase58()}`);
            try {
                const tss = await (program.account as any).tssPda.fetch(tssPda);
                formatAccount("Data", tss);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            // Fetch Rate Limit Config
            console.log("⏱️  Rate Limit Config");
            console.log(`   PDA: ${rateLimitConfigPda.toBase58()}`);
            try {
                const rateLimitConfig = await (program.account as any).rateLimitConfig.fetch(rateLimitConfigPda);
                formatAccount("Data", rateLimitConfig);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            // Fetch Fee Vault
            console.log("💸 Fee Vault");
            console.log(`   PDA: ${feeVaultPda.toBase58()}`);
            try {
                const feeVault = await (program.account as any).feeVault.fetch(feeVaultPda);
                formatAccount("Data", feeVault);
                const feeVaultBalance = await connection.getBalance(feeVaultPda);
                console.log(`   Balance (lamports): ${feeVaultBalance}`);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            console.log("✅ Configuration displayed successfully!\n");
        } catch (error: any) {
            console.error(`❌ Error fetching configuration: ${error.message}`);
            process.exit(1);
        }
    });

// Load environment variables
dotenv.config({ path: "../.env" });
dotenv.config();

// Parse command line arguments
program_cli.parse();
