/**
 * Squads multisig program upgrade script.
 *
 * All configuration values can be overridden via CLI flags — no file editing
 * needed between upgrades or when switching networks.
 *
 * ─── Modes ──────────────────────────────────────────────────────────────────
 *
 *   Show multisig / proposal state:
 *     npx ts-node app/squads-upgrade.ts --mode show [--tx-index <N>]
 *
 *   Propose an upgrade (mainnet step 1):
 *     npx ts-node app/squads-upgrade.ts --mode propose \
 *       --multisig <ADDR> --program <ADDR> --program-data <ADDR> --buffer <ADDR>
 *
 *   Execute after threshold + timelock (mainnet step 2):
 *     npx ts-node app/squads-upgrade.ts --mode execute --tx-index <N> \
 *       --multisig <ADDR> --program <ADDR> --program-data <ADDR> --buffer <ADDR>
 *
 *   Propose a timelock change (goes through member vote):
 *     npx ts-node app/squads-upgrade.ts --mode set-timelock --timelock-seconds 86400
 *
 *   Execute an approved config transaction (timelock change, member change, etc.):
 *     npx ts-node app/squads-upgrade.ts --mode execute-config --tx-index <N>
 *
 *   Devnet only — full upgrade flow in one shot:
 *     npx ts-node app/squads-upgrade.ts --mode all --buffer <ADDR>
 *
 *   Devnet only — full set-timelock flow in one shot:
 *     npx ts-node app/squads-upgrade.ts --mode all-setlock --timelock-seconds 60
 *
 * ─── Guards ─────────────────────────────────────────────────────────────────
 *
 *   --mode all and --mode all-setlock are blocked unless --rpc hostname is
 *   one of: api.devnet.solana.com, localhost, 127.0.0.1.
 *   On mainnet, always use separate propose / execute invocations.
 *
 * ─── Timelock ────────────────────────────────────────────────────────────────
 *
 *   Once set, ALL vault transactions (upgrades) and config transactions are
 *   frozen for `timeLock` seconds after reaching approval threshold. The
 *   --mode execute and --mode execute-config commands check expiry before
 *   submitting and abort with a precise "executable at" timestamp if the lock
 *   has not yet cleared.  Changing the time-lock itself is also subject to the
 *   current lock. There is no bypass — this is by design.
 */

import * as multisig from "@sqds/multisig";
import {
  ComputeBudgetProgram,
  Connection,
  Keypair,
  PublicKey,
  TransactionMessage,
  VersionedTransaction,
  SYSVAR_RENT_PUBKEY,
  SYSVAR_CLOCK_PUBKEY,
  TransactionInstruction,
  AccountMeta,
} from "@solana/web3.js";
import * as fs from "fs";

// ─── Defaults (devnet test values) ────────────────────────────────────────

const DEVNET_DEFAULTS = {
  rpcUrl:        "https://api.devnet.solana.com",
  multisigPda:   "HJKFqvANP2HvDT3hRApJaFU7jMdj6cQcwmB5At4ZXyWz",
  programId:     "DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp",
  programData:   "AXVQcbZHGnY9au7reU7VMH3vSjPS575eTTC2abyJupH6",
  bufferAddress: "FjmrsWKCWF8DkxuevHqkQeeYKniiSQFr7zbC6GByYLQs",
  keypairPath:   "./upgrade-keypair.json",
  keypair2Path:  "./clean-user-keypair.json",
  priorityFee:   0, // microlamports per compute unit (0 = no priority fee)
};

interface RunConfig {
  rpcUrl:        string;
  multisigPda:   PublicKey;
  programId:     PublicKey;
  programData:   PublicKey;
  bufferAddress: PublicKey;
  keypairPath:   string;
  keypair2Path:  string;
  priorityFee:   number;
}

// ─── CLI args ──────────────────────────────────────────────────────────────

type Mode = "propose" | "execute" | "set-timelock" | "execute-config" | "approve" | "show" | "all" | "all-setlock";

