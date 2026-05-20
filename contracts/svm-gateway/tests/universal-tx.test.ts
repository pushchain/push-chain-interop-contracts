import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import {
  PublicKey,
  Keypair,
  SystemProgram,
  LAMPORTS_PER_SOL,
} from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";
import { getSolPrice, calculateSolAmount } from "./setup-pricefeed";
import * as spl from "@solana/spl-token";
import { ensureTestSetup } from "./helpers/test-setup";

describe("Universal Gateway - send_universal_tx Tests", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const provider = anchor.getProvider() as anchor.AnchorProvider;
  const program = anchor.workspace
    .UniversalGateway as Program<UniversalGateway>;

  before(async () => {
    await ensureTestSetup();
  });

  let admin: Keypair;
  let operator: Keypair;
  let pauser: Keypair;
  let user1: Keypair;
  let user2: Keypair;
  let configPda: PublicKey;
  let vaultPda: PublicKey;
  let feeVaultPda: PublicKey;
  let rateLimitConfigPda: PublicKey;
  let mockPriceFeed: PublicKey;
  let solPrice: number;
  let mockUSDT: any;
  let mockUSDC: any;
  const DEFAULT_INBOUND_FEE_LAMPORTS = 50_000;
  const MAX_INBOUND_FEE_LAMPORTS = 2_000_000;

  // Helper to create payload (EVM-style: to address, value, calldata, gas params).
  const createPayload = (
    to: number,
    vType: any = { signedVerification: {} }
  ) => ({
    to: Array.from(Buffer.alloc(20, to)),
    value: new anchor.BN(0),
    data: Buffer.from([]),
    gasLimit: new anchor.BN(21000),
    maxFeePerGas: new anchor.BN(20000000000),
    maxPriorityFeePerGas: new anchor.BN(1000000000),
    nonce: new anchor.BN(0),
    deadline: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
    vType,
  });

  /**
   * Serialize payload as Anchor/Borsh-encoded UniversalPayload (matches program state.rs).
   * EVM relayer decodes the same format on Push chain. Smaller than JSON.
   */
  const serializePayload = (payload: any): Buffer => {
    // to: exactly 20 bytes (EVM address), match Rust [u8; 20]
    const toRaw = Buffer.from(new Uint8Array(payload.to));
    const toBuf = Buffer.alloc(20);
    toRaw.copy(toBuf, 0, 0, Math.min(20, toRaw.length));
    const data = Buffer.isBuffer(payload.data)
      ? payload.data
      : Buffer.from(payload.data ?? []);
    const value = BigInt(payload.value.toString());
    const gasLimit = BigInt(payload.gasLimit.toString());
    const maxFeePerGas = BigInt(payload.maxFeePerGas.toString());
    const maxPriorityFeePerGas = BigInt(
      payload.maxPriorityFeePerGas.toString()
    );
    const nonce = BigInt(payload.nonce.toString());
    const deadline = BigInt(payload.deadline.toString());
    const vTypeDiscriminant =
      payload.vType?.signedVerification !== undefined ? 0 : 1;

    const dataLen = data.length;
    const size = 20 + 8 + 4 + dataLen + 8 + 8 + 8 + 8 + 8 + 1;
    const buf = Buffer.alloc(size);
    let off = 0;
    toBuf.copy(buf, off);
    off += 20;
    buf.writeBigUInt64LE(value, off);
    off += 8;
    buf.writeUInt32LE(dataLen, off);
    off += 4;
    data.copy(buf, off);
    off += dataLen;
    buf.writeBigUInt64LE(gasLimit, off);
    off += 8;
    buf.writeBigUInt64LE(maxFeePerGas, off);
    off += 8;
    buf.writeBigUInt64LE(maxPriorityFeePerGas, off);
    off += 8;
    buf.writeBigUInt64LE(nonce, off);
    off += 8;
    buf.writeBigInt64LE(deadline, off);
    off += 8;
    buf.writeUInt8(vTypeDiscriminant, off);
    return buf;
  };


  // Helper to get token rate limit PDA
  const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit"), tokenMint.toBuffer()],
      program.programId
    );
    return pda;
  };

  const setInboundFee = async (feeLamports: number) => {
    await program.methods
      .setInboundFee(new anchor.BN(feeLamports))
      .accountsPartial({
        config: configPda,
        feeVault: feeVaultPda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin])
      .rpc();
  };

  const withInboundFee = (baseLamports: number) =>
    new anchor.BN(baseLamports + DEFAULT_INBOUND_FEE_LAMPORTS);

  before(async () => {
    admin = sharedState.getAdmin();
    operator = sharedState.getOperator();
    pauser = sharedState.getPauser();
    user1 = Keypair.generate();
    user2 = Keypair.generate();

    const airdropAmount = 20 * LAMPORTS_PER_SOL;
    await Promise.all([
      provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
      provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
    ]);
    await new Promise((resolve) => setTimeout(resolve, 2000));

    [configPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("config")],
      program.programId
    );
    [vaultPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("vault")],
      program.programId
    );
    [feeVaultPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("fee_vault")],
      program.programId
    );
    [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rate_limit_config")],
      program.programId
    );

    mockPriceFeed = sharedState.getMockPriceFeed();
    solPrice = await getSolPrice(mockPriceFeed);

    // Get mock tokens
    mockUSDT = sharedState.getMockUSDT();
    mockUSDC = sharedState.getMockUSDC();

    // Normalize token rate limits every run so this suite doesn't inherit stale 0-threshold state.
    const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // 1 sextillion
    for (const tokenMint of [
      PublicKey.default,
      mockUSDT.mint.publicKey,
      mockUSDC.mint.publicKey,
    ]) {
      await program.methods
        .setTokenRateLimit(
          veryLargeThreshold,
          tokenMint.equals(PublicKey.default) ? false : true,
          tokenMint.equals(PublicKey.default) ? false : true
        )
        .accountsPartial({
          admin: admin.publicKey,
          config: configPda,
          tokenRateLimit: getTokenRateLimitPda(tokenMint),
          tokenMint,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();
    }

    await setInboundFee(DEFAULT_INBOUND_FEE_LAMPORTS);
  });

  describe("GAS Route (TxType.GAS)", () => {
    it("Should deposit native SOL as gas without payload", async () => {
      const gasAmount = calculateSolAmount(2.5, solPrice);
      const initialVaultBalance = await provider.connection.getBalance(vaultPda);
      const initialFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      const initialUserBalance = await provider.connection.getBalance(user1.publicKey);

      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("gas_sig"),
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(gasAmount))
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

      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      const finalFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      // Bridge vault receives only the gas amount; fee goes to fee_vault (1:1 invariant)
      expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
      expect(finalFeeVaultBalance - initialFeeVaultBalance).to.equal(DEFAULT_INBOUND_FEE_LAMPORTS);
    });

    it("Should route GAS request with payload to GAS_AND_PAYLOAD (not reject)", async () => {
      // NOTE: This test verifies the correct behavior - amount==0 + payload>0 routes to GAS_AND_PAYLOAD
      const gasAmount = calculateSolAmount(2.5, solPrice);
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );
      const initialVaultBalance = await provider.connection.getBalance(
        vaultPda
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: serializePayload(createPayload(99)), // Non-empty payload
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("sig"),
      };

      // Should succeed and route to GAS_AND_PAYLOAD (fetchTxType logic)
      await program.methods
        .sendUniversalTx(req, withInboundFee(gasAmount))
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

      // Verify transaction succeeded (vault receives only gas; fee goes to fee_vault)
      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
    });
  });

  describe("GAS_AND_PAYLOAD Route", () => {
    it("Should deposit gas with payload", async () => {
      const gasAmount = calculateSolAmount(2.5, solPrice);
      const initialVaultBalance = await provider.connection.getBalance(
        vaultPda
      );
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: serializePayload(createPayload(1)),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("gas_payload_sig"),
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(gasAmount))
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

      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
    });

    it("Should allow payload-only execution (gas_amount == 0)", async () => {
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: serializePayload(createPayload(1)),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("payload_only"),
      };

      // Should succeed with 0 native amount
      await program.methods
        .sendUniversalTx(req, withInboundFee(0))
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

  describe("FUNDS Route - Native SOL", () => {
    it("Should bridge native SOL funds", async () => {
      const fundsAmount = 0.5 * LAMPORTS_PER_SOL;
      const initialVaultBalance = await provider.connection.getBalance(
        vaultPda
      );
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)), // Must be zero for FUNDS
        token: PublicKey.default,
        amount: new anchor.BN(fundsAmount),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("funds_sig"),
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(fundsAmount))
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

      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      expect(finalVaultBalance - initialVaultBalance).to.equal(fundsAmount);
    });

    it("Should bridge native SOL funds to explicit recipient", async () => {
      const fundsAmount = 0.75 * LAMPORTS_PER_SOL;
      const initialVaultBalance = await provider.connection.getBalance(
        vaultPda
      );
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 1)), // Non-zero recipient now allowed
        token: PublicKey.default,
        amount: new anchor.BN(fundsAmount),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("funds_nonzero_recipient"),
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(fundsAmount))
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

      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      expect(finalVaultBalance - initialVaultBalance).to.equal(fundsAmount);
    });

    it("Should reject FUNDS when native amount does not match bridge amount", async () => {
      const fundsAmount = 0.5 * LAMPORTS_PER_SOL;
      const wrongNativeAmount = fundsAmount - 1234;
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(fundsAmount),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("invalid_native_amount"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(wrongNativeAmount))
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
        expect.fail("Should reject FUNDS when native amount mismatches");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidAmount");
      }
    });
  });

  describe("FUNDS Route - SPL Token", () => {
    it("Should bridge SPL token funds", async () => {
      // Create user token account and mint tokens using mock token's methods
      const userTokenAccount = await mockUSDT.createTokenAccount(
        user1.publicKey
      );
      const gatewayTokenAccount = (
        await spl.getOrCreateAssociatedTokenAccount(
          provider.connection as any,
          admin,
          mockUSDT.mint.publicKey,
          vaultPda,
          true
        )
      ).address;

      // Mint tokens using mock token's mintTo method (uses correct mint authority)
      await mockUSDT.mintTo(userTokenAccount, 1000);
      const tokenAmount = new anchor.BN(1000 * 10 ** mockUSDT.config.decimals);

      const initialGatewayBalance = await mockUSDT.getBalance(gatewayTokenAccount);
      const initialFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      const usdtTokenRateLimitPda = getTokenRateLimitPda(
        mockUSDT.mint.publicKey
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: mockUSDT.mint.publicKey,
        amount: tokenAmount,
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("spl_funds_sig"),
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(0)) // Fee-only native amount for SPL FUNDS
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

      const finalGatewayBalance = await mockUSDT.getBalance(gatewayTokenAccount);
      const finalFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      const balanceIncrease =
        (finalGatewayBalance - initialGatewayBalance) * 10 ** mockUSDT.config.decimals;
      expect(balanceIncrease).to.equal(tokenAmount.toNumber());
      expect(finalFeeVaultBalance - initialFeeVaultBalance).to.equal(DEFAULT_INBOUND_FEE_LAMPORTS);
    });

    it("Should reject non-canonical vault-owned token account", async () => {
      const userTokenAccount = await mockUSDT.createTokenAccount(
        user1.publicKey
      );
      const nonCanonicalVaultAccount = await mockUSDT.createTokenAccount(
        vaultPda,
        true
      );
      await mockUSDT.mintTo(userTokenAccount, 250);

      const tokenAmount = new anchor.BN(250 * 10 ** mockUSDT.config.decimals);
      const usdtTokenRateLimitPda = getTokenRateLimitPda(
        mockUSDT.mint.publicKey
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: mockUSDT.mint.publicKey,
        amount: tokenAmount,
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("non_canonical_vault_sig"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(0))
          .accountsPartial({
            config: configPda,
            vault: vaultPda,
            feeVault: feeVaultPda,
            userTokenAccount: userTokenAccount,
            gatewayTokenAccount: nonCanonicalVaultAccount,
            user: user1.publicKey,
            priceUpdate: mockPriceFeed,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: usdtTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([user1])
          .rpc();
        expect.fail("Should reject non-canonical vault-owned token account");
      } catch (error: any) {
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidAccount");
      }
    });

    it("Should reject SPL deposit from token account not owned by signer (InvalidOwner)", async () => {
      // Create two users: victim owns the token account, attacker signs the tx.
      // This tests deposit_spl_to_vault line: parsed_user.owner == ctx.accounts.user.key()
      const victim = Keypair.generate();
      await provider.connection.requestAirdrop(victim.publicKey, 2 * anchor.web3.LAMPORTS_PER_SOL);

      const victimTokenAccount = await mockUSDT.createTokenAccount(victim.publicKey);
      const gatewayTokenAccount = (
        await spl.getOrCreateAssociatedTokenAccount(
          provider.connection as any,
          admin,
          mockUSDT.mint.publicKey,
          vaultPda,
          true
        )
      ).address;
      await mockUSDT.mintTo(victimTokenAccount, 1000);

      const tokenAmount = new anchor.BN(1000 * 10 ** mockUSDT.config.decimals);
      const usdtTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: mockUSDT.mint.publicKey,
        amount: tokenAmount,
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("invalid_owner_test"),
      };

      try {
        // user1 signs but victimTokenAccount is owned by victim — must be rejected
        await program.methods
          .sendUniversalTx(req, withInboundFee(0))
          .accountsPartial({
            config: configPda,
            vault: vaultPda,
            feeVault: feeVaultPda,
            userTokenAccount: victimTokenAccount,
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
        expect.fail("Should have rejected: token account owned by different wallet");
      } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidOwner");
      }
    });

    it("Should reject FUNDS SPL when native SOL is provided", async () => {
      const userTokenAccount = await mockUSDT.createTokenAccount(
        user1.publicKey
      );
      const gatewayTokenAccount = await mockUSDT.createTokenAccount(
        vaultPda,
        true
      );

      await mockUSDT.mintTo(userTokenAccount, 1000);
      const tokenAmount = new anchor.BN(1000 * 10 ** mockUSDT.config.decimals);
      const usdtTokenRateLimitPda = getTokenRateLimitPda(
        mockUSDT.mint.publicKey
      );
      const nativeAmount = calculateSolAmount(1.5, solPrice);

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: mockUSDT.mint.publicKey,
        amount: tokenAmount,
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("spl_native_invalid"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(nativeAmount))
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
        expect.fail("Should reject FUNDS SPL when native SOL is attached");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidAmount");
      }
    });
  });

  describe("FUNDS_AND_PAYLOAD Route - Native SOL with Batching", () => {
    it("Should batch gas + funds for native SOL", async () => {
      // Case 2.2: Batching with native SOL
      // Split: gasAmount = native_amount - req.amount
      // Gas must be >= $1 USD (min cap), funds can be any amount
      // Strategy: Use larger gas amount ($3) and small funds amount to ensure gas >= $1 after split
      const gasAmountLamports = calculateSolAmount(3.0, solPrice); // $3.00 for gas (well above $1 min cap)
      const fundsAmountLamports = calculateSolAmount(0.1, solPrice); // $0.10 for funds (very small)
      const totalAmount = gasAmountLamports + fundsAmountLamports; // Total = gas + funds

      // Verify: after split, gas_amount = totalAmount - fundsAmount = gasAmountLamports (should be >= $1)
      const expectedGasAfterSplit = totalAmount - fundsAmountLamports;
      const expectedGasUsd =
        (expectedGasAfterSplit / LAMPORTS_PER_SOL) * solPrice;
      if (expectedGasUsd < 1.0) {
        throw new Error(
          `Expected gas after split ${expectedGasUsd.toFixed(
            4
          )} USD is below minimum $1 USD cap. Gas: ${gasAmountLamports}, Funds: ${fundsAmountLamports}, Total: ${totalAmount}`
        );
      }

      const initialVaultBalance = await provider.connection.getBalance(
        vaultPda
      );
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 1)), // Non-zero allowed for FUNDS_AND_PAYLOAD
        token: PublicKey.default,
        amount: new anchor.BN(fundsAmountLamports),
        payload: serializePayload(createPayload(1)), // Non-empty payload required
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("batched_sig"),
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(totalAmount))
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

      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      // Bridge vault receives gas + funds; fee goes to fee_vault
      expect(finalVaultBalance - initialVaultBalance).to.equal(totalAmount);
    });

    it("Should reject FUNDS_AND_PAYLOAD native when native amount is insufficient", async () => {
      const fundsAmount = calculateSolAmount(0.75, solPrice);
      const insufficientNative = fundsAmount - 50_000; // native < funds
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 1)),
        token: PublicKey.default,
        amount: new anchor.BN(fundsAmount),
        payload: serializePayload(createPayload(1)),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("insufficient_native_sig"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(insufficientNative))
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
        expect.fail("Should reject when native gas is below bridge amount");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidAmount");
      }
    });
  });

  describe("FUNDS_AND_PAYLOAD Route - SPL Token", () => {
    it("Should bridge SPL funds with payload without batching (Case 2.1)", async () => {
      // Case 2.1: No Batching (native_amount == 0): user already has UEA with gas on Push Chain
      // User can directly move req.amount for req.token to Push Chain (SPL token only for Case 2.1)
      // Use USDC to avoid rate limit conflicts with USDT used in previous tests
      const userTokenAccount = await mockUSDC.createTokenAccount(
        user1.publicKey
      );
      const gatewayTokenAccount = (
        await spl.getOrCreateAssociatedTokenAccount(
          provider.connection as any,
          admin,
          mockUSDC.mint.publicKey,
          vaultPda,
          true
        )
      ).address;

      // Mint tokens using mock token's mintTo method
      await mockUSDC.mintTo(userTokenAccount, 500);
      const tokenAmount = new anchor.BN(500 * 10 ** mockUSDC.config.decimals);

      const initialGatewayBalance = await mockUSDC.getBalance(gatewayTokenAccount);
      const initialVaultBalance = await provider.connection.getBalance(vaultPda);
      const initialFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      const usdcTokenRateLimitPda = getTokenRateLimitPda(
        mockUSDC.mint.publicKey
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 1)), // Non-zero allowed for FUNDS_AND_PAYLOAD
        token: mockUSDC.mint.publicKey,
        amount: tokenAmount,
        payload: serializePayload(createPayload(1)), // Must have payload for FUNDS_AND_PAYLOAD
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("spl_no_batch_sig"),
      };

      // With protocol fee enabled, this route sends only fee as native amount.
      await program.methods
        .sendUniversalTx(req, withInboundFee(0))
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: userTokenAccount,
          gatewayTokenAccount: gatewayTokenAccount,
          user: user1.publicKey,
          priceUpdate: mockPriceFeed,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: usdcTokenRateLimitPda,
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([user1])
        .rpc();

      // SPL tokens go to gateway token account; fee goes to fee_vault; bridge vault unchanged
      const finalGatewayBalance = await mockUSDC.getBalance(gatewayTokenAccount);
      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      const finalFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      const balanceIncrease =
        (finalGatewayBalance - initialGatewayBalance) * 10 ** mockUSDC.config.decimals;
      expect(balanceIncrease).to.equal(tokenAmount.toNumber());
      expect(finalVaultBalance - initialVaultBalance).to.equal(0);
      expect(finalFeeVaultBalance - initialFeeVaultBalance).to.equal(DEFAULT_INBOUND_FEE_LAMPORTS);
    });

    it("Should batch native gas + SPL funds (Case 2.3)", async () => {
      // Setup SPL token accounts using mock token's methods
      const userTokenAccount = await mockUSDC.createTokenAccount(
        user1.publicKey
      );
      const gatewayTokenAccount = (
        await spl.getOrCreateAssociatedTokenAccount(
          provider.connection as any,
          admin,
          mockUSDC.mint.publicKey,
          vaultPda,
          true
        )
      ).address;

      // Mint tokens using mock token's mintTo method
      await mockUSDC.mintTo(userTokenAccount, 500);
      const tokenAmount = new anchor.BN(500 * 10 ** mockUSDC.config.decimals);

      // Case 2.3: Batching with SPL + native gas
      // Gas amount must be >= $1 USD (min cap) and <= $10 USD (max cap)
      // native_amount is sent as gas, req.amount is SPL bridge amount
      const gasAmount = calculateSolAmount(2.5, solPrice); // $2.50 for gas (within $1-$10 cap)

      // Verify gas amount is >= $1 USD
      const gasUsd = (gasAmount / LAMPORTS_PER_SOL) * solPrice;
      if (gasUsd < 1.0) {
        throw new Error(`Gas amount ${gasUsd} USD is below minimum $1 USD cap`);
      }
      const initialVaultBalance = await provider.connection.getBalance(
        vaultPda
      );
      const initialGatewayBalance = await mockUSDC.getBalance(
        gatewayTokenAccount
      );
      const usdcTokenRateLimitPda = getTokenRateLimitPda(
        mockUSDC.mint.publicKey
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 1)),
        token: mockUSDC.mint.publicKey,
        amount: tokenAmount,
        payload: serializePayload(createPayload(1)), // Non-empty payload required
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("spl_batched_sig"),
      };

      const initialFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);

      await program.methods
        .sendUniversalTx(req, withInboundFee(gasAmount))
        .accountsPartial({
          config: configPda,
          vault: vaultPda,
          feeVault: feeVaultPda,
          userTokenAccount: userTokenAccount,
          gatewayTokenAccount: gatewayTokenAccount,
          user: user1.publicKey,
          priceUpdate: mockPriceFeed,
          rateLimitConfig: rateLimitConfigPda,
          tokenRateLimit: usdcTokenRateLimitPda,
          tokenProgram: spl.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([user1])
        .rpc();

      const finalVaultBalance = await provider.connection.getBalance(vaultPda);
      const finalFeeVaultBalance = await provider.connection.getBalance(feeVaultPda);
      // Bridge vault receives only gas (no fee); fee goes to fee_vault
      expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
      expect(finalFeeVaultBalance - initialFeeVaultBalance).to.equal(DEFAULT_INBOUND_FEE_LAMPORTS);

      const finalGatewayBalance = await mockUSDC.getBalance(
        gatewayTokenAccount
      );
      const balanceIncrease =
        (finalGatewayBalance - initialGatewayBalance) *
        10 ** mockUSDC.config.decimals;
      expect(balanceIncrease).to.equal(tokenAmount.toNumber());
    });

    it("Should reject FUNDS_AND_PAYLOAD SPL when token rate limit PDA mismatches", async () => {
      const userTokenAccount = await mockUSDC.createTokenAccount(
        user1.publicKey
      );
      const gatewayTokenAccount = await mockUSDC.createTokenAccount(
        vaultPda,
        true
      );

      await mockUSDC.mintTo(userTokenAccount, 500);
      const tokenAmount = new anchor.BN(500 * 10 ** mockUSDC.config.decimals);
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      ); // intentionally wrong

      const req = {
        recipient: Array.from(Buffer.alloc(20, 1)),
        token: mockUSDC.mint.publicKey,
        amount: tokenAmount,
        payload: serializePayload(createPayload(1)),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("spl_bad_rate_limit"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(0))
          .accountsPartial({
            config: configPda,
            vault: vaultPda,
            feeVault: feeVaultPda,
            userTokenAccount: userTokenAccount,
            gatewayTokenAccount: gatewayTokenAccount,
            user: user1.publicKey,
            priceUpdate: mockPriceFeed,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: nativeSolTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([user1])
          .rpc();
        expect.fail(
          "Should reject FUNDS_AND_PAYLOAD SPL when token rate limit PDA is invalid"
        );
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidToken");
      }
    });
  });

  describe("Error Cases", () => {
    it("Should reject when paused", async () => {
      await program.methods
        .pause()
        .accountsPartial({ pauser: pauser.publicKey, config: configPda })
        .signers([pauser])
        .rpc();

      const gasAmount = calculateSolAmount(2.5, solPrice);
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("sig"),
      };

      try {
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
        expect.fail("Should reject when paused");
      } catch (error: any) {
        expect(error).to.exist;
        expect(error.error?.errorCode?.code || error.code).to.equal("Paused");
      }

      await program.methods
        .unpause()
        .accountsPartial({ operator: operator.publicKey, config: configPda })
        .signers([operator])
        .rpc();
    });

    it("Should reject GAS route amounts outside USD cap bounds", async () => {
      // Snapshot current caps — other test files may leave config at different values.
      // We pin to known bounds, test, then restore the exact prior state in `finally`.
      const configBefore = await program.account.config.fetch(configPda);
      const prevMin = configBefore.minCapUniversalTxUsd;
      const prevMax = configBefore.maxCapUniversalTxUsd;

      await program.methods
        .setCapsUsd(new anchor.BN(100_000_000), new anchor.BN(1_000_000_000)) // $1 min / $10 max
        .accountsPartial({ admin: admin.publicKey, config: configPda })
        .signers([admin])
        .rpc();

      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
      const cases = [
        { label: "BelowMinCap", usd: 0.5,  expectedError: "BelowMinCap" },  // $0.50 < $1 min
        { label: "AboveMaxCap", usd: 15.0, expectedError: "AboveMaxCap" },  // $15 > $10 max
      ];

      try {
        for (const { label, usd, expectedError } of cases) {
          const gasAmount = calculateSolAmount(usd, solPrice);
          const req = {
            recipient: Array.from(Buffer.alloc(20, 0)),
            token: PublicKey.default,
            amount: new anchor.BN(0),
            payload: Buffer.from([]),
            revertRecipient: user1.publicKey,
            signatureData: Buffer.from(label),
          };
          try {
            await program.methods
              .sendUniversalTx(req, withInboundFee(gasAmount))
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
            expect.fail(`${label}: Should have rejected with ${expectedError}`);
          } catch (error: any) {
            const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
            expect(errorCode).to.equal(expectedError, `${label}: wrong error code`);
          }
        }
      } finally {
        await program.methods
          .setCapsUsd(prevMin, prevMax)
          .accountsPartial({ admin: admin.publicKey, config: configPda })
          .signers([admin])
          .rpc();
      }
    });

    it("Should reject invalid parameter combinations (no gas or funds)", async () => {
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("sig"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(0))
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
        expect.fail("Should reject parameter set without gas or funds");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidInput");
      }
    });
  });

  describe("Protocol Fee", () => {
    it("Should accumulate fee_vault balance across multiple txs", async () => {
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
      const gasAmount = calculateSolAmount(2.5, solPrice);
      const feeVaultBefore = await provider.connection.getBalance(feeVaultPda);

      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("acc_test"),
      };

      const accounts = {
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
      };

      await program.methods
        .sendUniversalTx(req, withInboundFee(gasAmount))
        .accountsPartial(accounts)
        .signers([user1])
        .rpc();
      await program.methods
        .sendUniversalTx(req, withInboundFee(gasAmount))
        .accountsPartial(accounts)
        .signers([user1])
        .rpc();

      const feeVaultAfter = await provider.connection.getBalance(feeVaultPda);
      expect(feeVaultAfter - feeVaultBefore).to.equal(2 * DEFAULT_INBOUND_FEE_LAMPORTS);
    });

    it("Should reject unauthorized setInboundFee", async () => {
      try {
        await program.methods
          .setInboundFee(new anchor.BN(123_456))
          .accountsPartial({
            config: configPda,
            feeVault: feeVaultPda,
            admin: user1.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([user1])
          .rpc();
        expect.fail("Unauthorized setInboundFee should have failed");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("Unauthorized");
      }
    });

    it("Should accept zero and exact max protocol fee", async () => {
      await setInboundFee(0);
      let feeVault = await program.account.feeVault.fetch(feeVaultPda);
      expect(feeVault.inboundFeeLamports.toNumber()).to.equal(0);

      await setInboundFee(MAX_INBOUND_FEE_LAMPORTS);
      feeVault = await program.account.feeVault.fetch(feeVaultPda);
      expect(feeVault.inboundFeeLamports.toNumber()).to.equal(
        MAX_INBOUND_FEE_LAMPORTS
      );

      await setInboundFee(DEFAULT_INBOUND_FEE_LAMPORTS);
    });

    it("Should reject inbound fee above hard max", async () => {
      try {
        await setInboundFee(MAX_INBOUND_FEE_LAMPORTS + 1);
        expect.fail("setInboundFee above max should have failed");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidInput");
      }
    });

    it("Should reject when native amount is below inbound fee", async () => {
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("insufficient_inbound_fee"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, new anchor.BN(DEFAULT_INBOUND_FEE_LAMPORTS - 1))
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
        expect.fail("Should reject when native amount is below protocol fee");
      } catch (error: any) {
        expect(error).to.exist;
        const errorCode =
          error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InsufficientInboundFee");
      }
    });

    it("Should reject GAS route when oracle confidence exceeds threshold (InvalidPrice)", async () => {
      // Set a very tight confidence threshold (1 lamport) so the real mock feed's
      // confidence value exceeds it, triggering InvalidPrice on the next deposit.
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
      const configBefore = await program.account.config.fetch(configPda);
      const prevThreshold = configBefore.pythConfidenceThreshold;
      const restoreThreshold = prevThreshold.gt(new anchor.BN(0))
        ? prevThreshold
        : new anchor.BN(1_000_000);

      // Set a very tight threshold (1 raw unit) so the mock feed's confidence exceeds it.
      await program.methods
        .setPythConfidenceThreshold(new anchor.BN(1))
        .accountsPartial({ admin: admin.publicKey, config: configPda })
        .signers([admin])
        .rpc();

      const gasAmount = calculateSolAmount(2.5, solPrice);
      const req = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertRecipient: user1.publicKey,
        signatureData: Buffer.from("confidence_threshold_test"),
      };

      try {
        await program.methods
          .sendUniversalTx(req, withInboundFee(gasAmount))
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
        expect.fail("Should have rejected with InvalidPrice");
      } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        expect(errorCode).to.equal("InvalidPrice");
      } finally {
        // Setter rejects 0; fallback keeps restore valid on legacy-zero configs.
        await program.methods
          .setPythConfidenceThreshold(restoreThreshold)
          .accountsPartial({ admin: admin.publicKey, config: configPda })
          .signers([admin])
          .rpc();
      }
    });

    it("Should support fee-off mode for legacy SPL FUNDS call shape", async () => {
      const usdtTokenRateLimitPda = getTokenRateLimitPda(
        mockUSDT.mint.publicKey
      );

      await setInboundFee(0);
      try {
        const userTokenAccount = await mockUSDT.createTokenAccount(
          user1.publicKey
        );
        const gatewayTokenAccount = (
          await spl.getOrCreateAssociatedTokenAccount(
            provider.connection as any,
            admin,
            mockUSDT.mint.publicKey,
            vaultPda,
            true
          )
        ).address;
        await mockUSDT.mintTo(userTokenAccount, 500);
        const tokenAmount = new anchor.BN(200 * 10 ** mockUSDT.config.decimals);
        const initialGatewayBalance = await mockUSDT.getBalance(
          gatewayTokenAccount
        );

        const req = {
          recipient: Array.from(Buffer.alloc(20, 2)),
          token: mockUSDT.mint.publicKey,
          amount: tokenAmount,
          payload: Buffer.from([]),
          revertRecipient: user1.publicKey,
          signatureData: Buffer.from("fee_off_legacy_spl_funds"),
        };

        await program.methods
          .sendUniversalTx(req, new anchor.BN(0))
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

        const finalGatewayBalance = await mockUSDT.getBalance(
          gatewayTokenAccount
        );
        const balanceIncrease =
          (finalGatewayBalance - initialGatewayBalance) *
          10 ** mockUSDT.config.decimals;
        expect(balanceIncrease).to.equal(tokenAmount.toNumber());
      } finally {
        await setInboundFee(DEFAULT_INBOUND_FEE_LAMPORTS);
      }
    });
  });

  after(async () => {
    // Ensure contract is unpaused after all tests
    try {
      const config = await program.account.config.fetch(configPda);
      if (config.paused) {
        await program.methods
          .unpause()
          .accountsPartial({ operator: operator.publicKey, config: configPda })
          .signers([operator])
          .rpc();
      }
    } catch (error) {
      // Ignore errors
    }

    // Disable rate limits to prevent interference with other tests
    try {
      await setInboundFee(0);

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
      const nativeSolTokenRateLimitPda = getTokenRateLimitPda(
        PublicKey.default
      );
      await program.methods
        .setTokenRateLimit(veryLargeThreshold, false, false)
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
      // Ignore errors
    }
  });
});
