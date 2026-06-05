#!/usr/bin/env python3
"""
Convert AdaFace IR-101 (R100) WebFace12M to Core ML (fp16) for StyleMate.

AdaFace's adaptive-margin training targets LOW-QUALITY / varied faces (angles,
distance, lighting), which is exactly the auto-scan's hard case. This replaces
the InsightFace R50 (w600k_r50) as the face embedder.

Architecture: official AdaFace net.py (build_model('ir_101')).
Checkpoint:   adaface_ir101_webface12m.ckpt (Google Drive 1dswnavflETcnAuplZj1IOKKP0eM8ITgT).

CRITICAL I/O contract (differs from InsightFace!):
  - input  : [1, 3, 112, 112]
  - channel order: **BGR** (InsightFace uses RGB)
  - normalization: (pixel - 127.5) / 127.5   (mean 0.5, std 0.5)
  - output : 512-d embedding (forward returns (feature, norm); we keep feature)
The Swift side (createInputMultiArray) must feed BGR with this normalization.

Run (from scripts/, with adaface_venv active and the .ckpt downloaded):
    python convert_adaface.py
Then bundle:
    rm -rf ../MobileFaceNet.mlpackage && cp -R AdaFaceR100.mlpackage ../MobileFaceNet.mlpackage
"""

import numpy as np
import torch
import coremltools as ct
from pathlib import Path

import adaface_net as net  # official net.py, fetched into scripts/

SCRIPT_DIR = Path(__file__).parent
CKPT = SCRIPT_DIR / "adaface_ir101_webface12m.ckpt"
OUT = SCRIPT_DIR / "AdaFaceR100.mlpackage"

if not CKPT.exists():
    raise FileNotFoundError(f"{CKPT} not found — download it first (see header).")

print("Building IR-101 and loading checkpoint ...")
model = net.build_model("ir_101")
state = torch.load(str(CKPT), map_location="cpu")["state_dict"]
weights = {k[6:]: v for k, v in state.items() if k.startswith("model.")}
missing, unexpected = model.load_state_dict(weights, strict=False)
print(f"  loaded | missing={len(missing)} unexpected={len(unexpected)}")
assert len(missing) == 0, f"missing keys: {missing[:5]}"
model.eval()


class FeatureOnly(torch.nn.Module):
    """AdaFace forward returns (feature, norm); Core ML needs a single tensor."""
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        out = self.m(x)
        return out[0] if isinstance(out, (tuple, list)) else out


wrapped = FeatureOnly(model).eval()
example = torch.randn(1, 3, 112, 112)
with torch.no_grad():
    ref = wrapped(example)
print(f"  torch output shape {tuple(ref.shape)}")
assert ref.shape[-1] == 512, f"expected 512-d, got {tuple(ref.shape)}"

print("Tracing + converting to Core ML (fp16) ...")
traced = torch.jit.trace(wrapped, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112))],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.author = "AdaFace (mk-minchul), MIT-style research license"
mlmodel.short_description = "AdaFace IR-101 WebFace12M — 512-d face embedding, BGR 112x112, (x-127.5)/127.5"
mlmodel.save(str(OUT))

# Numerical parity check: Core ML vs torch on the same random input.
cm = mlmodel.predict({"input": example.numpy()})
cm_vec = np.array(next(iter(cm.values()))).flatten()
tv = ref.detach().numpy().flatten()
cos = float(np.dot(cm_vec, tv) / (np.linalg.norm(cm_vec) * np.linalg.norm(tv) + 1e-9))
print(f"Saved {OUT}")
print(f"Core ML vs torch cosine on same input: {cos:.4f} (should be > 0.99)")
assert cos > 0.99, "Core ML output diverges from torch — conversion problem!"
print("OK — bundle it: rm -rf ../MobileFaceNet.mlpackage && cp -R AdaFaceR100.mlpackage ../MobileFaceNet.mlpackage")
