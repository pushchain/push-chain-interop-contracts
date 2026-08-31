/**
 * decode-outbound-tx.js
 *
 * Decodes any Universal Gateway transaction (FinalizeUniversalTx, SendUniversalTx, RevertUniversalTx).
 * Shows full transaction metadata, balance changes, and all emitted events with decoded payloads.
 *
 * Usage: node app/decode-outbound-tx.js <signature> [signature2] ...
 *        yarn decode:outbound <signature>
 */

const anchor = require("@coral-xyz/anchor");
const { Connection, PublicKey, LAMPORTS_PER_SOL } = require("@solana/web3.js");
const fs = require("fs");

const PROGRAM_ID = "CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS";
const SYSTEM_PROGRAM = "11111111111111111111111111111111";

// ─── Borsh helpers ───────────────────────────────────────────────────────────

function readU64LE(buf, off) {
    return Number(buf.readBigUInt64LE(off));
}
function readI64LE(buf, off) {
    return Number(buf.readBigInt64LE(off));
}
function readVecU8(buf, off) {
    const len = buf.readUInt32LE(off);
    const start = off + 4;
    return { bytes: buf.slice(start, start + len), next: start + len };
}
function decodeVerificationType(buf, off) {
    const d = buf.readUInt8(off);
    return { value: d === 0 ? "SignedVerification" : "UniversalTxVerification", next: off + 1 };
}
function decodeUniversalPayload(buf) {
    let off = 0;
    const to = buf.slice(off, off + 20); off += 20;
    const value = readU64LE(buf, off); off += 8;
    const dataRes = readVecU8(buf, off); off = dataRes.next;
    const gasLimit = readU64LE(buf, off); off += 8;
    const maxFeePerGas = readU64LE(buf, off); off += 8;
    const maxPriorityFeePerGas = readU64LE(buf, off); off += 8;
    const nonce = readU64LE(buf, off); off += 8;
    const deadline = readI64LE(buf, off); off += 8;
    const vTypeRes = decodeVerificationType(buf, off);
    return {
        to: "0x" + to.toString("hex"),
        value,
        data: dataRes.bytes.length > 0 ? "0x" + dataRes.bytes.toString("hex") : "0x",
        gasLimit,
        maxFeePerGas,
        maxPriorityFeePerGas,
        nonce,
        deadline,
        verificationType: vTypeRes.value,
    };
}

function toBytes(raw) {
    if (!raw) return Buffer.alloc(0);
    if (Array.isArray(raw)) return Buffer.from(raw);
    if (Buffer.isBuffer(raw)) return raw;
    if (raw?.data) return Buffer.from(raw.data);
    return Buffer.from(raw);
}

function decodeTxType(raw) {
    if (raw === undefined || raw === null) return "Unknown";
    if (typeof raw === "object") {
        const key = Object.keys(raw)[0];
        return key ? key.charAt(0).toUpperCase() + key.slice(1) : "Unknown";
    }
    return ["Gas", "GasAndPayload", "Funds", "FundsAndPayload"][raw] ?? `Unknown(${raw})`;
}

function lamportsToSol(lamports) {
    return (Number(lamports) / LAMPORTS_PER_SOL).toFixed(9) + " SOL";
}

function isNativeToken(pk) {
    return !pk || pk.toString() === SYSTEM_PROGRAM;
}

function fmt32(arr) {
    return "0x" + toBytes(arr).toString("hex");
}
function fmt20(arr) {
    return "0x" + toBytes(arr).toString("hex");
}

// ─── Event decoders ───────────────────────────────────────────────────────────

function decodeUniversalTxEvent(e) {
    const payloadBytes = toBytes(e.payload);
    const sigData = toBytes(e.signature_data ?? e.signatureData);
    const revert = e.revert_instruction ?? e.revertInstruction ?? {};
    const revertMsg = toBytes(revert.revert_msg ?? revert.revertMsg ?? []);
    const token = e.token?.toString();
    const native = isNativeToken(e.token);

    let decodedPayload = null;
    let payloadError = null;
    if (payloadBytes.length > 0) {
        try { decodedPayload = decodeUniversalPayload(payloadBytes); }
        catch (err) { payloadError = err.message; }
    }

    return {
        event: "UniversalTx",
        tx_type: decodeTxType(e.tx_type ?? e.txType),
        sender: e.sender?.toString(),
        recipient: fmt20(e.recipient),
        token: native ? "SOL (native)" : token,
        amount: Number(e.amount),
        amount_human: native ? lamportsToSol(e.amount) : null,
        from_cea: e.from_cea ?? e.fromCea ?? false,
        revert_instruction: {
            fund_recipient: (revert.fund_recipient ?? revert.fundRecipient)?.toString(),
            revert_msg: revertMsg.length > 0 ? "0x" + revertMsg.toString("hex") : null,
        },
        signature_data: sigData.length > 0 ? "0x" + sigData.toString("hex") : null,
        payload: decodedPayload ?? (payloadError ? { decode_error: payloadError, raw_hex: "0x" + payloadBytes.toString("hex") } : null),
    };
}

