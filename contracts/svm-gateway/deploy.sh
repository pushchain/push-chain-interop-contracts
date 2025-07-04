#!/bin/bash

set -e

# Usage: ./deploy.sh devnet
CLUSTER="$1"

if [[ -z "$CLUSTER" ]]; then
  echo "❌ Please specify the cluster to deploy to (e.g., devnet, testnet, localnet, mainnet-beta)"
  exit 1
fi

# Optional: Custom keypair path (change this if needed)
KEYPAIR_PATH="$HOME/.config/solana/id.json"

echo "🔐 Using keypair: $KEYPAIR_PATH"

echo "📦 Building program..."
anchor build

echo "🚀 Deploying to $CLUSTER..."
solana config set --keypair "$KEYPAIR_PATH" --url "https://api.$CLUSTER.solana.com"
anchor deploy --provider.cluster "$CLUSTER" --provider.wallet "$KEYPAIR_PATH"

echo "✅ Successfully deployed to $CLUSTER"
