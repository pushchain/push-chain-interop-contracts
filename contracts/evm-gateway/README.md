# Universal Gateway

The Universal Gateway is a blockchain-based payment gateway that enables cross-chain transactions by converting ETH to stablecoins (USDT). It's designed to provide a seamless experience for users who want to transfer value across different blockchain networks.

## Overview

The Universal Gateway contract is an upgradeable smart contract that:

1. Accepts ETH deposits from users
2. Converts ETH to USDT using Uniswap
3. Records transaction details with USD value for cross-chain verification
4. Provides admin functionality for token recovery and contract upgrades

The contract uses Chainlink price feeds to determine accurate USD values for both ETH and USDT, ensuring reliable price data for cross-chain operations.

## Key Features

- **ETH to USDT Conversion**: Automatically converts ETH to USDT using Uniswap
- **Price Oracle Integration**: Uses Chainlink price feeds for accurate USD value calculations
- **Upgradeable Architecture**: Implements UUPS proxy pattern for future upgrades
- **Access Control**: Admin-only functions for token recovery and upgrades
- **Reentrancy Protection**: Guards against reentrancy attacks

## Contract Architecture

The contract inherits from several OpenZeppelin contracts:
- `Initializable`: Enables proxy-based upgradeability
- `UUPSUpgradeable`: Implements the UUPS upgradeability pattern
- `AccessControlUpgradeable`: Provides role-based access control
- `ReentrancyGuardUpgradeable`: Prevents reentrancy attacks

## Development Setup
### Installation

1. Clone the repository
```bash
git clone <repository-url>
cd push-chain-universal-contracts
```

2. Install dependencies
```bash
forge install
```

3. Install the OpenZeppelin Foundry Upgrades library
```bash
forge install OpenZeppelin/openzeppelin-foundry-upgrades
```

4. Create a symbolic link to the library in the evm-gateway/lib directory
```bash
cd contracts/evm-gateway
mkdir -p lib
ln -s ../../../lib/openzeppelin-foundry-upgrades lib/openzeppelin-foundry-upgrades
```

### Configuration

1. Create a `.env` file in the `contracts/evm-gateway` directory with your RPC URL:
```
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_API_KEY
```

2. Make sure your `foundry.toml` has the correct remappings:
```toml
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
    "openzeppelin-foundry-upgrades/=lib/openzeppelin-foundry-upgrades/src/",
]
```

## Testing

The contract includes tests that verify its core functionality:

1. Oracle price fetching
2. ETH to USDT conversion
3. Admin token recovery
4. Upgradeability

Run the tests with:
```bash
cd contracts/evm-gateway
forge test -vv
```

## Usage

### Adding Funds
Users can add funds by sending ETH to the contract:
```solidity
// Example: Adding 1 ETH
gateway.addFunds{value: 1 ether}(transactionHash);
```

### Recovering Tokens (Admin Only)
Admins can recover USDT from the contract:
```solidity
// Example: Recovering all USDT to a recipient address
uint256 balance = IERC20(USDT).balanceOf(address(gateway));
gateway.recoverToken(recipientAddress, balance);
```

## Security Considerations

- The contract uses OpenZeppelin's ReentrancyGuard to prevent reentrancy attacks
- Access control ensures only admins can recover tokens or upgrade the contract
- Slippage protection is implemented (0.5%) for the ETH to USDT swap

## License

MIT