function decodeUniversalTxFinalizedEvent(e) {
    const payloadBytes = toBytes(e.payload);
    const token = e.token?.toString();
    const native = isNativeToken(e.token);

    return {
        event: "UniversalTxFinalized",
        sub_tx_id: fmt32(e.sub_tx_id ?? e.subTxId),
        universal_tx_id: fmt32(e.universal_tx_id ?? e.universalTxId),
        gas_fee: Number(e.gas_fee ?? e.gasFee ?? 0),
        gas_used: Number(e.gas_used ?? e.gasUsed ?? 0),
        gas_to_refund: Number(e.gas_to_refund ?? e.gasToRefund ?? 0),
        ata_created: e.ata_created ?? e.ataCreated ?? false,
        push_account: fmt20(e.push_account ?? e.pushAccount),
        target: e.target?.toString(),
        token: native ? "SOL (native)" : token,
        amount: Number(e.amount),
        amount_human: native ? lamportsToSol(e.amount) : null,
        ix_data: payloadBytes.length > 0 ? "0x" + payloadBytes.toString("hex") : null,
    };
}

function decodeRevertUniversalTxEvent(e) {
    const revert = e.revert_instruction ?? e.revertInstruction ?? {};
    const revertMsg = toBytes(revert.revert_msg ?? revert.revertMsg ?? []);
    const token = e.token?.toString();
    const native = isNativeToken(e.token);

    return {
        event: "RevertUniversalTx",
        sub_tx_id: fmt32(e.sub_tx_id ?? e.subTxId),
        universal_tx_id: fmt32(e.universal_tx_id ?? e.universalTxId),
        fund_recipient: e.fund_recipient?.toString() ?? e.fundRecipient?.toString(),
        token: native ? "SOL (native)" : token,
        amount: Number(e.amount),
        amount_human: native ? lamportsToSol(e.amount) : null,
        revert_instruction: {
            fund_recipient: (revert.fund_recipient ?? revert.fundRecipient)?.toString(),
            revert_msg: revertMsg.length > 0 ? "0x" + revertMsg.toString("hex") : null,
        },
    };
}

function dispatchEvent(ev) {
    switch (ev.name) {
        case "UniversalTx":           return decodeUniversalTxEvent(ev.data);
        case "UniversalTxFinalized":  return decodeUniversalTxFinalizedEvent(ev.data);
        case "RevertUniversalTx":     return decodeRevertUniversalTxEvent(ev.data);
        default:                      return { event: ev.name, raw: ev.data };
    }
}

// ─── Pretty print helpers ────────────────────────────────────────────────────

function printUniversalTx(d, idx, total) {
    console.log(`  ┌─ Event ${idx} / ${total}  [UniversalTx — ${d.tx_type}]`);
    console.log(`  │  sender:          ${d.sender}`);
    console.log(`  │  recipient:       ${d.recipient}`);
    console.log(`  │  token:           ${d.token}`);
    console.log(`  │  amount:          ${d.amount}${d.amount_human ? ` (${d.amount_human})` : ""}`);
    console.log(`  │  from_cea:        ${d.from_cea}`);
    console.log(`  │  revert:`);
    console.log(`  │    fund_recipient: ${d.revert_instruction.fund_recipient}`);
    console.log(`  │    revert_msg:     ${d.revert_instruction.revert_msg ?? "(empty)"}`);
    console.log(`  │  signature_data:  ${d.signature_data ?? "(empty)"}`);
    if (d.payload) {
        console.log(`  │  payload:`);
        if (d.payload.decode_error) {
            console.log(`  │    ✗ decode_error: ${d.payload.decode_error}`);
            console.log(`  │    raw_hex:        ${d.payload.raw_hex}`);
        } else {
            for (const [k, v] of Object.entries(d.payload)) {
                console.log(`  │    ${k.padEnd(22)} ${v}`);
            }
        }
    } else {
        console.log(`  │  payload:         (empty)`);
    }
    console.log(`  └─`);
}

