#!/usr/bin/env python3
"""Recompute the solo circuit's reference case from its published files: one input, its input
commitment and the output the circuit gives for it. Nothing is proved and nothing is sent.

    circuits/spike-mlp/run_t3_k5_nonces/input.json   784 features and 5 nonce values
        + model.onnx, model.onnx.data, the pinned settings.json
        --EZKL compile_circuit, gen_witness-->  the Poseidon input commitment and 10 outputs

The witness is what the prover would prove, so its values are the circuit's, not the floating-
point model's: fixed point at 2^13, with the circuit's own rounding. Each input file is first
compared with its SHA-256 in provenance/COPIED_FILES.sha256. The results are then compared with
the published proof (clients/ts/published/solo-proof.json, the stored proof of test/fixtures/), and
the verifier id of the solo entry is read from deployments/base-sepolia.json.

    python3 scripts/reference_case.py [--json <file>]

Exit status 0 only if the commitment and every output equal the published ones. Needs Python 3.10+
and the ezkl package (23.0.5); measured at about 75 MB of memory and under a second.
"""
import argparse
import hashlib
import json
import os
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CIRCUIT = "circuits/spike-mlp/run_t3_k5_nonces"
FILES = ["input.json", "model.onnx", "model.onnx.data", "settings.json"]
# The BN254 scalar field: EZKL's outputs are its elements, negative values as p - |v|.
P = 0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001
SCALE = 13
EZKL_VERSION = "23.0.5"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def pinned():
    out = {}
    with open(os.path.join(ROOT, "provenance", "COPIED_FILES.sha256")) as f:
        for line in f:
            if line.strip():
                digest, path = line.split()
                out[path] = digest
    return out


def felt(le_hex):
    """An EZKL field element, little-endian hex, as an integer."""
    return int.from_bytes(bytes.fromhex(le_hex), "little")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--json", help="also write the case to this file")
    args = ap.parse_args()

    import ezkl

    ok = True
    pins = pinned()
    for name in FILES:
        rel = f"{CIRCUIT}/{name}"
        got = sha256(os.path.join(ROOT, rel))
        match = got == pins.get(rel)
        ok &= match
        print(f"{'ok  ' if match else 'DIFF'} sha256 {rel} {got}")
    if not ok:
        print("an input file is not the pinned one; stopping")
        return 1
    if ezkl.__version__ != EZKL_VERSION:
        print(f"note: ezkl {ezkl.__version__}, the circuits were built with {EZKL_VERSION}")

    c = os.path.join(ROOT, CIRCUIT)
    with tempfile.TemporaryDirectory() as tmp:
        compiled = os.path.join(tmp, "network.compiled")
        witness = os.path.join(tmp, "witness.json")
        if not ezkl.compile_circuit(os.path.join(c, "model.onnx"), compiled, os.path.join(c, "settings.json")):
            print("compile_circuit failed")
            return 1
        r = ezkl.gen_witness(os.path.join(c, "input.json"), compiled, witness)
        if hasattr(r, "__await__"):
            import asyncio

            asyncio.run(r)
        with open(witness) as f:
            w = json.load(f)

    commitment = "0x%064x" % felt(w["processed_inputs"]["poseidon_hash"][0])
    outputs = [felt(x) for x in w["outputs"][0]]
    signed = [v - P if v > P // 2 else v for v in outputs]
    output_bytes = "0x" + "".join("%064x" % v for v in outputs)

    with open(os.path.join(ROOT, "clients", "ts", "published", "solo-proof.json")) as f:
        published = json.load(f)
    with open(os.path.join(ROOT, "deployments", "base-sepolia.json")) as f:
        deployment = json.load(f)

    with open(os.path.join(c, "input.json")) as f:
        values = json.load(f)["input_data"][0]
    print(f"input:          {CIRCUIT}/input.json, {len(values)} values (784 features, 5 nonces)")
    m1 = commitment == published["inputCommitment"].lower()
    print(f"{'ok  ' if m1 else 'DIFF'} inputCommitment {commitment}")
    m2 = output_bytes == published["output"].lower()
    print(f"{'ok  ' if m2 else 'DIFF'} output, {len(outputs)} values, {len(outputs) * 32} bytes as the verifier reads them")
    for i, v in enumerate(signed):
        print(f"       [{i}] {v:>8} / 2^{SCALE} = {v / 2**SCALE:+.6f}")
    best = max(range(len(signed)), key=lambda i: signed[i])
    print(f"       largest: index {best}")
    print(f"verifierId:     {deployment['verifierIds']['solo']} (solo entry, {deployment['network']})")

    if args.json:
        case = {
            "circuit": CIRCUIT,
            "files": {name: pins[f"{CIRCUIT}/{name}"] for name in FILES},
            "inputCommitment": commitment,
            "outputFieldElements": ["0x%064x" % v for v in outputs],
            "outputSigned": signed,
            "outputScale": SCALE,
            "outputBytes": output_bytes,
            "largestIndex": best,
            "verifierId": deployment["verifierIds"]["solo"],
            "ezkl": ezkl.__version__,
        }
        with open(args.json, "w") as f:
            json.dump(case, f, indent=1)
            f.write("\n")
    if not (m1 and m2):
        print("DIFFER from the published proof")
        return 1
    print("MATCH: the published proof's input commitment and output")
    return 0


if __name__ == "__main__":
    sys.exit(main())
