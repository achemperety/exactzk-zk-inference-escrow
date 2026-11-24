"""
Task 3 — Realistic-model proving benchmarks.

Model: MNIST-scale MLP (784 → 64 → 32 → 10, ~52k params)
Wrapper: NoncedMLP appends k nonce dims (k=1 and k=5) for entropy comparison.
Measures: calibrate+compile+setup time, prove time, peak RSS, VK/PK/proof sizes,
          logrows and row budget utilisation.
"""
import os, sys, time, json, hashlib, shutil, tracemalloc, resource, math
import torch, torch.nn as nn, onnx, ezkl

WORK_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# Model definitions
# ---------------------------------------------------------------------------

class MnistMLP(nn.Module):
    """~52 650-param MLP for 784-dim (flattened MNIST-shaped) input."""
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(784, 64), nn.ReLU(),
            nn.Linear(64, 32),  nn.ReLU(),
            nn.Linear(32, 10),
        )
    def forward(self, x):
        return self.net(x)


class NoncedMLP(nn.Module):
    def __init__(self, mlp, n_real: int):
        super().__init__()
        self.mlp = mlp
        self.n_real = n_real

    def forward(self, x):          # x: [1, n_real + k_nonces]
        return self.mlp(x[:, :self.n_real])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def patch_opset(path: str):
    """Patch ONNX to opset 13 / ir_version 8 (EZKL tract compat)."""
    m = onnx.load(path)
    for op in m.opset_import:
        if op.domain in ("", "ai.onnx"):
            op.version = 13
    m.ir_version = 8
    onnx.checker.check_model(m)
    onnx.save(m, path)


def export_model(k_nonces: int, onnx_path: str, input_json_path: str,
                 n_real: int = 784, seed: int = 42):
    torch.manual_seed(seed)
    base = MnistMLP()
    base.eval()
    if k_nonces > 0:
        model = NoncedMLP(base, n_real)
    else:
        model = base
    model.eval()
    n_in = n_real + k_nonces
    x = torch.randn(1, n_in)
    torch.onnx.export(model, x, onnx_path,
                      opset_version=17,
                      input_names=["input"], output_names=["output"],
                      dynamic_axes=None)
    patch_opset(onnx_path)
    cal = {"input_data": [x.detach().numpy().flatten().tolist()]}
    with open(input_json_path, "w") as f:
        json.dump(cal, f)
    return onnx_path, input_json_path


def peak_rss_mb() -> float:
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS returns bytes; Linux returns kilobytes
    if sys.platform == "darwin":
        return ru / 1e6
    return ru / 1e3


def file_mb(path: str) -> float:
    if not os.path.exists(path):
        return 0.0
    total = 0
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for fn in files:
                total += os.path.getsize(os.path.join(root, fn))
    else:
        total = os.path.getsize(path)
    return total / 1e6


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


# ---------------------------------------------------------------------------
# Pipeline runner
# ---------------------------------------------------------------------------

