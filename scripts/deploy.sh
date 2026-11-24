#!/usr/bin/env bash
# Base Sepolia deployment, run by the holder of the deployer keystore. Every subcommand that needs the
# deployer asks for the keystore password at Foundry's prompt; nothing here reads or stores a key.
#
#   bash scripts/deploy.sh balances   the deployer's ETH and USDC (reads its address from the keystore)
#   bash scripts/deploy.sh dry        simulate script/DeployBaseSepolia.s.sol against the chain; sends nothing
#   bash scripts/deploy.sh send       the same, then broadcast, one transaction at a time
#
# Environment: RPC (default https://sepolia.base.org), ACCOUNT (default exactzk-v3-deployer).
# `send` refuses to run with uncommitted changes to the contracts, the script or the fixtures, so that the
# deployed code is a commit. Forge writes the result to broadcast/DeployBaseSepolia.s.sol/84532/run-latest.json.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${RPC:-https://sepolia.base.org}"
ACCOUNT="${ACCOUNT:-exactzk-v3-deployer}"
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e
SCRIPT=script/DeployBaseSepolia.s.sol

[ "$(cast chain-id --rpc-url "$RPC")" = 84532 ] || { echo "RPC is not Base Sepolia" >&2; exit 1; }

case "${1:-}" in
  balances)
    a=$(cast wallet address --account "$ACCOUNT")
    echo "ETH:  $(cast balance "$a" --rpc-url "$RPC" --ether)"
    echo "USDC: $(cast erc20-token balance "$USDC" "$a" --rpc-url "$RPC") units (1 USDC = 1000000)"
    echo "next nonce: $(cast nonce "$a" --rpc-url "$RPC")"
    ;;
  dry)
    echo "commit $(git rev-parse --short HEAD)"
    forge script "$SCRIPT" --rpc-url "$RPC" --account "$ACCOUNT"
    ;;
  send)
    if [ -n "$(git status --porcelain -- src script test/fixtures foundry.toml lib)" ]; then
      echo "uncommitted changes under src/, script/, test/fixtures/, lib/ or foundry.toml: commit first" >&2
      exit 1
    fi
    echo "commit $(git rev-parse HEAD)"
    forge script "$SCRIPT" --rpc-url "$RPC" --account "$ACCOUNT" --broadcast --slow
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
