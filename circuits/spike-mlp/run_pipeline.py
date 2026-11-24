"""
EZKL pipeline for Task 1 (determinism) and Task 2 (salted commitment).
Run from circuits/spike-mlp/ directory.
"""
import asyncio
import hashlib
import json
import os
import shutil
import sys
import time
import traceback

import ezkl


def sha256_file(path: str) -> str:
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def get_logrows(settings_path: str) -> int:
    with open(settings_path) as f:
        return json.load(f)["run_args"]["logrows"]


def ensure_srs(srs_path: str, logrows: int):
    """Download public SRS if not already present. Falls back to gen_srs for testing."""
    if os.path.exists(srs_path):
        print(f"  SRS already exists: {srs_path}", flush=True)
        return
    print(f"  Downloading SRS (logrows={logrows}) ...", flush=True)
    try:
        asyncio.run(ezkl.get_srs(srs_path=srs_path, logrows=logrows))
    except Exception as e:
        print(f"  get_srs failed ({e}), falling back to gen_srs (testing-only SRS) ...", flush=True)
        ezkl.gen_srs(srs_path=srs_path, logrows=logrows)


def run_pipeline(
    run_dir: str,
    model_path: str,
    input_json: str,
    shared_srs: str | None,
    visibility: dict,
) -> dict:
    """Run full EZKL pipeline in run_dir. Returns timing info and VK path."""
    os.makedirs(run_dir, exist_ok=True)
    t_start = time.time()

    settings_path = os.path.join(run_dir, "settings.json")
    compiled_path = os.path.join(run_dir, "compiled.ezkl")
    pk_path = os.path.join(run_dir, "pk.key")
    vk_path = os.path.join(run_dir, "vk.key")
    srs_path = shared_srs or os.path.join(run_dir, "kzg.srs")

    # 1. Gen settings
    run_args = ezkl.PyRunArgs()
    run_args.input_visibility = visibility["input"]
    run_args.output_visibility = visibility["output"]
    run_args.param_visibility = visibility["param"]

    print(f"[{run_dir}] gen_settings ...", flush=True)
    ezkl.gen_settings(model=model_path, output=settings_path, py_run_args=run_args)

    # 2. Calibrate
    print(f"[{run_dir}] calibrate_settings ...", flush=True)
    ezkl.calibrate_settings(
        data=input_json,
        model=model_path,
        settings=settings_path,
        target="resources",
    )

    logrows = get_logrows(settings_path)

    # 3. Compile
    print(f"[{run_dir}] compile_circuit ...", flush=True)
    ezkl.compile_circuit(
        model=model_path,
        compiled_circuit=compiled_path,
        settings_path=settings_path,
    )

    # 4. Ensure SRS exists
    ensure_srs(srs_path, logrows)

    # 5. Setup (keygen)
    print(f"[{run_dir}] setup (logrows={logrows}) ...", flush=True)
    t_setup = time.time()
    ezkl.setup(
        model=compiled_path,
        vk_path=vk_path,
        pk_path=pk_path,
        srs_path=srs_path,
        disable_selector_compression=False,
    )
    t_end = time.time()

    vk_size = os.path.getsize(vk_path)
    vk_sha = sha256_file(vk_path)

    result = {
        "vk_path": vk_path,
        "vk_size": vk_size,
        "vk_sha256": vk_sha,
        "logrows": logrows,
        "total_time_s": round(t_end - t_start, 2),
        "setup_time_s": round(t_end - t_setup, 2),
    }
    print(f"[{run_dir}] Done. VK {vk_size}B, SHA256={vk_sha[:20]}...", flush=True)
    return result


def task1_determinism():
    print("\n=== TASK 1: Determinism check ===\n")
    vis = {"input": "public", "output": "public", "param": "fixed"}

    # Run 1
    r1 = run_pipeline("run1", "model.onnx", "input.json", None, vis)
    srs1 = os.path.join("run1", "kzg.srs") if not os.path.exists("kzg.srs") else "kzg.srs"

    # Run 2 — fresh dirs, same SRS to isolate the VK determinism question
    r2 = run_pipeline("run2", "model.onnx", "input.json", srs1, vis)

    match = r1["vk_sha256"] == r2["vk_sha256"]
    print(f"\nRun1 VK SHA256: {r1['vk_sha256']}")
    print(f"Run2 VK SHA256: {r2['vk_sha256']}")
    print(f"VKs match byte-for-byte: {match}")

    if not match:
        with open(r1["vk_path"], "rb") as f1, open(r2["vk_path"], "rb") as f2:
            b1, b2 = f1.read(), f2.read()
        diff_bytes = sum(a != b for a, b in zip(b1, b2))
        print(f"Differing bytes: {diff_bytes} / {max(len(b1), len(b2))}")

    return r1, r2, match


