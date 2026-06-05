#!/usr/bin/env python3
"""
Convert InsightFace w600k_r50 (buffalo_L ResNet-50) to Core ML (fp16) for StyleMate.

This is the STRONGER face-embedding model that replaced the old buffalo_s
MobileFaceNet (w600k_mbf). Same I/O contract (112x112x3 RGB in, 512-dim out,
(px-127.5)/127.5 normalization), so no Swift changes are needed — the app loads
it by the historical resource name "MobileFaceNet".

Setup (once, on a Mac):
    python3 -m venv venv && source venv/bin/activate
    pip install "coremltools>=8" onnx onnx2torch torch "numpy<2"

Download the ONNX (buffalo_L pack, ~166MB):
    curl -L -o w600k_r50.onnx \
      "https://huggingface.co/deepghs/insightface/resolve/main/buffalo_l/w600k_r50.onnx?download=true"

Run:
    python convert_r50.py

Then copy the result into the bundle slot (the .mlpackage is gitignored — it's a
local build artifact, regenerated from this script):
    rm -rf ../MobileFaceNet.mlpackage && cp -R FaceNetR50.mlpackage ../MobileFaceNet.mlpackage
"""

import coremltools as ct
import numpy as np
import torch
from onnx2torch import convert as onnx2torch_convert
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
ONNX_PATH = SCRIPT_DIR / "w600k_r50.onnx"
OUTPUT_PATH = SCRIPT_DIR / "FaceNetR50.mlpackage"

if not ONNX_PATH.exists():
    raise FileNotFoundError(f"{ONNX_PATH} not found — download it first (see header).")

print("Loading ONNX via onnx2torch ...")
torch_model = onnx2torch_convert(str(ONNX_PATH)).eval()
traced = torch.jit.trace(torch_model, torch.randn(1, 3, 112, 112))

print("Converting to Core ML (fp16) ...")
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112))],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.author = "InsightFace (MIT License)"
mlmodel.short_description = "InsightFace w600k_r50 (buffalo_L ResNet-50) face embedding — 512-dim, 112x112 RGB"
mlmodel.license = "MIT"
mlmodel.save(str(OUTPUT_PATH))

# Sanity check: output must be 512-dim.
out = mlmodel.predict({"input": np.random.randn(1, 3, 112, 112).astype(np.float32)})
shape = np.array(next(iter(out.values()))).shape
print(f"Saved {OUTPUT_PATH} | output shape {shape}")
assert shape[-1] == 512, f"Expected 512-dim embedding, got {shape}"
print("OK — copy FaceNetR50.mlpackage to ../MobileFaceNet.mlpackage and rebuild.")