function printUniversalTxFinalized(d, idx, total) {
    console.log(`  ┌─ Event ${idx} / ${total}  [UniversalTxFinalized]`);
    console.log(`  │  sub_tx_id:       ${d.sub_tx_id}`);
    console.log(`  │  universal_tx_id: ${d.universal_tx_id}`);
    console.log(`  │  gas_fee:         ${d.gas_fee} (${lamportsToSol(d.gas_fee)})`);
    console.log(`  │  gas_used:        ${d.gas_used} (${lamportsToSol(d.gas_used)})`);
    console.log(`  │  gas_to_refund:   ${d.gas_to_refund} (${lamportsToSol(d.gas_to_refund)})`);
    console.log(`  │  ata_created:     ${d.ata_created}`);
    console.log(`  │  push_account:    ${d.push_account}`);
    console.log(`  │  target:          ${d.target}`);
    console.log(`  │  token:           ${d.token}`);
    console.log(`  │  amount:          ${d.amount}${d.amount_human ? ` (${d.amount_human})` : ""}`);
    console.log(`  │  ix_data:         ${d.ix_data ?? "(empty)"}`);
    console.log(`  └─`);
}

function printRevertUniversalTx(d, idx, total) {
    console.log(`  ┌─ Event ${idx} / ${total}  [RevertUniversalTx]`);
    console.log(`  │  sub_tx_id:       ${d.sub_tx_id}`);
    console.log(`  │  universal_tx_id: ${d.universal_tx_id}`);
    console.log(`  │  fund_recipient:  ${d.fund_recipient}`);
    console.log(`  │  token:           ${d.token}`);
    console.log(`  │  amount:          ${d.amount}${d.amount_human ? ` (${d.amount_human})` : ""}`);
    console.log(`  │  revert:`);
    console.log(`  │    fund_recipient: ${d.revert_instruction.fund_recipient}`);
    console.log(`  │    revert_msg:     ${d.revert_instruction.revert_msg ?? "(empty)"}`);
    console.log(`  └─`);
}

