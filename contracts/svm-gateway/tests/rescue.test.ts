/**
 * rescue.test.ts
 *
 * Tests for rescue_funds instruction (EVM parity: rescueFunds with subTxId).
 * Covers SOL and SPL token rescue via unified entrypoint.
 *
 * SVM deviations from EVM (intentional):
 *   - Auth: ECDSA TSS signature verification (not onlyRole)
 *   - gas_fee: relayer reimbursement from fee_vault
 *   - recipient derived from accounts, not a separate param
 *
 * Replay protection: ExecutedSubTx PDA (EVM parity: isExecuted[subTxId])
 */

import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import {
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID,
    createAssociatedTokenAccountInstruction,
    getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import * as sharedState from "./shared-state";
import {
    signTssMessage,
    TssInstruction,
    generateUniversalTxId,
    buildRescueAdditionalData,
} from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import {
    TOKEN_MULTIPLIER,
    asTokenAmount,
    makeTxIdGenerator,
    getExecutedTxPda as _getExecutedTxPda,
    getTokenRateLimitPda as _getTokenRateLimitPda,
} from "./helpers/test-utils";

// ─── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_GAS_FEE = BigInt(5_000); // lamports

// ─── Suite ────────────────────────────────────────────────────────────────────

describe("Universal Gateway - Rescue Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    before(async () => {
        await ensureTestSetup();
    });

    let admin: Keypair;
    let operator: Keypair;
    let pauser: Keypair;
    let recipient: Keypair;
    let relayer: Keypair;

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let feeVaultPda: PublicKey;
    let tssPda: PublicKey;
    let rateLimitConfigPda: PublicKey;
    let mockPriceFeed: PublicKey;

    let mockUSDT: any;
    let user1: Keypair;
    let user1UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let recipientUsdtAccount: PublicKey;

    const getTokenRateLimitPda = (tokenMint: PublicKey) =>
        _getTokenRateLimitPda(tokenMint, program.programId);

    const generateTxId = makeTxIdGenerator();
    const getExecutedTxPda = (subTxId: number[]) =>
        _getExecutedTxPda(subTxId, program.programId);

    const signTssMessageWithChainId = async (params: {
        instruction: TssInstruction;
        amount?: bigint;
        additional: (Uint8Array | number[])[];
    }) => {
        const tssAccount = await program.account.tssPda.fetch(tssPda);
        return signTssMessage({ ...params, chainId: tssAccount.chainId });
    };

    const expectRejection = async (promise: Promise<unknown>, message: string) => {
        let rejected = false;
        try {
            await promise;
        } catch (error: any) {
            rejected = true;
            const errorStr = error.toString();
            const errorMessage = error.error?.errorMessage || error.message || errorStr;
            const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
            const matches =
                errorStr.includes(message) ||
                errorMessage.includes(message) ||
                (errorCode && errorCode.toString().includes(message)) ||
                error.error?.errorCode?.code === message;
            if (!matches) {
                console.error(`Expected error "${message}", got:`, { errorStr, errorMessage, errorCode });
            }
            expect(matches).to.be.true;
        }
        expect(rejected, `Expected rejection with "${message}" but call succeeded`).to.be.true;
    };

    // ── Setup ─────────────────────────────────────────────────────────────────

    before(async () => {
        admin = sharedState.getAdmin();
        operator = sharedState.getOperator();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        user1 = sharedState.getUser1();

        recipient = Keypair.generate();
        relayer = Keypair.generate();

        await Promise.all([
            provider.connection.requestAirdrop(recipient.publicKey, 5 * anchor.web3.LAMPORTS_PER_SOL),
            provider.connection.requestAirdrop(relayer.publicKey, 5 * anchor.web3.LAMPORTS_PER_SOL),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [feeVaultPda] = PublicKey.findProgramAddressSync([Buffer.from("fee_vault")], program.programId);
        [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("tsspda_v2")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit_config")], program.programId
        );

        // Disable protocol fee so vault seeding is deterministic.
        await program.methods
            .setProtocolFee(new anchor.BN(0))
            .accountsPartial({ config: configPda, feeVault: feeVaultPda, admin: admin.publicKey, systemProgram: SystemProgram.programId })
            .signers([admin])
            .rpc();

        // Top up fee_vault to ensure at least 50_000 lamports above rent-exempt minimum.
        // We check the *available* balance (total - rent_exempt_min) so that a freshly
        // initialized fee_vault (available = 0) gets funded even though its total
        // lamport balance is non-zero.  The top-up is capped at 0.001 SOL so it
        // cannot push the full-suite balance past 2 SOL (withdraw.test.ts threshold).
        const feeVaultInfo = await provider.connection.getAccountInfo(feeVaultPda);
        const rentExemptMin = await provider.connection.getMinimumBalanceForRentExemption(
            feeVaultInfo ? feeVaultInfo.data.length : 67
        );
        const feeVaultTotal = feeVaultInfo ? feeVaultInfo.lamports : 0;
        const available = feeVaultTotal > rentExemptMin ? feeVaultTotal - rentExemptMin : 0;
        if (available < 50_000) {
            const topUp = 50_000 - available + 10_000; // target: 60_000 available
            const feeVaultFundTx = await provider.connection.requestAirdrop(feeVaultPda, topUp);
            await provider.connection.confirmTransaction(feeVaultFundTx);
        }

        mockPriceFeed = sharedState.getMockPriceFeed();

        // ── Seed vault with SOL ───────────────────────────────────────────────

        const nativeSolRateLimitPda = getTokenRateLimitPda(PublicKey.default);
        await program.methods
            .setTokenRateLimit(new anchor.BN("1000000000000000000000"), false, false)
            .accountsPartial({
                config: configPda,
                tokenRateLimit: nativeSolRateLimitPda,
                tokenMint: PublicKey.default,
                admin: admin.publicKey,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        const solDepositAmount = 5 * anchor.web3.LAMPORTS_PER_SOL;
        await program.methods
            .sendUniversalTx(
                {
                    recipient: Array.from(Buffer.alloc(20, 0)),
                    token: PublicKey.default,
                    amount: new anchor.BN(solDepositAmount),
                    payload: Buffer.from([]),
                    revertRecipient: user1.publicKey,
                    signatureData: Buffer.from([]),
                },
                new anchor.BN(solDepositAmount)
            )
            .accountsPartial({
                config: configPda,
                vault: vaultPda,
                feeVault: feeVaultPda,
                userTokenAccount: null,
                gatewayTokenAccount: null,
                user: user1.publicKey,
                priceUpdate: mockPriceFeed,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolRateLimitPda,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([user1])
            .rpc();

        // ── Seed vault with SPL tokens ────────────────────────────────────────

        user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
        const currentBalance = await mockUSDT.getBalance(user1UsdtAccount);
        if (currentBalance < 5_000) {
            await mockUSDT.mintTo(user1UsdtAccount, 5_000 - currentBalance);
        }

        vaultUsdtAccount = getAssociatedTokenAddressSync(
            mockUSDT.mint.publicKey,
            vaultPda,
            true,
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
        );
        const vaultAtaInfo = await provider.connection.getAccountInfo(vaultUsdtAccount);
        if (!vaultAtaInfo) {
            const createVaultAtaIx = createAssociatedTokenAccountInstruction(
                admin.publicKey,
                vaultUsdtAccount,
                vaultPda,
                mockUSDT.mint.publicKey,
                TOKEN_PROGRAM_ID,
                ASSOCIATED_TOKEN_PROGRAM_ID
            );
            await provider.sendAndConfirm(
                new anchor.web3.Transaction().add(createVaultAtaIx),
                [admin]
            );
        }
        recipientUsdtAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

        const splRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);
        await program.methods
            .setTokenRateLimit(new anchor.BN("1000000000000000000000"), true, true)
            .accountsPartial({
                config: configPda,
                tokenRateLimit: splRateLimitPda,
                tokenMint: mockUSDT.mint.publicKey,
                admin: admin.publicKey,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        const splDepositAmount = asTokenAmount(2_000);
        await program.methods
            .sendUniversalTx(
                {
                    recipient: Array.from(Buffer.alloc(20, 1)),
                    token: mockUSDT.mint.publicKey,
                    amount: splDepositAmount,
                    payload: Buffer.from([]),
                    revertRecipient: user1.publicKey,
                    signatureData: Buffer.from([]),
                },
                new anchor.BN(0)
            )
            .accountsPartial({
                config: configPda,
                vault: vaultPda,
                feeVault: feeVaultPda,
                user: user1.publicKey,
                userTokenAccount: user1UsdtAccount,
                gatewayTokenAccount: vaultUsdtAccount,
                priceUpdate: mockPriceFeed,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: splRateLimitPda,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([user1])
            .rpc();
    });

    // ── SOL Rescue ────────────────────────────────────────────────────────────

    describe("rescue_funds (SOL)", () => {
        it("rescues SOL with a valid TSS signature", async () => {
            const rescueAmount = anchor.web3.LAMPORTS_PER_SOL;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(rescueAmount),
                additional,
            });

            const vaultBefore = await provider.connection.getBalance(vaultPda);
            const recipientBefore = await provider.connection.getBalance(recipient.publicKey);
            const callerBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(rescueAmount),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig.signature,
                    sig.recoveryId,
                    sig.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedSubTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: null,
                    recipientTokenAccount: null,
                    tokenMint: null,
                    tokenProgram: null,
                })
                .signers([relayer])
                .rpc();

            const vaultAfter = await provider.connection.getBalance(vaultPda);
            const recipientAfter = await provider.connection.getBalance(recipient.publicKey);
            const callerAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(vaultAfter).to.equal(vaultBefore - rescueAmount);
            expect(recipientAfter).to.equal(recipientBefore + rescueAmount);
            // Relayer receives gas_fee from fee_vault, pays ExecutedSubTx PDA rent
            const actualRentForExecutedTx = 890880;
            const callerDelta = callerAfter - callerBefore;
            expect(callerDelta).to.be.closeTo(Number(DEFAULT_GAS_FEE) - actualRentForExecutedTx, 100_000);
        });

        it("rejects a tampered TSS signature", async () => {
            const rescueAmount = anchor.web3.LAMPORTS_PER_SOL;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(rescueAmount),
                additional,
            });

            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(rescueAmount),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        corrupted,
                        valid.recoveryId,
                        valid.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc(),
                "TssAuthFailed"
            );
        });

        it("rejects zero amount", async () => {
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(0),
                additional,
            });

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(0),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidAmount"
            );
        });

        it("rejects rescue while paused", async () => {
            await program.methods
                .pause()
                .accountsPartial({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();

            const rescueAmount = anchor.web3.LAMPORTS_PER_SOL;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(rescueAmount),
                additional,
            });

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(rescueAmount),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc(),
                "Paused"
            );

            await program.methods
                .unpause()
                .accountsPartial({ operator: operator.publicKey, config: configPda })
                .signers([operator])
                .rpc();
        });

        it("rejects when fee_vault cannot cover gas_fee", async () => {
            const rescueAmount = 1;
            // 100 SOL is guaranteed to exceed any fee_vault balance in test environments.
            const tooLargeGasFee = BigInt(100 * anchor.web3.LAMPORTS_PER_SOL);
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                tooLargeGasFee
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(rescueAmount),
                additional,
            });

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(rescueAmount),
                        new anchor.BN(Number(tooLargeGasFee)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc(),
                "InsufficientFeePool"
            );
        });

        it("rejects duplicate subTxId (replay protection)", async () => {
            const rescueAmount = anchor.web3.LAMPORTS_PER_SOL / 10;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(rescueAmount),
                additional,
            });

            // First call succeeds
            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(rescueAmount),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig.signature,
                    sig.recoveryId,
                    sig.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedSubTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: null,
                    recipientTokenAccount: null,
                    tokenMint: null,
                    tokenProgram: null,
                })
                .signers([relayer])
                .rpc();

            // Second call with same subTxId must fail
            try {
                await program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(rescueAmount),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have rejected duplicate subTxId");
            } catch (error: any) {
                const errorStr = error.toString();
                const allLogs = Array.isArray(error.logs) ? error.logs.join(' ') : '';
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");
                expect(isReplayError).to.be.true;
            }
        });
    });

    // ── SPL Rescue ────────────────────────────────────────────────────────────

    describe("rescue_funds (SPL)", () => {
        it("rescues SPL tokens with a valid TSS signature", async () => {
            const rescueTokens = 500;
            const rescueRaw = BigInt(rescueTokens) * TOKEN_MULTIPLIER;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE,
                mockUSDT.mint.publicKey
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            const vaultUsdtBefore = await mockUSDT.getBalance(vaultUsdtAccount);
            const recipientUsdtBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(Number(rescueRaw)),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig.signature,
                    sig.recoveryId,
                    sig.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedSubTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: vaultUsdtAccount,
                    recipientTokenAccount: recipientUsdtAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .signers([relayer])
                .rpc();

            const vaultUsdtAfter = await mockUSDT.getBalance(vaultUsdtAccount);
            const recipientUsdtAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(vaultUsdtAfter).to.equal(vaultUsdtBefore - rescueTokens);
            expect(recipientUsdtAfter).to.equal(recipientUsdtBefore + rescueTokens);
            // Relayer receives gas_fee from fee_vault, pays ExecutedSubTx PDA rent
            const actualRentForExecutedTx = 890880;
            const callerDelta = callerAfter - callerBefore;
            expect(callerDelta).to.be.closeTo(Number(DEFAULT_GAS_FEE) - actualRentForExecutedTx, 100_000);
        });

        it("rejects a tampered TSS signature", async () => {
            const rescueRaw = BigInt(100) * TOKEN_MULTIPLIER;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE,
                mockUSDT.mint.publicKey
            );
            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        corrupted,
                        valid.recoveryId,
                        valid.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientUsdtAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc(),
                "TssAuthFailed"
            );
        });

        it("rejects SPL rescue with wrong recipient (token account owner mismatch)", async () => {
            const rescueRaw = BigInt(100) * TOKEN_MULTIPLIER;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();
            const wrongRecipient = Keypair.generate();

            // Sign for the correct recipient
            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE,
                mockUSDT.mint.publicKey
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            // Pass a token account owned by wrongRecipient — owner check fires
            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: await mockUSDT.createTokenAccount(wrongRecipient.publicKey),
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidRecipient"
            );
        });

        it("rejects SPL rescue when TSS was signed for a different mint", async () => {
            const rescueRaw = BigInt(100) * TOKEN_MULTIPLIER;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            // Sign for a fake random mint
            const fakeMint = Keypair.generate().publicKey;
            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE,
                fakeMint
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            // Pass real USDT accounts — on-chain hash uses USDT mint, sig was for fakeMint.
            // The on-chain validator recomputes the hash with the real mint first, finds a
            // mismatch with the provided message_hash, and returns MessageHashMismatch before
            // even attempting signature recovery.
            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientUsdtAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc(),
                "MessageHashMismatch"
            );
        });

        it("rejects duplicate subTxId (replay protection)", async () => {
            const rescueTokens = 50;
            const rescueRaw = BigInt(rescueTokens) * TOKEN_MULTIPLIER;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                DEFAULT_GAS_FEE,
                mockUSDT.mint.publicKey
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            // First call succeeds
            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(Number(rescueRaw)),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig.signature,
                    sig.recoveryId,
                    sig.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedSubTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: vaultUsdtAccount,
                    recipientTokenAccount: recipientUsdtAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .signers([relayer])
                .rpc();

            // Second call with same subTxId must fail
            try {
                await program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientUsdtAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have rejected duplicate subTxId");
            } catch (error: any) {
                const errorStr = error.toString();
                const allLogs = Array.isArray(error.logs) ? error.logs.join(' ') : '';
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");
                expect(isReplayError).to.be.true;
            }
        });
    });
});
