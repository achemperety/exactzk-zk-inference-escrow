"""A warm prover (solo) and check_mode SAFE, on 2 vCPUs of an Intel Xeon Gold 5220R, with the canonical solo circuit.

    python warm_prover_and_check_mode.py <repo> <work dir> <warm|safe> [n warm proofs]

warm: compile the canonical circuit, set up its keys from the canonical SRS and check that the verifying
key is byte-identical to the pinned one; witness of the published input checked against the stored
proof's instances; one cold proof, then N more in the same process, each on the published input with
fresh nonces; every proof verified. safe: the same circuit with check_mode SAFE: keys set up, verifying
key compared byte for byte with the canonical one, one proof timed.
"""
import asyncio, hashlib, json, os, random, shutil, sys, time

import ezkl

repo, W, what = sys.argv[1], sys.argv[2], sys.argv[3]
N = int(sys.argv[4]) if len(sys.argv) > 4 else 5
D = os.path.join(repo, "circuits/spike-mlp/run_t3_k5_nonces")
SRS = os.path.join(D, "srs.bin")
PINNED_VK_SHA = "32439290a76c2ef71fb6f20ef203b001b54d9835b411554bae827df5364e9523"
os.makedirs(W, exist_ok=True)
loop = asyncio.new_event_loop()
results = {"experiment": what, "machine": None}


def run(r):
    return loop.run_until_complete(r) if (asyncio.iscoroutine(r) or asyncio.isfuture(r)) else r


def rss_mb():
    for line in open("/proc/self/status"):
        if line.startswith(("VmRSS", "VmHWM")):
            k, v = line.split(":")
            results.setdefault("_mem", {})[k] = int(v.split()[0]) // 1024
    return results["_mem"]


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def timed(label, f):
    t = time.time()
    out = f()
    dt = time.time() - t
    m = rss_mb()
    results.setdefault("steps", []).append({"step": label, "seconds": round(dt, 2), "rss_mb": m["VmRSS"], "peak_rss_mb": m["VmHWM"]})
    print(f"{label}: {dt:.2f} s, RSS {m['VmRSS']} MB, peak {m['VmHWM']} MB", flush=True)
    return out


cpu = [l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")]
results["machine"] = f"{cpu[0]}, 2 vCPUs, Linux"
settings = os.path.join(W, "settings.json")
s = json.load(open(os.path.join(D, "settings.json")))
if what == "safe":
    s["check_mode"] = "SAFE"
json.dump(s, open(settings, "w"))
compiled, vk, pk = (os.path.join(W, f) for f in ("model.compiled", "vk.key", "pk.key"))

timed("compile_circuit", lambda: run(ezkl.compile_circuit(os.path.join(D, "model.onnx"), compiled, settings)))
timed("setup", lambda: run(ezkl.setup(compiled, vk, pk, SRS)))
results["vk_sha256"] = sha(vk)
results["vk_equals_pinned"] = sha(vk) == PINNED_VK_SHA
results["vk_bytes"] = os.path.getsize(vk)
results["pk_bytes"] = os.path.getsize(pk)
print("verifying key", sha(vk), "equals the pinned one" if results["vk_equals_pinned"] else "DIFFERS from the pinned one", flush=True)

x = json.load(open(os.path.join(D, "input.json")))["input_data"][0]
stored = json.load(open(os.path.join(D, "proof.json")))
inputs = [("published", x)] + [(f"fresh-{i}", x[:784] + [random.uniform(-1, 1) for _ in range(5)]) for i in range(N if what == "warm" else 0)]
for i, (label, values) in enumerate(inputs):
    inp, wit, prf = (os.path.join(W, f"{label}.{e}") for e in ("input.json", "witness.json", "proof.json"))
    json.dump({"input_data": [values]}, open(inp, "w"))
    w = timed(f"gen_witness {label}", lambda: run(ezkl.gen_witness(inp, compiled, wit)))
    if label == "published":
        got = json.load(open(wit))
        results["published_instances_equal_stored_proof"] = got["outputs"] == stored["instances"] if "outputs" in got else None
        inst = run(ezkl.gen_witness(inp, compiled, wit))  # unchanged; kept for symmetry
    timed(f"prove {label} ({'cold' if i == 0 else 'warm'})", lambda: run(ezkl.prove(wit, compiled, pk, prf, SRS)))
    ok = run(ezkl.verify(prf, settings, vk, SRS))
    results.setdefault("verified", []).append({label: bool(ok)})
    if label == "published":
        p = json.load(open(prf))
        results["published_proof_instances_equal_stored"] = p["instances"] == stored["instances"]
    if i == 1 and what == "warm":
        shutil.copyfile(prf, os.path.join(W, "fresh-proof-for-onchain-check.json"))

json.dump(results, open(os.path.join(W, f"{what}-results.json"), "w"), indent=2)
print(json.dumps({k: v for k, v in results.items() if k != "steps"}, indent=1), flush=True)
loop.run_until_complete(asyncio.sleep(2))
loop.close()
