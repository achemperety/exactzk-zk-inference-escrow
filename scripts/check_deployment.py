#!/usr/bin/env python3
"""Check a deployment made by script/DeployBaseSepolia.s.sol, read-only, against the chain.

    python3 scripts/check_deployment.py <broadcast run json> <rpc-url> [--write deployments/base-sepolia.json]

From Forge's broadcast file it takes only the transaction hashes. Everything else is read from the
chain through the given endpoint: each receipt (status, block, created address), the runtime code of
every created contract, the verifier entries, the seeds and every link. Our contracts are compared
with this checkout's build (`forge build` first; compiled without metadata, immutables zeroed on both
sides); the two EZKL verifiers with the code hashes in circuits/spike-mlp/MANIFEST.md. The ERC-8004
registries and x402's escrow are the ones script/DeployBaseSepolia.s.sol names. With --write it records
the addresses of the contracts this deployment created, and nothing else, in the given file.
"""
import json, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAST = shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")
SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ENTRY = "entry(bytes32)((address,uint32,uint32,uint32,address,bytes32,bytes32,bytes32,bytes32))"
OURS = ["VerifierRegistry", "Halo2EzklAdapter", "SoloSettlement", "ChannelSettlement",
        "ProofEvaluator8183", "ProofValidator8004", "AuthCaptureProofOperator"]
failures = []


def cast(*args):
    return subprocess.run([CAST, *args], capture_output=True, text=True, check=True).stdout.strip()


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures.append(what)


def script_constant(name):
    text = open(os.path.join(ROOT, "script/DeployBaseSepolia.s.sol")).read()
    return re.search(name + r"\s*[:=]\s*(0x[0-9a-fA-F]+)", text).group(1)


def manifest_hashes():
    text = open(os.path.join(ROOT, "circuits/spike-mlp/MANIFEST.md")).read()
    pinned = re.findall(r"as pinned \(what `EXTCODEHASH` returns\) \| `(0x[0-9a-f]{64})`", text)
    vk = re.findall(r"`keccak256\(vk\.key\)` \| `(0x[0-9a-f]{64})`", text)
    assert len(pinned) == 2 and len(vk) == 2
    return {"solo": (pinned[0], vk[0]), "k8": (pinned[1], vk[1])}


def zeroed(code, refs):
    b = bytearray(code)
    for start, length in refs:
        b[start : start + length] = bytes(length)
    return bytes(b)


def built(name):
    art = json.load(open(os.path.join(ROOT, f"out/{name}.sol/{name}.json")))["deployedBytecode"]
    refs = [(r["start"], r["length"]) for rs in art.get("immutableReferences", {}).values() for r in rs]
    return bytes.fromhex(art["object"][2:]), refs


