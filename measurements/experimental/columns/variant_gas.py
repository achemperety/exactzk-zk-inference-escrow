"""Gas of each EXPERIMENTAL verifier (column count, arg-max head) against its own proof, on a local node under Osaka.

    python3 variant_gas.py <variants dir> <rpc>

For each variant: deploy its generated verifier through EZKL (its own compilation path, as for the
pinned verifiers), send one verifyProof transaction with its proof, and split the receipt's gas into
intrinsic, calldata and execution. No proving here; the proofs were made on 2 vCPUs of an Intel Xeon Gold 5220R.
"""
import asyncio, json, os, subprocess, sys

import ezkl

root, rpc = sys.argv[1], sys.argv[2]
KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # Anvil's published account 0


def cast(*a):
    return subprocess.run(["cast", *a], capture_output=True, text=True, check=True).stdout.strip()


async def deploy(sol, addr_file):
    r = ezkl.deploy_evm(addr_file, rpc, sol, private_key=KEY)
    if asyncio.iscoroutine(r) or asyncio.isfuture(r):
        await r
    return open(addr_file).read().strip()


loop = asyncio.new_event_loop()
rows = []
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if not os.path.exists(os.path.join(d, "result.json")):
        continue
    r = json.load(open(os.path.join(d, "result.json")))
    addr = loop.run_until_complete(deploy(os.path.join(d, "Verifier.sol"), os.path.join(d, "addr.txt")))
    code = cast("code", addr, "-r", rpc)
    p = json.load(open(os.path.join(d, "proof.json")))
    proof = bytes(p["proof"]) if isinstance(p["proof"], list) else bytes.fromhex(p["proof"].removeprefix("0x"))
    inst = [int.from_bytes(bytes.fromhex(s), "little") for s in p["instances"][0]]
    data = cast("calldata", "verifyProof(bytes,uint256[])", "0x" + proof.hex(), "[" + ",".join(map(str, inst)) + "]")
    ok = cast("call", addr, data, "-r", rpc)
    tx = json.loads(cast("send", addr, data, "-r", rpc, "--private-key", "0x" + KEY, "--json"))
    gas = int(tx["gasUsed"], 16)
    b = bytes.fromhex(data[2:])
    z = b.count(0)
    std, floor = 4 * z + 16 * (len(b) - z), 10 * z + 40 * (len(b) - z)
    row = {
        "variant": name, "num_inner_cols": r["num_inner_cols"], "argmax_head": r["argmax_head"], "logrows": r["logrows"],
        "num_rows": r["num_rows"], "public_instances": r["public_instances"], "vk_bytes": r["vk_bytes"], "pk_bytes": r["pk_bytes"],
        "setup_s": r["steps"]["setup"]["seconds"], "prove_s": r["steps"]["prove"]["seconds"],
        "peak_rss_mb": max(s["peak_rss_mb"] for s in r["steps"].values()), "verified_offchain": r["verified"],
        "verifier_runtime_bytes": (len(code) - 2) // 2, "proof_bytes": len(proof), "verify_call_returned_true": int(ok, 16) == 1,
        "tx_gas": gas, "calldata_gas": std, "calldata_floor": floor, "execution_gas": gas - 21000 - std,
        "floor_binds": 21000 + floor > gas,
    }
    rows.append(row)
    print(json.dumps(row), flush=True)
json.dump(rows, open(os.path.join(root, "gas.json"), "w"), indent=2)
loop.run_until_complete(asyncio.sleep(1))
loop.close()
