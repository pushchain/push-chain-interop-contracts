# Push Chain Universal Contracts

The Universal Gateway contracts are the main entry point to Push Chain from any external blockchain. These contracts are designed to be deployed on multiple EVM (Ethereum Virtual Machine), SVM (Solana Virtual Machine), and other blockchain platforms, serving as the core entry point for users of those chains to initiate transactions, lock funds, and interact with the Push ecosystem.

## Overview

This repository acts as a modular repository that includes all gateway contracts for different blockchain ecosystems. The Universal Gateway contracts enable cross-chain interoperability by:

1. Accepting native tokens (e.g., ETH, SOL) or other tokens from users
2. Converting them to stablecoins when necessary
3. Recording transaction details with USD value for cross-chain verification
4. Providing admin functionality for token recovery and contract upgrades

## Repository Structure

```
push-chain-universal-contracts/
├── contracts/                    # Smart contracts for different blockchains
│   ├── evm-gateway/              # Ethereum and EVM-compatible chain contracts
│   └── svm-gateway/              # Solana and SVM-compatible chain contracts
├── lib/                          # External libraries and dependencies
└── tools/                        # Development and deployment tools
```

## EVM Gateway

The EVM Gateway contract is an upgradeable smart contract that handles ETH to USDT conversion using Uniswap and Chainlink price feeds. It's designed for Ethereum and EVM-compatible chains like Polygon, Arbitrum, Optimism, etc.

Key features:
- ETH to USDT conversion
- Price oracle integration
- Upgradeable architecture
- Access control
- Reentrancy protection

For more details on EVM-Gateway, see the [EVM Gateway README](contracts/evm-gateway/README.md).

## SVM Gateway

The SVM Gateway contracts handle transactions on Solana and other SVM-compatible chains.

## Development

Each gateway implementation has its own development setup and requirements. Please refer to the specific README files in each directory for detailed instructions on setup, testing, and deployment.

## License

MIT