interface ParsedArgs {
  mode:            Mode;
  txIndex:         bigint | null;
  timelockSeconds: number | null;
  // config overrides
  rpcUrl?:        string;
  multisigPda?:   string;
  programId?:     string;
  programData?:   string;
  bufferAddress?: string;
  keypairPath?:   string;
  keypair2Path?:  string;
  priorityFee?:   number;
}

function parseArgs(): ParsedArgs {
  const args = process.argv.slice(2);
  let mode: Mode = "propose";
  let txIndex: bigint | null = null;
  let timelockSeconds: number | null = null;
  const overrides: Partial<ParsedArgs> = {};

  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    const next = args[i + 1];

    switch (flag) {
      case "--mode": {
        const valid: Mode[] = ["propose", "execute", "set-timelock", "execute-config", "approve", "show", "all", "all-setlock"];
        if (!valid.includes(next as Mode)) {
          console.error(`Unknown --mode "${next}". Valid: ${valid.join(", ")}`);
          process.exit(1);
        }
        mode = next as Mode; i++; break;
      }
      case "--tx-index":        txIndex = BigInt(next); i++; break;
      case "--timelock-seconds": {
        const v = parseInt(next, 10);
        if (isNaN(v) || v < 0) { console.error("--timelock-seconds must be a non-negative integer"); process.exit(1); }
        timelockSeconds = v; i++; break;
      }
      case "--rpc":          overrides.rpcUrl        = next; i++; break;
      case "--multisig":     overrides.multisigPda   = next; i++; break;
      case "--program":      overrides.programId     = next; i++; break;
      case "--program-data": overrides.programData   = next; i++; break;
      case "--buffer":       overrides.bufferAddress = next; i++; break;
      case "--keypair":      overrides.keypairPath   = next; i++; break;
      case "--keypair2":     overrides.keypair2Path  = next; i++; break;
      case "--priority-fee": {
        const v = parseInt(next, 10);
        if (isNaN(v) || v < 0) { console.error("--priority-fee must be a non-negative integer (microlamports)"); process.exit(1); }
        overrides.priorityFee = v; i++; break;
      }
      default:
        if (flag.startsWith("--")) { console.error(`Unknown flag: ${flag}`); process.exit(1); }
    }
  }

  if (mode === "execute" && txIndex === null) {
    console.error("--mode execute requires --tx-index <N>"); process.exit(1);
  }
  if (mode === "execute-config" && txIndex === null) {
    console.error("--mode execute-config requires --tx-index <N>"); process.exit(1);
  }
  if (mode === "approve" && txIndex === null) {
    console.error("--mode approve requires --tx-index <N>"); process.exit(1);
  }
  if (mode === "set-timelock" && timelockSeconds === null) {
    console.error("--mode set-timelock requires --timelock-seconds <N>"); process.exit(1);
  }
  if (mode === "all-setlock" && timelockSeconds === null) {
    console.error("--mode all-setlock requires --timelock-seconds <N>"); process.exit(1);
  }

  return { mode, txIndex, timelockSeconds, ...overrides };
}

function resolveConfig(parsed: ParsedArgs): RunConfig {
  return {
    rpcUrl:        parsed.rpcUrl        ?? DEVNET_DEFAULTS.rpcUrl,
    multisigPda:   new PublicKey(parsed.multisigPda   ?? DEVNET_DEFAULTS.multisigPda),
    programId:     new PublicKey(parsed.programId     ?? DEVNET_DEFAULTS.programId),
    programData:   new PublicKey(parsed.programData   ?? DEVNET_DEFAULTS.programData),
    bufferAddress: new PublicKey(parsed.bufferAddress ?? DEVNET_DEFAULTS.bufferAddress),
    keypairPath:   parsed.keypairPath   ?? DEVNET_DEFAULTS.keypairPath,
    keypair2Path:  parsed.keypair2Path  ?? DEVNET_DEFAULTS.keypair2Path,
    priorityFee:   parsed.priorityFee   ?? DEVNET_DEFAULTS.priorityFee,
  };
}

// ─── Helpers ───────────────────────────────────────────────────────────────

function loadKeypair(path: string): Keypair {
  return Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(fs.readFileSync(path, "utf-8")))
  );
}

