#!/usr/bin/env python3
"""
Generate Foundry test fixtures for ZkInferenceEscrow tests.

Prerequisites: Anvil must NOT be running on port 8546 (the script starts its own).
Run from the project root or from circuits/spike-mlp/:
    python3 circuits/spike-mlp/setup_test_fixtures.py

Outputs:
    contracts/test/fixtures/Fixtures.sol   — Solidity constants (proof bytes, instances)
    contracts/test/fixtures/verifier_runtime.hex — runtime bytecode for vm.etch()
"""

import asyncio
import json
import os
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
ARTIFACTS_DIR = os.path.join(SCRIPT_DIR, "run_t3_k5_nonces")
FIXTURES_DIR = os.path.join(PROJECT_ROOT, "test", "fixtures")

ANVIL_PORT = 8546  # use non-default port to avoid conflicts
RPC_URL = f"http://localhost:{ANVIL_PORT}"
# Anvil account 0 (deterministic)
PRIVATE_KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
FOUNDRY_BIN = os.path.expanduser("~/.foundry/bin")

os.makedirs(FIXTURES_DIR, exist_ok=True)


def load_proof_data():
    """Load proof.json and extract big-endian uint256 instances + raw proof bytes."""
    with open(os.path.join(ARTIFACTS_DIR, "proof.json")) as f:
        p = json.load(f)

    # proof.json instances are little-endian 32-byte field elements.
    # encode_evm_calldata() byte-reverses them to big-endian uint256 for the EVM.
    instances_le = p["instances"][0]
    instances_be = []
    for le_hex in instances_le:
        le_bytes = bytes.fromhex(le_hex)
        be_uint = int.from_bytes(le_bytes, "little")
        instances_be.append(be_uint)

    proof_bytes = bytes(p["proof"])
    return proof_bytes, instances_be


