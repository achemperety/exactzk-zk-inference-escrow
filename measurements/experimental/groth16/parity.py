"""Which integer arithmetic reproduces the canonical solo circuit's outputs? (groundwork for the Groth16 prototype; run on 2 vCPUs of an Intel Xeon Gold 5220R.)

    python parity.py <repo> <compiled circuit> <k16 input.json> <out dir>

Reads the canonical model's weights, gets EZKL's own witness outputs (gen_witness of the canonical
compiled circuit; no proving) for 25 inputs, and compares them with candidate integer pipelines.
Writes the quantised weights and the reference outputs for the Groth16 prototype.
"""
import asyncio, json, math, os, random, sys

import ezkl
import numpy as np
import onnx
from onnx import numpy_helper

repo, compiled, k16_inputs, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
D = os.path.join(repo, "circuits/spike-mlp/run_t3_k5_nonces")
P = 21888242871839275222246405745257275088548364400416034343698204186575808495617
loop = asyncio.new_event_loop()


def run(thunk):
    async def go():
        r = thunk()
        return (await r) if (asyncio.iscoroutine(r) or asyncio.isfuture(r)) else r
    return loop.run_until_complete(go())


m = onnx.load(os.path.join(D, "model.onnx"))
print("nodes:", [(n.op_type, list(n.input), list(n.output)) for n in m.graph.node])
init = {i.name: numpy_helper.to_array(i) for i in m.graph.initializer}
print("initializers:", {k: v.shape for k, v in init.items()})
gemms = [n for n in m.graph.node if n.op_type in ("Gemm", "MatMul")]
layers = []
for n in gemms:
    attrs = {a.name: helper_val for a in n.attribute for helper_val in [onnx.helper.get_attribute_value(a)]}
    W = init[n.input[1]].astype(np.float64)
    if n.op_type == "Gemm" and attrs.get("transB", 0) == 0:
        W = W.T  # make it [out, in]
    b = init[n.input[2]].astype(np.float64) if len(n.input) > 2 else np.zeros(W.shape[0])
    layers.append((W, b))
print("layers (out, in):", [l[0].shape for l in layers])


def rnd(v):  # round half away from zero, as Rust's f64::round
    return np.sign(v) * np.floor(np.abs(v) + 0.5)


S = 13
Wq = [rnd(W * 2**S).astype(object) for W, _ in layers]
bq_hi = [rnd(b * 2**(2 * S)).astype(object) for _, b in layers]
bq_lo = [rnd(b * 2**S).astype(object) for _, b in layers]


def signed(fe):
    v = int.from_bytes(bytes.fromhex(fe), "little")
    return v - P if v > P // 2 else v


def div_floor(a, d):
    return a // d


def div_round(a, d):  # round half away from zero
    return (abs(a) + d // 2) // d * (1 if a >= 0 else -1)


def div_round_up(a, d):  # round half up (toward +inf)
    return (a + d // 2) // d


def pipeline(x789, rescale, bias_hi=True, relu_before=False):
    h = np.array([int(v) for v in rnd(np.array(x789[:784]) * 2**S)], dtype=object)
    for i, (W, bh, bl) in enumerate(zip(Wq, bq_hi, bq_lo)):
        if bias_hi:
            acc = W.dot(h) + bh
            y = np.array([rescale(int(a), 2**S) for a in acc], dtype=object)
        else:
            acc = W.dot(h)
            y = np.array([rescale(int(a), 2**S) for a in acc], dtype=object) + bl
        if i < len(Wq) - 1:
            y = np.array([max(0, int(v)) for v in y], dtype=object)
        h = y
    return [int(v) for v in h]


inputs = [("published", json.load(open(os.path.join(D, "input.json")))["input_data"][0])]
k16 = json.load(open(k16_inputs))["input_data"]
inputs += [(f"k16-lane-{i}", v) for i, v in enumerate(k16)]
rng = random.Random(20261124)
inputs += [(f"random-{i}", [rng.random() for _ in range(784)] + [rng.uniform(-1, 1) for _ in range(5)]) for i in range(8)]

candidates = {
    "bias at 2^26, round half away": lambda x: pipeline(x, div_round, True),
    "bias at 2^26, floor": lambda x: pipeline(x, div_floor, True),
    "bias at 2^26, round half up": lambda x: pipeline(x, div_round_up, True),
    "bias at 2^13 after rescale, round half away": lambda x: pipeline(x, div_round, False),
}
score = {k: 0 for k in candidates}
ref = []
for label, x in inputs:
    inp, wit = os.path.join(out, f"{label}.input.json"), os.path.join(out, f"{label}.witness.json")
    json.dump({"input_data": [x]}, open(inp, "w"))
    run(lambda: ezkl.gen_witness(inp, compiled, wit))
    w = json.load(open(wit))
    ez = [signed(fe) for fe in w["outputs"][0]]
    commit = int.from_bytes(bytes.fromhex(w["processed_inputs"]["poseidon_hash"][0]), "little") if "processed_inputs" in w and w["processed_inputs"] else None
    row = {"label": label, "input": x, "ezkl_outputs": ez, "ezkl_commitment": hex(commit) if commit is not None else None}
    for k, f in candidates.items():
        got = f(x)
        row[k] = got
        if got == ez:
            score[k] += 1
    ref.append(row)
    os.remove(wit)
print("exact matches out of", len(inputs), ":", json.dumps(score, indent=1))
best = max(score, key=score.get)
print("best:", best)
if score[best] < len(inputs):
    for r in ref:
        if r[best] != r["ezkl_outputs"]:
            print(r["label"], "ezkl", r["ezkl_outputs"], "\n   ours", r[best])
            break
json.dump({"scale": S, "semantics": best, "W": [[[int(v) for v in row] for row in W] for W in Wq],
           "b26": [[int(v) for v in b] for b in bq_hi], "b13": [[int(v) for v in b] for b in bq_lo]},
          open(os.path.join(out, "weights.json"), "w"))
json.dump([{k: r[k] for k in ("label", "input", "ezkl_outputs", "ezkl_commitment")} for r in ref],
          open(os.path.join(out, "reference.json"), "w"))
loop.close()
