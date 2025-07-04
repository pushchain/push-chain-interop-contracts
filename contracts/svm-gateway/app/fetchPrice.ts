// app/real-complete-flow.ts
import * as anchor from "@coral-xyz/anchor";
import {
    Connection,
    PublicKey,
    Keypair,
} from "@solana/web3.js";
import fs from "fs";
import { Program, AnchorProvider } from "@coral-xyz/anchor";
import type { Pushsolanalocker } from "../target/types/pushsolanalocker";

// Constants
const PROGRAM_ID = new PublicKey("3zrWaMknHTRQpZSxY4BvQxw9TStSXiHcmcp3NMPTFkke");
const PRICE_ACCOUNT = new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE");

// Create connection
const connection = new Connection("https://api.devnet.solana.com", "confirmed");


// Create provider
const provider = new AnchorProvider(
    connection,
    { publicKey: new PublicKey("EfQYRThwBu4MsU7Lf3D2e68tCtdwfYj6f66ot1e2HNrq") } as any,
    { commitment: "confirmed" }
);

// Load IDL
const idl = JSON.parse(fs.readFileSync("target/idl/pushsolanalocker.json", "utf8"));

// Create program instance
const program = new Program(idl as Pushsolanalocker, provider);

async function run() {
    console.log("🚀 Testing getSolPrice view-only function\n");

    try {
        // Call getSolPrice using the view method
        const priceData = await program.methods
            .getSolPrice()
            .accounts({
                priceUpdate: PRICE_ACCOUNT,
            })
            .view();

        console.log("Price data:", priceData);

        if (!priceData || !priceData.price) {
            throw new Error("Invalid price data returned");
        }

        const usdPrice = priceData.exponent >= 0
            ? priceData.price.toNumber() * Math.pow(10, priceData.exponent)
            : priceData.price.toNumber() / Math.pow(10, Math.abs(priceData.exponent));

        console.log(`✅ SOL Price: ${usdPrice.toFixed(2)} USD`);
        console.log(`⏰ Published: ${new Date(priceData.publishTime.toNumber() * 1000).toISOString()}\n`);
    } catch (error) {
        console.error(`❌ getSolPrice failed: ${error.message || error}`);
        if (error.stack) console.error("Stack trace:", error.stack);
        process.exit(1);
    }
}

run().catch((e) => {
    console.error("❌ Script crashed:", e);
    process.exit(1);
});