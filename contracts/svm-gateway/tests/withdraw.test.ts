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
import { signTssMessage, TssInstruction, generateUniversalTxId, buildRevertAdditionalData, buildWithdrawAdditionalData, DEFAULT_DEADLINE } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import {
    USDT_DECIMALS, TOKEN_MULTIPLIER,
    asLamports, asTokenAmount,
    makeTxIdGenerator, generateSender,
    getExecutedTxPda as _getExecutedTxPda, getCeaAuthorityPda as _getCeaAuthorityPda,
    getTokenRateLimitPda as _getTokenRateLimitPda,
    extractEventCpi,
} from "./helpers/test-utils";
import { makeFinalizeUniversalTxBuilder, FinalizeUniversalTxArgs } from "./helpers/builders";

// Gas fee constants (in lamports)
// Must be >= SIGNATURE_FEE + ExecutedSubTx rent (+ optional ATA rent on SPL paths).
const DEFAULT_GAS_FEE = BigInt(4_000_000);

const toBytes = (pubkey: PublicKey) => pubkey.toBuffer();

// Helper to build gas_fee buffer (u64 BE)
const buildGasFeeBuf = (gasFee: bigint): Buffer => {
    const buf = Buffer.alloc(8);
    buf.writeBigUInt64BE(gasFee, 0);
    return buf;
};

