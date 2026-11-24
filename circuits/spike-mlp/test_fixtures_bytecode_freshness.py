#!/usr/bin/env python3
"""
test_fixtures_bytecode_freshness.py — drift canary for the Foundry test
fixtures: it fails when they no longer embed the verifier the pinned key produces.

contracts/test/fixtures/Fixtures.sol and FixturesK8.sol each embed a
Halo2Verifier's runtime bytecode as a hex literal, generated once and
committed. If vk.key/srs.bin/settings.json are later regenerated without
regenerating these fixtures, Foundry tests keep passing (they vm.etch the
embedded bytecode and never touch the real vk.key), while a real on-chain
verifyProof() call against a freshly-generated verifier would revert — this
exact gap once let a stale K=8 fixture go unnoticed. This script
closes it: it regenerates each verifier fresh from the *current* canonical
artifacts, deploys it locally, and asserts the metadata-stripped bytecode
hash matches what's embedded in the corresponding fixture.

Run from circuits/spike-mlp/:
    python3 test_fixtures_bytecode_freshness.py
Exit code 0 = both fixtures fresh; 1 = at least one is stale.
"""
import asyncio
import os
import re
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
FIXTURES_DIR = os.path.join(PROJECT_ROOT, "test", "fixtures")

sys.path.insert(0, SCRIPT_DIR)
from passport_attest import strip_cbor_metadata  # noqa: E402

FOUNDRY_BIN = os.path.expanduser("~/.foundry/bin")
ANVIL_PORT = 8548  # distinct from other bytecode-repro scripts in this dir
RPC_URL = f"http://localhost:{ANVIL_PORT}"
PRIVATE_KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

CASES = [
    {
        "label": "solo",
        "artifacts_dir": os.path.join(SCRIPT_DIR, "run_t3_k5_nonces"),
        "sol_name": "Halo2Verifier.sol",
        "fixture_path": os.path.join(FIXTURES_DIR, "Fixtures.sol"),
    },
    {
        "label": "K=8 batch",
        "artifacts_dir": os.path.join(SCRIPT_DIR, "run_mnist_mw_k8"),
        "sol_name": "Halo2Verifier_k8.sol",
        "fixture_path": os.path.join(FIXTURES_DIR, "FixturesK8.sol"),
    },
]


def extract_embedded_bytecode(fixture_path: str) -> str:
    text = open(fixture_path).read()
    m = re.search(r'verifierBytecode\(\).*?return hex"([0-9a-fA-F]+)"', text, re.S)
    if not m:
        raise RuntimeError(f"no verifierBytecode() hex literal found in {fixture_path}")
    return "0x" + m.group(1)


def start_anvil():
    proc = subprocess.Popen(
        [os.path.join(FOUNDRY_BIN, "anvil"),
         "--port", str(ANVIL_PORT), "--block-time", "1", "--silent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(2)
    return proc


async def _regen_and_deploy(artifacts_dir, sol_name, tmpdir):
    import ezkl

    vk_path = os.path.join(artifacts_dir, "vk.key")
    settings_path = os.path.join(artifacts_dir, "settings.json")
    srs_path = os.path.join(artifacts_dir, "srs.bin")
    sol_path = os.path.join(tmpdir, sol_name)
    abi_path = os.path.join(tmpdir, sol_name.replace(".sol", ".abi"))

    result = ezkl.create_evm_verifier(
        vk_path=vk_path, settings_path=settings_path,
        sol_code_path=sol_path, abi_path=abi_path,
        srs_path=srs_path, reusable=False,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result

    addr_path = tempfile.mktemp(suffix=".addr")
    result = ezkl.deploy_evm(
        addr_path=addr_path, rpc_url=RPC_URL, sol_code_path=sol_path,
        optimizer_runs=1, private_key=PRIVATE_KEY,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result
    await asyncio.sleep(1)

    with open(addr_path) as f:
        return f.read().strip()


def run_async(coro_fn, *args):
    loop = asyncio.new_event_loop()
    try:
        result = loop.run_until_complete(coro_fn(*args))
        loop.run_until_complete(asyncio.sleep(1))
        return result
    finally:
        loop.close()


def stripped_hash_of(code_hex: str) -> str:
    from web3 import Web3
    stripped = strip_cbor_metadata(code_hex)
    return Web3.keccak(bytes.fromhex(stripped[2:])).hex()


def main():
    from web3 import Web3

    print("=== Foundry fixture bytecode freshness canary ===\n")
    print(f"Starting Anvil on port {ANVIL_PORT} ...")
    anvil = start_anvil()

    all_ok = True
    try:
        w3 = Web3(Web3.HTTPProvider(RPC_URL))
        for case in CASES:
            label = case["label"]
            print(f"\n--- {label} ---")

            embedded_hex = extract_embedded_bytecode(case["fixture_path"])
            embedded_hash = stripped_hash_of(embedded_hex)
            print(f"  {os.path.basename(case['fixture_path'])} embedded stripped hash: 0x{embedded_hash}")

            with tempfile.TemporaryDirectory() as tmpdir:
                addr = run_async(_regen_and_deploy, case["artifacts_dir"], case["sol_name"], tmpdir)
            code = w3.eth.get_code(Web3.to_checksum_address(addr))
            code_hex = "0x" + code.hex() if not code.hex().startswith("0x") else code.hex()
            fresh_hash = stripped_hash_of(code_hex)
            print(f"  freshly regenerated stripped hash:              0x{fresh_hash}")

            ok = embedded_hash == fresh_hash
            print(f"  {'MATCH — fixture is fresh' if ok else 'MISMATCH — fixture is STALE, regenerate it'}")
            all_ok = all_ok and ok
    finally:
        print("\nStopping Anvil...")
        anvil.terminate()
        anvil.wait()

    print(f"\nALL FIXTURES FRESH: {all_ok}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
