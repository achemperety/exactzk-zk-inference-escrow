#!/usr/bin/env bash
# One command, two modes (README.md, "Quickstart"). Needs Node 20 or later and git; nothing else.
#
#   bash quickstart.sh                              published-proof mode on Base Sepolia
#   bash quickstart.sh live <prover url> <input.json>
#
# Published-proof mode creates a throwaway key in .quickstart/key, asks you to fund it from faucets,
# then pays this repository's Base Sepolia deployment with the published solo proof and prints the
# settlement transaction, the output and the outcome. Nothing is proved on this machine.
set -euo pipefail
cd "$(dirname "$0")/clients/ts"
node -e 'const v = process.versions.node; if (+v.split(".")[0] < 20) { console.error(`Node 20 or later is needed; this is ${v}`); process.exit(1); }'
if [ "${1:-published}" = live ]; then
  npm ci --no-audit --no-fund --loglevel=error --omit=dev
else
  npm ci --no-audit --no-fund --loglevel=error --omit=dev --omit=optional
fi
exec ./node_modules/.bin/tsx bin/quickstart.ts "$@"