def run_pipeline(label: str, k_nonces: int, shared_srs: str | None = None):
    print(f"\n{'='*60}")
    print(f"  {label}  (k_nonces={k_nonces})")
    print(f"{'='*60}")

    run_dir = os.path.join(WORK_DIR, f"run_t3_{label.replace(' ', '_')}")
    shutil.rmtree(run_dir, ignore_errors=True)
    os.makedirs(run_dir)

    onnx_path      = os.path.join(run_dir, "model.onnx")
    input_path     = os.path.join(run_dir, "input.json")
    settings_path  = os.path.join(run_dir, "settings.json")
    compiled_path  = os.path.join(run_dir, "model.compiled")
    srs_path       = os.path.join(run_dir, "srs.bin")
    vk_path        = os.path.join(run_dir, "vk.key")
    pk_path        = os.path.join(run_dir, "pk.key")
    witness_path   = os.path.join(run_dir, "witness.json")
    proof_path     = os.path.join(run_dir, "proof.json")

    # ---- export --------------------------------------------------------
    t0 = time.perf_counter()
    print("  Exporting model …")
    export_model(k_nonces, onnx_path, input_path)
    t_export = time.perf_counter() - t0
    print(f"    done in {t_export:.2f}s")

    # ---- gen settings --------------------------------------------------
    print("  gen_settings …")
    t0 = time.perf_counter()
    run_args = ezkl.PyRunArgs()
    run_args.input_visibility  = "hashed/public"
    run_args.output_visibility = "public"
    run_args.param_visibility  = "fixed"
    ezkl.gen_settings(onnx_path, settings_path, py_run_args=run_args)
    t_settings = time.perf_counter() - t0
    print(f"    done in {t_settings:.2f}s")

    # ---- calibrate -----------------------------------------------------
    print("  calibrate_settings …")
    t0 = time.perf_counter()
    ezkl.calibrate_settings(input_path, onnx_path, settings_path,
                            target="resources")
    t_calibrate = time.perf_counter() - t0

    with open(settings_path) as f:
        settings = json.load(f)
    logrows   = settings.get("run_args", {}).get("logrows", "?")
    num_rows  = settings.get("num_rows", "?")
    capacity  = 2 ** logrows if isinstance(logrows, int) else "?"
    utilpct   = f"{100*num_rows/capacity:.1f}%" if isinstance(capacity, int) else "?"
    print(f"    done in {t_calibrate:.2f}s")
    print(f"    logrows={logrows}, num_rows={num_rows}, capacity={capacity}, util={utilpct}")

    # ---- compile -------------------------------------------------------
    print("  compile_circuit …")
    t0 = time.perf_counter()
    ezkl.compile_circuit(onnx_path, compiled_path, settings_path)
    t_compile = time.perf_counter() - t0
    print(f"    done in {t_compile:.2f}s")

    # ---- SRS -----------------------------------------------------------
    if shared_srs and os.path.exists(shared_srs):
        print(f"  Reusing SRS from {shared_srs}")
        shutil.copy(shared_srs, srs_path)
    else:
        print(f"  gen_srs (logrows={logrows}) …")
        t0 = time.perf_counter()
        ezkl.gen_srs(srs_path, logrows)
        t_srs = time.perf_counter() - t0
        print(f"    done in {t_srs:.2f}s  ({file_mb(srs_path):.1f} MB)")

    # ---- setup (keygen) -----------------------------------------------
    print("  setup (keygen) …")
    rss_before_setup = peak_rss_mb()
    t0 = time.perf_counter()
    ezkl.setup(compiled_path, vk_path, pk_path, srs_path)
    t_setup = time.perf_counter() - t0
    rss_after_setup = peak_rss_mb()
    print(f"    done in {t_setup:.2f}s")
    print(f"    VK: {file_mb(vk_path)*1000:.0f} KB  PK: {file_mb(pk_path)*1000:.0f} KB")
    print(f"    Peak RSS after setup: {rss_after_setup:.0f} MB  (delta: +{rss_after_setup-rss_before_setup:.0f} MB)")

    # ---- witness -------------------------------------------------------
    print("  gen_witness …")
    t0 = time.perf_counter()
    ezkl.gen_witness(input_path, compiled_path, witness_path)
    t_witness = time.perf_counter() - t0
    print(f"    done in {t_witness:.2f}s")

    # ---- prove ---------------------------------------------------------
    print("  prove …")
    tracemalloc.start()
    rss_before_prove = peak_rss_mb()
    t0 = time.perf_counter()
    ezkl.prove(witness_path, compiled_path, pk_path, proof_path, srs_path)
    t_prove = time.perf_counter() - t0
    current, peak_py = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    rss_after_prove = peak_rss_mb()
    print(f"    done in {t_prove:.2f}s")
    print(f"    Proof size: {file_mb(proof_path)*1000:.0f} KB")
    print(f"    Peak RSS during prove: {rss_after_prove:.0f} MB  (delta: +{rss_after_prove-rss_before_prove:.0f} MB)")
    print(f"    tracemalloc peak: {peak_py/1e6:.0f} MB")

    # ---- verify --------------------------------------------------------
    print("  verify …")
    ok = ezkl.verify(proof_path, settings_path, vk_path, srs_path)
    print(f"    verify: {'OK' if ok else 'FAILED'}")

    result = {
        "label":          label,
        "k_nonces":       k_nonces,
        "logrows":        logrows,
        "num_rows":       num_rows,
        "capacity":       capacity,
        "utilization":    utilpct,
        "t_calibrate_s":  round(t_calibrate, 2),
        "t_compile_s":    round(t_compile, 2),
        "t_setup_s":      round(t_setup, 2),
        "t_witness_s":    round(t_witness, 2),
        "t_prove_s":      round(t_prove, 2),
        "vk_kb":          round(file_mb(vk_path)*1000, 0),
        "pk_mb":          round(file_mb(pk_path), 1),
        "proof_kb":       round(file_mb(proof_path)*1000, 0),
        "rss_after_setup_mb":  round(rss_after_setup, 0),
        "rss_after_prove_mb":  round(rss_after_prove, 0),
        "peak_py_mb":     round(peak_py/1e6, 0),
        "verify_ok":      ok,
        "vk_sha256":      sha256_file(vk_path),
    }
    print(f"\n  Summary: {json.dumps(result, indent=2)}")
    return result, srs_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("Task 3 — Realistic-model proving benchmarks")
    print(f"  Working dir: {WORK_DIR}")
    print(f"  EZKL {ezkl.__version__}, PyTorch {torch.__version__}")

    results = []

    # Run k=1 first; reuse SRS for k=5 if logrows matches
    r1, srs1 = run_pipeline("k1_nonces", k_nonces=1)
    results.append(r1)

    # k=5: reuse SRS only if same logrows
    srs_for_k5 = srs1 if r1["logrows"] == r1["logrows"] else None  # always True; we check below
    r5, _ = run_pipeline("k5_nonces", k_nonces=5, shared_srs=srs1)
    results.append(r5)

    # ---- Summary table ------------------------------------------------
    print("\n\n" + "="*70)
    print("TASK 3 SUMMARY")
    print("="*70)
    fields = [
        ("logrows",             "logrows"),
        ("num_rows",            "rows used"),
        ("utilization",         "utilization"),
        ("t_calibrate_s",       "calibrate (s)"),
        ("t_compile_s",         "compile (s)"),
        ("t_setup_s",           "setup (s)"),
        ("t_prove_s",           "prove (s)"),
        ("vk_kb",               "VK (KB)"),
        ("pk_mb",               "PK (MB)"),
        ("proof_kb",            "proof (KB)"),
        ("rss_after_setup_mb",  "RSS@setup (MB)"),
        ("rss_after_prove_mb",  "RSS@prove (MB)"),
    ]
    header = f"{'Metric':<22}" + "".join(f"{r['label']:>14}" for r in results)
    print(header)
    print("-" * (22 + 14 * len(results)))
    for key, label in fields:
        row = f"{label:<22}"
        for r in results:
            v = r.get(key, "—")
            row += f"{str(v):>14}"
        print(row)

    print("\nNonce-is-free check:")
    if r1["logrows"] == r5["logrows"]:
        row_delta = r5["num_rows"] - r1["num_rows"]
        print(f"  logrows unchanged ({r1['logrows']}): STILL FREE at this model size")
        print(f"  Row delta k5-k1: +{row_delta} rows")
    else:
        print(f"  logrows CHANGED: {r1['logrows']} → {r5['logrows']}")
        print(f"  Adding k=4 nonce dims tipped the circuit into the next bucket.")
        pk_delta = r5["pk_mb"] - r1["pk_mb"]
        print(f"  PK cost of crossing boundary: +{pk_delta:.0f} MB")

    # Save results JSON
    out_path = os.path.join(WORK_DIR, "task3_results.json")
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nFull results saved to {out_path}")


if __name__ == "__main__":
    main()