def task2_salted_commitment():
    print("\n=== TASK 2: Salted input commitment ===\n")

    import torch
    import torch.nn as nn
    import onnx

    torch.manual_seed(42)

    class SpikeMLP(nn.Module):
        def __init__(self):
            super().__init__()
            self.net = nn.Sequential(
                nn.Linear(4, 16), nn.ReLU(),
                nn.Linear(16, 8), nn.ReLU(),
                nn.Linear(8, 2),
            )
        def forward(self, x):
            return self.net(x)

    base_mlp = SpikeMLP()
    base_mlp.eval()

    # ---- Approach A: original 4-input model, input_visibility=hashed/public ----
    print("Approach A: original model, input_visibility='hashed/public'")
    vis_a = {"input": "hashed/public", "output": "public", "param": "fixed"}
    approach_a_ok = False
    r_a = None
    try:
        r_a = run_pipeline("run_hashed", "model.onnx", "input.json", None, vis_a)
        print(f"  Approach A succeeded. logrows={r_a['logrows']}")

        # Generate witness to show Poseidon hash appears instead of raw input
        compiled_path = os.path.join("run_hashed", "compiled.ezkl")
        witness_path = os.path.join("run_hashed", "witness.json")
        ezkl.gen_witness(data="input.json", model=compiled_path, output=witness_path)
        with open(witness_path) as f:
            witness = json.load(f)
        raw_input = json.load(open("input.json"))["input_data"][0]
        print(f"  Raw input (float): {raw_input}")
        print(f"  Witness keys: {list(witness.keys())}")
        # Inputs should be hashed (Poseidon field elements, not raw floats)
        if "inputs" in witness:
            print(f"  Witness inputs (Poseidon hash, not raw floats): {witness['inputs'][:4]}")
        approach_a_ok = True
    except Exception as e:
        print(f"  Approach A failed: {e}")
        traceback.print_exc()

    # ---- Approach B: nonce concatenated to input, hashed/public on 5-dim vector ----
    print("\nApproach B: nonce as 5th input dimension, hashed/public visibility")
    approach_b_ok = False
    try:
        class NoncedMLP(nn.Module):
            """Accepts concat(input[4], nonce[1]) as 5-dim vector.
            EZKL commits Poseidon(input||nonce) to the public transcript.
            The nonce is never used in the actual computation — it exists
            only to differentiate the commitment for each inference call."""
            def __init__(self, mlp):
                super().__init__()
                self.mlp = mlp

            def forward(self, x):
                # x: [1, 5] — first 4 are features, last 1 is client nonce
                return self.mlp(x[:, :4])

        nonce_model = NoncedMLP(base_mlp)
        nonce_model.eval()

        real_input = torch.tensor([[0.5, -0.3, 0.8, -0.1]])
        nonce = torch.tensor([[42.0]])
        x_with_nonce = torch.cat([real_input, nonce], dim=1)

        torch.onnx.export(
            nonce_model, x_with_nonce, "model_nonce.onnx",
            export_params=True, opset_version=12,
            do_constant_folding=True,
            input_names=["input_with_nonce"],
            output_names=["output"],
        )
        # Downgrade opset to 13 + ir8 for EZKL/tract compat
        m = onnx.load("model_nonce.onnx")
        for op in m.opset_import:
            if op.domain in ("", "ai.onnx"):
                op.version = 13
        m.ir_version = 8
        onnx.checker.check_model(m)
        onnx.save(m, "model_nonce.onnx")
        print(f"  Exported model_nonce.onnx (5-dim: 4 features + 1 nonce)")

        cal_b = {"input_data": [x_with_nonce.detach().numpy().flatten().tolist()]}
        with open("input_nonce.json", "w") as f:
            json.dump(cal_b, f)

        vis_b = {"input": "hashed/public", "output": "public", "param": "fixed"}
        r_b = run_pipeline("run_nonce", "model_nonce.onnx", "input_nonce.json", None, vis_b)

        # Generate witness with nonce=42
        ezkl.gen_witness(
            data="input_nonce.json",
            model=os.path.join("run_nonce", "compiled.ezkl"),
            output=os.path.join("run_nonce", "witness_nonce42.json"),
        )

        # Generate witness with different nonce=99 to show commitment differs
        nonce2 = torch.tensor([[99.0]])
        x_nonce2 = torch.cat([real_input, nonce2], dim=1)
        cal_b2 = {"input_data": [x_nonce2.detach().numpy().flatten().tolist()]}
        with open("input_nonce2.json", "w") as f:
            json.dump(cal_b2, f)
        ezkl.gen_witness(
            data="input_nonce2.json",
            model=os.path.join("run_nonce", "compiled.ezkl"),
            output=os.path.join("run_nonce", "witness_nonce99.json"),
        )

        with open(os.path.join("run_nonce", "witness_nonce42.json")) as f:
            w1 = json.load(f)
        with open(os.path.join("run_nonce", "witness_nonce99.json")) as f:
            w2 = json.load(f)

        print(f"  Witness nonce=42 keys: {list(w1.keys())}")
        print(f"  Witness nonce=99 keys: {list(w2.keys())}")

        # Compare commitment hashes
        if "inputs" in w1 and "inputs" in w2:
            print(f"  Hash(input||nonce=42): {w1['inputs'][:4]}")
            print(f"  Hash(input||nonce=99): {w2['inputs'][:4]}")
            hashes_differ = w1["inputs"] != w2["inputs"]
            print(f"  Commitments differ with different nonce: {hashes_differ}")

        print(f"  Approach B succeeded.")
        approach_b_ok = True
    except Exception as e:
        print(f"  Approach B failed: {e}")
        traceback.print_exc()

    return approach_a_ok, approach_b_ok, r_a


if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    if not os.path.exists("model.onnx"):
        print("model.onnx not found — run export_model.py first")
        sys.exit(1)

    r1, r2, deterministic = task1_determinism()
    a_ok, b_ok, r_hashed = task2_salted_commitment()

    print("\n=== SUMMARY ===")
    print(f"Task 1 — VKs deterministic: {deterministic}")
    print(f"  Run1: {r1['vk_size']}B, logrows={r1['logrows']}, total={r1['total_time_s']}s (setup={r1['setup_time_s']}s)")
    print(f"  Run2: {r2['vk_size']}B, logrows={r2['logrows']}, total={r2['total_time_s']}s (setup={r2['setup_time_s']}s)")
    print(f"Task 2 — Approach A (hashed/public on original 4-input model): {a_ok}")
    print(f"Task 2 — Approach B (nonce-concat 5-input model, hashed/public): {b_ok}")