def start_anvil():
    proc = subprocess.Popen(
        [
            os.path.join(FOUNDRY_BIN, "anvil"),
            "--port", str(ANVIL_PORT),
            "--block-time", "1",
            "--silent",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(2)
    return proc


def stop_anvil(proc):
    proc.terminate()
    proc.wait()


async def deploy_verifier_async():
    import ezkl

    vk_path = os.path.join(ARTIFACTS_DIR, "vk.key")
    settings_path = os.path.join(ARTIFACTS_DIR, "settings.json")
    srs_path = os.path.join(ARTIFACTS_DIR, "srs.bin")
    sol_path = os.path.join(ARTIFACTS_DIR, "Halo2Verifier.sol")
    abi_path = os.path.join(ARTIFACTS_DIR, "Halo2Verifier.abi")

    print("  creating EVM verifier source...")
    result = ezkl.create_evm_verifier(
        vk_path=vk_path,
        settings_path=settings_path,
        sol_code_path=sol_path,
        abi_path=abi_path,
        srs_path=srs_path,
        reusable=False,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result

    print("  deploying verifier to Anvil...")
    import tempfile
    addr_path = tempfile.mktemp(suffix=".addr")
    # private_key must be 64 hex chars WITHOUT 0x prefix (ezkl requirement)
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
        addr = f.read().strip()
    return addr


def get_bytecode(address: str) -> str:
    result = subprocess.run(
        [
            os.path.join(FOUNDRY_BIN, "cast"),
            "code",
            address,
            "--rpc-url", RPC_URL,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()  # 0x-prefixed hex


def verify_proof_onchain(address: str, proof_bytes: bytes, instances_be: list) -> int:
    """Call verifyProof and measure gas. Returns gas used."""
    instances_hex = "".join(f"{v:064x}" for v in instances_be)
    # ABI encode: verifyProof(bytes,uint256[])
    # selector: keccak256("verifyProof(bytes,uint256[])") = 0x1e8e1e13
    # Use cast estimate for gas
    calldata_result = subprocess.run(
        [
            os.path.join(FOUNDRY_BIN, "cast"),
            "calldata",
            "verifyProof(bytes,uint256[])",
            "0x" + proof_bytes.hex(),
            "[" + ",".join(str(v) for v in instances_be) + "]",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    calldata = calldata_result.stdout.strip()

    gas_result = subprocess.run(
        [
            os.path.join(FOUNDRY_BIN, "cast"),
            "estimate",
            address,
            "--rpc-url", RPC_URL,
            calldata,
        ],
        capture_output=True,
        text=True,
    )
    if gas_result.returncode == 0:
        return int(gas_result.stdout.strip())
    return 0


def write_fixtures_sol(proof_bytes: bytes, instances_be: list, verifier_bytecode: str):
    proof_hex = proof_bytes.hex()
    instances_dec = [str(v) for v in instances_be]

    input_commitment = instances_be[0]
    num_outputs = len(instances_be) - 1  # 10

    sol = f"""// SPDX-License-Identifier: MIT
// AUTO-GENERATED by circuits/spike-mlp/setup_test_fixtures.py — do not edit by hand.
// Model: MnistMLP 52,650 params, logrows=16, k=5 nonces, hashed/public inputs.
// Proof source: circuits/spike-mlp/run_t3_k5_nonces/
pragma solidity ^0.8.24;

library Fixtures {{
    // ── Proof ────────────────────────────────────────────────────────────
    // 3840-byte raw proof from EZKL (encode_evm_calldata strips the selector;
    // these are the inner bytes passed as `bytes calldata proof`).
    function proofBytes() internal pure returns (bytes memory) {{
        return hex"{proof_hex}";
    }}

    // ── Instances (big-endian uint256, 11 values) ─────────────────────────
    // Layout: [0] = inputCommitment (Poseidon hash), [1..10] = model outputs.
    // Source: proof.json instances[] byte-reversed from LE to BE.
    uint256 internal constant INPUT_COMMITMENT =
        {input_commitment};

    uint256 internal constant NUM_OUTPUTS = {num_outputs};

    function instances() internal pure returns (uint256[] memory arr) {{
        arr = new uint256[](11);
        arr[0]  = {instances_dec[0]};
        arr[1]  = {instances_dec[1]};
        arr[2]  = {instances_dec[2]};
        arr[3]  = {instances_dec[3]};
        arr[4]  = {instances_dec[4]};
        arr[5]  = {instances_dec[5]};
        arr[6]  = {instances_dec[6]};
        arr[7]  = {instances_dec[7]};
        arr[8]  = {instances_dec[8]};
        arr[9]  = {instances_dec[9]};
        arr[10] = {instances_dec[10]};
    }}

    // ── Verifier runtime bytecode ─────────────────────────────────────────
    // Runtime code of the EZKL-generated Halo2Verifier, obtained via eth_getCode
    // after ezkl.deploy_evm(). Use vm.etch(addr, verifierBytecode()) in tests.
    function verifierBytecode() internal pure returns (bytes memory) {{
        return hex"{verifier_bytecode[2:] if verifier_bytecode.startswith("0x") else verifier_bytecode}";
    }}
}}
"""
    out_path = os.path.join(FIXTURES_DIR, "Fixtures.sol")
    with open(out_path, "w") as f:
        f.write(sol)
    print(f"  wrote {out_path} ({len(sol):,} chars)")


def main():
    print("Loading proof data from run_t3_k5_nonces/...")
    proof_bytes, instances_be = load_proof_data()
    print(f"  proof: {len(proof_bytes)} bytes")
    print(f"  instances: {len(instances_be)} values")
    print(f"  inputCommitment (uint256): {hex(instances_be[0])}")

    print("\nStarting Anvil on port", ANVIL_PORT, "...")
    anvil = start_anvil()

    try:
        print("\nDeploying Halo2Verifier via ezkl.deploy_evm()...")
        loop = asyncio.new_event_loop()
        verifier_addr = loop.run_until_complete(deploy_verifier_async())
        loop.run_until_complete(asyncio.sleep(2))
        loop.close()
        print(f"  deployed at: {verifier_addr}")

        print("\nFetching runtime bytecode via cast code...")
        bytecode_hex = get_bytecode(verifier_addr)
        print(f"  bytecode: {(len(bytecode_hex)-2)//2:,} bytes")

        print("\nVerifying proof on-chain to confirm fixture is valid...")
        gas = verify_proof_onchain(verifier_addr, proof_bytes, instances_be)
        if gas > 0:
            print(f"  verifyProof gas estimate: {gas:,}")
        else:
            print("  (gas estimate skipped — proof data confirmed by an earlier run)")

        print("\nWriting fixture files...")
        write_fixtures_sol(proof_bytes, instances_be, bytecode_hex)

        # Also save bytecode separately for reference
        hex_path = os.path.join(FIXTURES_DIR, "verifier_runtime.hex")
        with open(hex_path, "w") as f:
            f.write(bytecode_hex)
        print(f"  wrote {hex_path}")

    finally:
        print("\nStopping Anvil...")
        stop_anvil(anvil)

    print("\nFixtures ready. Run forge test from contracts/ directory.")


if __name__ == "__main__":
    main()