function fmtSeconds(s: number): string {
  if (s === 0) return "0s (no lock)";
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const parts: string[] = [];
  if (h > 0) parts.push(`${h}h`);
  if (m > 0) parts.push(`${m}m`);
  if (sec > 0) parts.push(`${sec}s`);
  return parts.join(" ");
}

function fmtTimestamp(unixSec: number): string {
  return new Date(unixSec * 1000).toISOString().replace("T", " ").replace("Z", " UTC");
}

function buildUpgradeInstruction(cfg: RunConfig, spillAddress: PublicKey, upgradeAuthority: PublicKey): TransactionInstruction {
  // BPFLoaderUpgradeable::Upgrade = discriminant 3 (u32 LE)
  const BPF_LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
  const data = Buffer.from([3, 0, 0, 0]);
  const keys: AccountMeta[] = [
    { pubkey: cfg.programData,   isSigner: false, isWritable: true  },
    { pubkey: cfg.programId,     isSigner: false, isWritable: true  },
    { pubkey: cfg.bufferAddress, isSigner: false, isWritable: true  },
    { pubkey: spillAddress,      isSigner: false, isWritable: true  },
    { pubkey: SYSVAR_RENT_PUBKEY,  isSigner: false, isWritable: false },
    { pubkey: SYSVAR_CLOCK_PUBKEY, isSigner: false, isWritable: false },
    { pubkey: upgradeAuthority,  isSigner: true,  isWritable: false },
  ];
  return new TransactionInstruction({ programId: BPF_LOADER, keys, data });
}

async function sendAndConfirm(
  connection: Connection,
  cfg: RunConfig,
  ixs: TransactionInstruction[],
  signers: Keypair[],
  label: string,
): Promise<string> {
  const allIxs = cfg.priorityFee > 0
    ? [ComputeBudgetProgram.setComputeUnitPrice({ microLamports: cfg.priorityFee }), ...ixs]
    : ixs;

  const { blockhash } = await connection.getLatestBlockhash();
  const msg = new TransactionMessage({
    payerKey: signers[0].publicKey,
    recentBlockhash: blockhash,
    instructions: allIxs,
  }).compileToV0Message();
  const tx = new VersionedTransaction(msg);
  tx.sign(signers);
  const sig = await connection.sendTransaction(tx);
  await connection.confirmTransaction(sig, "confirmed");
  console.log(`  ✓ ${label}: ${sig}`);
  return sig;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForTimelock(timeLockSeconds: number, approvedAt: number, label: string): Promise<void> {
  const executableAt = approvedAt + timeLockSeconds;
  const now = Math.floor(Date.now() / 1000);
  const remaining = executableAt - now + 2; // +2s clock-skew buffer
  if (remaining <= 0) return;
  console.log(`\n  ⏳ ${label}: timelock is ${fmtSeconds(timeLockSeconds)}.`);
  console.log(`     Waiting ${remaining}s for it to clear (executable at ${fmtTimestamp(executableAt)})...`);
  await sleep(remaining * 1000);
  console.log("  ✓ Timelock window cleared.");
}

// ─── Timelock check (shared by execute and execute-config) ─────────────────

async function checkTimelockExpiry(
  connection: Connection,
  cfg: RunConfig,
  txIndex: bigint,
  label: string,
): Promise<void> {
  const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);
  const timeLock = msState.timeLock;
  if (timeLock === 0) return;

  const [proposalPda] = multisig.getProposalPda({ multisigPda: cfg.multisigPda, transactionIndex: txIndex });
  const proposal = await multisig.accounts.Proposal.fromAccountAddress(connection, proposalPda);

  if (!multisig.types.isProposalStatusApproved(proposal.status)) {
    return; // not yet approved — let execute produce the on-chain error
  }

  const approvedAt = Number(proposal.status.timestamp.toString());
  const executableAt = approvedAt + timeLock;
  const now = Math.floor(Date.now() / 1000);

  if (now < executableAt) {
    const remaining = executableAt - now;
    console.error(`\n  Timelock not expired for ${label} (tx ${txIndex}):`);
    console.error(`    Approved at:    ${fmtTimestamp(approvedAt)}`);
    console.error(`    Timelock:       ${fmtSeconds(timeLock)}`);
    console.error(`    Executable at:  ${fmtTimestamp(executableAt)}  (in ${fmtSeconds(remaining)})`);
    process.exit(1);
  }

  console.log(`  ✓ Timelock cleared (approved ${fmtSeconds(now - approvedAt)} ago, lock was ${fmtSeconds(timeLock)})`);
}

