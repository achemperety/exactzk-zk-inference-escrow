"""
Single-stage EZKL benchmark runner. Each invocation performs exactly ONE
ezkl pipeline stage in a fresh process, so /usr/bin/time -l (external,
kernel-rusage-based) and resource.getrusage (internal, same-process) can
both observe that process's peak RSS in isolation from any other stage.

Usage:
  python3 run_stage.py <work_dir> <stage> [--k8]

Stages: compile_setup, witness, prove, verify

Prints one line starting with "RESULT_JSON:" containing timing + internal
RSS reading. The external /usr/bin/time -l reading is captured by the
calling shell wrapper into a separate log file.
"""
import os, sys, time, json, resource, argparse
import ezkl

def peak_rss_bytes() -> int:
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS ru_maxrss is bytes; Linux is kilobytes.
    return ru if sys.platform == "darwin" else ru * 1024

def file_bytes(path: str) -> int:
    return os.path.getsize(path) if os.path.exists(path) else 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("work_dir")
    ap.add_argument("stage", choices=["compile_setup", "witness", "prove", "verify"])
    args = ap.parse_args()

    wd = args.work_dir
    onnx_path     = os.path.join(wd, "model.onnx")
    settings_path = os.path.join(wd, "settings.json")
    compiled_path = os.path.join(wd, "model.compiled")
    srs_path      = os.path.join(wd, "srs.bin")
    vk_path       = os.path.join(wd, "vk.key")
    pk_path       = os.path.join(wd, "pk.key")
    input_path    = os.path.join(wd, "input.json")
    witness_path  = os.path.join(wd, "witness.json")
    proof_path    = os.path.join(wd, "proof.json")

    result = {"stage": args.stage, "ezkl_version": ezkl.__version__}

    if args.stage == "compile_setup":
        t0 = time.perf_counter()
        ezkl.compile_circuit(onnx_path, compiled_path, settings_path)
        t_compile = time.perf_counter() - t0

        t0 = time.perf_counter()
        ezkl.setup(compiled_path, vk_path, pk_path, srs_path)
        t_setup = time.perf_counter() - t0

        result.update({
            "t_compile_s": round(t_compile, 4),
            "t_setup_s":   round(t_setup, 4),
            "t_total_s":   round(t_compile + t_setup, 4),
            "vk_bytes":    file_bytes(vk_path),
            "pk_bytes":    file_bytes(pk_path),
            "compiled_bytes": file_bytes(compiled_path),
        })

    elif args.stage == "witness":
        t0 = time.perf_counter()
        ezkl.gen_witness(input_path, compiled_path, witness_path)
        t_witness = time.perf_counter() - t0
        result.update({
            "t_witness_s": round(t_witness, 4),
            "witness_bytes": file_bytes(witness_path),
        })

    elif args.stage == "prove":
        t0 = time.perf_counter()
        ezkl.prove(witness_path, compiled_path, pk_path, proof_path, srs_path)
        t_prove = time.perf_counter() - t0
        result.update({
            "t_prove_s": round(t_prove, 4),
            "proof_bytes": file_bytes(proof_path),
        })

    elif args.stage == "verify":
        t0 = time.perf_counter()
        ok = ezkl.verify(proof_path, settings_path, vk_path, srs_path)
        t_verify = time.perf_counter() - t0
        result.update({
            "t_verify_s": round(t_verify, 4),
            "verify_ok": bool(ok),
        })

    result["internal_peak_rss_bytes"] = peak_rss_bytes()

    print("RESULT_JSON:" + json.dumps(result))

if __name__ == "__main__":
    main()
