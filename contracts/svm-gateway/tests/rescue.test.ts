/**
 * rescue.test.ts
 *
 * Tests for rescue_funds instruction (EVM parity: rescueFunds with subTxId).
 * Covers SOL and SPL token rescue via unified entrypoint.
 *
 * SVM deviations from EVM (intentional):
 *   - Auth: ECDSA TSS signature verification (not onlyRole)
 *   - gas_fee: relayer reimbursement from vault because rescue is Push-paid
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

const DEFAULT_GAS_FEE = BigInt(5_000); // lamports (used by rejection tests that fail before the gas-cap check)

// Measured rescue reimbursement = signature fee + ExecutedSubTx PDA rent. rescue_funds now
// reimburses this measured amount from the bridge `vault` (Push-paid gas via swapAndBurnGas),
// with the signed gas_fee acting as a cap. Native/SPL rescue create no recipient ATA, so there
// is no ATA-rent term (that only applies to the PC20 remint path).
const SIGNATURE_FEE_LAMPORTS = 5_000;
let executedSubTxRent = 0;
let rescueGasUsed = 0;
let rescueGasFee = BigInt(0); // signed cap = measured + buffer

// ─── Suite ────────────────────────────────────────────────────────────────────

describe("Universal Gateway - Rescue Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    before(async () => {
        await ensureTestSetup();
        executedSubTxRent = await provider.connection.getMinimumBalanceForRentExemption(8);
        rescueGasUsed = SIGNATURE_FEE_LAMPORTS + executedSubTxRent;
        rescueGasFee = BigInt(rescueGasUsed + 100_000);
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

            // Signed gas_fee must equal the RPC gas_fee arg (rescueGasFee), and must be >= the
            // measured gas_used so the vault reimbursement cap check passes.
            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                rescueGasFee
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: BigInt(rescueAmount),
                additional,
            });

            const vaultBefore = await provider.connection.getBalance(vaultPda);
            const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);
            const recipientBefore = await provider.connection.getBalance(recipient.publicKey);
            const callerBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(rescueAmount),
                    new anchor.BN(Number(rescueGasFee)),
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
            const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
            const recipientAfter = await provider.connection.getBalance(recipient.publicKey);
            const callerAfter = await provider.connection.getBalance(relayer.publicKey);

            // Rescue reimbursement now comes from `vault` (Push-paid gas), measured cost only.
            // Vault loses the rescued principal AND the measured gas_used.
            expect(vaultAfter).to.equal(vaultBefore - rescueAmount - rescueGasUsed);
            // fee_vault is no longer touched by rescue.
            expect(feeVaultAfter).to.equal(feeVaultBefore);
            expect(recipientAfter).to.equal(recipientBefore + rescueAmount);
            // Relayer is made whole: pays base tx fee + ExecutedSubTx rent, reimbursed exactly
            // rescueGasUsed from vault -> net ~= 0.
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
            const rescueAmount = 1;
            // rescue_funds reimburses the measured cost (signature fee + ExecutedSubTx rent) from
            // `vault`, capped by the signed gas_fee. A gas_fee below the measured cost must reject.
            const tooSmallGasFee = BigInt(SIGNATURE_FEE_LAMPORTS); // 5_000 < rescueGasUsed
            const subTxId = generateTxId();
            const executedSubTxPda = getExecutedTxPda(subTxId);
            const universalTxId = generateUniversalTxId();

            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                tooSmallGasFee
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
                        new anchor.BN(Number(tooSmallGasFee)),
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

            // First rescue must succeed, so gas_fee must cover the measured gas_used.
            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                rescueGasFee
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
                    new anchor.BN(Number(rescueGasFee)),
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
                        new anchor.BN(Number(rescueGasFee)),
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
                rescueGasFee,
                mockUSDT.mint.publicKey
            );
            const sig = await signTssMessageWithChainId({
                instruction: TssInstruction.Rescue,
                amount: rescueRaw,
                additional,
            });

            const vaultUsdtBefore = await mockUSDT.getBalance(vaultUsdtAccount);
            const recipientUsdtBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            const vaultSolBefore = await provider.connection.getBalance(vaultPda);
            const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);
            const callerBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .rescueFunds(
                    Array.from(subTxId),
                    Array.from(universalTxId),
                    new anchor.BN(Number(rescueRaw)),
                    new anchor.BN(Number(rescueGasFee)),
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

            const vaultUsdtAfter = await mockUSDT.getBalance(vaultUsdtAccount);
            const recipientUsdtAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            const vaultSolAfter = await provider.connection.getBalance(vaultPda);
            const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
            const callerAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(vaultUsdtAfter).to.equal(vaultUsdtBefore - rescueTokens);
            expect(recipientUsdtAfter).to.equal(recipientUsdtBefore + rescueTokens);
            // SPL rescue moves tokens from the vault ATA, but the measured gas reimbursement is
            // SOL pulled from the SOL `vault` PDA (Push-paid gas), not fee_vault.
            expect(vaultSolAfter).to.equal(vaultSolBefore - rescueGasUsed);
            expect(feeVaultAfter).to.equal(feeVaultBefore);
            // Relayer made whole: pays base tx fee + ExecutedSubTx rent, reimbursed rescueGasUsed.
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

            // First rescue must succeed, so gas_fee must cover the measured gas_used.
            const additional = buildRescueAdditionalData(
                subTxId,
                universalTxId,
                recipient.publicKey,
                rescueGasFee,
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
                    new anchor.BN(Number(rescueGasFee)),
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
                        new anchor.BN(Number(rescueGasFee)),
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
    });
});
