#!/usr/bin/env bash
# The TypeScript client (clients/ts) against the Python middleware (clients/python) on a local node:
#
#   bash clients/e2e/run.sh
#
# Needs Foundry (forge, anvil), `npm install` done in clients/ts, and a Python with web3 7.14
# (x402/server/.venv from x402/server/requirements.txt, or PYTHON=...). The chain state is the one
# script/X402LocalChain.s.sol builds for the x402 run: x402's escrow and collector at their canonical
# addresses, the test token at the USDC address, the registry, adapter, pinned solo verifier,
# SoloSettlement and the operator. No proving: the server presents the stored solo proof. Three
# small processes run at once (node, server, client); the peak memory of each is printed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LOGS="x402/.state/logs"
mkdir -p "$LOGS"
FORGE="${FORGE:-$(command -v forge || echo ~/.foundry/bin/forge)}"
ANVIL="${ANVIL:-$(command -v anvil || echo ~/.foundry/bin/anvil)}"
PYTHON="${PYTHON:-x402/server/.venv/bin/python}"

"$FORGE" script script/X402LocalChain.s.sol > "$LOGS/clients-script.log"
/usr/bin/time -l "$ANVIL" --chain-id 84532 --port 8545 --hardfork osaka --silent 2> "$LOGS/clients-anvil.time" &
ANVIL_TIME=$!
for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8545 && break; sleep 0.2; done
python3 -I x402/server/load_state.py x402/.state

/usr/bin/time -l "$PYTHON" clients/e2e/server.py 2> "$LOGS/clients-server.time" &
SERVER_TIME=$!
for _ in $(seq 50); do curl -s -o /dev/null -X POST http://127.0.0.1:8402/infer && break; sleep 0.2; done

status=0
(cd clients/ts && /usr/bin/time -l ./node_modules/.bin/tsx test/e2e.ts 2> "$ROOT/$LOGS/clients-client.time") || status=$?

for t in $SERVER_TIME $ANVIL_TIME; do
  pkill -TERM -P "$t" || true
  wait "$t" 2>/dev/null || true
done
if [ "$status" -ne 0 ]; then
  echo "client failed:"
  grep -v -E '^ +[0-9]+ +[a-z]' "$LOGS/clients-client.time" | grep -v -E 'real +[0-9.]+ user' | head -20
fi
for p in client server anvil; do
  printf '%-7s peak RSS %s bytes\n' "$p" "$(awk '/maximum resident set size/ {print $1}' "$LOGS/clients-$p.time")"
done
exit $status
