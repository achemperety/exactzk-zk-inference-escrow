#!/usr/bin/env python3
"""Does a chain apply EIP-7623's calldata floor? Read-only, from transactions already on the chain.

    python3 scripts/calldata_floor_check.py <rpc-url> [blocks to scan, default 300]

Needs `cast` (Foundry). A transaction sent to an account without code runs no code, so its gas is exactly 21,000 plus its
calldata: 4 gas per token under the standard price, 10 per token under the floor (a token is a zero
byte, or a quarter of a non-zero byte, as EIP-7623 counts them). Every such transaction with data in
the scanned blocks is classified by which of the two its receipt matches.
"""
import json, os, shutil, subprocess, sys, time

rpc = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 300
CAST = shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")


def call(method, params, tries=4):
    for t in range(tries):
        r = subprocess.run([CAST, "rpc", method, *[json.dumps(p) if not isinstance(p, str) else p for p in params],
                            "--rpc-url", rpc], capture_output=True, text=True)
        if r.returncode == 0:
            return json.loads(r.stdout)
        time.sleep(2 * (t + 1))
    raise RuntimeError(f"{method} failed: {r.stderr.strip()[:200]}")


head = int(call("eth_blockNumber", []), 16)
code_cache, floor, standard, other, examples = {}, 0, 0, 0, []
for b in range(head - n + 1, head + 1):
    block = call("eth_getBlockByNumber", [hex(b), True])
    receipts = {r["transactionHash"]: r for r in call("eth_getBlockReceipts", [hex(b)])}
    for tx in block["transactions"]:
        data = bytes.fromhex(tx["input"][2:])
        to = tx.get("to")
        if not data or not to or tx.get("type") == "0x7e":  # skip deposits and creations
            continue
        if to not in code_cache:
            code_cache[to] = call("eth_getCode", [to, "latest"]) not in ("0x", "0x0")  # code rarely changes
        if code_cache[to]:
            continue
        z = data.count(0)
        tokens = z + 4 * (len(data) - z)
        gas = int(receipts[tx["hash"]]["gasUsed"], 16)
        if gas == 21000 + 10 * tokens and tokens > 0:
            floor += 1
            kind = "floor"
        elif gas == 21000 + 4 * tokens:
            standard += 1
            kind = "standard"
        else:
            other += 1
            kind = "neither"
        if len(examples) < 5 or kind != "floor":
            examples.append({"block": b, "tx": tx["hash"], "bytes": len(data), "tokens": tokens, "gasUsed": gas,
                             "standard": 21000 + 4 * tokens, "floor": 21000 + 10 * tokens, "matches": kind})
print(f"chain id {int(call('eth_chainId', []), 16)}, blocks {head - n + 1} to {head}")
print(f"transactions with data to accounts without code: floor {floor}, standard {standard}, neither {other}")
for e in examples[:8]:
    print(json.dumps(e))
