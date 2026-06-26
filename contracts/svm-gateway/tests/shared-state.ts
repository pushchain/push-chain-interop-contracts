import * as anchor from "@coral-xyz/anchor";
import { PublicKey, Keypair } from "@solana/web3.js";

/**
 * Shared state across all test files
 * This ensures all tests use the same admin, tokens, and PDAs
 */

// Keypairs (initialized once in setup.test.ts)
export let admin: Keypair | null = null;
export let operator: Keypair | null = null;
export let pauser: Keypair | null = null;
export let counterAuthority: Keypair | null = null;
export let user1: Keypair | null = null;
export let user2: Keypair | null = null;

// Mock tokens (created once in setup.test.ts)
export let mockUSDT: any = null;
export let mockUSDC: any = null;

// Pyth
export let mockPythOracle: any = null;
export let mockPriceFeed: PublicKey | null = null;
let dummyPythFeed: PublicKey | null = null; // Cached dummy feed

// Setter functions
export function setAdmin(keypair: Keypair) {
    admin = keypair;
}

export function setOperator(keypair: Keypair) {
    operator = keypair;
}

export function setPauser(keypair: Keypair) {
    pauser = keypair;
}

export function setMockUSDT(token: any) {
    mockUSDT = token;
}

export function setMockUSDC(token: any) {
    mockUSDC = token;
}

export function setMockPythOracle(oracle: any) {
    mockPythOracle = oracle;
}

export function setMockPriceFeed(feed: PublicKey) {
    mockPriceFeed = feed;
}

export function setCounterAuthority(keypair: Keypair) {
    counterAuthority = keypair;
}

export function setUser1(keypair: Keypair) {
    user1 = keypair;
}

export function setUser2(keypair: Keypair) {
    user2 = keypair;
}

// Getter functions (with validation)
export function getAdmin(): Keypair {
    if (!admin) throw new Error("Admin not initialized - did setup.test.ts run?");
    return admin;
}

export function getOperator(): Keypair {
    if (!operator) throw new Error("Operator not initialized - did setup.test.ts run?");
    return operator;
}

export function getPauser(): Keypair {
    if (!pauser) throw new Error("Pauser not initialized - did setup.test.ts run?");
    return pauser;
}

export function getMockUSDT(): any {
    if (!mockUSDT) throw new Error("Mock USDT not initialized - did setup.test.ts run?");
    return mockUSDT;
}

export function getMockUSDC(): any {
    if (!mockUSDC) throw new Error("Mock USDC not initialized - did setup.test.ts run?");
    return mockUSDC;
}

export function getMockPriceFeed(): PublicKey {
    // Return cached dummy if not set - Pyth is skipped for now
    if (!mockPriceFeed) {
        if (!dummyPythFeed) {
            // Generate and cache a dummy keypair for all tests to use
            dummyPythFeed = Keypair.generate().publicKey;
        }
        return dummyPythFeed;
    }
    return mockPriceFeed;
}

export function getCounterAuthority(): Keypair {
    if (!counterAuthority) {
        // Generate and cache if not set
        counterAuthority = Keypair.generate();
    }
    return counterAuthority;
}

export function getUser1(): Keypair {
    if (!user1) throw new Error("User1 not initialized - did setup.test.ts run?");
    return user1;
}

export function getUser2(): Keypair {
    if (!user2) throw new Error("User2 not initialized - did setup.test.ts run?");
    return user2;
}
