import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram, LAMPORTS_PER_SOL } from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";
import { getSolPrice, calculateSolAmount } from "./setup-pricefeed";
import * as spl from "@solana/spl-token";
import { ensureTestSetup } from "./helpers/test-setup";

describe("Universal Gateway - Rate Limiting Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    before(async () => {
        await ensureTestSetup();
    });

    let admin: Keypair;
    let user1: Keypair;
    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let feeVaultPda: PublicKey;
    let rateLimitConfigPda: PublicKey;
    let mockPriceFeed: PublicKey;
    let solPrice: number;
    let mockUSDT: any;

    // Helper to get token rate limit PDA
    const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), tokenMint.toBuffer()],
            program.programId
        );
        return pda;
    };


    before(async () => {
        admin = sharedState.getAdmin();
        user1 = Keypair.generate();

        const airdropAmount = 20 * LAMPORTS_PER_SOL;
        await provider.connection.requestAirdrop(user1.publicKey, airdropAmount);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [feeVaultPda] = PublicKey.findProgramAddressSync([Buffer.from("fee_vault")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);

        mockPriceFeed = sharedState.getMockPriceFeed();
        solPrice = await getSolPrice(mockPriceFeed);
        mockUSDT = sharedState.getMockUSDT();

        // Normalize native token rate limit so this suite starts from a supported token state.
        const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // 1 sextillion (effectively unlimited)
        const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
        await program.methods
            .setTokenRateLimit(veryLargeThreshold)
            .accountsPartial({
                admin: admin.publicKey,
                config: configPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenMint: PublicKey.default,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();
    });

    describe("Block USD Cap Enforcement", () => {
        it("Should enforce block USD cap when enabled", async () => {
            // Enable block USD cap: $4 per slot (4 * 1e8 = 400_000_000)
            // Use $4 so that a single $3 transaction is under, but $3 + $3 = $6 would exceed
            const blockCapUsd = 4; // $4
            const blockCapLamports = new anchor.BN(blockCapUsd * 100_000_000); // 8 decimals

            await program.methods
                .setBlockUsdCap(blockCapLamports)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Calculate gas amount: $3 USD (within $1-$10 caps, but $3 + $3 = $6 > $4 block cap)
            const gasAmountUsd = 3; // $3
            const gasAmount = calculateSolAmount(gasAmountUsd, solPrice);

            const req1 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0), // GAS route
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig1"),
            };

            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            // First transaction should succeed (consumes $3, under $4 cap)
            await program.methods
                .sendUniversalTx(req1, new anchor.BN(gasAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Verify first transaction consumed $3
            const rateLimitConfigAfterFirst = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            const consumedAfterFirst = rateLimitConfigAfterFirst.consumedUsdInBlock.toNumber();
            const slotAfterFirst = rateLimitConfigAfterFirst.lastSlot.toNumber();

            // Verify consumed amount is approximately $3 (with some tolerance for price calculation)
            // Note: calculate_usd_amount returns value in 8 decimals, so we need to account for price precision
            // The actual consumed amount depends on the price calculation, so we just verify it's > 0
            expect(consumedAfterFirst).to.be.greaterThan(0);
            // Also verify it's reasonable (should be close to $3 * 1e8, but allow for price calculation differences)
            const minExpected = (gasAmountUsd * 0.5) * 100_000_000; // At least 50% of expected
            const maxExpected = (gasAmountUsd * 1.5) * 100_000_000; // At most 150% of expected
            expect(consumedAfterFirst).to.be.within(minExpected, maxExpected);

            // Second transaction should fail if in same slot (would exceed $4 cap: $3 + $3 = $6)
            // Send immediately to maximize chance of same slot
            let secondTxSucceeded = false;
            let slotAfterSecond: number;
            let consumedAfterSecond: number;

            try {
                await program.methods
                    .sendUniversalTx(req1, new anchor.BN(gasAmount))
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        userTokenAccount: null,
                        gatewayTokenAccount: null,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();

                secondTxSucceeded = true;
                const rateLimitConfigAfterSecond = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
                consumedAfterSecond = rateLimitConfigAfterSecond.consumedUsdInBlock.toNumber();
                slotAfterSecond = rateLimitConfigAfterSecond.lastSlot.toNumber();
            } catch (error: any) {
                // Transaction failed - check if it's the expected error
                const errorNumber = error.error?.errorCode?.number || error.errorCode?.number;
                const errorCode = error.error?.errorCode?.code ||
                    error.errorCode?.code ||
                    error.code ||
                    error.error?.code;

                if (errorNumber === 6019 || errorCode === "BlockUsdCapExceeded") {
                    // Expected error - verify it was in the same slot
                    const rateLimitConfigAfterSecond = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
                    slotAfterSecond = rateLimitConfigAfterSecond.lastSlot.toNumber();
                    consumedAfterSecond = rateLimitConfigAfterSecond.consumedUsdInBlock.toNumber();

                    // If same slot, consumed should still be $3 (second tx failed before adding)
                    // If different slot, consumed would be reset to 0
                    if (slotAfterSecond === slotAfterFirst) {
                        // Same slot - verify consumed amount didn't increase (tx failed before adding)
                        expect(consumedAfterSecond).to.be.closeTo(consumedAfterFirst, consumedAfterFirst * 0.1);
                        return; // Test passed - same slot, correctly rejected
                    } else {
                        // Different slot - this test case is invalid, but verify reset happened
                        expect(consumedAfterSecond).to.equal(0);
                        expect.fail("Second transaction was in different slot - cannot test same-slot cap enforcement. This is expected in Solana's async model.");
                    }
                } else {
                    throw error; // Unexpected error
                }
            }

            // If we reach here, second transaction succeeded
            if (secondTxSucceeded) {
                // Check if it was in the same slot
                if (slotAfterSecond === slotAfterFirst) {
                    // Same slot - this is a bug! Should have been rejected
                    expect.fail(`Block USD cap exceeded in same slot! Slot: ${slotAfterFirst}, Consumed: ${consumedAfterSecond} (should be <= ${blockCapUsd * 100_000_000})`);
                } else {
                    // Different slot - consumed should have reset
                    const expectedConsumed = gasAmountUsd * 100_000_000;
                    const minExpected = (gasAmountUsd * 0.5) * 100_000_000;
                    const maxExpected = (gasAmountUsd * 1.5) * 100_000_000;
                    expect(consumedAfterSecond).to.be.within(minExpected, maxExpected);
                    expect(slotAfterSecond).to.be.greaterThan(slotAfterFirst);
                    // This is expected behavior - slots advanced, cap reset
                }
            }

            // Disable block cap for other tests
            await program.methods
                .setBlockUsdCap(new anchor.BN(0))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        });

        it("Should reset consumed amount when slot changes", async () => {
            // Enable block USD cap: $10 per slot
            const blockCapUsd = 10;
            const blockCapLamports = new anchor.BN(blockCapUsd * 100_000_000);

            await program.methods
                .setBlockUsdCap(blockCapLamports)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const gasAmountUsd = 2.5; // $2.5 (above $1 min cap, below $10 max cap)
            const gasAmount = calculateSolAmount(gasAmountUsd, solPrice);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig"),
            };

            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            // First transaction
            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const config1 = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            const slot1 = config1.lastSlot.toNumber();
            const consumed1 = config1.consumedUsdInBlock.toNumber();

            // Wait a bit to ensure next transaction is in a different slot
            await new Promise(resolve => setTimeout(resolve, 500));

            // Second transaction in new slot should reset consumed amount
            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const config2 = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            const slot2 = config2.lastSlot.toNumber();
            const consumed2 = config2.consumedUsdInBlock.toNumber();

            // If slots are different, consumed should have reset
            if (slot2 !== slot1) {
                // New slot - consumed should reset to ~$2.5 (not accumulate from previous slot)
                const minExpected = (gasAmountUsd * 0.5) * 100_000_000;
                const maxExpected = (gasAmountUsd * 1.5) * 100_000_000;
                expect(consumed2).to.be.within(minExpected, maxExpected);
                expect(consumed2).to.be.lessThan(consumed1 + maxExpected); // Should NOT accumulate from previous slot
            } else {
                // Same slot - consumed should accumulate
                expect(consumed2).to.be.greaterThan(consumed1);
            }

            // Disable block cap
            await program.methods
                .setBlockUsdCap(new anchor.BN(0))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        });

        it("Should allow transactions when block USD cap is disabled (0)", async () => {
            // Ensure block cap is disabled
            await program.methods
                .setBlockUsdCap(new anchor.BN(0))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const gasAmount = calculateSolAmount(2.5, solPrice);
            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig"),
            };

            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            // Should succeed even with multiple transactions
            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Second transaction should also succeed (cap disabled)
            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        });
    });

    describe("Token Rate Limit Enforcement (Epoch-based)", () => {
        it("Should enforce token rate limit for native SOL when enabled", async () => {
            // Enable epoch duration (1 hour = 3600 seconds)
            await program.methods
                .updateEpochDuration(new anchor.BN(3600))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Set rate limit threshold: 1 SOL per epoch
            const limitThreshold = new anchor.BN(LAMPORTS_PER_SOL);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First transaction: 0.5 SOL (should succeed)
            const fundsAmount1 = 0.5 * LAMPORTS_PER_SOL;
            const req1 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount1),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig1"),
            };

            await program.methods
                .sendUniversalTx(req1, new anchor.BN(fundsAmount1))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Second transaction: 0.5 SOL (should succeed, total = 1 SOL = limit)
            const req2 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount1),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig2"),
            };

            await program.methods
                .sendUniversalTx(req2, new anchor.BN(fundsAmount1))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Third transaction: 0.1 SOL (should fail, would exceed 1 SOL limit)
            const fundsAmount3 = 0.1 * LAMPORTS_PER_SOL;
            const req3 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount3),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig3"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req3, new anchor.BN(fundsAmount3))
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        userTokenAccount: null,
                        gatewayTokenAccount: null,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when token rate limit would be exceeded");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code;
                expect(errorCode).to.equal("RateLimitExceeded");
            }
        });

        it("Should enforce token rate limit for SPL tokens when enabled", async () => {
            // Create user token account and mint tokens
            const userTokenAccount = await mockUSDT.createTokenAccount(user1.publicKey);
            const gatewayTokenAccount = (
                await spl.getOrCreateAssociatedTokenAccount(
                    provider.connection as any,
                    admin,
                    mockUSDT.mint.publicKey,
                    vaultPda,
                    true
                )
            ).address;
            await mockUSDT.mintTo(userTokenAccount, 5000); // 5000 tokens

            // Set rate limit: 1000 tokens per epoch (1000 * 10^6 = 1_000_000_000)
            const limitThreshold = new anchor.BN(1000 * Math.pow(10, mockUSDT.config.decimals));
            const usdtTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: usdtTokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First transaction: 500 tokens (should succeed)
            const tokenAmount1 = new anchor.BN(500 * Math.pow(10, mockUSDT.config.decimals));
            const req1 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: mockUSDT.mint.publicKey,
                amount: tokenAmount1,
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("spl_sig1"),
            };

            await program.methods
                .sendUniversalTx(req1, new anchor.BN(0))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: userTokenAccount,
                    gatewayTokenAccount: gatewayTokenAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdtTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Second transaction: 500 tokens (should succeed, total = 1000 = limit)
            const req2 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: mockUSDT.mint.publicKey,
                amount: tokenAmount1,
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("spl_sig2"),
            };

            await program.methods
                .sendUniversalTx(req2, new anchor.BN(0))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: userTokenAccount,
                    gatewayTokenAccount: gatewayTokenAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdtTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Third transaction: 100 tokens (should fail, would exceed 1000 limit)
            const tokenAmount3 = new anchor.BN(100 * Math.pow(10, mockUSDT.config.decimals));
            const req3 = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: mockUSDT.mint.publicKey,
                amount: tokenAmount3,
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("spl_sig3"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req3, new anchor.BN(0))
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        userTokenAccount: userTokenAccount,
                        gatewayTokenAccount: gatewayTokenAccount,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: usdtTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when SPL token rate limit would be exceeded");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code;
                expect(errorCode).to.equal("RateLimitExceeded");
            }
        });

        it("Should reject when limit_threshold is 0 (token not supported)", async () => {
            // Set limit_threshold to 0 - this means token is NOT supported (EVM v0 parity)
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            await program.methods
                .setTokenRateLimit(new anchor.BN(0))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Should fail with NotSupported error (threshold = 0 means token not supported)
            const largeAmount = 10 * LAMPORTS_PER_SOL;
            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(largeAmount),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(largeAmount))
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        userTokenAccount: null,
                        gatewayTokenAccount: null,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when limit_threshold is 0 (token not supported)");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code;
                expect(errorCode).to.equal("NotSupported");
            }
        });

        it("Should skip token rate limit when epoch_duration is 0", async () => {
            // Disable epoch duration
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

            // Set a small limit threshold
            const limitThreshold = new anchor.BN(LAMPORTS_PER_SOL);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Should succeed even with amounts exceeding threshold (epoch disabled)
            // Use a reasonable amount that user has balance for (check balance first)
            const userBalance = await provider.connection.getBalance(user1.publicKey);
            const largeAmount = Math.min(5 * LAMPORTS_PER_SOL, userBalance - 0.1 * LAMPORTS_PER_SOL); // Use 5 SOL or available balance - 0.1 SOL for fees

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(largeAmount),
                payload: Buffer.from([]),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(largeAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        });
    });

    describe("Rate Limit Edge Cases", () => {
        it("Should handle rate limits in FUNDS_AND_PAYLOAD routes", async () => {
            // Enable rate limiting
            await program.methods
                .updateEpochDuration(new anchor.BN(3600))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const limitThreshold = new anchor.BN(0.5 * LAMPORTS_PER_SOL);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // FUNDS_AND_PAYLOAD with batching should enforce rate limit on funds portion
            // Gas amount must be within USD caps ($1-$10), so use $2.50 for gas
            const gasAmountUsd = 2.5;
            const gasAmount = calculateSolAmount(gasAmountUsd, solPrice);
            const fundsAmount = 0.3 * LAMPORTS_PER_SOL;
            const totalAmount = fundsAmount + gasAmount;

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount),
                payload: Buffer.from("payload"),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig"),
            };

            // Should succeed (funds = 0.3 SOL, under 0.5 SOL limit)
            await program.methods
                .sendUniversalTx(req, new anchor.BN(totalAmount))
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    userTokenAccount: null,
                    gatewayTokenAccount: null,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Second transaction with 0.3 SOL funds should fail (total would be 0.6 SOL > 0.5 limit)
            const req2 = {
                recipient: Array.from(Buffer.alloc(20, 1)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount),
                payload: Buffer.from("payload"),
                revertRecipient: user1.publicKey,
                signatureData: Buffer.from("sig2"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req2, new anchor.BN(totalAmount))
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        userTokenAccount: null,
                        gatewayTokenAccount: null,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when rate limit would be exceeded in FUNDS_AND_PAYLOAD");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code;
                expect(errorCode).to.equal("RateLimitExceeded");
            }
        });
    });

    after(async () => {
        // Cleanup: Disable rate limits to prevent interference with other tests
        try {
            // Disable block USD cap
            await program.methods
                .setBlockUsdCap(new anchor.BN(0))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Disable epoch duration
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

            // Set very large thresholds to effectively disable
            const veryLargeThreshold = new anchor.BN("1000000000000000000000");
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        } catch (error) {
            // Ignore errors during cleanup
        }
    });
});
