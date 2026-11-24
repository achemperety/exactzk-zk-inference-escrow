#!/usr/bin/env bash
# Fetch the x402 TypeScript packages this directory builds against, at one pinned commit, into
# x402/vendor/x402 (not tracked). Only the two packages used are checked out: @x402/core (types,
# zod schemas, header encoding, the client) and @x402/evm (the auth-capture client scheme).
set -euo pipefail
COMMIT=3eb54b2984a955118845115b3fd5db4c926d0382
DIR="$(cd "$(dirname "$0")" && pwd)/vendor/x402"
if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$COMMIT" ]; then
  echo "x402 already at $COMMIT"
  exit 0
fi
rm -rf "$DIR"
git clone -q --filter=blob:none --no-checkout https://github.com/x402-foundation/x402 "$DIR"
git -C "$DIR" sparse-checkout set --no-cone typescript/packages/core typescript/packages/mechanisms/evm
git -C "$DIR" checkout -q "$COMMIT"
test "$(git -C "$DIR" rev-parse HEAD)" = "$COMMIT"
echo "x402 at $(git -C "$DIR" rev-parse HEAD)"
