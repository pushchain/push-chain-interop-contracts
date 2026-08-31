const anchor = require("@coral-xyz/anchor");
const { Connection, PublicKey } = require("@solana/web3.js");
const fs = require("fs");

async function decodeTx(sig, label) {
    try {
        const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
        const connection = new Connection("https://api.devnet.solana.com", { commitment: "confirmed" });
        const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
        const coder = new anchor.BorshEventCoder(idl);

        const tx = await connection.getTransaction(sig, { commitment: "confirmed", maxSupportedTransactionVersion: 0 });
        console.log("tx.version", tx.version);
        if (!tx) {
            console.log(`${label}: Transaction not found. Check if signature is correct and network matches.`);
            return;
        }
        if (!tx.meta || !tx.meta.logMessages) {
            console.log(`${label}: No logs found in transaction`);
            return;
        }
        if (tx.meta.err) {
            console.log(`${label}: Transaction failed with error:`, tx.meta.err);
            return;
        }
        // Events land in inner instructions (emit_cpi self-CPI), not in program logs.
        // Layout per inner ix: [EVENT_IX_TAG_LE: 8 bytes] || [event_disc: 8 bytes] || [borsh(event)].
        const staticKeys = (tx.transaction.message.staticAccountKeys ?? tx.transaction.message.accountKeys ?? []).map(k => k.toString());
        const loadedWritable = (tx.meta?.loadedAddresses?.writable ?? []).map(k => k.toString());
        const loadedReadonly = (tx.meta?.loadedAddresses?.readonly ?? []).map(k => k.toString());
        const allKeys = [...staticKeys, ...loadedWritable, ...loadedReadonly];
        const programIdx = allKeys.findIndex(k => k === PROGRAM_ID.toBase58());
        const dataBufs = [];
        if (programIdx !== -1) {
            for (const inner of tx.meta?.innerInstructions ?? []) {
                for (const ix of inner.instructions) {
                    if (ix.programIdIndex !== programIdx) continue;
                    const raw = Buffer.from(anchor.utils.bytes.bs58.decode(ix.data));
                    if (raw.length < 16) continue;
                    dataBufs.push(raw.slice(8)); // strip EVENT_IX_TAG_LE
                }
            }
        }
        if (dataBufs.length === 0) {
            console.log(`${label}: No emit_cpi events in tx`);
            return;
        }

        console.log(`${label}: Found ${dataBufs.length} event(s)`);
        const UNIVERSAL_TX_DISCRIMINATOR = Buffer.from([0x6c, 0x9a, 0xd8, 0x29, 0xb5, 0xea, 0x1d, 0x7c]);
        dataBufs.forEach((buf, idx) => {
            const disc = buf.slice(0, 8);
            const isUniversalTx = disc.equals(UNIVERSAL_TX_DISCRIMINATOR);
            console.log(`  [${idx}] discriminator=${disc.toString('hex')} data_len=${buf.length - 8} ${isUniversalTx ? '(UniversalTx)' : ''}`);
            if (isUniversalTx) {
                const eventData = buf.slice(8);
                console.log(`    Raw event data (FULL, ${eventData.length} bytes): ${eventData.toString('hex')}`);
            }
        });

        function readU64LE(buf, off) {
            if (off + 8 > buf.length) throw new Error(`Buffer overflow: trying to read u64 at offset ${off}, buffer length ${buf.length}`);
            return Number(buf.readBigUInt64LE(off));
        }
        function readI64LE(buf, off) {
            if (off + 8 > buf.length) throw new Error(`Buffer overflow: trying to read i64 at offset ${off}, buffer length ${buf.length}`);
            return Number(buf.readBigInt64LE(off));
        }
        function readVecU8(buf, off) {
            if (off + 4 > buf.length) throw new Error(`Buffer overflow: trying to read vec length at offset ${off}, buffer length ${buf.length}`);
            const len = buf.readUInt32LE(off);
            const start = off + 4;
            const end = start + len;
            if (end > buf.length) throw new Error(`Buffer overflow: trying to read vec of length ${len} at offset ${start}, buffer length ${buf.length}`);
            return { bytes: buf.slice(start, end), next: end };
        }
        function decodeVerificationType(buf, off) {
            if (off >= buf.length) throw new Error(`Buffer overflow: trying to read u8 at offset ${off}, buffer length ${buf.length}`);
            const d = buf.readUInt8(off);
            if (d === 0) return { value: "SignedVerification", next: off + 1 };
            if (d === 1) return { value: "UniversalTxVerification", next: off + 1 };
            return { value: "Unknown", next: off + 1 };
        }
        function decodeUniversalPayload(buf) {
            try {
                let off = 0;
                if (buf.length < 20) throw new Error(`Buffer too small for 'to' field: ${buf.length} bytes`);
                const to = buf.slice(off, off + 20);
                off += 20;

                const value = readU64LE(buf, off);
                off += 8;

                const dataRes = readVecU8(buf, off);
                const data = dataRes.bytes;
                off = dataRes.next;

                const gasLimit = readU64LE(buf, off);
                off += 8;

                const maxFeePerGas = readU64LE(buf, off);
                off += 8;

                const maxPriorityFeePerGas = readU64LE(buf, off);
                off += 8;

                const nonce = readU64LE(buf, off);
                off += 8;

                const deadline = readI64LE(buf, off);
                off += 8;

                const vTypeRes = decodeVerificationType(buf, off);
                const vType = vTypeRes.value;
                off = vTypeRes.next;

                return {
                    to: "0x" + to.toString("hex"),
                    value,
                    data: "0x" + data.toString("hex"),
                    gasLimit,
                    maxFeePerGas,
                    maxPriorityFeePerGas,
                    nonce,
                    deadline,
                    vType
                };
            } catch (err) {
                console.error(`Error decoding payload (buffer length: ${buf.length}):`, err.message);
                throw err;
            }
        }

        const decoded = [];
        for (const buf of dataBufs) {
            try {
                const ev = coder.decode(buf.toString("base64"));
                if (ev) decoded.push(ev);
            } catch { /* skip non-event bytes */ }
        }

        // Find ALL UniversalTx events (there might be multiple)
        const uniEvents = decoded.filter(e => e && e.name === "UniversalTx");
        if (uniEvents.length === 0) {
            console.log(`${label}: UniversalTx event not found. Events found:`, decoded.map(d => d ? d.name : 'null'));
            return;
        }

        console.log(`${label}: Found ${uniEvents.length} UniversalTx event(s)`);

        // Helper function to decode tx_type
        function decodeTxType(e) {
            const txType = e.tx_type !== undefined ? e.tx_type : e.txType;
            if (txType === undefined) return 'Unknown';
            if (typeof txType === 'object' && txType !== null) {
                const keys = Object.keys(txType);
                if (keys.length > 0) {
                    return keys[0].charAt(0).toUpperCase() + keys[0].slice(1);
                }
            } else if (typeof txType === 'number') {
                const txTypeNames = ['Gas', 'GasAndPayload', 'Funds', 'FundsAndPayload'];
                return txTypeNames[txType] || `Unknown(${txType})`;
            }
            return String(txType);
        }

        // Show ALL events first
        console.log(`\n=== All ${uniEvents.length} UniversalTx Event(s) ===`);
        uniEvents.forEach((ev, idx) => {
            const e = ev.data;
            const payloadBytes = Array.isArray(e.payload) ? Buffer.from(e.payload) : Buffer.isBuffer(e.payload) ? e.payload : Buffer.from(e.payload || []);
            const txTypeName = decodeTxType(e);
            console.log(`\nEvent ${idx + 1}:`);
            console.log(`  - tx_type: ${txTypeName}`);
            console.log(`  - sender: ${e.sender}`);
            console.log(`  - token: ${e.token}`);
            console.log(`  - amount: ${e.amount}`);
            console.log(`  - payload length: ${payloadBytes.length} bytes`);
        });

        // Find the event with a non-empty payload for detailed decoding
        let uni = uniEvents.find(e => e.data.payload && (Array.isArray(e.data.payload) ? e.data.payload.length > 0 : Buffer.isBuffer(e.data.payload) ? e.data.payload.length > 0 : true));
        if (!uni) {
            // If none have payload, use the largest one (likely has the payload)
            uni = uniEvents.reduce((prev, curr) => {
                const prevSize = prev.data.payload ? (Array.isArray(prev.data.payload) ? prev.data.payload.length : Buffer.isBuffer(prev.data.payload) ? prev.data.payload.length : 0) : 0;
                const currSize = curr.data.payload ? (Array.isArray(curr.data.payload) ? curr.data.payload.length : Buffer.isBuffer(curr.data.payload) ? curr.data.payload.length : 0) : 0;
                return currSize > prevSize ? curr : prev;
            });
        }

        console.log(`\n=== Detailed Decode of Event with Payload ===`);
        const e = uni.data;
        console.log(`${label}: Found UniversalTx event`);
        console.log(`  - sender: ${e.sender}`);
        console.log(`  - recipient: 0x${Buffer.from(e.recipient).toString('hex')}`);
        console.log(`  - token: ${e.token}`);
        console.log(`  - amount: ${e.amount}`);

        // Show revert_recipient if present
        if (e.revert_recipient || e.revertRecipient) {
            console.log(`  - revert_recipient: ${e.revert_recipient || e.revertRecipient}`);
        }

        // Show signature_data if present
        if (e.signature_data || e.signatureData) {
            const sigData = e.signature_data || e.signatureData;
            const sigBuf = Array.isArray(sigData) ? Buffer.from(sigData) : Buffer.isBuffer(sigData) ? sigData : Buffer.from(sigData || []);
            console.log(`  - signature_data length: ${sigBuf.length} bytes`);
            if (sigBuf.length > 0) {
                console.log(`  - signature_data (hex): ${sigBuf.toString('hex')}`);
            }
        }

        // Try both snake_case and camelCase for tx_type
        const txType = e.tx_type !== undefined ? e.tx_type : e.txType;
        const txTypeName = decodeTxType(e);
            console.log(`  - tx_type: ${txTypeName}`);

        // Handle payload - it might be an array, buffer, or already deserialized
        let payloadBytes;
        if (Array.isArray(e.payload)) {
            payloadBytes = Buffer.from(e.payload);
        } else if (Buffer.isBuffer(e.payload)) {
            payloadBytes = e.payload;
        } else if (e.payload && typeof e.payload === 'object' && e.payload.data) {
            // Anchor might have already deserialized it
            payloadBytes = Buffer.from(e.payload.data);
        } else {
            payloadBytes = Buffer.from(e.payload || []);
        }

        console.log(`  - payload length: ${payloadBytes.length} bytes`);
        console.log(`  - payload (hex): ${payloadBytes.length > 0 ? payloadBytes.toString('hex').substring(0, 100) + '...' : 'empty'}`);

        if (payloadBytes.length === 0) {
            console.log(`${label}: No payload in event (empty payload)`);
            console.log(`  This might be a GAS-only route (TxType::Gas) or payload was not included.`);
            return;
        }

        // Check if payload is JSON (starts with '{') or Borsh
        const isJson = payloadBytes[0] === 0x7b; // '{' in ASCII
        if (isJson) {
            console.log(`  - Payload appears to be JSON (not Borsh). This is incorrect - should use Borsh serialization.`);
            try {
                const jsonPayload = JSON.parse(payloadBytes.toString('utf8'));
                console.log(`\n${label}: (JSON Payload - INCORRECT FORMAT):`);
                console.log(JSON.stringify({ payload: jsonPayload }, null, 2));
                console.log(`\n⚠️  WARNING: Payload is JSON but should be Borsh-serialized UniversalPayload!`);
                return;
            } catch (err) {
                console.log(`  - Failed to parse as JSON: ${err.message}`);
            }
        }

        console.log(`  - Attempting to decode payload as Borsh (${payloadBytes.length} bytes)...`);
        const payload = decodeUniversalPayload(payloadBytes);

        // Build complete event data for comparison
        const eventData = {
            sender: e.sender.toString(),
            recipient: "0x" + Buffer.from(e.recipient).toString('hex'),
            token: e.token.toString(),
            amount: e.amount.toString(),
            tx_type: txTypeName,
            payload: payload,
            revert_recipient: (e.revert_recipient || e.revertRecipient) ? (e.revert_recipient || e.revertRecipient).toString() : null,
            signature_data: (() => {
                const sigData = e.signature_data || e.signatureData;
                const sigBuf = Array.isArray(sigData) ? Buffer.from(sigData) : Buffer.isBuffer(sigData) ? sigData : Buffer.from(sigData || []);
                return sigBuf.length > 0 ? "0x" + sigBuf.toString('hex') : null;
            })()
        };

        console.log(`\n${label}:`);
        console.log(JSON.stringify(eventData, null, 2));
    } catch (err) {
        console.error(`${label} Error:`, err?.message || String(err));
    }
}

const [, , ...sigs] = process.argv;
if (sigs.length === 0) {
    console.log("Usage: node app/decode-tx.js <transaction_signature> [signature2] ...");
    console.log("\nExample:");
    console.log("  node app/decode-tx.js xuV3B2KRBdUSPrP76uLp7dDPXjf4seiyW9Dqq5WARGghJUhvVirJqyYeUmJz8PaAFUhjaJhcp6wzzoNzCTLNnHW");
    console.log("\nThis script decodes UniversalTx events from Solana transactions.");
    process.exit(1);
} else {
    (async () => {
        for (const sig of sigs) {
            await decodeTx(sig, sig);
        }
    })();
}

