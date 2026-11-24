#!/usr/bin/env python3
"""
test_verifier_bytecode_repro.py — same-host reproducibility test for the
deployed verifier bytecode, whose keccak256 is what a client compares.

Earlier runs confirmed vk.key is cross-machine reproducible. This script asks
the next question: is the DOWNSTREAM artifact — the deployed Halo2Verifier.sol
bytecode that keccak256(eth_getCode(...)) hashes — also reproducible? That
pipeline has two extra steps vk.key doesn't go through:
    vk.key -> [ezkl.create_evm_verifier] -> Halo2Verifier.sol -> [ezkl.deploy_evm / solc] -> bytecode

Isolates which step (if any) introduces divergence by running 4 deployments
from the same pinned run_t3_k5_nonces/{vk.key,settings.json,srs.bin}:
    A, B — fresh create_evm_verifier() each time, then deploy_evm()
           (tests source-regeneration determinism + full pipeline)
    C, D — deploy_evm() of the SAME already-committed Halo2Verifier.sol,
           called twice (tests solc-compile determinism in isolation,
           holding source bytes fixed)

Run from circuits/spike-mlp/:
    python3 test_verifier_bytecode_repro.py
"""

import asyncio
import hashlib
import os
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from passport_attest import strip_cbor_metadata  # noqa: E402 — canonical impl

ARTIFACTS_DIR = os.path.join(SCRIPT_DIR, "run_t3_k5_nonces")

ANVIL_PORT = 8549  # distinct from 8545/8546/8547/8548 used by other scripts
RPC_URL = f"http://localhost:{ANVIL_PORT}"
# Anvil account 0 (deterministic) — same key used by setup_test_fixtures.py
PRIVATE_KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
FOUNDRY_BIN = os.path.expanduser("~/.foundry/bin")

VK_PATH = os.path.join(ARTIFACTS_DIR, "vk.key")
SETTINGS_PATH = os.path.join(ARTIFACTS_DIR, "settings.json")
SRS_PATH = os.path.join(ARTIFACTS_DIR, "srs.bin")
COMMITTED_SOL_PATH = os.path.join(ARTIFACTS_DIR, "Halo2Verifier.sol")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def keccak256_hex(data: bytes) -> str:
    from web3 import Web3
    return Web3.keccak(data).hex()


