#!/usr/bin/env python3
"""Check a verifier registry entry against the published circuit files, read-only.

From the published files of a circuit, regenerate what the chain runs and compare it with the
entry registered on Base Sepolia:

    model file + pinned settings.json + SRS  --EZKL key setup------------>  verifying key
    verifying key + settings.json + SRS      --EZKL create_evm_verifier--->  verifier source
    verifier source                          --solc 0.8.20, optimizer, 1 run->  runtime bytecode

and then, from the chain (eth_call and eth_getCode only; nothing is signed or sent):

    keccak256(verifying key)                  == the entry's vkHash
    runtime bytecode, metadata trailer removed == the entry's verifier code, trailer removed
    keccak256(the verifier's code)            == the entry's targetCodeHash
    the entry's fields                        hash to the verifier id that was asked for

Every input file is first compared with its SHA-256 in provenance/. The pinned settings.json is
part of the circuit's identity: settings regenerated from the model can order their range checks
differently and give another verifying key.

    python3 scripts/verify_entry.py solo             model -> key -> verifier -> chain
    python3 scripts/verify_entry.py k8 --from-vk     pinned key -> verifier -> chain

--from-vk skips the key setup and starts from the pinned vk.key (still checked against its
SHA-256): the step that needs no model weights. The key setup needs EZKL 23.0.5 and, measured,
about 1 GB of memory for the solo circuit and about 6.3 GB for the K=8 circuit.

Exit status 0 only if every comparison matches. Needs Python 3.10+ and the ezkl package (23.0.5);
solc 0.8.20 is taken from --solc or downloaded from binaries.soliditylang.org and checked against
its published SHA-256. The unit tests (scripts/test_verify_entry.py) need neither.
"""

import argparse
import hashlib
import json
import os
import platform
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The current deployment, v3.1. deployments/base-sepolia.json is v3.0: its entries stay valid but carry
# the known issue in docs/known-issues/2026-11-out-of-gas-as-invalid.md.
DEFAULT_DEPLOYMENT = os.path.join(REPO, "deployments", "base-sepolia-v3.1.json")

CIRCUITS = {
    "solo": {"dir": "circuits/spike-mlp/run_t3_k5_nonces", "model": "model.onnx", "sol": "Halo2Verifier.sol", "lanes": 1},
    "k8": {"dir": "circuits/spike-mlp/run_mnist_mw_k8", "model": "model_k8.onnx", "sol": "Halo2Verifier_k8.sol", "lanes": 8},
}
OUTPUT_SIZE = 320  # ten outputs per lane, one 32-byte word each
PROOF_SYSTEM_TAG = b"halo2-kzg-bn254/ezkl"  # Halo2EzklAdapter.PROOF_SYSTEM is its keccak256
EXPECTED_CHAIN_ID = 84532

# The compiler EZKL 23.0.5 used for the pinned verifiers (the version in their metadata trailer),
# with the options that reproduce their bytecode. Release builds and their SHA-256 as listed in
# binaries.soliditylang.org/<platform>/list.json.
SOLC_VERSION = "0.8.20+commit.a1b79de6"
SOLC_ARGS = ["--optimize", "--optimize-runs", "1", "--bin-runtime"]
SOLC_BUILDS = {
    "Linux": ("linux-amd64/solc-linux-amd64-v0.8.20+commit.a1b79de6",
              "0479d44fdf9c501c25337fdc540419f1593b884a87b47f023da4f1c700fda782"),
    "Darwin": ("macosx-amd64/solc-macosx-amd64-v0.8.20+commit.a1b79de6",
               "fc329945e0068e4e955d0a7b583776dc8d25e72ab657a044618a7ce7dd0519aa"),
}
SOLC_VERSION_BYTES = bytes([0, 8, 20])

# ── keccak256, in pure Python (about 1 s per MB) ────────────────────────────────────────────────

_M64 = (1 << 64) - 1
_RC = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)
_ROT = ((0, 36, 3, 41, 18), (1, 44, 10, 45, 2), (62, 6, 43, 15, 61), (28, 55, 25, 21, 56), (27, 20, 39, 8, 14))
_PI = tuple((x + 5 * y, y + 5 * ((2 * x + 3 * y) % 5), _ROT[x][y]) for x in range(5) for y in range(5))


