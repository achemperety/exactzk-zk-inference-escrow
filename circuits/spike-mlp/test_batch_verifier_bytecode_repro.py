#!/usr/bin/env python3
"""
test_batch_verifier_bytecode_repro.py — K=8 batch verifier bytecode
reproducibility check for run_mnist_mw_k8, as run on a second machine
(Host A, arm64/macOS) after the reference run on Host B (x86_64).

Two independent create_evm_verifier()+deploy_evm() runs from different tmp
paths, then keccak256_from_code() (the canonical strip_cbor_metadata-aware
function from passport_attest.py) against each deployment. Reports the
metadata-stripped hash for comparison against the Host B reference:
    d0cab4041caaf77ea95fe45a29d14950be503ce26eb982af11026634112d8c67

Run from circuits/spike-mlp/:
    python3 test_batch_verifier_bytecode_repro.py
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
from passport_attest import strip_cbor_metadata, keccak256_from_code  # noqa: E402

ARTIFACTS_DIR = os.path.join(SCRIPT_DIR, "run_mnist_mw_k8")

ANVIL_PORT = 8550  # distinct from other bytecode-repro scripts (8549 used by solo)
RPC_URL = f"http://localhost:{ANVIL_PORT}"
PRIVATE_KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
FOUNDRY_BIN = os.path.expanduser("~/.foundry/bin")

VK_PATH = os.path.join(ARTIFACTS_DIR, "vk.key")
SETTINGS_PATH = os.path.join(ARTIFACTS_DIR, "settings.json")
SRS_PATH = os.path.join(ARTIFACTS_DIR, "srs.bin")
ONNX_PATH = os.path.join(ARTIFACTS_DIR, "model_k8.onnx")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


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


def main():
    print("=== batch (K=8) verifier bytecode reproducibility (Host A, arm64/macOS) ===\n")

    for label, path in [("model_k8.onnx", ONNX_PATH), ("settings.json", SETTINGS_PATH),
                         ("srs.bin", SRS_PATH), ("vk.key", VK_PATH)]:
        print(f"  pinned input {label:20s} sha256={sha256_file(path)}")
    print()

    print(f"Starting Anvil on port {ANVIL_PORT} ...")
    anvil = start_anvil()

    results = {}
    try:
        from web3 import Web3
        w3 = Web3(Web3.HTTPProvider(RPC_URL))

        for run_id, dirprefix in (("1", "batch_verifier_gen_hostA_"), ("2", "batch_verifier_gen2_hostA_")):
            tmpdir = tempfile.mkdtemp(prefix=dirprefix)
            print(f"\n--- Run {run_id} ({tmpdir}) ---")
            sol_path = os.path.join(tmpdir, "Halo2Verifier_k8.sol")
            abi_path = os.path.join(tmpdir, "Halo2Verifier_k8.abi")
            addr_path = os.path.join(tmpdir, "verifier_k8.addr")

            t0 = time.perf_counter()
            run_async(create_evm_verifier_async, sol_path, abi_path)
            sol_sha = sha256_file(sol_path)
            print(f"  create_evm_verifier done in {time.perf_counter()-t0:.2f}s")
            print(f"  Halo2Verifier_k8.sol sha256={sol_sha}  ({os.path.getsize(sol_path):,} bytes)")

            t0 = time.perf_counter()
            addr = run_async(deploy_evm_async, sol_path, addr_path)
            print(f"  deploy_evm done in {time.perf_counter()-t0:.2f}s -> {addr}")

            code = w3.eth.get_code(Web3.to_checksum_address(addr))
            code_hex = "0x" + code.hex() if not code.hex().startswith("0x") else code.hex()
            raw_hash = Web3.keccak(code).hex()
            stripped_hex = strip_cbor_metadata(code_hex)
            stripped_hash = keccak256_from_code(w3, addr).hex()

            print(f"  total bytecode:              {len(code):,} bytes")
            print(f"  raw eth_getCode keccak256:   {raw_hash}")
            print(f"  metadata-stripped keccak256: {stripped_hash}")

            trailer_len = (len(code_hex) - len(stripped_hex)) // 2
            print(f"  trailer ({trailer_len} bytes): {code_hex[len(stripped_hex):]}")

            results[run_id] = {
                "sol_sha256": sol_sha, "addr": addr,
                "raw_hash": raw_hash, "stripped_hash": stripped_hash,
            }
    finally:
        print("\nStopping Anvil...")
        stop_anvil(anvil)

    print("\n\n=== Comparisons ===\n")
    sol_match = results["1"]["sol_sha256"] == results["2"]["sol_sha256"]
    print(f"  Halo2Verifier_k8.sol sha256, run1 vs run2   : {'MATCH' if sol_match else 'DIVERGE'}")
    raw_match = results["1"]["raw_hash"] == results["2"]["raw_hash"]
    print(f"  raw eth_getCode keccak256, run1 vs run2     : {'MATCH' if raw_match else 'DIVERGE (expected — different tmp paths)'}")
    stripped_match = results["1"]["stripped_hash"] == results["2"]["stripped_hash"]
    print(f"  metadata-stripped keccak256, run1 vs run2   : {'MATCH' if stripped_match else 'DIVERGE'}")

    REFERENCE = "d0cab4041caaf77ea95fe45a29d14950be503ce26eb982af11026634112d8c67"
    print(f"\n=== Host B reference (x86_64) ===")
    print(f"  reference: {REFERENCE}")
    print(f"  run 1:     {results['1']['stripped_hash']}   {'MATCH' if results['1']['stripped_hash'] == REFERENCE else 'DIVERGE'}")
    print(f"  run 2:     {results['2']['stripped_hash']}   {'MATCH' if results['2']['stripped_hash'] == REFERENCE else 'DIVERGE'}")

    all_match = sol_match and stripped_match and results["1"]["stripped_hash"] == REFERENCE
    print(f"\nALL CHECKS PASS (same-host stable + matches Host B reference): {all_match}")
    return 0 if all_match else 1


if __name__ == "__main__":
    sys.exit(main())
