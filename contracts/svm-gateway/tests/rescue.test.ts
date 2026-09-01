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

// Under the measured-reimbursement model, gas_fee is a signed ceiling; the on-chain
// program refunds actual `gas_used = SIGNATURE_FEE + ExecutedSubTx rent (+ recipient ATA
// rent when just created)`. This default is sized to comfortably cover the base measured
// cost (~896k lamports) with slack for any rejection tests that just need a valid signed cap.
const DEFAULT_GAS_FEE = BigInt(3_000_000); // lamports

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
        deadline?: bigint;
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
        [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("final_tss_pda")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit_config")], program.programId
        );

        // Disable inbound fee so vault seeding is deterministic.
        await program.methods
            .setInboundFee(new anchor.BN(0))
            .accountsPartial({ config: configPda, feeVault: feeVaultPda, admin: admin.publicKey, systemProgram: SystemProgram.programId })
            .signers([admin])
            .rpc();

        // Top up fee_vault to cover measured reimbursements across the whole suite.
        // Under the measured-reimbursement model, each successful rescue drains
        // (SIGNATURE_FEE + ExecutedSubTx rent ≈ 895k, plus recipient ATA rent ≈ 2M when
        // this suite's fresh-ATA test fires). Target ~20M available so the whole suite
        // — plus other files' revert tests sharing the same fee_vault — stays covered.
        const TARGET_FEE_VAULT_AVAILABLE = 20_000_000;
        const feeVaultInfo = await provider.connection.getAccountInfo(feeVaultPda);
        const rentExemptMin = await provider.connection.getMinimumBalanceForRentExemption(
            feeVaultInfo ? feeVaultInfo.data.length : 67
        );
        const feeVaultTotal = feeVaultInfo ? feeVaultInfo.lamports : 0;
        const available = feeVaultTotal > rentExemptMin ? feeVaultTotal - rentExemptMin : 0;
        if (available < TARGET_FEE_VAULT_AVAILABLE) {
            const topUp = TARGET_FEE_VAULT_AVAILABLE - available;
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
                    new anchor.BN(4102444800),
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
            // Measured-cost reimbursement: caller pays ExecutedSubTx rent + tx fee, gets back
            // (SIGNATURE_FEE + ExecutedSubTx rent). Native path creates no ATA, so net ≈ 0.
            const callerDelta = callerAfter - callerBefore;
            expect(callerDelta).to.be.closeTo(0, 50_000);
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
                        new anchor.BN(4102444800),
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
                        new anchor.BN(4102444800),
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
                        new anchor.BN(4102444800),
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

        it("rejects when signed gas_fee is below the measured gas_used (InsufficientGasBudget)", async () => {
            // Under the measured-reimbursement model, gas_fee is a signed ceiling and the
            // on-chain program refunds the measured cost. Signing a gas_fee smaller than
            // the base measured cost (SIGNATURE_FEE + ExecutedSubTx rent ≈ 895k lamports)
            // trips the cap check before any lamports move.
            const rescueAmount = 1;
            const tooLowGasFee = BigInt(100_000);
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                tooLowGasFee
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
                        new anchor.BN(Number(tooLowGasFee)),
                        new anchor.BN(4102444800),
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
                "InsufficientGasBudget"
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
                    new anchor.BN(4102444800),
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
                        new anchor.BN(4102444800),
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
                    new anchor.BN(4102444800),
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
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                })
                .signers([relayer])
                .rpc();

            const vaultUsdtAfter = await mockUSDT.getBalance(vaultUsdtAccount);
            const recipientUsdtAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(vaultUsdtAfter).to.equal(vaultUsdtBefore - rescueTokens);
            expect(recipientUsdtAfter).to.equal(recipientUsdtBefore + rescueTokens);
            // Measured-cost reimbursement: recipient ATA existed pre-call, so no ATA-rent term.
            // Caller nets ≈ 0 (pays ExecutedSubTx rent + tx fee, refunded SIG_FEE + ExecutedSubTx rent).
            const callerDelta = callerAfter - callerBefore;
            expect(callerDelta).to.be.closeTo(0, 50_000);
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
                        new anchor.BN(4102444800),
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

        it("rejects SPL rescue when recipientTokenAccount is not the canonical ATA for recipient", async () => {
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

            // Under the auto-create model, the on-chain program derives the canonical ATA
            // from (recipient wallet, mint) and requires the passed slot to match. Passing
            // an ATA owned by a different wallet trips the ATA-address check.
            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
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
                "InvalidAccount"
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
                        new anchor.BN(4102444800),
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
                    new anchor.BN(4102444800),
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
                        new anchor.BN(4102444800),
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

        it("rejects rescue_funds with an expired deadline (SignatureExpired)", async () => {
            const rescueRaw = BigInt(100) * TOKEN_MULTIPLIER;
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();
            const pastDeadline = BigInt(1);

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
                deadline: pastDeadline,
            });

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(pastDeadline.toString()),
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
                "SignatureExpired"
            );
        });

        it("auto-creates recipient ATA on SPL rescue to a fresh wallet and reimburses ATA rent", async () => {
            // Rescue to a wallet whose (recipient, mint) canonical ATA does not exist.
            // Program creates it via inline manual CPI, folds rent into measured gas_used,
            // and pays the caller from fee_vault. gas_fee is the signed ceiling.
            const rescueTokens = 100;
            const rescueRaw = BigInt(rescueTokens) * TOKEN_MULTIPLIER;

            const freshRecipient = Keypair.generate();
            const recipientAta = getAssociatedTokenAddressSync(
                mockUSDT.mint.publicKey,
                freshRecipient.publicKey
            );
            const preAtaInfo = await provider.connection.getAccountInfo(recipientAta);
            expect(preAtaInfo, "precondition: canonical ATA must not exist yet").to.be.null;

            const ataRent = await provider.connection.getMinimumBalanceForRentExemption(165);
            const executedSubTxRent = await provider.connection.getMinimumBalanceForRentExemption(8);
            const measuredGasUsed = 5_000 + executedSubTxRent + ataRent;
            const signedGasFee = BigInt(measuredGasUsed + 500_000);

            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                freshRecipient.publicKey,
                signedGasFee,
                mockUSDT.mint.publicKey
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            const callerBefore = await provider.connection.getBalance(relayer.publicKey);
            const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);

            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(Number(rescueRaw)),
                    new anchor.BN(signedGasFee.toString()),
                    new anchor.BN(4102444800),
                    sig.signature,
                    sig.recoveryId,
                    sig.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: freshRecipient.publicKey,
                    executedSubTx: executedSubTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: vaultUsdtAccount,
                    recipientTokenAccount: recipientAta,
                    tokenMint: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                })
                .signers([relayer])
                .rpc();

            const postAtaInfo = await provider.connection.getAccountInfo(recipientAta);
            expect(postAtaInfo, "recipient ATA must exist after rescue").to.not.be.null;
            expect(await mockUSDT.getBalance(recipientAta)).to.equal(rescueTokens);

            const callerAfter = await provider.connection.getBalance(relayer.publicKey);
            const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
            expect(feeVaultBefore - feeVaultAfter).to.equal(measuredGasUsed);
            expect(callerAfter - callerBefore).to.be.closeTo(0, 50_000);
        });

        it("rejects SPL rescue to a fresh wallet when gas_fee cannot cover ATA rent (InsufficientGasBudget)", async () => {
            const rescueRaw = BigInt(100) * TOKEN_MULTIPLIER;

            const freshRecipient = Keypair.generate();
            const recipientAta = getAssociatedTokenAddressSync(
                mockUSDT.mint.publicKey,
                freshRecipient.publicKey
            );

            const executedSubTxRent = await provider.connection.getMinimumBalanceForRentExemption(8);
            // Cover base only (SIG_FEE + ExecutedSubTx rent); measured cost with ATA rent > gas_fee.
            const undersizedGasFee = BigInt(5_000 + executedSubTxRent + 1);

            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                freshRecipient.publicKey,
                undersizedGasFee,
                mockUSDT.mint.publicKey
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            await expectRejection(
                program.methods
                    .rescueFunds(
                        Array.from(subTxId),
                        Array.from(universalTxId),
                        new anchor.BN(Number(rescueRaw)),
                        new anchor.BN(undersizedGasFee.toString()),
                        new anchor.BN(4102444800),
                        sig.signature,
                        sig.recoveryId,
                        sig.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: freshRecipient.publicKey,
                        executedSubTx: executedSubTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientAta,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    })
                    .signers([relayer])
                    .rpc(),
                "InsufficientGasBudget"
            );
        });
    });
});