def main():
    run_file, rpc = sys.argv[1], sys.argv[2]
    out = sys.argv[sys.argv.index("--write") + 1] if "--write" in sys.argv else None
    run = json.load(open(run_file))
    check(cast("chain-id", "--rpc-url", rpc) == "84532", "the endpoint serves chain id 84532")
    head = cast("block-number", "--rpc-url", rpc)
    print(f"read at block {head}")

    created, blocks = {}, []
    verifiers = []
    for t in run["transactions"]:
        r = json.loads(cast("receipt", t["hash"], "--json", "--rpc-url", rpc))
        blocks.append(int(r["blockNumber"], 16))
        label = t.get("contractName") or t.get("function") or "?"
        check(r["status"] == "0x1", f"{label}: transaction {t['hash'][:10]}… succeeded in block {blocks[-1]}")
        if t["transactionType"] == "CREATE":
            addr = cast("to-check-sum-address", r["contractAddress"])
            check(addr.lower() == (t["contractAddress"] or "").lower(), f"{label}: receipt creates {addr}")
            if t.get("contractName"):
                created[t["contractName"]] = addr
            else:
                verifiers.append(addr)
    check(len(verifiers) == 2, "two contracts created from raw runtime bytes (the verifiers)")
    solo_v, k8_v = verifiers

    for name in OURS:
        live = bytes.fromhex(cast("code", created[name], "--rpc-url", rpc, "--block", head)[2:])
        code, refs = built(name)
        same = len(live) == len(code) and zeroed(live, refs) == zeroed(code, refs)
        check(same, f"{name} at {created[name]}: {len(live)} bytes, equal to this checkout's build ({len(refs)} immutable references zeroed)")

    pins = manifest_hashes()
    ids = {"solo": script_constant("SOLO_ID"), "k8": script_constant("K8_ID")}
    shape = {"solo": (1, 600000), "k8": (8, 660000)}
    registry, adapter = created["VerifierRegistry"], created["Halo2EzklAdapter"]
    adapter_hash = cast("keccak", cast("code", adapter, "--rpc-url", rpc, "--block", head))
    for key, addr in (("solo", solo_v), ("k8", k8_v)):
        code_hash, vk_hash = pins[key]
        live_hash = cast("keccak", cast("code", addr, "--rpc-url", rpc, "--block", head))
        check(live_hash == code_hash, f"{key} verifier at {addr}: code hash {live_hash} equals MANIFEST.md")
        check(cast("call", registry, "exists(bytes32)(bool)", ids[key], "--rpc-url", rpc) == "true", f"{key} id {ids[key]} registered")
        e = [x.strip() for x in cast("call", registry, ENTRY, ids[key], "--rpc-url", rpc).strip("()").split(",")]
        lanes, gas = shape[key]
        expect = [adapter.lower(), str(lanes), "320", str(gas), addr.lower(), adapter_hash, code_hash, vk_hash, "0x" + "0" * 64]
        got = [e[0].lower(), e[1], e[2], e[3].split()[0], e[4].lower(), e[5], e[6], e[7], e[8]]
        check(got == expect, f"{key} entry: adapter, {lanes} lane(s), 320 output bytes, verifyGas {gas}, target, both code hashes, vk hash")

    usdc = script_constant("usdc")
    for name in ("SoloSettlement", "ChannelSettlement"):
        bal = cast("call", usdc, "balanceOf(address)(uint256)", created[name], "--rpc-url", rpc, "--block", head).split()[0]
        # Exactly the seed right after deployment; afterwards the contracts also hold what payers have
        # locked or deposited and what providers have not yet withdrawn.
        check(int(bal) >= 1, f"{name} holds {bal} unit(s) of USDC, its one-unit seed included")

    validation = script_constant("validationRegistry")
    for name in ("SoloSettlement", "ChannelSettlement", "ProofEvaluator8183", "ProofValidator8004", "AuthCaptureProofOperator"):
        got = cast("call", created[name], "registry()(address)", "--rpc-url", rpc)
        check(got.lower() == registry.lower(), f"{name}.registry() is the VerifierRegistry")
    got = cast("call", created["ProofValidator8004"], "validationRegistry()(address)", "--rpc-url", rpc)
    check(got.lower() == validation.lower(), f"ProofValidator8004.validationRegistry() is the ERC-8004 authors' testnet registry {validation}")
    impl = "0x" + cast("storage", validation, SLOT, "--rpc-url", rpc, "--block", head)[-40:]
    check(impl.lower() == script_constant("validationImplementation").lower(), f"that registry's implementation is still {impl}")
    escrow = script_constant("escrow")
    got = cast("call", created["AuthCaptureProofOperator"], "escrow()(address)", "--rpc-url", rpc)
    check(got.lower() == escrow.lower(), f"AuthCaptureProofOperator.escrow() is x402's canonical escrow {escrow}")

    if failures:
        sys.exit(f"{len(failures)} check(s) failed")
    print("all checks passed")
    if out:
        commit = subprocess.run(["git", "-C", ROOT, "rev-parse", run["commit"]], capture_output=True, text=True, check=True).stdout.strip()
        ts = int(cast("block", str(min(blocks)), "--field", "timestamp", "--rpc-url", rpc))
        record = {
            "network": "Base Sepolia",
            "chainId": 84532,
            "commit": commit,
            "blocks": [min(blocks), max(blocks)],
            "date": subprocess.run(["date", "-u", "-r", str(ts), "+%Y-%m-%d"], capture_output=True, text=True).stdout.strip(),
            "contracts": {
                "VerifierRegistry": created["VerifierRegistry"],
                "Halo2EzklAdapter": created["Halo2EzklAdapter"],
                "soloVerifier": solo_v,
                "k8Verifier": k8_v,
                "SoloSettlement": created["SoloSettlement"],
                "ChannelSettlement": created["ChannelSettlement"],
                "ProofEvaluator8183": created["ProofEvaluator8183"],
                "ProofValidator8004": created["ProofValidator8004"],
                "AuthCaptureProofOperator": created["AuthCaptureProofOperator"],
            },
            "verifierIds": {"solo": ids["solo"], "k8": ids["k8"]},
        }
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w") as f:
            json.dump(record, f, indent=2)
            f.write("\n")
        print("wrote", out)


if __name__ == "__main__":
    main()