// ─── Modes ─────────────────────────────────────────────────────────────────

async function show(connection: Connection, cfg: RunConfig, txIndex: bigint | null): Promise<void> {
  const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);

  console.log("\nMultisig state:");
  console.log("  Address:       ", cfg.multisigPda.toBase58());
  console.log("  Threshold:     ", `${msState.threshold} of ${msState.members.length} members`);
  console.log("  Time-lock:     ", fmtSeconds(msState.timeLock));
  console.log("  Latest tx idx: ", msState.transactionIndex.toString());
  console.log("  Members:");
  for (const m of msState.members) {
    const perms = [
      m.permissions.mask & 1 ? "Initiate" : "",
      m.permissions.mask & 2 ? "Vote"     : "",
      m.permissions.mask & 4 ? "Execute"  : "",
    ].filter(Boolean).join("+");
    console.log(`    ${m.key.toBase58()}  [${perms}]`);
  }

  if (txIndex !== null) {
    const [proposalPda] = multisig.getProposalPda({ multisigPda: cfg.multisigPda, transactionIndex: txIndex });
    let proposal: multisig.accounts.Proposal;
    try {
      proposal = await multisig.accounts.Proposal.fromAccountAddress(connection, proposalPda);
    } catch {
      console.log(`\nProposal for tx ${txIndex}: not found`);
      return;
    }

    console.log(`\nProposal tx ${txIndex}:`);
    console.log("  Status:   ", proposal.status.__kind);
    console.log("  Approved: ", `${proposal.approved.length} / ${msState.threshold} required`);
    console.log("  Approved by:");
    for (const k of proposal.approved) console.log(`    ${k.toBase58()}`);

    if (multisig.types.isProposalStatusApproved(proposal.status)) {
      const approvedAt = Number(proposal.status.timestamp.toString());
      const timeLock = msState.timeLock;
      if (timeLock > 0) {
        const executableAt = approvedAt + timeLock;
        const now = Math.floor(Date.now() / 1000);
        if (now < executableAt) {
          const remaining = executableAt - now;
          console.log("  Timelock: ", `NOT YET EXPIRED — executable at ${fmtTimestamp(executableAt)} (in ${fmtSeconds(remaining)})`);
        } else {
          console.log("  Timelock: ", "CLEARED — ready to execute");
        }
      } else {
        console.log("  Timelock: ", "none — ready to execute immediately");
      }
    }
  }
}

async function propose(connection: Connection, cfg: RunConfig, member1: Keypair, vaultPda: PublicKey): Promise<bigint> {
  const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);
  const txIndex = BigInt(msState.transactionIndex.toString()) + 1n;
  console.log("Transaction index:", txIndex.toString());

  if (msState.timeLock > 0) {
    console.log(`  ⚠️  Multisig has a ${fmtSeconds(msState.timeLock)} time-lock.`);
    console.log(`      Execution cannot happen until that window elapses after the last required approval.`);
  }

  const upgradeIx = buildUpgradeInstruction(cfg, member1.publicKey, vaultPda);
  const { blockhash } = await connection.getLatestBlockhash();
  const innerMessage = new TransactionMessage({
    payerKey: vaultPda,
    recentBlockhash: blockhash,
    instructions: [upgradeIx],
  });

  const vaultTxIx = multisig.instructions.vaultTransactionCreate({
    multisigPda: cfg.multisigPda,
    transactionIndex: txIndex,
    creator: member1.publicKey,
    rentPayer: member1.publicKey,
    vaultIndex: 0,
    ephemeralSigners: 0,
    transactionMessage: innerMessage,
  });
  const proposalIx = multisig.instructions.proposalCreate({
    multisigPda: cfg.multisigPda,
    transactionIndex: txIndex,
    creator: member1.publicKey,
    rentPayer: member1.publicKey,
    isDraft: false,
  });
  await sendAndConfirm(connection, cfg, [vaultTxIx, proposalIx], [member1], "vault tx + proposal created");

  console.log("\n✅ Proposal live. Transaction index:", txIndex.toString());
  console.log("   Each approver must independently verify the buffer hash before approving:");
  console.log(`   solana-verify get-buffer-hash -u ${cfg.rpcUrl} ${cfg.bufferAddress.toBase58()}`);
  console.log("   solana-verify get-executable-hash target/deploy/universal_gateway.so");
  console.log("   Hashes must match. Approve via Squads UI or a separate key invocation.");
  console.log("   When threshold is reached:");
  console.log(`   npx ts-node app/squads-upgrade.ts --mode execute --tx-index ${txIndex} \\`);
  console.log(`     --multisig ${cfg.multisigPda.toBase58()} \\`);
  console.log(`     --program ${cfg.programId.toBase58()} \\`);
  console.log(`     --program-data ${cfg.programData.toBase58()} \\`);
  console.log(`     --buffer ${cfg.bufferAddress.toBase58()}`);

  return txIndex;
}