function printEvent(d, idx, total) {
    switch (d.event) {
        case "UniversalTx":          return printUniversalTx(d, idx, total);
        case "UniversalTxFinalized": return printUniversalTxFinalized(d, idx, total);
        case "RevertUniversalTx":    return printRevertUniversalTx(d, idx, total);
        default:
            console.log(`  ┌─ Event ${idx} / ${total}  [${d.event}]`);
            console.log(JSON.stringify(d.raw, null, 2).split("\n").map(l => "  │  " + l).join("\n"));
            console.log(`  └─`);
    }
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function decodeOutboundTx(sig) {
    const connection = new Connection("https://api.devnet.solana.com", { commitment: "confirmed" });
    const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
    const coder = new anchor.BorshEventCoder(idl);

    console.log(`\n${"═".repeat(72)}`);
    console.log(`  TX: ${sig}`);
    console.log(`${"═".repeat(72)}`);

    const tx = await connection.getTransaction(sig, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
    });

    if (!tx) {
        console.log("  ✗ Transaction not found\n");
        return;
    }

    // Metadata
    const blockTime = tx.blockTime ? new Date(tx.blockTime * 1000).toISOString() : "unknown";
    const fee = tx.meta?.fee ?? 0;
    const failed = !!tx.meta?.err;

    // Include ALT-loaded accounts so vault/CEA show up in balance changes.
    // Solana balance array order: static keys, loaded writable, loaded readonly.
    const staticKeys = (tx.transaction.message.staticAccountKeys ?? tx.transaction.message.accountKeys ?? []).map(k => k.toString());
    const loadedWritable = (tx.meta?.loadedAddresses?.writable ?? []).map(k => k.toString());
    const loadedReadonly = (tx.meta?.loadedAddresses?.readonly ?? []).map(k => k.toString());
    const allKeys = [...staticKeys, ...loadedWritable, ...loadedReadonly];
    const caller = allKeys[0];

    // Identify which gateway instruction was called
    const logs = tx.meta?.logMessages ?? [];
    const instructionLog = logs.find(l => l.startsWith("Program log: Instruction:"));
    const instruction = instructionLog ? instructionLog.replace("Program log: Instruction: ", "") : "Unknown";

    console.log(`\n  ┌─ Metadata`);
    console.log(`  │  Instruction: ${instruction}`);
    console.log(`  │  Slot:        ${tx.slot}`);
    console.log(`  │  Time:        ${blockTime}`);
    console.log(`  │  Fee:         ${fee} lamports (${lamportsToSol(fee)})`);
    console.log(`  │  Status:      ${failed ? "FAILED — " + JSON.stringify(tx.meta.err) : "SUCCESS"}`);
    console.log(`  │  Caller:      ${caller}`);
    console.log(`  └─`);

    if (failed) {
        const errorLog = logs.find(l => l.includes("Error") || l.includes("failed"));
        if (errorLog) console.log(`\n  Error log: ${errorLog}`);
        console.log();
        return;
    }

    // SOL balance changes (allKeys covers static + ALT accounts)
    const preBalances = tx.meta?.preBalances ?? [];
    const postBalances = tx.meta?.postBalances ?? [];
    const changes = allKeys
        .map((k, i) => ({ account: k.toString(), delta: (postBalances[i] ?? 0) - (preBalances[i] ?? 0) }))
        .filter(c => c.delta !== 0);

    if (changes.length > 0) {
        console.log(`\n  ┌─ SOL Balance Changes`);
        for (const { account, delta } of changes) {
            console.log(`  │  ${(delta > 0 ? "+" : "") + lamportsToSol(delta).padStart(16)}   ${account}`);
        }
        console.log(`  └─`);
    }

    // Decode events from emit_cpi inner instructions.
    // Layout: [EVENT_IX_TAG_LE: 8 bytes] || [event_discriminator: 8 bytes] || [borsh(event)].
    // coder.decode accepts base64 of the last two fields; strip the 8-byte tag first.
    const programIdx = allKeys.findIndex(k => k === PROGRAM_ID);
    const events = [];
    if (programIdx !== -1) {
        const bs58 = anchor.utils.bytes.bs58;
        for (const inner of tx.meta?.innerInstructions ?? []) {
            for (const ix of inner.instructions) {
                if (ix.programIdIndex !== programIdx) continue;
                const raw = Buffer.from(bs58.decode(ix.data));
                if (raw.length < 16) continue;
                try {
                    const ev = coder.decode(raw.slice(8).toString("base64"));
                    if (ev) events.push(ev);
                } catch { /* not an event */ }
            }
        }
    }

    const gatewayEvents = events.filter(e =>
        ["UniversalTx", "UniversalTxFinalized", "RevertUniversalTx"].includes(e.name)
    );

    if (gatewayEvents.length === 0) {
        const names = events.map(e => e.name);
        console.log(`\n  ✗ No gateway events found. Events present: ${names.join(", ") || "none"}\n`);
        return;
    }

    console.log(`\n  ${gatewayEvents.length} gateway event(s)\n`);

    const decoded = gatewayEvents.map(ev => dispatchEvent(ev));

    for (let i = 0; i < decoded.length; i++) {
        printEvent(decoded[i], i + 1, decoded.length);
        console.log();
    }

    // JSON summary
    const summary = {
        signature: sig,
        instruction,
        slot: tx.slot,
        block_time: blockTime,
        fee_lamports: fee,
        status: "success",
        caller,
        balance_changes: changes.map(({ account, delta }) => ({
            account,
            delta_lamports: delta,
            delta_sol: lamportsToSol(delta),
        })),
        events: decoded,
    };

    console.log(`  ┌─ JSON`);
    console.log(JSON.stringify(summary, null, 4).split("\n").map(l => "  │  " + l).join("\n"));
    console.log(`  └─\n`);
}

// ─── Entry point ─────────────────────────────────────────────────────────────

const [, , ...sigs] = process.argv;
if (sigs.length === 0) {
    console.log("Usage: node app/decode-outbound-tx.js <signature> [sig2] ...");
    console.log("       yarn decode:outbound <signature>");
    console.log("\nDecodes any Universal Gateway transaction.");
    console.log("Handles: FinalizeUniversalTx, SendUniversalTx, RevertUniversalTx");
    process.exit(1);
}

(async () => {
    for (const sig of sigs) {
        await decodeOutboundTx(sig).catch(err =>
            console.error(`Error decoding ${sig}:`, err?.message ?? String(err))
        );
    }
})();
