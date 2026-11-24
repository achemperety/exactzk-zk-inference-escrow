import torch
import torch.nn as nn
import json
import numpy as np

torch.manual_seed(42)


class SpikeMLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(4, 16),
            nn.ReLU(),
            nn.Linear(16, 8),
            nn.ReLU(),
            nn.Linear(8, 2),
        )

    def forward(self, x):
        return self.net(x)


model = SpikeMLP()
model.eval()

x = torch.randn(1, 4)

torch.onnx.export(
    model,
    x,
    "model.onnx",
    opset_version=17,
    input_names=["input"],
    output_names=["output"],
    dynamic_axes=None,
)

# PyTorch 2.11+ always exports opset 18 / ir_version 10; patch to opset 13 / ir 8
# so EZKL's tract backend can parse it.
import onnx as _onnx
_m = _onnx.load("model.onnx")
for _op in _m.opset_import:
    if _op.domain in ("", "ai.onnx"):
        _op.version = 13
_m.ir_version = 8
_onnx.checker.check_model(_m)
_onnx.save(_m, "model.onnx")
print("Exported model.onnx (opset 13 / ir_version 8 for EZKL compat)")
print(f"  Input shape: {list(x.shape)}")
print(f"  Output shape: {list(model(x).shape)}")

# Generate calibration data
cal_data = {
    "input_data": [x.detach().numpy().flatten().tolist()]
}
with open("input.json", "w") as f:
    json.dump(cal_data, f)
print("Wrote input.json")
