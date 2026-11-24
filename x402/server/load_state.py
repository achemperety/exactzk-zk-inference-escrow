#!/usr/bin/env python3
"""Put the state written by script/X402LocalChain.s.sol on a local node.

    python load_state.py <state dir> [--rpc http://127.0.0.1:8545]

The node must run with chain id 84532 (`anvil --chain-id 84532`). Every account in state.json gets
its code, nonce, balance and storage through the node's `anvil_set*` methods. Only a local
development node accepts these; nothing here can touch a real network.
"""
import json, os, sys, urllib.request


def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req))
    if "error" in out:
        raise SystemExit(f"{method}: {out['error']}")
    return out.get("result")


def main():
    state_dir = sys.argv[1]
    url = sys.argv[sys.argv.index("--rpc") + 1] if "--rpc" in sys.argv else "http://127.0.0.1:8545"
    if int(rpc(url, "eth_chainId", []), 16) != 84532:
        raise SystemExit("the node must run with --chain-id 84532")
    state = json.load(open(os.path.join(state_dir, "state.json")))
    slots = 0
    for address, account in state.items():
        rpc(url, "anvil_setCode", [address, account.get("code", "0x")])
        rpc(url, "anvil_setNonce", [address, account.get("nonce", "0x0")])
        if int(account.get("balance", "0x0"), 16):
            rpc(url, "anvil_setBalance", [address, account["balance"]])
        for slot, value in account.get("storage", {}).items():
            rpc(url, "anvil_setStorageAt", [address, slot, "0x" + value[2:].rjust(64, "0")])
            slots += 1
    print(f"loaded {len(state)} accounts, {slots} storage slots")


if __name__ == "__main__":
    main()
