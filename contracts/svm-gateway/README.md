# Push Chain SVM Gateway

Solana-side gateway for Push Chain universal transactions. This program handles inbound deposits from Solana to Push Chain and outbound finalization, reverts, and emergency rescues from Push Chain back to Solana.

## Getting Started

### Dependencies

- Rust + Cargo 1.75+
- [Solana CLI](https://docs.solanalabs.com/cli/install) 1.18+
- [Anchor CLI](https://www.anchor-lang.com/docs/installation) 0.31.1
- Node.js 20+ and npm

### Setup

```bash
npm install
anchor build
```

### Test

```bash
anchor test                                        # all tests
TEST_FILE=tests/execute.test.ts anchor test        # single file
npm run test:execute                               # convenience script
# also: test:withdraw, test:admin, test:rate-limit, test:universal-tx,
#        test:rescue, test:cea-to-uea, test:execute-heavy
```

### CLI Tools

```bash
# Token management
npm run token:create          # create SPL token
npm run token:mint            # mint tokens
npm run token:whitelist       # add token to rate limits
npm run token:remove-whitelist # remove token from rate limits
npm run token:list            # list whitelisted tokens

# Gateway configuration
npm run config:show           # display current config
npm run config:tss-init       -- --admin-keypair <admin-keypair.json> --eth 0x<40-hex-address> --chain-id <chain-id>
npm run config:tss-update     -- --operator-keypair <operator-keypair.json> --eth 0x<40-hex-address> --chain-id <chain-id>
npm run config:operator-set   -- --admin-keypair <admin-keypair.json> --new-operator <operator-pubkey>
npm run config:pause          -- --pauser-keypair <pauser-keypair.json>
npm run config:unpause        -- --operator-keypair <operator-keypair.json>

# Same commands, but wrapped into a Squads vault proposal instead of direct execution
npm run config:tss-update     -- --multisig <multisig-pda> --member-keypair <member.json> --eth 0x<40-hex-address> --chain-id <chain-id>
npm run config:squads-approve -- --multisig <multisig-pda> --member-keypair <member.json> --tx-index <n>
npm run config:squads-execute -- --multisig <multisig-pda> --member-keypair <member.json> --tx-index <n>
```

Each authority-bearing `config-cli` command supports both models:
- EOA: pass the role keypair flag for that command, such as `--admin-keypair`, `--operator-keypair`, or `--pauser-keypair`
- Squads vault: pass `--multisig <multisig-pda>` and `--member-keypair <member.json>` to create a vault transaction proposal instead of executing directly

This is role-local. Admin can be Squads while operator is an EOA, or vice versa.

---

## Instruction Map

| Function | Direction | instruction_id | Notes |
|---|---|---|---|
| `send_universal_tx` | Solana -> Push Chain | N/A | Inbound deposit entrypoint |
| `finalize_universal_tx` | Push Chain -> Solana | `1` / `2` | `1=withdraw`, `2=execute` |
| `store_execute_ix_data` | Push Chain -> Solana (prep) | N/A | Store large `ix_data` before ref-finalize |
| `finalize_universal_tx_with_ix_data_ref` | Push Chain -> Solana | `2` | Execute via stored `ix_data` (for payloads > ~900 bytes) |
| `close_stored_ix_data` | Push Chain -> Solana (cleanup) | N/A | Close stored PDA and recover rent |
| `revert_universal_tx` | Push Chain -> Solana | `3` | Unified SOL + SPL revert |
| `rescue_funds` | Push Chain -> Solana | `4` | Emergency fund release |

---

## Docs and Tooling

### Program Documentation

- [SVM Gateway Overview](./docs/0-SVM-GATEWAY.md)
- [Deposit / Inbound](./docs/1-DEPOSIT.md)
- [Withdraw + Execute](./docs/2-WITHDRAW-EXECUTE.md)
- [Revert](./docs/3-REVERT.md)
- [CEA](./docs/4-CEA.md)
- [Rescue](./docs/5-RESCUE.md)
- [TX-Size Ref-Finalize Route](./docs/6-TX-SIZE-REF-ROUTE.md)
- [Threat Model](./docs/THREAT_MODEL.md)
- [Runbook](./docs/RUNBOOK.md)

### Integration

- [Integration Guide](./INTEGRATION_GUIDE.md)

### Devnet Program IDs

- Main: `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`
- Dummy: `DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp`

### Push Chain

- **Testnet RPC:** `https://rpc.testnet.push.org`
- **Docs:** [https://push.org/docs/](https://push.org/docs/)

---

## License

ISC