async function execute(connection: Connection, cfg: RunConfig, member1: Keypair, txIndex: bigint): Promise<void> {
  console.log(`\n[execute] Running upgrade for transaction index ${txIndex}...`);

  await checkTimelockExpiry(connection, cfg, txIndex, "vault tx (upgrade)");

  const { instruction: executeIx, lookupTableAccounts } =
    await multisig.instructions.vaultTransactionExecute({
      connection,
      multisigPda: cfg.multisigPda,
      transactionIndex: txIndex,
      member: member1.publicKey,
    });

  const allIxs = cfg.priorityFee > 0
    ? [ComputeBudgetProgram.setComputeUnitPrice({ microLamports: cfg.priorityFee }), executeIx]
    : [executeIx];

  const { blockhash } = await connection.getLatestBlockhash();
  const execMsg = new TransactionMessage({
    payerKey: member1.publicKey,
    recentBlockhash: blockhash,
    instructions: allIxs,
  }).compileToV0Message(lookupTableAccounts);
  const execTx = new VersionedTransaction(execMsg);
  execTx.sign([member1]);
  const execSig = await connection.sendTransaction(execTx, { skipPreflight: true });
  await connection.confirmTransaction(execSig, "confirmed");
  console.log(`  ✓ upgrade executed: ${execSig}`);

  console.log("\n✅ Done. Verify (confirmTransaction ≠ inner success — always check):");
  console.log(`  solana program show ${cfg.programId.toBase58()} --url ${cfg.rpcUrl}`);
  console.log("  Last Deployed In Slot must have advanced.");
  console.log("  Authority must still show the Vault PDA — not a personal key.");
}

async function setTimelock(connection: Connection, cfg: RunConfig, member1: Keypair, timelockSeconds: number): Promise<bigint> {
  const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);
  const txIndex = BigInt(msState.transactionIndex.toString()) + 1n;

  console.log("Current time-lock:  ", fmtSeconds(msState.timeLock));
  console.log("Proposed time-lock: ", fmtSeconds(timelockSeconds));
  console.log("Transaction index:  ", txIndex.toString());

  if (msState.timeLock > 0) {
    console.log(`\n  ⚠️  The change itself must also wait ${fmtSeconds(msState.timeLock)} after approval`);
    console.log(`      before execute-config can run (current lock applies to config txs too).`);
  }

  const configTxIx = multisig.instructions.configTransactionCreate({
    multisigPda: cfg.multisigPda,
    transactionIndex: txIndex,
    creator: member1.publicKey,
    rentPayer: member1.publicKey,
    actions: [{ __kind: "SetTimeLock", newTimeLock: timelockSeconds }],
  });
  const proposalIx = multisig.instructions.proposalCreate({
    multisigPda: cfg.multisigPda,
    transactionIndex: txIndex,
    creator: member1.publicKey,
    rentPayer: member1.publicKey,
    isDraft: false,
  });
  await sendAndConfirm(connection, cfg, [configTxIx, proposalIx], [member1], "config tx + proposal created");

  console.log("\n✅ Time-lock change proposed. Transaction index:", txIndex.toString());
  console.log("   Members must approve via Squads UI or separate keys.");
  console.log("   When threshold is reached:");
  console.log(`   npx ts-node app/squads-upgrade.ts --mode execute-config --tx-index ${txIndex} \\`);
  console.log(`     --multisig ${cfg.multisigPda.toBase58()}`);

  return txIndex;
}