def _keccak_f(a):
    for rc in _RC:
        c = [a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] for x in range(5)]
        for x in range(5):
            n = c[(x + 1) % 5]
            d = c[(x + 4) % 5] ^ (((n << 1) | (n >> 63)) & _M64)
            for y in range(x, 25, 5):
                a[y] ^= d
        b = [0] * 25
        for src, dst, r in _PI:
            v = a[src]
            b[dst] = (((v << r) | (v >> (64 - r))) & _M64) if r else v
        for y in range(0, 25, 5):
            b0, b1, b2, b3, b4 = b[y:y + 5]
            a[y], a[y + 1], a[y + 2], a[y + 3], a[y + 4] = (
                b0 ^ (~b1 & b2), b1 ^ (~b2 & b3), b2 ^ (~b3 & b4), b3 ^ (~b4 & b0), b4 ^ (~b0 & b1))
        a[0] ^= rc


def keccak256(data: bytes) -> bytes:
    rate = 136
    buf = bytearray(data)
    buf.append(0x01)
    buf.extend(b"\x00" * (-len(buf) % rate))
    buf[-1] |= 0x80
    a = [0] * 25
    for off in range(0, len(buf), rate):
        for i in range(rate // 8):
            a[i] ^= int.from_bytes(buf[off + 8 * i:off + 8 * i + 8], "little")
        _keccak_f(a)
    return b"".join(a[i].to_bytes(8, "little") for i in range(4))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def hx(b: bytes) -> str:
    return "0x" + bytes(b).hex()


# ── solc's metadata trailer ─────────────────────────────────────────────────────────────────────


def split_trailer(code: bytes):
    """Split runtime bytecode into (code, trailer), where the trailer is solc 0.8.20's default
    metadata: CBOR {"ipfs": <34-byte multihash>, "solc": <3-byte version>} and its 2-byte length.
    The trailer hashes the compiler's metadata, which includes the path the source was compiled
    from; it is never executed. Raises ValueError unless the trailer has exactly that form, so
    nothing but the metadata hash can differ between the two sides of a comparison."""
    code = bytes(code)
    if len(code) < 53:
        raise ValueError("code shorter than a metadata trailer")
    trailer = code[-53:]
    ok = (trailer[-2:] == b"\x00\x33"
          and trailer[:10] == b"\xa2\x64ipfs\x58\x22\x12\x20"
          and trailer[42:48] == b"\x64solc\x43"
          and trailer[48:51] == SOLC_VERSION_BYTES)
    if not ok:
        raise ValueError("no solc 0.8.20 metadata trailer of the expected form")
    return code[:-53], trailer


# ── ABI helpers for the registry ────────────────────────────────────────────────────────────────

ENTRY_FIELDS = ("adapter", "lanes", "outputSize", "verifyGas", "target",
                "adapterCodeHash", "targetCodeHash", "vkHash", "emptyLane")


def selector(sig: str) -> bytes:
    return keccak256(sig.encode())[:4]


def decode_entry(raw: bytes) -> dict:
    """VerifierEntry is a static struct, so entry() returns its nine words inline."""
    if len(raw) != 9 * 32:
        raise ValueError(f"entry() returned {len(raw)} bytes, expected 288")
    w = [raw[32 * i:32 * i + 32] for i in range(9)]
    return {
        "adapter": hx(w[0][12:]), "lanes": int.from_bytes(w[1], "big"), "outputSize": int.from_bytes(w[2], "big"),
        "verifyGas": int.from_bytes(w[3], "big"), "target": hx(w[4][12:]), "adapterCodeHash": hx(w[5]),
        "targetCodeHash": hx(w[6]), "vkHash": hx(w[7]), "emptyLane": hx(w[8]),
    }


def compute_id(proof_system: bytes, e: dict) -> bytes:
    """VerifierRegistry.computeId: every field but the two addresses."""
    words = [proof_system, bytes.fromhex(e["vkHash"][2:]), bytes.fromhex(e["targetCodeHash"][2:]),
             bytes.fromhex(e["adapterCodeHash"][2:]), e["lanes"].to_bytes(32, "big"),
             e["outputSize"].to_bytes(32, "big"), e["verifyGas"].to_bytes(32, "big"), bytes.fromhex(e["emptyLane"][2:])]
    return keccak256(b"".join(words))


# ── Chain access (read-only JSON-RPC) ───────────────────────────────────────────────────────────


class Chain:
    def __init__(self, url):
        self.url, self.block = url, "latest"

    def rpc(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json", "User-Agent": "verify-entry"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    out = json.load(r)
                if "error" in out:
                    raise RuntimeError(f"{method}: {out['error']}")
                return out["result"]
            except Exception:
                if attempt == 3:
                    raise
                time.sleep(2 * (attempt + 1))

    def pin_block(self):
        self.block = self.rpc("eth_blockNumber", [])
        return int(self.block, 16)

    def chain_id(self):
        return int(self.rpc("eth_chainId", []), 16)

    def call(self, to, data: bytes) -> bytes:
        return bytes.fromhex(self.rpc("eth_call", [{"to": to, "data": hx(data)}, self.block])[2:])

    def code(self, addr) -> bytes:
        return bytes.fromhex(self.rpc("eth_getCode", [addr, self.block])[2:])


def read_entry(chain, registry, verifier_id: bytes) -> dict:
    """Everything the comparison needs from the chain, as raw values."""
    raw = chain.call(registry, selector("entry(bytes32)") + verifier_id)
    e = decode_entry(raw)
    view = {"entry": e, "entryRaw": raw,
            "entryHash": chain.call(registry, selector("entryHash(bytes32)") + verifier_id),
            "registryCode": chain.code(registry)}
    if int(e["adapter"], 16):
        view["targetCode"] = chain.code(e["target"])
        view["adapterCode"] = chain.code(e["adapter"])
        view["proofSystem"] = chain.call(e["adapter"], selector("proofSystem()"))
    return view


# ── The comparison ──────────────────────────────────────────────────────────────────────────────


def compare(verifier_id: bytes, view: dict, vk: bytes, runtime: bytes, lanes: int) -> list:
    """Return one row per check: (name, ok, detail). Pure: no file, network or EZKL access."""
    rows = []

    def row(name, ok, detail=""):
        rows.append((name, bool(ok), detail))

    e = view["entry"]
    row("registry has code", len(view["registryCode"]) > 0)
    registered = int.from_bytes(view["entryHash"], "big") != 0 and int(e["adapter"], 16) != 0
    row("entry is registered", registered, hx(verifier_id))
    if not registered:
        return rows
    row("entry() is the registered entry (keccak256 of its encoding = entryHash)",
        keccak256(view["entryRaw"]) == view["entryHash"], hx(view["entryHash"]))
    row("entry shape: lanes", e["lanes"] == lanes, f"{e['lanes']} (circuit: {lanes})")
    row("entry shape: outputSize", e["outputSize"] == OUTPUT_SIZE, f"{e['outputSize']} (circuit: {OUTPUT_SIZE})")
    row("adapter reports the EZKL proof system", view["proofSystem"] == keccak256(PROOF_SYSTEM_TAG), hx(view["proofSystem"]))
    row("verifier id = computeId(proof system, entry)", compute_id(view["proofSystem"], e) == verifier_id,
        hx(compute_id(view["proofSystem"], e)))
    row("adapter's code hash = entry.adapterCodeHash", hx(keccak256(view["adapterCode"])) == e["adapterCodeHash"],
        e["adapterCodeHash"])
    target = view["targetCode"]
    row("verifier's code hash = entry.targetCodeHash", hx(keccak256(target)) == e["targetCodeHash"], e["targetCodeHash"])
    row("verifier is not a delegated account (EIP-7702)", target[:3] != b"\xef\x01\x00")
    vk_hash = hx(keccak256(vk))
    row("keccak256(regenerated verifying key) = entry.vkHash", vk_hash == e["vkHash"], vk_hash)
    try:
        local_code, _ = split_trailer(runtime)
        chain_code, _ = split_trailer(target)
        same = local_code == chain_code
        detail = f"{hx(keccak256(local_code))} ({len(local_code)} bytes) vs {hx(keccak256(chain_code))} ({len(chain_code)} bytes)"
    except ValueError as err:
        same, detail = False, str(err)
    row("regenerated verifier = on-chain verifier, metadata trailer removed", same, detail)
    return rows


def verdict(rows) -> str:
    return "MATCH" if rows and all(ok for _, ok, _ in rows) else "MISMATCH"


# ── Regeneration (EZKL and solc) ────────────────────────────────────────────────────────────────


def pinned_sha256():
    pins = {}
    for name in ("COPIED_FILES.sha256", "SRS.sha256"):
        with open(os.path.join(REPO, "provenance", name)) as f:
            for line in f:
                if line.strip():
                    digest, path = line.split(None, 1)
                    pins[path.strip()] = digest
    return pins


def get_solc(path, cache):
    if not path:
        system = platform.system()
        if system not in SOLC_BUILDS:
            sys.exit(f"no pinned solc build for {system}; pass --solc with a solc {SOLC_VERSION}")
        rel, digest = SOLC_BUILDS[system]
        path = os.path.join(cache, os.path.basename(rel))
        if not os.path.exists(path) or sha256_file(path) != digest:
            os.makedirs(cache, exist_ok=True)
            req = urllib.request.Request(f"https://binaries.soliditylang.org/{rel}", headers={"User-Agent": "verify-entry"})
            with urllib.request.urlopen(req, timeout=120) as r, open(path + ".part", "wb") as f:
                shutil.copyfileobj(r, f)
            if sha256_file(path + ".part") != digest:
                os.remove(path + ".part")
                sys.exit(f"downloaded solc does not have the published SHA-256 {digest}")
            os.replace(path + ".part", path)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    out = subprocess.run([path, "--version"], capture_output=True, text=True, check=True).stdout
    if SOLC_VERSION not in out:
        sys.exit(f"{path} is not solc {SOLC_VERSION}")
    return path


def compile_runtime(solc, sol_path, workdir):
    out = os.path.join(workdir, "solc-out")
    subprocess.run([solc, *SOLC_ARGS, sol_path, "-o", out, "--overwrite"], check=True, capture_output=True)
    with open(os.path.join(out, "Halo2Verifier.bin-runtime")) as f:
        return bytes.fromhex(f.read().strip())


def regenerate(c, args, workdir, timings):
    """Return (vk bytes, verifier source bytes). EZKL is imported only here."""
    import asyncio

    import ezkl

    d = os.path.join(REPO, c["dir"])
    settings = args.settings or os.path.join(d, "settings.json")
    srs = os.path.join(d, "srs.bin")
    loop = asyncio.new_event_loop()

    def run(thunk):
        async def go():
            r = thunk()
            return (await r) if (asyncio.iscoroutine(r) or asyncio.isfuture(r)) else r
        return loop.run_until_complete(go())

    if args.from_vk:
        vk = os.path.join(d, "vk.key")
    else:
        compiled, vk, pk = (os.path.join(workdir, n) for n in ("model.compiled", "vk.key", "pk.key"))
        t = time.time()
        run(lambda: ezkl.compile_circuit(os.path.join(d, c["model"]), compiled, settings))
        run(lambda: ezkl.setup(compiled, vk, pk, srs))
        timings["key setup"] = time.time() - t
        os.remove(pk)  # hundreds of MB; not needed for the comparison
    sol, abi = os.path.join(workdir, "Halo2Verifier.sol"), os.path.join(workdir, "Halo2Verifier.abi")
    t = time.time()
    run(lambda: ezkl.create_evm_verifier(vk, settings, sol, abi, srs))
    timings["verifier source"] = time.time() - t
    loop.run_until_complete(asyncio.sleep(1))
    loop.close()
    with open(vk, "rb") as f1, open(sol, "rb") as f2:
        return f1.read(), f2.read(), sol


def peak_mb():
    """Peak resident set of this process, in which EZKL runs. solc runs as a child and is not
    included (a forked child's own peak would count the pages it shares with this process)."""
    scale = 1 if platform.system() == "Darwin" else 1024  # ru_maxrss: bytes on macOS, KiB on Linux
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * scale / 1e6)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("circuit", choices=sorted(CIRCUITS))
    p.add_argument("--from-vk", action="store_true", help="start from the pinned vk.key; no key setup")
    p.add_argument("--rpc", default="https://sepolia.base.org")
    p.add_argument("--deployment", default=DEFAULT_DEPLOYMENT,
                   help="default: deployments/base-sepolia-v3.1.json; base-sepolia.json is v3.0")
    p.add_argument("--verifier-id", help="default: the deployment file's id for this circuit")
    p.add_argument("--settings", help="another settings.json, to see a mismatch (default: the pinned one)")
    p.add_argument("--solc", help=f"a solc {SOLC_VERSION} binary (default: download the release build)")
    p.add_argument("--solc-cache", default=os.path.expanduser("~/.cache/exactzk-verify-entry"))
    p.add_argument("--json", help="also write the result to this file")
    args = p.parse_args()

    t0 = time.time()
    c = CIRCUITS[args.circuit]
    rows, timings = [], {}
    pins = pinned_sha256()
    inputs = ["settings.json", "srs.bin"] + (["vk.key"] if args.from_vk else [c["model"], c["model"] + ".data"])
    for name in inputs:
        rel = f"{c['dir']}/{name}"
        path = args.settings if (name == "settings.json" and args.settings) else os.path.join(REPO, rel)
        if not os.path.exists(path):
            sys.exit(f"missing {path}" + (" (bash scripts/fetch_srs.sh downloads it)" if name == "srs.bin" else ""))
        got = sha256_file(path)
        rows.append((f"input {name}: SHA-256 = provenance/", got == pins[rel], got))

    with open(args.deployment) as f:
        dep = json.load(f)
    registry = dep["contracts"]["VerifierRegistry"]
    verifier_id = bytes.fromhex((args.verifier_id or dep["verifierIds"][args.circuit])[2:])

    workdir = tempfile.mkdtemp(prefix="verify-entry-")
    try:
        solc = get_solc(args.solc, args.solc_cache)
        vk, source, sol_path = regenerate(c, args, workdir, timings)
        pinned_vk = pins[f"{c['dir']}/vk.key"]
        if not args.from_vk:
            rows.append(("regenerated verifying key: SHA-256 = pinned vk.key", hashlib.sha256(vk).hexdigest() == pinned_vk,
                         hashlib.sha256(vk).hexdigest()))
        src_sha = hashlib.sha256(source).hexdigest()
        rows.append(("regenerated verifier source: SHA-256 = pinned", src_sha == pins[f"{c['dir']}/{c['sol']}"], src_sha))
        t = time.time()
        runtime = compile_runtime(solc, sol_path, workdir)
        timings["compile"] = time.time() - t

        t = time.time()
        chain = Chain(args.rpc)
        chain_id = chain.chain_id()
        block = chain.pin_block()
        rows.append(("chain id", chain_id == EXPECTED_CHAIN_ID, str(chain_id)))
        view = read_entry(chain, registry, verifier_id)
        timings["chain reads"] = time.time() - t
        rows += compare(verifier_id, view, vk, runtime, c["lanes"])
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    result = {
        "circuit": args.circuit, "mode": "from-vk" if args.from_vk else "full", "verifierId": hx(verifier_id),
        "deployment": os.path.relpath(args.deployment, REPO), "rpc": args.rpc, "block": block, "result": verdict(rows),
        "checks": [{"check": n, "ok": o, "detail": d} for n, o, d in rows],
        "seconds": {k: round(v, 2) for k, v in {**timings, "total": time.time() - t0}.items()},
        "peakRssMB": peak_mb(),
        "machine": f"{platform.system()} {platform.machine()}, {os.cpu_count()} logical CPUs",
    }
    for n, o, d in rows:
        print(f"{'MATCH   ' if o else 'MISMATCH'} {n}" + (f"  [{d}]" if d else ""))
    print(f"\n{result['result']}: {args.circuit} ({result['mode']}), entry {hx(verifier_id)}, block {block}")
    print(f"time {result['seconds']}, peak RSS of this process {result['peakRssMB']} MB")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)
    sys.exit(0 if result["result"] == "MATCH" else 1)


if __name__ == "__main__":
    main()
