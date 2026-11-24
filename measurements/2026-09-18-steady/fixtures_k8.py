#!/usr/bin/env python3
"""Regex-extract proofBytes()/instances()/verifierBytecode() directly from
contracts/test/fixtures/FixturesK8.sol (self-consistent triple, baked together
2026-09-08 per git log). Never touch circuits/spike-mlp/run_mnist_mw_k8/proof.json
(stale, predates the vk.key regen)."""
import os
import re

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES_K8 = os.path.join(PROJECT_ROOT, "contracts", "test", "fixtures", "FixturesK8.sol")


def _src():
    with open(FIXTURES_K8) as f:
        return f.read()


def load_proof_bytes() -> bytes:
    src = _src()
    m = re.search(r'function proofBytes.*?return hex"([0-9a-fA-F]+)"', src, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find proofBytes hex in FixturesK8.sol")
    return bytes.fromhex(m.group(1))


def load_instances() -> list:
    src = _src()
    m = re.search(r'function instances\(\).*?\{(.*?)\n    \}', src, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find instances() body in FixturesK8.sol")
    body = m.group(1)
    assigns = re.findall(r'arr\[(\d+)\]\s*=\s*(\d+);', body)
    if len(assigns) != 88:
        raise RuntimeError(f"Expected 88 instance assignments, found {len(assigns)}")
    arr = [0] * 88
    for idx_s, val_s in assigns:
        arr[int(idx_s)] = int(val_s)
    return arr


def load_verifier_bytecode_hex() -> str:
    src = _src()
    m = re.search(r'function verifierBytecode.*?return hex"([0-9a-fA-F]+)"', src, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find verifierBytecode hex in FixturesK8.sol")
    return m.group(1)


if __name__ == "__main__":
    p = load_proof_bytes()
    i = load_instances()
    v = load_verifier_bytecode_hex()
    print(f"proof bytes: {len(p)}")
    print(f"instances: {len(i)} (first={i[0]}, last={i[-1]})")
    print(f"verifier bytecode: {len(v)//2} bytes")
    assert len(p) == 3840, f"expected 3840-byte proof, got {len(p)}"
    assert len(i) == 88
