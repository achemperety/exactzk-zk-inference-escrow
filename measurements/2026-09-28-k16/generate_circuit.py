#!/usr/bin/env python3
"""
Generate MnistMLP BatchKWrapper(K) ONNX + calibrated settings.json + input.json
for a given K, reusing the exact model/geometry/scale pinning from
circuits/spike-mlp/f2_mnist_scaling.py (the script that produced the canonical
run_mnist_mw_k8/ artifacts). Only export+gen_settings+calibrate_settings run
here (single process) -- compile_circuit/setup/gen_witness/prove/verify are
measured separately, one fresh process per stage, by run_stage.py in this
same directory, per the corrected (cold-process) method from
measurements/2026-09-28-proving-cost/.

Usage: python3 generate_circuit.py <K> <out_dir>
"""
import json, os, sys, shutil
import torch, torch.nn as nn, onnx, ezkl

D_MNIST = 784
K_NONCES = 5
C_MNIST = 10
PINNED_SCALE = 13


class MnistMLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(784, 64), nn.ReLU(),
            nn.Linear(64, 32), nn.ReLU(),
            nn.Linear(32, 10),
        )
    def forward(self, x):
        return self.net(x)


class BatchKWrapper(nn.Module):
    def __init__(self, core, D, K):
        super().__init__()
        self.core = core
        self.D = D
        self.K = K
    def forward(self, *lanes):
        stripped = [x[:, :self.D] for x in lanes]
        batch = torch.cat(stripped, dim=0)
        y = self.core(batch)
        return tuple(y[i:i+1] for i in range(self.K))


def patch_opset(path):
    m = onnx.load(path)
    for op in m.opset_import:
        if op.domain in ("", "ai.onnx"):
            op.version = 13
    m.ir_version = 8
    onnx.checker.check_model(m)
    onnx.save(m, path)


def pin_scales(settings_path, scale):
    with open(settings_path) as f:
        s = json.load(f)
    s["run_args"]["input_scale"] = scale
    s["run_args"]["param_scale"] = scale
    with open(settings_path, "w") as f:
        json.dump(s, f)


def read_logrows(settings_path):
    with open(settings_path) as f:
        return json.load(f)["run_args"]["logrows"]


def main():
    K = int(sys.argv[1])
    out_dir = sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    onnx_path = os.path.join(out_dir, "model.onnx")
    input_json = os.path.join(out_dir, "input.json")
    settings_path = os.path.join(out_dir, "settings.json")

    torch.manual_seed(42)
    core = MnistMLP()
    core.eval()

    torch.manual_seed(7)
    model = BatchKWrapper(core, D=D_MNIST, K=K)
    model.eval()

    lane_w = D_MNIST + K_NONCES
    lanes = [torch.randn(1, lane_w) for _ in range(K)]

    print(f"Exporting ONNX K={K} lane_width={lane_w} ...", flush=True)
    torch.onnx.export(
        model, tuple(lanes), onnx_path,
        opset_version=17,
        input_names=[f"x_{i}" for i in range(K)],
        output_names=[f"y_{i}" for i in range(K)],
        dynamic_axes=None,
    )
    patch_opset(onnx_path)

    model_proto = onnx.load(onnx_path)
    op_types = {n.op_type for n in model_proto.graph.node}
    assert "Concat" in op_types, f"K={K}: Concat missing"
    print(f"ONNX ops: {sorted(op_types)}", flush=True)

    raw_lanes = [l.detach().numpy().flatten().tolist() for l in lanes]
    with open(input_json, "w") as f:
        json.dump({"input_data": raw_lanes}, f)

    run_args = ezkl.PyRunArgs()
    run_args.input_visibility = "hashed/public"
    run_args.output_visibility = "public"
    run_args.param_visibility = "fixed"
    run_args.input_scale = PINNED_SCALE
    run_args.param_scale = PINNED_SCALE

    print("gen_settings ...", flush=True)
    ezkl.gen_settings(onnx_path, settings_path, py_run_args=run_args)

    print("calibrate_settings ...", flush=True)
    ezkl.calibrate_settings(input_json, onnx_path, settings_path, target="resources")

    logrows_cal = read_logrows(settings_path)
    pin_scales(settings_path, PINNED_SCALE)
    logrows = read_logrows(settings_path)

    print(f"K={K} logrows_cal={logrows_cal} logrows_final={logrows} rows={2**logrows:,}", flush=True)

    result = {"K": K, "logrows_cal": logrows_cal, "logrows": logrows, "rows": 2**logrows}
    with open(os.path.join(out_dir, "gen_result.json"), "w") as f:
        json.dump(result, f, indent=2)
    print("RESULT_JSON:" + json.dumps(result))


if __name__ == "__main__":
    main()