def start_anvil():
    proc = subprocess.Popen(
        [os.path.join(FOUNDRY_BIN, "anvil"),
         "--port", str(ANVIL_PORT), "--block-time", "1", "--silent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(2)
    return proc


def stop_anvil(proc):
    proc.terminate()
    proc.wait()


async def create_evm_verifier_async(sol_path: str, abi_path: str):
    import ezkl
    result = ezkl.create_evm_verifier(
        vk_path=VK_PATH,
        settings_path=SETTINGS_PATH,
        sol_code_path=sol_path,
        abi_path=abi_path,
        srs_path=SRS_PATH,
        reusable=False,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result
    await asyncio.sleep(2)


async def deploy_evm_async(sol_path: str, addr_path: str):
    import ezkl
    result = ezkl.deploy_evm(
        addr_path=addr_path,
        rpc_url=RPC_URL,
        sol_code_path=sol_path,
        optimizer_runs=1,
        private_key=PRIVATE_KEY,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result
    await asyncio.sleep(2)
    with open(addr_path) as f:
        return f.read().strip()


def run_async(coro_fn, *args):
    loop = asyncio.new_event_loop()
    try:
        result = loop.run_until_complete(coro_fn(*args))
        loop.run_until_complete(asyncio.sleep(2))
        return result
    finally:
        loop.close()


def get_bytecode(address: str) -> str:
    result = subprocess.run(
        [os.path.join(FOUNDRY_BIN, "cast"), "code", address, "--rpc-url", RPC_URL],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def main():
    print("=== verifier bytecode reproducibility (same-host) ===\n")

    for label, path in [("vk.key", VK_PATH), ("settings.json", SETTINGS_PATH),
                         ("srs.bin", SRS_PATH), ("Halo2Verifier.sol (committed)", COMMITTED_SOL_PATH)]:
        print(f"  pinned input {label:32s} sha256={sha256_file(path)}")
    print()

    print(f"Starting Anvil on port {ANVIL_PORT} ...")
    anvil = start_anvil()

    results = {}
    try:
        tmpdir = tempfile.mkdtemp(prefix="pg_bytecode_repro_")

        # --- Runs A, B: fresh create_evm_verifier() each time, then deploy ---
        for run_id in ("A", "B"):
            print(f"\n--- Run {run_id}: fresh create_evm_verifier() + deploy_evm() ---")
            sol_path = os.path.join(tmpdir, f"Halo2Verifier_{run_id}.sol")
            abi_path = os.path.join(tmpdir, f"Halo2Verifier_{run_id}.abi")
            addr_path = os.path.join(tmpdir, f"verifier_{run_id}.addr")

            t0 = time.perf_counter()
            run_async(create_evm_verifier_async, sol_path, abi_path)
            print(f"  create_evm_verifier done in {time.perf_counter()-t0:.2f}s")
            sol_sha = sha256_file(sol_path)
            print(f"  generated Halo2Verifier.sol sha256={sol_sha}  ({os.path.getsize(sol_path):,} bytes)")

            t0 = time.perf_counter()
            addr = run_async(deploy_evm_async, sol_path, addr_path)
            print(f"  deploy_evm done in {time.perf_counter()-t0:.2f}s -> {addr}")

            code = get_bytecode(addr)
            code_hash = keccak256_hex(bytes.fromhex(code[2:]))
            print(f"  eth_getCode: {(len(code)-2)//2:,} bytes  keccak256={code_hash}")

            results[run_id] = {"sol_path": sol_path, "sol_sha256": sol_sha,
                                "addr": addr, "code": code, "code_keccak256": code_hash}

        # --- Runs C, D: deploy the SAME already-committed .sol twice ---
        for run_id in ("C", "D"):
            print(f"\n--- Run {run_id}: deploy_evm() of committed Halo2Verifier.sol (unchanged source) ---")
            addr_path = os.path.join(tmpdir, f"verifier_{run_id}.addr")

            t0 = time.perf_counter()
            addr = run_async(deploy_evm_async, COMMITTED_SOL_PATH, addr_path)
            print(f"  deploy_evm done in {time.perf_counter()-t0:.2f}s -> {addr}")

            code = get_bytecode(addr)
            code_hash = keccak256_hex(bytes.fromhex(code[2:]))
            print(f"  eth_getCode: {(len(code)-2)//2:,} bytes  keccak256={code_hash}")

            results[run_id] = {"addr": addr, "code": code, "code_keccak256": code_hash}

    finally:
        print("\nStopping Anvil...")
        stop_anvil(anvil)

    # --- Comparisons ---
    print("\n\n=== Comparisons ===\n")

    def cmp(name, a_key, b_key, field="code"):
        a, b = results[a_key][field], results[b_key][field]
        match = a == b
        print(f"  {name:55s} {'MATCH' if match else 'DIVERGE'}")
        return match

    print("1. Source regeneration determinism (create_evm_verifier called twice):")
    src_match = results["A"]["sol_sha256"] == results["B"]["sol_sha256"]
    print(f"   Halo2Verifier_A.sol sha256 == Halo2Verifier_B.sol sha256  {'MATCH' if src_match else 'DIVERGE'}")

    print("\n2. Full-pipeline bytecode determinism (fresh regen + deploy, A vs B):")
    ab_match = cmp("eth_getCode(A) == eth_getCode(B)", "A", "B")

    print("\n3. Solc-compile determinism in isolation (same committed source, C vs D):")
    cd_match = cmp("eth_getCode(C) == eth_getCode(D)", "C", "D")

    print("\n4. Fresh regen vs. committed artifact (A vs C):")
    ac_match = cmp("eth_getCode(A) == eth_getCode(C)", "A", "C")

    a_stripped = strip_cbor_metadata(results["A"]["code"])
    b_stripped = strip_cbor_metadata(results["B"]["code"])
    stripped_match = a_stripped == b_stripped
    print(f"\n5. Executable-only (CBOR-metadata-stripped) bytecode, A vs B:")
    print(f"   {'MATCH' if stripped_match else 'DIVERGE'}")
    if not ab_match:
        if stripped_match:
            print("   -> raw eth_getCode divergence (check 2) is confined to the trailing CBOR")
            print("      metadata (source-path-derived IPFS hash), NOT the executable logic.")
            print("      This is EXPECTED: A and B used different tmp filenames by construction.")
        else:
            print("   -> divergence extends into the executable portion (semantic, NOT just metadata).")

    if not cd_match:
        print("\n   C vs D diverged with byte-identical source input AND identical compile path")
        print("   — this would indicate solc itself is nondeterministic, unlike the expected")
        print("   path-only divergence above.")

    print("\n=== Summary ===")
    print(f"  source regen (create_evm_verifier) reproducible      : {src_match}")
    print(f"  raw eth_getCode, same compile path (C vs D)          : {cd_match}")
    print(f"  raw eth_getCode, different compile paths (A vs B)    : {ab_match}  (expected False — see below)")
    print(f"  executable-only, metadata stripped (A vs B)          : {stripped_match}")

    # The real reproducibility verdict for a *third-party* attester (who will
    # inevitably compile from a different filesystem path than the original
    # deployer) is the metadata-stripped comparison, not raw eth_getCode.
    all_match = src_match and cd_match and stripped_match
    print(f"\n  ALL SAME-HOST CHECKS PASS (metadata-aware): {all_match}")
    if ab_match is False and stripped_match:
        print("  NOTE: raw eth_getCode is path-sensitive (solc metadata) — do not hash it directly")
        print("        for cross-attester comparison; strip CBOR metadata first.")

    return 0 if all_match else 1


if __name__ == "__main__":
    sys.exit(main())
