import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";
import { getTssEthAddress, TSS_CHAIN_ID } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import { extractEventCpi } from "./helpers/test-utils";


describe("Universal Gateway - Admin Functions Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    const getErrorCode = (error: any): string | undefined => {
        return (
            error?.error?.errorCode?.code ||
            error?.errorCode?.code ||
            error?.error?.errorCode ||
            error?.code ||
            /Error Code: ([A-Za-z0-9_]+)/.exec(String(error))?.[1]
        );
    };

    before(async () => {
        await ensureTestSetup();
    });

    // Test accounts
    let admin: Keypair;
    let newAdmin: Keypair;
    let operator: Keypair;
    let pauser: Keypair;
    let newPauser: Keypair;
    let unauthorizedUser: Keypair;

    // Program PDAs
    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;
    let rateLimitConfigPda: PublicKey;

    // Mock assets
    let mockPriceFeed: PublicKey;
    let mockUSDT: any;
    before(async () => {
        admin = sharedState.getAdmin();
        operator = sharedState.getOperator();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        mockPriceFeed = sharedState.getMockPriceFeed();

        // Additional actors for admin mutation tests
        newAdmin = Keypair.generate();
        newPauser = Keypair.generate();
        unauthorizedUser = Keypair.generate();

        // Airdrop SOL
        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(newAdmin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(newPauser.publicKey, airdropAmount),
            provider.connection.requestAirdrop(unauthorizedUser.publicKey, airdropAmount),
        ]);

        await new Promise(resolve => setTimeout(resolve, 2000));

        // Derive PDAs
        [configPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("config")],
            program.programId
        );

        [vaultPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("vault")],
            program.programId
        );

        [tssPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("final_tss_pda")],
            program.programId
        );

        [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit_config")],
            program.programId
        );

        const config = await program.account.config.fetch(configPda);
        expect(config.admin.toString()).to.equal(admin.publicKey.toString());
        expect(config.pauser.toString()).to.equal(pauser.publicKey.toString());
        expect(config.operator.toString()).to.equal(operator.publicKey.toString());

    });

    describe("Access Control", () => {
        it("Verifies initial admin configuration", async () => {

            const config = await program.account.config.fetch(configPda);

            expect(config.admin.toString()).to.equal(admin.publicKey.toString());
            expect(config.operator.toString()).to.equal(operator.publicKey.toString());
            expect(config.pauser.toString()).to.equal(pauser.publicKey.toString());
            expect(config.pendingAdmin.toString()).to.equal(PublicKey.default.toString());
            expect(config.pendingPauser.toString()).to.equal(PublicKey.default.toString());
            expect(config.paused).to.be.false;

        });

        it("Updates operator authority and emits OperatorChanged", async () => {
            const newOperator = Keypair.generate();
            await provider.connection.requestAirdrop(
                newOperator.publicKey,
                2 * anchor.web3.LAMPORTS_PER_SOL
            );
            await new Promise(resolve => setTimeout(resolve, 2000));

            let rotated = false;
            let config = await program.account.config.fetch(configPda);

            try {
                const txSig = await program.methods
                    .setOperator(newOperator.publicKey)
                    .accountsPartial({
                        admin: admin.publicKey,
                        config: configPda,
                    })
                    .signers([admin])
                    .rpc();
                rotated = true;

                config = await program.account.config.fetch(configPda);
                expect(config.operator.toString()).to.equal(newOperator.publicKey.toString());

                const events = await extractEventCpi(provider.connection, program, txSig);

                const operatorChanged = events.find(event => event.name === "operatorChanged");
                expect(operatorChanged).to.exist;
                expect((operatorChanged!.data as any).oldOperator.toString()).to.equal(operator.publicKey.toString());
                expect((operatorChanged!.data as any).newOperator.toString()).to.equal(newOperator.publicKey.toString());

                await program.methods
                    .pause()
                    .accountsPartial({
                        pauser: pauser.publicKey,
                        config: configPda,
                    })
                    .signers([pauser])
                    .rpc();

                try {
                    await program.methods
                        .unpause()
                        .accountsPartial({
                            operator: operator.publicKey,
                            config: configPda,
                        })
                        .signers([operator])
                        .rpc();
                    expect.fail("Old operator should not retain unpause access after rotation");
                } catch (error: any) {
                    const errorCode = getErrorCode(error);
                    expect(errorCode).to.equal("Unauthorized");
                }
            } finally {
                if (rotated) {
                    const latestConfig = await program.account.config.fetch(configPda);
                    if (latestConfig.paused) {
                        await program.methods
                            .unpause()
                            .accountsPartial({
                                operator: newOperator.publicKey,
                                config: configPda,
                            })
                            .signers([newOperator])
                            .rpc();
                    }

                    await program.methods
                        .setOperator(operator.publicKey)
                        .accountsPartial({
                            admin: admin.publicKey,
                            config: configPda,
                        })
                        .signers([admin])
                        .rpc();
                }
            }

            config = await program.account.config.fetch(configPda);
            expect(config.operator.toString()).to.equal(operator.publicKey.toString());
        });

        it("Rejects operator updates from non-admin", async () => {
            const anotherOperator = Keypair.generate();

            try {
                await program.methods
                    .setOperator(anotherOperator.publicKey)
                    .accountsPartial({
                        admin: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();
                expect.fail("Unauthorized set_operator should have failed");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }

            const config = await program.account.config.fetch(configPda);
            expect(config.operator.toString()).to.equal(operator.publicKey.toString());
        });

        it("Rejects zero-address operator updates", async () => {
            try {
                await program.methods
                    .setOperator(PublicKey.default)
                    .accountsPartial({
                        admin: admin.publicKey,
                        config: configPda,
                    })
                    .signers([admin])
                    .rpc();
                expect.fail("Zero-address operator update should have failed");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("ZeroAddress");
            }

            const config = await program.account.config.fetch(configPda);
            expect(config.operator.toString()).to.equal(operator.publicKey.toString());
        });

        it("Rotates admin authority", async () => {
            // Propose admin -> newAdmin
            await program.methods
                .proposeAuthorities(newAdmin.publicKey, null)
                .accountsPartial({
                    config: configPda,
                    admin: admin.publicKey,
                })
                .signers([admin])
                .rpc();

            let config = await program.account.config.fetch(configPda);
            expect(config.admin.toString()).to.equal(admin.publicKey.toString());
            expect(config.pendingAdmin.toString()).to.equal(newAdmin.publicKey.toString());

            try {
                await program.methods
                    .acceptAdmin()
                    .accountsPartial({
                        config: configPda,
                        pendingAdmin: unauthorizedUser.publicKey,
                    })
                    .signers([unauthorizedUser])
                    .rpc();
                expect.fail("Only the proposed admin should be able to accept");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }

            await program.methods
                .acceptAdmin()
                .accountsPartial({
                    config: configPda,
                    pendingAdmin: newAdmin.publicKey,
                })
                .signers([newAdmin])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.admin.toString()).to.equal(newAdmin.publicKey.toString());
            expect(config.pendingAdmin.toString()).to.equal(PublicKey.default.toString());

            // Old admin should now fail admin-only action
            try {
                await program.methods
                    .setCapsUsd(new anchor.BN(100_000_000), new anchor.BN(1_000_000_000))
                    .accountsPartial({
                        admin: admin.publicKey,
                        config: configPda,
                    })
                    .signers([admin])
                    .rpc();
                expect.fail("Old admin should not have access after rotation");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }

            // Rotate back to original admin to keep suite stable
            await program.methods
                .proposeAuthorities(admin.publicKey, null)
                .accountsPartial({
                    config: configPda,
                    admin: newAdmin.publicKey,
                })
                .signers([newAdmin])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.admin.toString()).to.equal(newAdmin.publicKey.toString());
            expect(config.pendingAdmin.toString()).to.equal(admin.publicKey.toString());

            await program.methods
                .acceptAdmin()
                .accountsPartial({
                    config: configPda,
                    pendingAdmin: admin.publicKey,
                })
                .signers([admin])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.admin.toString()).to.equal(admin.publicKey.toString());
            expect(config.pendingAdmin.toString()).to.equal(PublicKey.default.toString());
        });

        it("Updates pauser authority", async () => {
            await program.methods
                .proposeAuthorities(null, newPauser.publicKey)
                .accountsPartial({
                    config: configPda,
                    admin: admin.publicKey,
                })
                .signers([admin])
                .rpc();

            let config = await program.account.config.fetch(configPda);
            expect(config.pauser.toString()).to.equal(pauser.publicKey.toString());
            expect(config.pendingPauser.toString()).to.equal(newPauser.publicKey.toString());

            await program.methods
                .acceptPauser()
                .accountsPartial({
                    config: configPda,
                    pendingPauser: newPauser.publicKey,
                })
                .signers([newPauser])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.pauser.toString()).to.equal(newPauser.publicKey.toString());
            expect(config.pendingPauser.toString()).to.equal(PublicKey.default.toString());

            // New pauser can pause
            await program.methods
                .pause()
                .accountsPartial({
                    pauser: newPauser.publicKey,
                    config: configPda,
                })
                .signers([newPauser])
                .rpc();

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            try {
                await program.methods
                    .pause()
                    .accountsPartial({
                        pauser: pauser.publicKey,
                        config: configPda,
                    })
                    .signers([pauser])
                    .rpc();
                expect.fail("Old pauser should not have access after acceptance");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }

            // Restore original pauser for remaining tests
            await program.methods
                .proposeAuthorities(null, pauser.publicKey)
                .accountsPartial({
                    config: configPda,
                    admin: admin.publicKey,
                })
                .signers([admin])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.pauser.toString()).to.equal(newPauser.publicKey.toString());
            expect(config.pendingPauser.toString()).to.equal(pauser.publicKey.toString());

            await program.methods
                .acceptPauser()
                .accountsPartial({
                    config: configPda,
                    pendingPauser: pauser.publicKey,
                })
                .signers([pauser])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.pauser.toString()).to.equal(pauser.publicKey.toString());
            expect(config.pendingPauser.toString()).to.equal(PublicKey.default.toString());
        });

        it("Updates USD caps", async () => {

            const newMinCap = new anchor.BN(150_000_000);
            const newMaxCap = new anchor.BN(2_000_000_000);

            await program.methods
                .setCapsUsd(newMinCap, newMaxCap)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.minCapUniversalTxUsd.toString()).to.equal(newMinCap.toString());
            expect(config.maxCapUniversalTxUsd.toString()).to.equal(newMaxCap.toString());

        });

        it("Rejects propose_authorities from non-admin", async () => {
            try {
                await program.methods
                    .proposeAuthorities(unauthorizedUser.publicKey, null)
                    .accountsPartial({
                        config: configPda,
                        admin: unauthorizedUser.publicKey,
                    })
                    .signers([unauthorizedUser])
                    .rpc();
                expect.fail("Unauthorized propose_authorities should have failed");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }
        });

        it("Rejects propose_authorities with both args null", async () => {
            try {
                await program.methods
                    .proposeAuthorities(null, null)
                    .accountsPartial({
                        config: configPda,
                        admin: admin.publicKey,
                    })
                    .signers([admin])
                    .rpc();
                expect.fail("propose_authorities with both null should have failed");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("InvalidInput");
            }
        });

        it("Rejects unauthorized admin operations", async () => {
            try {
                const newMinCap = new anchor.BN(200_000_000);
                const newMaxCap = new anchor.BN(300_000_000);

                await program.methods
                    .setCapsUsd(newMinCap, newMaxCap)
                    .accountsPartial({
                        admin: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();

                expect.fail("Unauthorized TSS update should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }
        });
    });

    describe("Pause/Unpause Functionality", () => {
        it("Pauses the contract", async () => {

            await program.methods
                .pause()
                .accountsPartial({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.true;

        });

        it("Allows admin to pause as emergency fallback", async () => {
            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            await program.methods
                .pause()
                .accountsPartial({
                    pauser: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            let config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.true;

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.false;
        });

        it("Unpauses the contract", async () => {

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.false;

        });

        it("Rejects unpause from pauser", async () => {
            await program.methods
                .pause()
                .accountsPartial({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            try {
                await program.methods
                    .unpause()
                    .accountsPartial({
                        operator: pauser.publicKey,
                        config: configPda,
                    })
                    .signers([pauser])
                    .rpc();

                expect.fail("Pauser unpause should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.false;
        });

        it("Rejects pause/unpause from unauthorized users", async () => {
            try {
                await program.methods
                    .pause()
                    .accountsPartial({
                        pauser: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();

                expect.fail("Unauthorized pause should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }

            try {
                await program.methods
                    .unpause()
                    .accountsPartial({
                        operator: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();

                expect.fail("Unauthorized unpause should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("Unauthorized");
            }
        });
    });

    describe("Configuration Updates", () => {
        it("Updates USD caps", async () => {

            const newMinCap = new anchor.BN(200_000_000); // $2
            const newMaxCap = new anchor.BN(2_000_000_000); // $20

            await program.methods
                .setCapsUsd(newMinCap, newMaxCap)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.minCapUniversalTxUsd.toString()).to.equal(newMinCap.toString());
            expect(config.maxCapUniversalTxUsd.toString()).to.equal(newMaxCap.toString());

        });

        it("Updates Pyth configuration", async () => {
            const newPriceFeed = Keypair.generate().publicKey;
            const newConfidenceThreshold = new anchor.BN(2000000);

            // Update price feed
            await program.methods
                .setPythPriceFeed(newPriceFeed)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            // Update confidence threshold
            await program.methods
                .setPythConfidenceThreshold(newConfidenceThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.pythPriceFeed.toString()).to.equal(newPriceFeed.toString());
            expect(config.pythConfidenceThreshold.toString()).to.equal(newConfidenceThreshold.toString());

            // Restore original price feed for other tests
            await program.methods
                .setPythPriceFeed(mockPriceFeed)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();
        });

        it("Updates Pyth max age seconds", async () => {
            const newMaxAge = new anchor.BN(90);

            await program.methods
                .setPythMaxAgeSeconds(newMaxAge)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.pythMaxAgeSeconds.toString()).to.equal(newMaxAge.toString());

            // Reject zero
            try {
                await program.methods
                    .setPythMaxAgeSeconds(new anchor.BN(0))
                    .accountsPartial({
                        admin: admin.publicKey,
                        config: configPda,
                    })
                    .signers([admin])
                    .rpc();
                expect.fail("Zero max age should have been rejected");
            } catch (error: any) {
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("InvalidAmount");
            }

            // Restore to a working value for remaining tests
            await program.methods
                .setPythMaxAgeSeconds(new anchor.BN(3600))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();
        });

        it("Updates rate limiting configuration", async () => {

            const newBlockCap = new anchor.BN(1_000_000_000_000); // $10,000
            const newEpochDuration = new anchor.BN(7200); // 2 hours

            await program.methods
                .setBlockUsdCap(newBlockCap)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .updateEpochDuration(newEpochDuration)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const rateLimitConfig = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            expect(rateLimitConfig.blockUsdCap.toString()).to.equal(newBlockCap.toString());
            expect(rateLimitConfig.epochDurationSec.toString()).to.equal(newEpochDuration.toString());

        });

        it("Allows admin config setters while paused", async () => {
            const originalConfig = await program.account.config.fetch(configPda);
            const pausedMinCap = new anchor.BN(250_000_000);
            const pausedMaxCap = new anchor.BN(2_500_000_000);
            const pausedPriceFeed = Keypair.generate().publicKey;
            const pausedConfidenceThreshold = new anchor.BN(3_000_000);
            const pausedMaxAge = new anchor.BN(120);

            await program.methods
                .pause()
                .accountsPartial({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            await program.methods
                .setCapsUsd(pausedMinCap, pausedMaxCap)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .setPythPriceFeed(pausedPriceFeed)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .setPythConfidenceThreshold(pausedConfidenceThreshold)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .setPythMaxAgeSeconds(pausedMaxAge)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            const pausedConfig = await program.account.config.fetch(configPda);
            expect(pausedConfig.minCapUniversalTxUsd.toString()).to.equal(pausedMinCap.toString());
            expect(pausedConfig.maxCapUniversalTxUsd.toString()).to.equal(pausedMaxCap.toString());
            expect(pausedConfig.pythPriceFeed.toString()).to.equal(pausedPriceFeed.toString());
            expect(pausedConfig.pythConfidenceThreshold.toString()).to.equal(pausedConfidenceThreshold.toString());
            expect(pausedConfig.pythMaxAgeSeconds.toString()).to.equal(pausedMaxAge.toString());

            await program.methods
                .setCapsUsd(
                    new anchor.BN(originalConfig.minCapUniversalTxUsd.toString()),
                    new anchor.BN(originalConfig.maxCapUniversalTxUsd.toString())
                )
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .setPythPriceFeed(originalConfig.pythPriceFeed)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .setPythConfidenceThreshold(new anchor.BN(originalConfig.pythConfidenceThreshold.toString()))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .setPythMaxAgeSeconds(new anchor.BN(originalConfig.pythMaxAgeSeconds.toString()))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();
        });

        it("Allows rate limit config setters while paused", async () => {
            const originalRateLimitConfig = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            const pausedBlockCap = new anchor.BN(2_000_000_000_000);
            const pausedEpochDuration = new anchor.BN(3600);

            await program.methods
                .pause()
                .accountsPartial({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            await program.methods
                .setBlockUsdCap(pausedBlockCap)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .updateEpochDuration(pausedEpochDuration)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            const pausedRateLimitConfig = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            expect(pausedRateLimitConfig.blockUsdCap.toString()).to.equal(pausedBlockCap.toString());
            expect(pausedRateLimitConfig.epochDurationSec.toString()).to.equal(pausedEpochDuration.toString());

            await program.methods
                .setBlockUsdCap(new anchor.BN(originalRateLimitConfig.blockUsdCap.toString()))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .updateEpochDuration(new anchor.BN(originalRateLimitConfig.epochDurationSec.toString()))
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        });
    });

    describe("Token Rate Limits", () => {
        it("Sets token rate limit threshold", async () => {

            const limitThreshold = new anchor.BN(1000 * Math.pow(10, 6)); // 1000 tokens

            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );

            await program.methods
                .setTokenRateLimit(limitThreshold, true, true)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const tokenRateLimit = await program.account.tokenRateLimit.fetch(tokenRateLimitPda);
            expect(tokenRateLimit.tokenMint.toString()).to.equal(mockUSDT.mint.publicKey.toString());
            expect(tokenRateLimit.limitThreshold.toString()).to.equal(limitThreshold.toString());

        });

        it("Allows native SOL rate limit updates without authority acknowledgments", async () => {
            const limitThreshold = new anchor.BN(500 * 10 ** 9);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), PublicKey.default.toBuffer()],
                program.programId
            );

            await program.methods
                .setTokenRateLimit(limitThreshold, false, false)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const tokenRateLimit = await program.account.tokenRateLimit.fetch(tokenRateLimitPda);
            expect(tokenRateLimit.tokenMint.toString()).to.equal(PublicKey.default.toString());
            expect(tokenRateLimit.limitThreshold.toString()).to.equal(limitThreshold.toString());
        });

        it("Rejects SPL mint authorities unless explicitly acknowledged", async () => {
            const limitThreshold = new anchor.BN(2000 * Math.pow(10, 6));
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );

            for (const [trustedMintAuthority, trustedFreezeAuthority] of [
                [false, false],
                [true, false],
                [false, true],
            ] as const) {
                try {
                    await program.methods
                        .setTokenRateLimit(limitThreshold, trustedMintAuthority, trustedFreezeAuthority)
                        .accountsPartial({
                            admin: admin.publicKey,
                            config: configPda,
                            tokenRateLimit: tokenRateLimitPda,
                            tokenMint: mockUSDT.mint.publicKey,
                            systemProgram: SystemProgram.programId,
                        })
                        .signers([admin])
                        .rpc();

                    expect.fail("Missing authority acknowledgment should have failed");
                } catch (error: any) {
                    const errorCode = getErrorCode(error);
                    expect(errorCode).to.equal("InvalidMint");
                }
            }
        });

        it("Allows token rate limit updates while paused", async () => {
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );
            const originalTokenRateLimit = await program.account.tokenRateLimit.fetch(tokenRateLimitPda);
            const pausedThreshold = new anchor.BN(3000 * Math.pow(10, 6));

            await program.methods
                .pause()
                .accountsPartial({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            await program.methods
                .setTokenRateLimit(pausedThreshold, true, true)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .unpause()
                .accountsPartial({
                    operator: operator.publicKey,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            const pausedTokenRateLimit = await program.account.tokenRateLimit.fetch(tokenRateLimitPda);
            expect(pausedTokenRateLimit.limitThreshold.toString()).to.equal(pausedThreshold.toString());

            await program.methods
                .setTokenRateLimit(new anchor.BN(originalTokenRateLimit.limitThreshold.toString()), true, true)
                .accountsPartial({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        });
    });

    describe("TSS Management", () => {
        it("Rejects TSS initialization by non-admin", async () => {
            // Use the correct TSS PDA seed (just "tss", not with extra bytes)
            const [actualTssPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("final_tss_pda")],
                program.programId
            );

            // Check if TSS already exists
            let tssExists = false;
            try {
                await program.account.tssPda.fetch(actualTssPda);
                tssExists = true;
            } catch {
                // TSS doesn't exist yet
            }

            if (tssExists) {
                // TSS already exists, test that non-admin can't update it (also requires authority)
                const newTssEthAddress = Array.from(Buffer.alloc(20, 99));
                try {
                    await program.methods
                        .updateTss(newTssEthAddress, "999")
                        .accountsPartial({
                            authority: unauthorizedUser.publicKey,
                            tssPda: actualTssPda,
                            config: configPda,
                        })
                        .signers([unauthorizedUser])
                        .rpc();

                    expect.fail("Unauthorized TSS update should have failed");
                } catch (error: any) {
                    expect(error).to.exist;
                    const errorCode = getErrorCode(error);
                    expect(errorCode).to.equal("Unauthorized");
                }
            } else {
                // TSS doesn't exist, test that non-admin can't initialize it
                // The constraint check happens during account validation, before init
                const expectedTssEthAddress = getTssEthAddress();
                const chainId = TSS_CHAIN_ID;

                try {
                    await program.methods
                        .initTss(expectedTssEthAddress, chainId)
                        .accountsPartial({
                            authority: unauthorizedUser.publicKey,
                            tssPda: actualTssPda,
                            config: configPda,
                            systemProgram: SystemProgram.programId,
                        })
                        .signers([unauthorizedUser])
                        .rpc();

                    expect.fail("Unauthorized TSS initialization should have failed");
                } catch (error: any) {
                    expect(error).to.exist;
                    // Constraint returns ConstraintRaw when validation fails
                    const errorCode = getErrorCode(error);
                    expect(errorCode).to.equal("ConstraintRaw");
                }
            }
        });

        it("Initializes TSS PDA if not already initialized", async () => {
            const expectedTssEthAddress = getTssEthAddress();
            const chainId = TSS_CHAIN_ID;

            try {
                const existingTss = await program.account.tssPda.fetch(tssPda);
                // Verify it's already initialized correctly
                expect(existingTss.chainId).to.equal(chainId);
                return;
            } catch {
                // Not initialized, proceed with initialization
            }

            await program.methods
                .initTss(expectedTssEthAddress, chainId)
                .accountsPartial({
                    authority: admin.publicKey,
                    tssPda: tssPda,
                    config: configPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const tss = await program.account.tssPda.fetch(tssPda);
            expect(tss.chainId).to.equal(chainId);
        });

        it("Updates TSS configuration", async () => {
            const newTssEthAddress = Array.from(Buffer.alloc(20, 2));
            const newChainId = "137";

            await program.methods
                .updateTss(newTssEthAddress, newChainId)
                .accountsPartial({
                    authority: operator.publicKey,
                    tssPda: tssPda,
                    config: configPda,
                })
                .signers([operator])
                .rpc();

            const tss = await program.account.tssPda.fetch(tssPda);
            expect(tss.chainId).to.equal(newChainId);
        });

    });


    describe("Price Oracle Functions", () => {
        it("Gets SOL price from Pyth oracle", async () => {
            const priceData = await program.methods
                .getSolPrice()
                .accountsPartial({
                    priceUpdate: mockPriceFeed,
                })
                .view();

            expect(priceData).to.not.be.null;
            expect(priceData.price.toNumber()).to.be.greaterThan(0);
            expect(priceData.exponent).to.be.a('number');
        });
    });

    describe("Error Conditions", () => {
        it("Rejects invalid USD caps (min > max)", async () => {
            const invalidMinCap = new anchor.BN(2_000_000_000); // $20
            const invalidMaxCap = new anchor.BN(1_000_000_000); // $10 (less than min)

            try {
                await program.methods
                    .setCapsUsd(invalidMinCap, invalidMaxCap)
                    .accountsPartial({
                        admin: admin.publicKey,
                        config: configPda,
                    })
                    .signers([admin])
                    .rpc();

                expect.fail("Invalid caps should have been rejected");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = getErrorCode(error);
                expect(errorCode).to.equal("InvalidCapRange");
            }
        });

    });

    after(async () => {
        const expectedTssEthAddress = getTssEthAddress();
        await program.methods
            .updateTss(expectedTssEthAddress, TSS_CHAIN_ID)
            .accountsPartial({
                tssPda,
                config: configPda,
                authority: operator.publicKey,
            })
            .signers([operator])
            .rpc();

    });
});
