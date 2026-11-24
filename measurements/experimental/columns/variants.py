"""EXPERIMENTAL circuit variants of the canonical solo circuit, on 2 vCPUs of an Intel Xeon Gold 5220R. New keys; never canonical.

    python variants.py <repo> <out dir> <name> <num_inner_cols> [--argmax]

Same model, same weights, same scales (13), same visibility (hashed/public input, public output,
fixed parameters), check_mode UNSAFE as the canonical settings; only the number of inner columns
changes, or (--argmax) an ArgMax node is appended so the circuit outputs one value instead of ten.
Settings come from gen_settings and calibrate_settings (target "resources", scales [13]). Keys are set
up from the canonical SRS files (the solo one up to logrows 16, the K=8 one up to logrows 19), the
published input is proved, the proof verified, and the EVM verifier source written for the gas
measurement on the Mac.
"""
import asyncio, hashlib, json, os, shutil, sys, time

import ezkl
import onnx
from onnx import helper

repo, out, name, cols = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ARGMAX = "--argmax" in sys.argv
D = os.path.join(repo, "circuits/spike-mlp/run_t3_k5_nonces")
W = os.path.join(out, name)
os.makedirs(W, exist_ok=True)
loop = asyncio.new_event_loop()
R = {"variant": name, "num_inner_cols": cols, "argmax_head": ARGMAX, "label": "EXPERIMENTAL"}


def run(thunk):
    """Call an EZKL function inside the event loop (some of its calls need one) and await it if needed."""
    async def go():
        r = thunk()
        return (await r) if (asyncio.iscoroutine(r) or asyncio.isfuture(r)) else r
    return loop.run_until_complete(go())


def peak_mb():
    for line in open("/proc/self/status"):
        if line.startswith("VmHWM"):
            return int(line.split()[1]) // 1024


def step(label, f):
    t = time.time()
    v = f()
    R.setdefault("steps", {})[label] = {"seconds": round(time.time() - t, 2), "peak_rss_mb": peak_mb()}
    print(f"[{name}] {label}: {time.time() - t:.2f} s, peak {peak_mb()} MB", flush=True)
    return v


model = os.path.join(W, "model.onnx")
shutil.copyfile(os.path.join(D, "model.onnx"), model)
shutil.copyfile(os.path.join(D, "model.onnx.data"), os.path.join(W, "model.onnx.data"))
if ARGMAX:
    m = onnx.load(model)
    out_name = m.graph.output[0].name
    m.graph.node.append(helper.make_node("ArgMax", [out_name], ["argmax_i64"], axis=1, keepdims=1))
    m.graph.node.append(helper.make_node("Cast", ["argmax_i64"], ["argmax"], to=onnx.TensorProto.FLOAT))
    m.graph.output.pop()
    m.graph.output.append(helper.make_tensor_value_info("argmax", onnx.TensorProto.FLOAT, [1, 1]))
    onnx.save(m, model)  # weights embedded: EZKL's importer rejected the model re-saved with external data
data = os.path.join(W, "input.json")
shutil.copyfile(os.path.join(D, "input.json"), data)

ra = ezkl.PyRunArgs()
ra.input_visibility = "hashed/public"
ra.output_visibility = "public"
ra.param_visibility = "fixed"
ra.input_scale = 13
ra.param_scale = 13
ra.num_inner_cols = cols
settings = os.path.join(W, "settings.json")
step("gen_settings", lambda: run(lambda: ezkl.gen_settings(model, settings, py_run_args=ra)))
step("calibrate_settings", lambda: run(lambda: ezkl.calibrate_settings(data, model, settings, "resources", scales=[13])))
s = json.load(open(settings))
s["check_mode"] = "UNSAFE"
json.dump(s, open(settings, "w"))
k = s["run_args"]["logrows"]
R.update(logrows=k, num_rows=s.get("num_rows"), total_assignments=s.get("total_assignments"),
         lookup_range=s["run_args"].get("lookup_range"), instances=sum(x if isinstance(x, int) else 0 for x in []) or None)
srs = os.path.join(D, "srs.bin") if k <= 16 else os.path.join(repo, "circuits/spike-mlp/run_mnist_mw_k8/srs.bin")
compiled, vk, pk = (os.path.join(W, f) for f in ("model.compiled", "vk.key", "pk.key"))
step("compile_circuit", lambda: run(lambda: ezkl.compile_circuit(model, compiled, settings)))
step("setup", lambda: run(lambda: ezkl.setup(compiled, vk, pk, srs)))
R["vk_sha256"] = hashlib.sha256(open(vk, "rb").read()).hexdigest()
R["vk_bytes"], R["pk_bytes"] = os.path.getsize(vk), os.path.getsize(pk)
wit, prf = os.path.join(W, "witness.json"), os.path.join(W, "proof.json")
step("gen_witness", lambda: run(lambda: ezkl.gen_witness(data, compiled, wit)))
step("prove", lambda: run(lambda: ezkl.prove(wit, compiled, pk, prf, srs)))
R["verified"] = bool(run(lambda: ezkl.verify(prf, settings, vk, srs)))
p = json.load(open(prf))
R["public_instances"] = len(p["instances"][0])
step("create_evm_verifier", lambda: run(lambda: ezkl.create_evm_verifier(vk, settings, os.path.join(W, "Verifier.sol"), os.path.join(W, "Verifier.abi"), srs)))
os.remove(pk)  # experimental keys are not kept
json.dump(R, open(os.path.join(W, "result.json"), "w"), indent=2)
print(json.dumps({k: v for k, v in R.items() if k != "steps"}), flush=True)
loop.run_until_complete(asyncio.sleep(1))
loop.close()