async function executeConfig(connection: Connection, cfg: RunConfig, member1: Keypair, txIndex: bigint): Promise<void> {
  console.log(`\n[execute-config] Applying config transaction ${txIndex}...`);

  await checkTimelockExpiry(connection, cfg, txIndex, "config tx");

  const configExecIx = multisig.instructions.configTransactionExecute({
    multisigPda: cfg.multisigPda,
    transactionIndex: txIndex,
    member: member1.publicKey,
    rentPayer: member1.publicKey,
  });
  await sendAndConfirm(connection, cfg, [configExecIx], [member1], `config tx ${txIndex} executed`);

  const newMsState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);
  console.log(`\n✅ Config applied. New time-lock: ${fmtSeconds(newMsState.timeLock)}`);
}

async function approve(connection: Connection, cfg: RunConfig, member: Keypair, txIndex: bigint): Promise<void> {
  const [proposalPda] = multisig.getProposalPda({ multisigPda: cfg.multisigPda, transactionIndex: txIndex });
  const proposal = await multisig.accounts.Proposal.fromAccountAddress(connection, proposalPda);

  if (proposal.status.__kind === "Executed") {
    console.error(`Proposal ${txIndex} is already Executed — nothing to approve.`);
    process.exit(1);
  }
  if (proposal.status.__kind !== "Active") {
    console.error(`Proposal ${txIndex} is in status "${proposal.status.__kind}" — can only approve Active proposals.`);
    process.exit(1);
  }
  if (proposal.approved.some(k => k.equals(member.publicKey))) {
    console.log(`  ℹ️  ${member.publicKey.toBase58()} has already approved tx ${txIndex} — skipping.`);
    return;
  }

  const approveIx = multisig.instructions.proposalApprove({
    multisigPda: cfg.multisigPda,
    transactionIndex: txIndex,
    member: member.publicKey,
  });
  await sendAndConfirm(connection, cfg, [approveIx], [member], `tx ${txIndex} approved by ${member.publicKey.toBase58()}`);

  const updated = await multisig.accounts.Proposal.fromAccountAddress(connection, proposalPda);
  const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);
  console.log(`  Approvals: ${updated.approved.length} / ${msState.threshold} required`);
  if (updated.status.__kind === "Approved") {
    console.log(`\n✅ Threshold reached — proposal is now Approved.`);
    if (msState.timeLock > 0) {
      const approvedAt = Number((updated.status as any).timestamp.toString());
      const executableAt = approvedAt + msState.timeLock;
      console.log(`   Timelock: ${fmtSeconds(msState.timeLock)} — executable at ${fmtTimestamp(executableAt)}`);
    }
  }
}

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  const parsed = parseArgs();
  const cfg = resolveConfig(parsed);
  const { mode, txIndex, timelockSeconds } = parsed;

  const isAutomated = mode === "all" || mode === "all-setlock";
  if (isAutomated) {
    // Parse the hostname to avoid substring-match bypasses (e.g. a mainnet URL
    // with "devnet" in the path or subdomain would fool a simple .includes() check).
    let hostname: string;
    try {
      hostname = new URL(cfg.rpcUrl).hostname;
    } catch {
      console.error(`ERROR: --rpc "${cfg.rpcUrl}" is not a valid URL.`);
      process.exit(1);
    }
    const allowedHosts = ["api.devnet.solana.com", "localhost", "127.0.0.1"];
    if (!allowedHosts.includes(hostname)) {
      console.error(
        `ERROR: --mode ${mode} is not permitted on this RPC (hostname: ${hostname}).\n` +
        "Automated modes are only allowed on api.devnet.solana.com, localhost, or 127.0.0.1.\n" +
        "On mainnet, always use separate --mode propose / --mode execute invocations\n" +
        "so each approver signs independently."
      );
      process.exit(1);
    }
  }

  const connection = new Connection(cfg.rpcUrl, "confirmed");

  if (mode === "show") {
    await show(connection, cfg, txIndex);
    return;
  }

  const member1 = loadKeypair(cfg.keypairPath);
  const [vaultPda] = multisig.getVaultPda({ multisigPda: cfg.multisigPda, index: 0 });

  console.log("Mode:      ", mode);
  console.log("RPC:       ", cfg.rpcUrl);
  console.log("Multisig:  ", cfg.multisigPda.toBase58());
  console.log("Vault PDA: ", vaultPda.toBase58());
  console.log("Member 1:  ", member1.publicKey.toBase58());
  if (cfg.priorityFee > 0) console.log("Priority:  ", `${cfg.priorityFee} microlamports/CU`);

  if (mode === "propose") {
    await propose(connection, cfg, member1, vaultPda);

  } else if (mode === "execute") {
    await execute(connection, cfg, member1, txIndex!);

  } else if (mode === "set-timelock") {
    await setTimelock(connection, cfg, member1, timelockSeconds!);

  } else if (mode === "approve") {
    await approve(connection, cfg, member1, txIndex!);

  } else if (mode === "execute-config") {
    await executeConfig(connection, cfg, member1, txIndex!);

  } else if (mode === "all-setlock") {
    const member2 = loadKeypair(cfg.keypair2Path);
    console.log("Member 2:  ", member2.publicKey.toBase58());

    const cfgTxIndex = await setTimelock(connection, cfg, member1, timelockSeconds!);

    console.log("\n[2/3] Approving (member 1)...");
    const a1 = multisig.instructions.proposalApprove({
      multisigPda: cfg.multisigPda, transactionIndex: cfgTxIndex, member: member1.publicKey,
    });
    await sendAndConfirm(connection, cfg, [a1], [member1], "member 1 approved");

    console.log("\n[3/3] Approving (member 2)...");
    const a2 = multisig.instructions.proposalApprove({
      multisigPda: cfg.multisigPda, transactionIndex: cfgTxIndex, member: member2.publicKey,
    });
    await sendAndConfirm(connection, cfg, [a2], [member2], "member 2 approved");

    await executeConfig(connection, cfg, member1, cfgTxIndex);

  } else {
    // all — devnet only (guarded above)
    const member2 = loadKeypair(cfg.keypair2Path);
    console.log("Member 2:  ", member2.publicKey.toBase58());

    const newTxIndex = await propose(connection, cfg, member1, vaultPda);

    console.log("\n[2/3] Approving (member 1)...");
    const approve1Ix = multisig.instructions.proposalApprove({
      multisigPda: cfg.multisigPda, transactionIndex: newTxIndex, member: member1.publicKey,
    });
    await sendAndConfirm(connection, cfg, [approve1Ix], [member1], "member 1 approved");

    console.log("\n[3/3] Approving (member 2)...");
    const approve2Ix = multisig.instructions.proposalApprove({
      multisigPda: cfg.multisigPda, transactionIndex: newTxIndex, member: member2.publicKey,
    });
    await sendAndConfirm(connection, cfg, [approve2Ix], [member2], "member 2 approved");

    // Wait out the timelock if one is set.
    const msState = await multisig.accounts.Multisig.fromAccountAddress(connection, cfg.multisigPda);
    if (msState.timeLock > 0) {
      const [proposalPda] = multisig.getProposalPda({ multisigPda: cfg.multisigPda, transactionIndex: newTxIndex });
      const proposal = await multisig.accounts.Proposal.fromAccountAddress(connection, proposalPda);
      if (multisig.types.isProposalStatusApproved(proposal.status)) {
        const approvedAt = Number(proposal.status.timestamp.toString());
        await waitForTimelock(msState.timeLock, approvedAt, "upgrade tx");
      }
    }

    await execute(connection, cfg, member1, newTxIndex);
  }
}

main().catch((e) => {
  console.error("Error:", e);
  process.exit(1);
});