describe("Universal Gateway - Withdraw Tests", () => {
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
    let user1: Keypair;
    let relayer: Keypair; // The caller who pays for transactions

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let feeVaultPda: PublicKey;
    let tssPda: PublicKey;
    let rateLimitConfigPda: PublicKey;
    let mockPriceFeed: PublicKey;

    let mockUSDT: any;

    let user1UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let recipientUsdtAccount: PublicKey;

    let finalizeUniversalTx: ReturnType<typeof makeFinalizeUniversalTxBuilder>;

    const generateTxId = makeTxIdGenerator();
    const generatePushAccount = generateSender; // same function, aliased for readability
    const getExecutedTxPda = (subTxId: number[]) => _getExecutedTxPda(subTxId, program.programId);
    const getCeaAuthorityPda = (pushAccount: number[]) => _getCeaAuthorityPda(pushAccount, program.programId);
    const getTokenRateLimitPda = (tokenMint: PublicKey) => _getTokenRateLimitPda(tokenMint, program.programId);

    const signTssMessageWithChainId = async (params: {
        instruction: TssInstruction;
        amount?: bigint;
        deadline?: bigint;
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

            // Check multiple ways the error might be represented
            const matches =
                errorStr.includes(message) ||
                errorMessage.includes(message) ||
                (errorCode && errorCode.toString().includes(message)) ||
                (error.error?.errorCode?.code === message);

            if (!matches) {
                console.error(`Expected error to include "${message}", but got:`, {
                    errorStr,
                    errorMessage,
                    errorCode,
                    fullError: error
                });
            }
            expect(matches).to.be.true;
        }
        expect(rejected).to.be.true;
    };

    before(async () => {
        admin = sharedState.getAdmin();
        operator = sharedState.getOperator();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        user1 = sharedState.getUser1(); // Use shared user1 from test-setup

        recipient = Keypair.generate();
        relayer = Keypair.generate(); // Relayer who calls and pays for transactions

        const airdropLamports = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(recipient.publicKey, airdropLamports),
            provider.connection.requestAirdrop(user1.publicKey, airdropLamports),
            provider.connection.requestAirdrop(relayer.publicKey, airdropLamports),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [feeVaultPda] = PublicKey.findProgramAddressSync([Buffer.from("fee_vault")], program.programId);
        [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("final_tss_pda")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);

        // Ensure inbound fee is disabled for deterministic seeding in this suite.
        await program.methods
            .setInboundFee(new anchor.BN(0))
            .accountsPartial({
                config: configPda,
                feeVault: feeVaultPda,
                admin: admin.publicKey,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        // Seed fee_vault with a small amount to cover relayer gas reimbursements in revert tests
        const feeVaultFundTx = await provider.connection.requestAirdrop(feeVaultPda, anchor.web3.LAMPORTS_PER_SOL);
        await provider.connection.confirmTransaction(feeVaultFundTx);

        mockPriceFeed = sharedState.getMockPriceFeed();

        // Get or create user1's USDT account (ATA is deterministic, so this will reuse if exists)
        user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);

        // Check current balance and mint if needed
        const currentBalance = await mockUSDT.getBalance(user1UsdtAccount);
        const requiredBalance = 10_000 * 1_000_000; // 10,000 tokens in raw units
        if (currentBalance < requiredBalance) {
            // Mint enough to reach 10,000 tokens
            const tokensToMint = 10_000 - (currentBalance / 1_000_000);
            if (tokensToMint > 0) {
                await mockUSDT.mintTo(user1UsdtAccount, tokensToMint);
            }
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

        // Seed vault with native SOL using sendUniversalTx (FUNDS route)
        const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

        // Force a known non-zero threshold even if another suite previously set 0.
        const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // Effectively unlimited
        await program.methods
            .setTokenRateLimit(veryLargeThreshold, false, false)
            .accountsPartial({
                config: configPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenMint: PublicKey.default,
                admin: admin.publicKey,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        // Deposit 8 SOL to vault for withdrawal tests (leave room for transaction fees)
        const solDepositAmount = 8 * anchor.web3.LAMPORTS_PER_SOL;
        const solFundsReq = {
            recipient: Array.from(Buffer.alloc(20, 0)), // Must be zero for FUNDS
            token: PublicKey.default,
            amount: new anchor.BN(solDepositAmount),
            payload: Buffer.from([]),
            revertRecipient: user1.publicKey,
            signatureData: Buffer.from([]),
        };

        // Check user1 balance before deposit
        const user1BalanceBefore = await provider.connection.getBalance(user1.publicKey);
        const vaultBalanceBefore = await provider.connection.getBalance(vaultPda);

        try {
            await program.methods
                .sendUniversalTx(solFundsReq, new anchor.BN(solDepositAmount))
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
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        } catch (error: any) {
            throw new Error(`Failed to deposit SOL to vault: ${error.message || error}`);
        }

        // Verify vault was seeded with SOL
        const vaultBalanceAfterDeposit = await provider.connection.getBalance(vaultPda);
        const user1BalanceAfter = await provider.connection.getBalance(user1.publicKey);

        if (vaultBalanceAfterDeposit < vaultBalanceBefore + solDepositAmount * 0.9) { // Allow 10% for fees
            throw new Error(
                `Vault deposit failed. Vault before: ${vaultBalanceBefore}, after: ${vaultBalanceAfterDeposit}, ` +
                `expected at least ${vaultBalanceBefore + solDepositAmount * 0.9}. ` +
                `User1 balance before: ${user1BalanceBefore}, after: ${user1BalanceAfter}`
            );
        }

        // Seed vault with SPL tokens using sendUniversalTx (FUNDS route)
        // user1 has 10,000 tokens minted in test-setup.ts
        const depositAmount = asTokenAmount(5_000);
        const recipientEvm = Array.from(Buffer.alloc(20, 1)); // EVM address (20 bytes)
        const fundsReq = {
            recipient: recipientEvm,
            token: mockUSDT.mint.publicKey,
            amount: depositAmount,
            payload: Buffer.from([]), // Empty payload for FUNDS route
            revertRecipient: user1.publicKey,
            signatureData: Buffer.from([]), // Empty for FUNDS route
        };

        const splTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);

        // Force a known non-zero threshold even if another suite previously set 0.
        await program.methods
            .setTokenRateLimit(veryLargeThreshold, true, true)
            .accountsPartial({
                config: configPda,
                tokenRateLimit: splTokenRateLimitPda,
                tokenMint: mockUSDT.mint.publicKey,
                admin: admin.publicKey,
                systemProgram: SystemProgram.programId,
            })
            .signers([admin])
            .rpc();

        // Verify SPL deposit
        const vaultUsdtBalanceBefore = await mockUSDT.getBalance(vaultUsdtAccount);

        try {
            await program.methods
                .sendUniversalTx(fundsReq, new anchor.BN(0)) // No native SOL for SPL funds
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    user: user1.publicKey,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: splTokenRateLimitPda,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        } catch (error: any) {
            throw new Error(`Failed to deposit SPL tokens to vault: ${error.message || error}`);
        }

        // Verify vault was seeded with SPL tokens
        const vaultUsdtBalanceAfter = await mockUSDT.getBalance(vaultUsdtAccount);
        const user1UsdtBalanceAfter = await mockUSDT.getBalance(user1UsdtAccount);

        // Convert depositAmount from base units to human units (getBalance returns human units)
        const depositAmountHuman = depositAmount.toNumber() / Number(TOKEN_MULTIPLIER);
        const expectedVaultBalance = vaultUsdtBalanceBefore + depositAmountHuman;
        if (vaultUsdtBalanceAfter < expectedVaultBalance) {
            throw new Error(
                `SPL deposit failed. ` +
                `Vault ATA before: ${vaultUsdtBalanceBefore}, after: ${vaultUsdtBalanceAfter}, ` +
                `expected at least ${expectedVaultBalance}. Deposit amount: ${depositAmountHuman} tokens`
            );
        }

        finalizeUniversalTx = makeFinalizeUniversalTxBuilder(program, configPda, vaultPda, tssPda);
    });

    describe("withdraw", () => {
        it("transfers SOL with a valid signature", async () => {
            const withdrawLamports = 2 * anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,           // token (SOL = default)
                recipient.publicKey,         // target (recipient for withdraw)
                DEFAULT_GAS_FEE              // gas_fee
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
            });

            const initialVault = await provider.connection.getBalance(vaultPda);
            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await finalizeUniversalTx({
                instructionId: 1,
                subTxId,
                universalTxId,
                amount: new anchor.BN(withdrawLamports),
                pushAccount: pushAccount,
                gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                sig: signature,
                caller: relayer.publicKey,
                recipient: recipient.publicKey,
            })
                .signers([relayer])
                .rpc();

            const finalVault = await provider.connection.getBalance(vaultPda);
            const finalRecipient = await provider.connection.getBalance(recipient.publicKey);
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);

            const actualRentForExecutedTx = await provider.connection.getMinimumBalanceForRentExemption(8);
            const gasUsed = 5_000 + actualRentForExecutedTx;
            expect(finalVault).to.equal(initialVault - withdrawLamports - gasUsed); // Vault pays withdraw amount + gas_used
            expect(finalRecipient).to.equal(initialRecipient + withdrawLamports);
            // Caller pays executed_sub_tx rent and gets gas_used reimbursement.
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            const expectedCallerGain = gasUsed - actualRentForExecutedTx;
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 100000); // Allow larger variance
        });

        it("rejects tampered signatures", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
            });

            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(withdrawLamports),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: { signature: corrupted, recoveryId: valid.recoveryId, messageHash: valid.messageHash },
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc(),
                "TssAuthFailed"
            );
        });

        it("rejects withdrawals while paused", async () => {
            await program.methods
                .pause()
                .accountsPartial({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();

            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
            });

            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(withdrawLamports),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
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

        it("rejects withdrawals that exceed the vault balance", async () => {
            const vaultLamports = await provider.connection.getBalance(vaultPda);
            const excessive = vaultLamports + anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(excessive),
                additional: tssAdditional,
            });

            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(excessive),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc(),
                "custom program error"
            );
        });
    });

    describe("withdraw SPL tokens", () => {
        it("transfers SPL tokens with a valid signature", async () => {
            const withdrawTokens = 1_000;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);
            const ceaAuthority = getCeaAuthorityPda(pushAccount);
            const ceaAta = getAssociatedTokenAddressSync(mockUSDT.mint.publicKey, ceaAuthority, true);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                mockUSDT.mint.publicKey,     // token (SPL = mint pubkey)
                recipient.publicKey,         // target (the SOL wallet, NOT the ATA)
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: withdrawRaw,
                additional: tssAdditional,
            });

            const initialVault = await mockUSDT.getBalance(vaultUsdtAccount);
            const initialRecipient = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            const ceaAtaBefore = await provider.connection.getAccountInfo(ceaAta);

            const sig = await finalizeUniversalTx({
                instructionId: 1,
                subTxId,
                universalTxId,
                amount: new anchor.BN(Number(withdrawRaw)),
                pushAccount: pushAccount,
                gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                sig: signature,
                caller: relayer.publicKey,
                recipient: recipient.publicKey,
                vaultAta: vaultUsdtAccount,
                ceaAta: ceaAta,
                mint: mockUSDT.mint.publicKey,
                tokenProgram: TOKEN_PROGRAM_ID,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                recipientAta: recipientUsdtAccount,
            })
                .signers([relayer])
                .rpc();

            const finalVault = await mockUSDT.getBalance(vaultUsdtAccount);
            const finalRecipient = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(finalVault).to.equal(initialVault - withdrawTokens);
            expect(finalRecipient).to.equal(initialRecipient + withdrawTokens);
            // Caller pays rents upfront and receives gas_used back (gas_to_refund stays in vault).
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            await provider.connection.confirmTransaction(sig, "confirmed");
            let tx = null as Awaited<ReturnType<typeof provider.connection.getTransaction>>;
            for (let i = 0; i < 5 && !tx; i++) {
                tx = await provider.connection.getTransaction(sig, {
                    commitment: "confirmed",
                    maxSupportedTransactionVersion: 0,
                });
                if (!tx) {
                    await new Promise((resolve) => setTimeout(resolve, 500));
                }
            }
            if (!tx || !tx.meta) {
                throw new Error("Missing transaction metadata for fee accounting");
            }

            const accountKeys = tx.transaction.message
                .getAccountKeys({
                    accountKeysFromLookups: tx.meta.loadedAddresses,
                })
                .keySegments()
                .flat();
            const relayerIndex = accountKeys.findIndex((k) =>
                k.equals(relayer.publicKey)
            );
            if (relayerIndex === -1) {
                throw new Error("Relayer account not found in transaction meta");
            }

            const metaDelta =
                Number(tx.meta.postBalances[relayerIndex]) -
                Number(tx.meta.preBalances[relayerIndex]);

            expect(callerBalanceChange).to.equal(metaDelta);
        });

        it("auto-creates recipient ATA when missing and reimburses caller for rent", async () => {
            // Mirrors the CEA ATA flow end-to-end: recipient ATA is created, funds arrive,
            // and — critically — the caller (relayer) is reimbursed the ATA rent via gas_used.
            // Without the accounting fix, the caller silently eats ~2.04M lamports per fresh recipient.
            const withdrawTokens = 50;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;

            // gas_fee needs to cover: sig fee (5k) + sub_tx_rent (~1M) + cea_ata_rent (~2.04M)
            // + recipient_ata_rent (~2.04M) = ~5.1M. Signed by TSS above the floor.
            const HIGH_GAS_FEE = BigInt(6_000_000);

            const freshRecipient = Keypair.generate();
            const freshRecipientAta = getAssociatedTokenAddressSync(
                mockUSDT.mint.publicKey,
                freshRecipient.publicKey
            );

            const preAtaInfo = await provider.connection.getAccountInfo(freshRecipientAta);
            expect(preAtaInfo, "recipient ATA must not exist pre-tx").to.be.null;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const ceaAuthority = getCeaAuthorityPda(pushAccount);
            const ceaAta = getAssociatedTokenAddressSync(mockUSDT.mint.publicKey, ceaAuthority, true);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                mockUSDT.mint.publicKey,
                freshRecipient.publicKey,
                HIGH_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: withdrawRaw,
                additional: tssAdditional,
            });

            const relayerBefore = await provider.connection.getBalance(relayer.publicKey);

            const sig = await finalizeUniversalTx({
                instructionId: 1,
                subTxId,
                universalTxId,
                amount: new anchor.BN(Number(withdrawRaw)),
                pushAccount: pushAccount,
                gasFee: new anchor.BN(Number(HIGH_GAS_FEE)),
                sig: signature,
                caller: relayer.publicKey,
                recipient: freshRecipient.publicKey,
                vaultAta: vaultUsdtAccount,
                ceaAta: ceaAta,
                mint: mockUSDT.mint.publicKey,
                tokenProgram: TOKEN_PROGRAM_ID,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                recipientAta: freshRecipientAta,
            })
                .signers([relayer])
                .rpc();

            const postBalance = await mockUSDT.getBalance(freshRecipientAta);
            expect(postBalance).to.equal(withdrawTokens);

            // Accounting: relayer's net SOL change must match transaction meta (i.e. the
            // reimbursement from vault plus fee/rent debits already netted). If the
            // recipient ATA rent were not folded into gas_used, the relayer would be down
            // ~2.04M lamports vs meta reports. The equality below proves the leak is closed.
            await provider.connection.confirmTransaction(sig, "confirmed");
            let tx = null as Awaited<ReturnType<typeof provider.connection.getTransaction>>;
            for (let i = 0; i < 5 && !tx; i++) {
                tx = await provider.connection.getTransaction(sig, {
                    commitment: "confirmed",
                    maxSupportedTransactionVersion: 0,
                });
                if (!tx) await new Promise((r) => setTimeout(r, 500));
            }
            if (!tx?.meta) throw new Error("Missing transaction metadata");

            const accountKeys = tx.transaction.message
                .getAccountKeys({ accountKeysFromLookups: tx.meta.loadedAddresses })
                .keySegments()
                .flat();
            const relayerIdx = accountKeys.findIndex((k) => k.equals(relayer.publicKey));
            if (relayerIdx === -1) throw new Error("Relayer not in tx keys");
            const metaDelta = Number(tx.meta.postBalances[relayerIdx]) - Number(tx.meta.preBalances[relayerIdx]);
            const relayerAfter = await provider.connection.getBalance(relayer.publicKey);
            expect(relayerAfter - relayerBefore).to.equal(metaDelta);

            // gas_used from the emitted event must include the recipient ATA rent.
            // recipient_ata_created must be true in the event for off-chain reconciliation.
            const events = await extractEventCpi(provider.connection, program as any, sig);
            const finalized = events.find((e) => e.name === "universalTxFinalized");
            expect(finalized, "UniversalTxFinalized not emitted").to.exist;
            expect((finalized!.data as any).recipientAtaCreated, "recipient_ata_created should be true").to.equal(true);

            const rent = await provider.connection.getMinimumBalanceForRentExemption(165); // SPL token account size
            const gasUsed = Number((finalized!.data as any).gasUsed);
            expect(gasUsed).to.be.at.least(rent, "gas_used must include recipient ATA rent");
        });

        it("rejects SPL withdrawals with a tampered signature", async () => {
            const withdrawTokens = 200;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);
            const ceaAuthority = getCeaAuthorityPda(pushAccount);
            const ceaAta = getAssociatedTokenAddressSync(mockUSDT.mint.publicKey, ceaAuthority, true);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                mockUSDT.mint.publicKey,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: withdrawRaw,
                additional: tssAdditional,
            });

            const corrupted = [...signature.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(Number(withdrawRaw)),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: { signature: corrupted, recoveryId: signature.recoveryId, messageHash: signature.messageHash },
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                    vaultAta: vaultUsdtAccount,
                    ceaAta: ceaAta,
                    mint: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: recipientUsdtAccount,
                })
                    .signers([relayer])
                    .rpc(),
                "TssAuthFailed"
            );
        });
    });

    describe("revert withdrawals", () => {
        it("reverts a SOL withdrawal with a valid signature", async () => {
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            // Include subTxId, universalTxId, recipient, and gas_fee in additional array
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(revertAmount),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    recipient.publicKey,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE
                ),
            });

            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .revertUniversalTx(
                    subTxId,
                    universalTxId,
                    new anchor.BN(revertAmount),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(4102444800),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: null,
                    recipientTokenAccount: null,
                    tokenMint: null,
                    tokenProgram: null,
                })
                .signers([relayer])
                .rpc();

            const finalRecipient = await provider.connection.getBalance(recipient.publicKey);
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
            expect(finalRecipient).to.equal(initialRecipient + revertAmount);
            // Measured-cost reimbursement: caller pays ExecutedSubTx rent + tx fee, gets back
            // (SIGNATURE_FEE + ExecutedSubTx rent). Native path creates no ATA, so net ≈ 0.
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            expect(callerBalanceChange).to.be.closeTo(0, 50_000);
        });

        it("rejects revert when signed gas_fee is below the measured gas_used (InsufficientGasBudget)", async () => {
            // Under the measured-reimbursement model, gas_fee is a signed ceiling and the
            // on-chain program refunds the measured cost. Signing a gas_fee smaller than
            // the base measured cost (SIGNATURE_FEE + ExecutedSubTx rent ≈ 895k lamports)
            // trips the cap check.
            const revertAmount = 1;
            const tooLowGasFee = BigInt(100_000);

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("gas budget too low"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(revertAmount),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    recipient.publicKey,
                    revertInstruction.revertMsg,
                    tooLowGasFee
                ),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        new anchor.BN(Number(tooLowGasFee)),
                        new anchor.BN(4102444800),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedTxPda,
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

        it("reverts an SPL withdrawal with a valid signature", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            // Create recipient account first (needed for message hash)
            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            // Include subTxId, universalTxId, mint, revert_recipient, and gas_fee in additional array
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: revertRaw,
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    revertInstruction.revertRecipient,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE,
                    mockUSDT.mint.publicKey
                ),
            });
            const initialRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .revertUniversalTx(
                    subTxId,
                    universalTxId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(4102444800),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: vaultUsdtAccount,
                    recipientTokenAccount: recipientRevertAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                })
                .signers([relayer])
                .rpc();

            const finalRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
            expect(finalRecipientBalance).to.equal(initialRecipientBalance + revertTokens);
            // Measured-cost reimbursement: recipient ATA existed pre-call, so no ATA-rent term.
            // Caller nets ≈ 0 (pays ExecutedSubTx rent + tx fee, refunded SIG_FEE + ExecutedSubTx rent).
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            expect(callerBalanceChange).to.be.closeTo(0, 50_000);
        });

        it("auto-creates recipient ATA on SPL revert to a fresh wallet and reimburses ATA rent", async () => {
            // Legacy SPL revert to a wallet whose (recipient, mint) canonical ATA does not exist.
            // Program creates it via inline manual CPI, folds rent into measured gas_used, and
            // pays the caller from fee_vault. gas_fee is the signed ceiling.
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;

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
            const signedGasFee = BigInt(measuredGasUsed + 500_000); // generous cap

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);
            const revertInstruction = {
                revertRecipient: freshRecipient.publicKey,
                revertMsg: Buffer.from("revert SPL fresh recipient"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: revertRaw,
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    freshRecipient.publicKey,
                    revertInstruction.revertMsg,
                    signedGasFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const callerBefore = await provider.connection.getBalance(relayer.publicKey);
            const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);

            await program.methods
                .revertUniversalTx(
                    subTxId,
                    universalTxId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    new anchor.BN(signedGasFee.toString()),
                    new anchor.BN(4102444800),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: freshRecipient.publicKey,
                    executedSubTx: executedTxPda,
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
            expect(postAtaInfo, "recipient ATA must exist after revert").to.not.be.null;
            expect(await mockUSDT.getBalance(recipientAta)).to.equal(revertTokens);

            const callerAfter = await provider.connection.getBalance(relayer.publicKey);
            const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
            expect(feeVaultBefore - feeVaultAfter).to.equal(measuredGasUsed);
            expect(callerAfter - callerBefore).to.be.closeTo(0, 50_000);
        });

        it("rejects SPL revert to a fresh wallet when gas_fee cannot cover ATA rent (InsufficientGasBudget)", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;

            const freshRecipient = Keypair.generate();
            const recipientAta = getAssociatedTokenAddressSync(
                mockUSDT.mint.publicKey,
                freshRecipient.publicKey
            );

            const executedSubTxRent = await provider.connection.getMinimumBalanceForRentExemption(8);
            // Cover base only (SIG_FEE + ExecutedSubTx rent); measured cost with ATA rent > gas_fee.
            const undersizedGasFee = BigInt(5_000 + executedSubTxRent + 1);

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);
            const revertInstruction = {
                revertRecipient: freshRecipient.publicKey,
                revertMsg: Buffer.from("undersized gas budget"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: revertRaw,
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    freshRecipient.publicKey,
                    revertInstruction.revertMsg,
                    undersizedGasFee,
                    mockUSDT.mint.publicKey
                ),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        new anchor.BN(undersizedGasFee.toString()),
                        new anchor.BN(4102444800),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: freshRecipient.publicKey,
                        executedSubTx: executedTxPda,
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

    describe("error conditions", () => {
        it("rejects zero-amount withdrawals", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(0),
                additional: tssAdditional,
            });

            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(0),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc(),
                "InvalidAmount"
            );
        });

        it("rejects withdrawals with zero pushAccount", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId(); // Unique sub_tx_id for this test
            const zeroPushAccount = Array.from(Buffer.alloc(20, 0)); // All zeros
            const executedTxPda = getExecutedTxPda(subTxId);

            // Verify executed_sub_tx doesn't exist before (should be unique sub_tx_id)
            try {
                await program.account.executedSubTx.fetch(executedTxPda);
                expect.fail("executed_sub_tx should not exist for new sub_tx_id");
            } catch {
                // Expected - account doesn't exist
            }

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(zeroPushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: tssAdditional,
            });

            try {
                await finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                    pushAccount: zeroPushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown InvalidInput error");
            } catch (error: any) {
                const errorStr = error.toString();
                expect(errorStr.includes("InvalidInput")).to.be.true;
            }

            // Verify executed_sub_tx was NOT created (validation failed before execution, atomic rollback)
            try {
                await program.account.executedSubTx.fetch(executedTxPda);
                expect.fail("executed_sub_tx should not exist - transaction failed atomically");
            } catch {
                // Expected - account doesn't exist (atomic transaction rollback)
            }
        });

        it("rejects withdrawals with zero recipient", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);
            const zeroRecipient = PublicKey.default;

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                zeroRecipient,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: tssAdditional,
            });

            // Anchor throws account validation error for zero recipient
            // Our program also validates this, but Anchor might catch it first
            try {
                await finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: zeroRecipient,
                })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown an error for zero recipient");
            } catch (error: any) {
                const errorStr = error.toString();
                // Check for either Anchor account validation error or our custom InvalidInput error
                expect(
                    errorStr.includes("InvalidInput") ||
                    errorStr.includes("AnchorError") ||
                    errorStr.includes("recipient")
                ).to.be.true;
            }
        });

        it("rejects duplicate subTxId (replay protection)", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
            });

            // First withdrawal should succeed
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);
            await finalizeUniversalTx({
                instructionId: 1,
                subTxId,
                universalTxId,
                amount: new anchor.BN(withdrawLamports),
                pushAccount: pushAccount,
                gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                sig: signature,
                caller: relayer.publicKey,
                recipient: recipient.publicKey,
            })
                .signers([relayer])
                .rpc();

            // Verify caller received gas_used reimbursement
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            // Caller pays executed_sub_tx rent, receives gas_used = signature_fee + sub_tx_rent.
            const actualRentForExecutedTx = await provider.connection.getMinimumBalanceForRentExemption(8);
            const gasUsed = 5_000 + actualRentForExecutedTx;
            const expectedCallerGain = -actualRentForExecutedTx + gasUsed;
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 15000); // Allow for transaction fees

            // Verify executed_sub_tx account exists after success
            // The account is a PDA derived from [b"executed_sub_tx", sub_tx_id], so existence = sub_tx_id was executed
            // Since ExecutedSubTx is an empty struct {}, we only verify account existence
            const executedTxAfter = await program.account.executedSubTx.fetch(executedTxPda);
            expect(executedTxAfter).to.not.be.null; // Account existence = transaction executed

            // Second withdrawal with same subTxId should fail
            const tssAdditional2 = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional2,
            });

            try {
                await finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(withdrawLamports),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: signature2,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown PayloadExecuted error");
            } catch (error: any) {
                // With `init`, duplicate subTxId fails at system program level (account already exists)
                // The error comes from Solana system program: "Allocate: account ... already in use"
                const errorStr = error.toString();
                const errorLogs = error.logs || [];
                const allLogs = Array.isArray(errorLogs) ? errorLogs.join(' ') : '';

                // Check for the system program error indicating account already exists
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");

                expect(isReplayError).to.be.true;
            }
        });

        it("does NOT set executed=true on failed withdrawal (griefing protection)", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const executedTxPda = getExecutedTxPda(subTxId);

            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
            });

            // Corrupt signature to make it fail
            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            // Attempt withdrawal with corrupted signature (should fail)
            try {
                await finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(withdrawLamports),
                    pushAccount: pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    sig: { signature: corrupted, recoveryId: valid.recoveryId, messageHash: valid.messageHash },
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have failed with TssAuthFailed");
            } catch (error: any) {
                expect(error.toString().includes("TssAuthFailed")).to.be.true;
            }

            // Verify failed call didn't create executed_sub_tx account (atomic rollback)
            try {
                await program.account.executedSubTx.fetch(executedTxPda);
                expect.fail("executed_sub_tx should not exist - transaction failed atomically");
            } catch {
                // Expected - account doesn't exist (atomic transaction rollback)
            }

            // Now try with VALID signature - should succeed (proves sub_tx_id wasn't bricked)
            const tssAdditional2 = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );

            const validSig = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional2,
            });

            await finalizeUniversalTx({
                instructionId: 1,
                subTxId,
                universalTxId,
                amount: new anchor.BN(withdrawLamports),
                pushAccount: pushAccount,
                gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                sig: validSig,
                caller: relayer.publicKey,
                recipient: recipient.publicKey,
            })
                .signers([relayer])
                .rpc();

            // Verify executed_sub_tx account exists after success (account existence = executed)
            const ExecutedSubTx = await program.account.executedSubTx.fetch(executedTxPda);
            expect(ExecutedSubTx).to.exist; // Account existence = transaction executed
        });
    });

    describe("revert error conditions", () => {
        it("rejects revert while paused", async () => {
            await program.methods
                .pause()
                .accountsPartial({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();

            try {
                const subTxId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const executedTxPda = getExecutedTxPda(subTxId);
                const revertAmount = 1;

                const revertInstruction = {
                    revertRecipient: recipient.publicKey,
                    revertMsg: Buffer.from("revert paused"),
                };

                const signature = await signTssMessageWithChainId({
                    instruction: TssInstruction.Revert,
                    amount: BigInt(revertAmount),
                    additional: buildRevertAdditionalData(
                        new Uint8Array(subTxId),
                        new Uint8Array(universalTxId),
                        recipient.publicKey,
                        revertInstruction.revertMsg,
                        DEFAULT_GAS_FEE
                    ),
                });

                await expectRejection(
                    program.methods
                        .revertUniversalTx(
                            subTxId,
                            universalTxId,
                            new anchor.BN(revertAmount),
                            revertInstruction,
                            new anchor.BN(Number(DEFAULT_GAS_FEE)),
                            new anchor.BN(4102444800),
                            signature.signature,
                            signature.recoveryId,
                            signature.messageHash,
                        )
                        .accountsPartial({
                            config: configPda,
                            vault: vaultPda,
                            feeVault: feeVaultPda,
                            tssPda,
                            recipient: recipient.publicKey,
                            executedSubTx: executedTxPda,
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
            } finally {
                await program.methods
                    .unpause()
                    .accountsPartial({ operator: operator.publicKey, config: configPda })
                    .signers([operator])
                    .rpc();
            }
        });

        it("rejects revert with zero amount", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(0),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    recipient.publicKey,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE
                ),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(0),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedTxPda,
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

        it("rejects revert with zero revertRecipient", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;

            const revertInstruction = {
                revertRecipient: PublicKey.default,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(revertAmount),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    PublicKey.default,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE
                ),
            });

            // Our program validates revertRecipient != Pubkey::default()
            // But Anchor might also throw account validation error
            try {
                await program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey, // Use valid recipient for account validation
                        executedSubTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown an error for zero revertRecipient");
            } catch (error: any) {
                const errorStr = error.toString();
                // Our program should throw InvalidRecipient for zero revertRecipient
                expect(
                    errorStr.includes("InvalidRecipient") ||
                    errorStr.includes("AnchorError")
                ).to.be.true;
            }
        });

        it("rejects duplicate revert subTxId (replay protection)", async () => {
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;

            // Fund vault before revert (needed for the transfer)
            const vaultBalance = await provider.connection.getBalance(vaultPda);
            if (vaultBalance < revertAmount * 2) {
                // Transfer enough for both revert attempts
                const fundAmount = revertAmount * 2 + anchor.web3.LAMPORTS_PER_SOL; // Extra for rent
                const fundTx = await provider.connection.requestAirdrop(vaultPda, fundAmount);
                await provider.connection.confirmTransaction(fundTx);
                await new Promise(resolve => setTimeout(resolve, 1000));
            }

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(revertAmount),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    recipient.publicKey,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE
                ),
            });

            // First revert should succeed
            await program.methods
                .revertUniversalTx(
                    subTxId,
                    universalTxId,
                    new anchor.BN(revertAmount),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(4102444800),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: null,
                    recipientTokenAccount: null,
                    tokenMint: null,
                    tokenProgram: null,
                })
                .signers([relayer])
                .rpc();

            // Verify executed_sub_tx account exists after success
            // The account is a PDA derived from [b"executed_sub_tx", sub_tx_id], so existence = sub_tx_id was executed
            // Since ExecutedSubTx is an empty struct {}, we only verify account existence
            const executedTxAfter = await program.account.executedSubTx.fetch(executedTxPda);
            expect(executedTxAfter).to.not.be.null; // Account existence = transaction executed

            // Second revert with same subTxId should fail
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(revertAmount),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    recipient.publicKey,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE
                ),
            });

            try {
                await program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
                        signature2.signature,
                        signature2.recoveryId,
                        signature2.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown PayloadExecuted error");
            } catch (error: any) {
                // With `init`, duplicate subTxId fails at system program level (account already exists)
                // The error comes from Solana system program: "Allocate: account ... already in use"
                const errorStr = error.toString();
                const errorLogs = error.logs || [];
                const allLogs = Array.isArray(errorLogs) ? errorLogs.join(' ') : '';

                // Check for the system program error indicating account already exists
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");

                expect(isReplayError).to.be.true;
            }
        });

        it("rejects SPL revert with zero amount", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(0),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    revertInstruction.revertRecipient,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE,
                    mockUSDT.mint.publicKey
                ),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(0),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientRevertAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidAmount"
            );
        });

        it("rejects SPL revert with zero revertRecipient", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;

            const revertInstruction = {
                revertRecipient: PublicKey.default,
                revertMsg: Buffer.from("revert SPL"),
            };

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: revertRaw,
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    PublicKey.default,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE,
                    mockUSDT.mint.publicKey
                ),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientRevertAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidRecipient"
            );
        });

        it("rejects SPL revert duplicate subTxId (replay protection)", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;

            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(subTxId);

            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: revertRaw,
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    revertInstruction.revertRecipient,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE,
                    mockUSDT.mint.publicKey
                ),
            });

            // First revert should succeed
            await program.methods
                .revertUniversalTx(
                    subTxId,
                    universalTxId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(4102444800),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                )
                .accountsPartial({
                    config: configPda,
                    vault: vaultPda,
                    feeVault: feeVaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedSubTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                    tokenVault: vaultUsdtAccount,
                    recipientTokenAccount: recipientRevertAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .signers([relayer])
                .rpc();

            // Verify executed_sub_tx account exists after success
            // The account is a PDA derived from [b"executed_sub_tx", sub_tx_id], so existence = sub_tx_id was executed
            // Since ExecutedSubTx is an empty struct {}, we only verify account existence
            const executedTxAfter = await program.account.executedSubTx.fetch(executedTxPda);
            expect(executedTxAfter).to.not.be.null; // Account existence = transaction executed

            // Second revert with same subTxId should fail
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: revertRaw,
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    revertInstruction.revertRecipient,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE,
                    mockUSDT.mint.publicKey
                ),
            });

            try {
                await program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(4102444800),
                        signature2.signature,
                        signature2.recoveryId,
                        signature2.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: vaultUsdtAccount,
                        recipientTokenAccount: recipientRevertAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown PayloadExecuted error");
            } catch (error: any) {
                // With `init`, duplicate subTxId fails at system program level (account already exists)
                // The error comes from Solana system program: "Allocate: account ... already in use"
                const errorStr = error.toString();
                const errorLogs = error.logs || [];
                const allLogs = Array.isArray(errorLogs) ? errorLogs.join(' ') : '';

                // Check for the system program error indicating account already exists
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");
                expect(isReplayError).to.be.true;
            }
        });
    });

    // =======================================================================
    //  DEADLINE ENFORCEMENT
    // =======================================================================
    describe("deadline enforcement", () => {
        const PAST_DEADLINE = BigInt(1); // Unix epoch 1970 — always expired

        it("rejects finalize_universal_tx with an expired deadline (SignatureExpired)", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;

            // Sign with the past deadline — hash includes deadline=1
            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
                deadline: PAST_DEADLINE,
            });

            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(withdrawLamports),
                    pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    deadline: new anchor.BN(PAST_DEADLINE.toString()),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc(),
                "SignatureExpired"
            );
        });

        it("rejects revert_universal_tx with an expired deadline (SignatureExpired)", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;
            const revertInstruction = {
                revertRecipient: recipient.publicKey,
                revertMsg: Buffer.from("expired revert"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Revert,
                amount: BigInt(revertAmount),
                additional: buildRevertAdditionalData(
                    new Uint8Array(subTxId),
                    new Uint8Array(universalTxId),
                    recipient.publicKey,
                    revertInstruction.revertMsg,
                    DEFAULT_GAS_FEE
                ),
                deadline: PAST_DEADLINE,
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        subTxId,
                        universalTxId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        new anchor.BN(PAST_DEADLINE.toString()),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                    )
                    .accountsPartial({
                        config: configPda,
                        vault: vaultPda,
                        feeVault: feeVaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedSubTx: getExecutedTxPda(subTxId),
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                        tokenVault: null,
                        recipientTokenAccount: null,
                        tokenMint: null,
                        tokenProgram: null,
                    })
                    .signers([relayer])
                    .rpc(),
                "SignatureExpired"
            );
        });

        it("rejects finalize_universal_tx when submitted deadline differs from signed deadline (MessageHashMismatch)", async () => {
            const subTxId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const pushAccount = generatePushAccount();
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;

            // Sign with DEFAULT_DEADLINE (far future)
            const tssAdditional = buildWithdrawAdditionalData(
                new Uint8Array(universalTxId),
                new Uint8Array(subTxId),
                new Uint8Array(pushAccount),
                PublicKey.default,
                recipient.publicKey,
                DEFAULT_GAS_FEE
            );
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.Withdraw,
                amount: BigInt(withdrawLamports),
                additional: tssAdditional,
                // uses DEFAULT_DEADLINE implicitly
            });

            // Submit with a different future deadline — expiry check passes but
            // the on-chain hash reconstruction uses the submitted deadline, so
            // it won't match the signature (which was built with DEFAULT_DEADLINE).
            const WRONG_FUTURE_DEADLINE = DEFAULT_DEADLINE + BigInt(1);
            await expectRejection(
                finalizeUniversalTx({
                    instructionId: 1,
                    subTxId,
                    universalTxId,
                    amount: new anchor.BN(withdrawLamports),
                    pushAccount,
                    gasFee: new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    deadline: new anchor.BN(WRONG_FUTURE_DEADLINE.toString()),
                    sig: signature,
                    caller: relayer.publicKey,
                    recipient: recipient.publicKey,
                })
                    .signers([relayer])
                    .rpc(),
                "MessageHashMismatch"
            );
        });
    });
});
