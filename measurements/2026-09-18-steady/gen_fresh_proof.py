#!/usr/bin/env python3
"""Attempt to generate a genuinely fresh K=8 batch proof using the CURRENT
run_mnist_mw_k8 pk.key/witness.json/srs.bin (regenerated 2026-08-29). Runs
standalone (no Anvil/web3) so it can be launched as a background process
while chain-side measurements proceed in parallel. Writes status/result to
proof2_status.json in this directory.
"""
import json
import os
import time
import traceback

HERE = os.path.dirname(__file__)
RUN_DIR = os.path.abspath(os.path.join(HERE, "..", "..", "circuits", "spike-mlp", "run_mnist_mw_k8"))
STATUS_PATH = os.path.join(HERE, "proof2_status.json")
PROOF2_PATH = os.path.join(HERE, "proof2.json")


def write_status(**kw):
    kw["ts"] = time.time()
    with open(STATUS_PATH, "w") as f:
        json.dump(kw, f, indent=2)


def main():
    write_status(state="starting")
    import ezkl

    model_path = os.path.join(RUN_DIR, "model_k8.compiled")
    witness_path = os.path.join(RUN_DIR, "witness.json")
    pk_path = os.path.join(RUN_DIR, "pk.key")
    srs_path = os.path.join(RUN_DIR, "srs.bin")

    for p in (model_path, witness_path, pk_path, srs_path):
        if not os.path.exists(p):
            write_status(state="failed", reason=f"missing input file: {p}")
            return

    write_status(state="proving", pk_size_bytes=os.path.getsize(pk_path))
    t0 = time.time()
    try:
        ok = ezkl.prove(witness_path, model_path, pk_path, PROOF2_PATH, srs_path)
    except Exception as e:
        write_status(state="failed", reason=f"ezkl.prove raised: {e}", traceback=traceback.format_exc(),
                     elapsed_s=time.time() - t0)
        return
    elapsed = time.time() - t0

    if not ok or not os.path.exists(PROOF2_PATH):
        write_status(state="failed", reason=f"ezkl.prove returned {ok!r} / no proof file", elapsed_s=elapsed)
        return

    write_status(state="proved", elapsed_s=elapsed, proof_path=PROOF2_PATH)


if __name__ == "__main__":
    main()
