import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../../target/types/universal_gateway";
import {
    PublicKey,
    Keypair,
    SystemProgram,
} from "@solana/web3.js";
import { createMockUSDT, createMockUSDC } from "./mockSpl";
import * as sharedState from "../shared-state";
import { getTssEthAddress, TSS_CHAIN_ID } from "./tss";
import { setupPriceFeed } from "../setup-pricefeed";

// Module-level promise to ensure setup runs only once per process
let setupPromise: Promise<void> | null = null;
const UPGRADEABLE_LOADER_PROGRAM_ID = new PublicKey(
    "BPFLoaderUpgradeab1e11111111111111111111111"
);

/**
 * Ensures test setup is complete. Idempotent - runs exactly once per process.
 * Can be called from any test file's before() hook.
 */
export async function ensureTestSetup(): Promise<void> {
    if (setupPromise) {
        return setupPromise;
    }

    setupPromise = (async () => {
        // Initialize Anchor provider if not already set
        if (!anchor.getProvider()) {
            anchor.setProvider(anchor.AnchorProvider.env());
        }
        const provider = anchor.getProvider() as anchor.AnchorProvider;
        const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

        // Step 1: Create keypairs and set shared state
        const adminWallet = provider.wallet as anchor.Wallet;
        const admin = adminWallet.payer as Keypair;
        const tssAddress = Keypair.generate();
        const pauser = Keypair.generate();
        const user1 = Keypair.generate();
        const user2 = Keypair.generate();

        sharedState.setAdmin(admin);
        sharedState.setTssAddress(tssAddress);
        sharedState.setPauser(pauser);
        sharedState.setUser1(user1);
        sharedState.setUser2(user2);

        // Step 2: Airdrop SOL to all accounts
        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(tssAddress.publicKey, airdropAmount),
            provider.connection.requestAirdrop(pauser.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
        ]);

        await new Promise(resolve => setTimeout(resolve, 2000));

        // Step 3: Initialize mock SPL tokens
        const mockUSDT = await createMockUSDT(provider.connection, admin);
        await mockUSDT.createMint();
        sharedState.setMockUSDT(mockUSDT);

        const mockUSDC = await createMockUSDC(provider.connection, admin);
        await mockUSDC.createMint();
        sharedState.setMockUSDC(mockUSDC);

        // Create token accounts and mint initial balances for testing
        const user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
        await mockUSDT.mintTo(user1UsdtAccount, 10000);
        const user1UsdcAccount = await mockUSDC.createTokenAccount(user1.publicKey);
        await mockUSDC.mintTo(user1UsdcAccount, 5000);
        const user2UsdtAccount = await mockUSDT.createTokenAccount(user2.publicKey);
        await mockUSDT.mintTo(user2UsdtAccount, 7500);

        // Step 4: Derive program PDAs
        const [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        const [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        const [feeVaultPda] = PublicKey.findProgramAddressSync([Buffer.from("fee_vault")], program.programId);
        const [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);
        const [nativeTokenRateLimitPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), PublicKey.default.toBuffer()],
            program.programId
        );
        const [usdtTokenRateLimitPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
            program.programId
        );
        const [usdcTokenRateLimitPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), mockUSDC.mint.publicKey.toBuffer()],
            program.programId
        );

        // Step 5: Setup mock Pyth price feed
        let mockPriceFeed: PublicKey;
        try {
            // Try to use existing price feed from config if it exists
            const configAccount = await program.account.config.fetch(configPda);
            mockPriceFeed = configAccount.pythPriceFeed;
            sharedState.setMockPriceFeed(mockPriceFeed);
        } catch {
            // Config doesn't exist yet, create new price feed
            mockPriceFeed = await setupPriceFeed();
            sharedState.setMockPriceFeed(mockPriceFeed);
        }

        // Step 6: Initialize or fetch config
        let configAccount: any;
        try {
            configAccount = await program.account.config.fetch(configPda);
            if (configAccount.admin.toString() !== admin.publicKey.toString()) {
                throw new Error(
                    `Config admin ${configAccount.admin.toString()} does not match provider wallet ${admin.publicKey.toString()}. Delete .anchor/test-ledger and rerun tests.`
                );
            }
            // Use existing price feed from config
            sharedState.setMockPriceFeed(configAccount.pythPriceFeed);
        } catch {
            const [programData] = PublicKey.findProgramAddressSync(
                [program.programId.toBuffer()],
                UPGRADEABLE_LOADER_PROGRAM_ID
            );
            // Initialize with mock-pyth price feed
            await program.methods
                .initialize(
                    admin.publicKey,
                    pauser.publicKey,
                    tssAddress.publicKey,
                    new anchor.BN(100_000_000),
                    new anchor.BN(1_000_000_000),
                    mockPriceFeed
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    program: program.programId,
                    programData,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
            configAccount = await program.account.config.fetch(configPda);
            sharedState.setMockPriceFeed(configAccount.pythPriceFeed);
        }

        // Step 7: Initialize or update TSS
        const [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("tsspda_v2")], program.programId);
        const expectedTssEthAddress = getTssEthAddress();
        const expectedChainId = TSS_CHAIN_ID; // String: Solana cluster pubkey

        try {
            const existingTss = await program.account.tssPda.fetch(tssPda);
            const storedAddress = Buffer.from(existingTss.tssEthAddress);
            const expectedAddress = Buffer.from(expectedTssEthAddress);
            if (!storedAddress.equals(expectedAddress) || existingTss.chainId !== expectedChainId) {
                await program.methods
                    .updateTss(expectedTssEthAddress, expectedChainId)
                    .accountsPartial({ tssPda, config: configPda, authority: admin.publicKey })
                    .signers([admin])
                    .rpc();
            }
        } catch {
            await program.methods
                .initTss(expectedTssEthAddress, expectedChainId)
                .accountsPartial({
                    tssPda,
                    authority: admin.publicKey,
                    config: configPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }

        // Step 8: Initialize rate_limit_config PDA (required for universal gateway)
        try {
            await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
        } catch {
            // Not initialized, create it by calling set_block_usd_cap (which uses init_if_needed)
            await program.methods
                .setBlockUsdCap(new anchor.BN(1_000_000_000)) // 1 billion USD cap
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }

        // Step 9: Ensure fee_vault exists (devnet-safe path) and starts disabled
        await program.methods
            .setProtocolFee(new anchor.BN(0))
            .accountsPartial({
                config: configPda,
                feeVault: feeVaultPda,
                admin: admin.publicKey,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        // Step 10: Normalize rate-limit state so suites don't inherit stale 0-threshold config
        await program.methods
            .updateEpochDuration(new anchor.BN(0))
            .accountsPartial({
                admin: admin.publicKey,
                config: configPda,
                rateLimitConfig: rateLimitConfigPda,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        const veryLargeThreshold = new anchor.BN("1000000000000000000000");
        for (const [tokenMint, tokenRateLimit] of [
            [PublicKey.default, nativeTokenRateLimitPda],
            [mockUSDT.mint.publicKey, usdtTokenRateLimitPda],
            [mockUSDC.mint.publicKey, usdcTokenRateLimitPda],
        ] as const) {
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit,
                    tokenMint,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }
    })();

    return setupPromise;
}
