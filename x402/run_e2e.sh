#!/usr/bin/env bash
# End-to-end run of the x402 server and clients on a local node (x402/README.md).
#
#   bash x402/run_e2e.sh
#
# Needs Foundry (forge, anvil), Node with `npm install` done in x402/, and the server's virtual
# environment (x402/server/.venv, from x402/server/requirements.txt). No proving happens: the
# server presents the stored solo proof. Three small processes run at once (the local node, the
# server, the client); the peak memory of each is printed at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGS="x402/.state/logs"
mkdir -p "$LOGS"
FORGE="${FORGE:-$(command -v forge || echo ~/.foundry/bin/forge)}"
ANVIL="${ANVIL:-$(command -v anvil || echo ~/.foundry/bin/anvil)}"

bash x402/fetch_x402.sh
"$FORGE" script script/X402LocalChain.s.sol > "$LOGS/script.log"

/usr/bin/time -l "$ANVIL" --chain-id 84532 --port 8545 --hardfork osaka --silent 2> "$LOGS/anvil.time" &
ANVIL_TIME=$!
for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8545 && break; sleep 0.2; done
python3 -I x402/server/load_state.py x402/.state

(cd x402/server && X402_FAULTS=1 exec /usr/bin/time -l .venv/bin/python server.py ../.state 2> ../.state/logs/server.time) &
SERVER_TIME=$!
for _ in $(seq 50); do curl -s -o /dev/null -X POST http://127.0.0.1:8402/infer && break; sleep 0.2; done

status=0
(cd x402 && /usr/bin/time -l npx tsx client/e2e.ts 2> .state/logs/client.time) || status=$?

for t in $SERVER_TIME $ANVIL_TIME; do
  pkill -TERM -P "$t" || true
  wait "$t" 2>/dev/null || true
done
if [ "$status" -ne 0 ]; then
  echo "client failed:"
  grep -v -E '^ +[0-9]+ +[a-z]' "$LOGS/client.time" | grep -v -E 'real +[0-9.]+ user' | head -20
fi
for p in client server anvil; do
  printf '%-7s peak RSS %s bytes\n' "$p" "$(awk '/maximum resident set size/ {print $1}' "$LOGS/$p.time")"
done
exit $status
