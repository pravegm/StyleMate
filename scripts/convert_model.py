#!/usr/bin/env python3
"""
Convert InsightFace MobileFaceNet (w600k_mbf.onnx) to CoreML (.mlpackage).

Requirements:
    pip install coremltools onnx onnx2torch torch

Usage (run on macOS):
    python convert_model.py

Output:
    MobileFaceNet.mlpackage  (drag into Xcode project)
"""

import coremltools as ct
import numpy as np
import torch
from onnx2torch import convert as onnx2torch_convert
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
ONNX_PATH = SCRIPT_DIR / "w600k_mbf.onnx"
OUTPUT_PATH = SCRIPT_DIR / "MobileFaceNet.mlpackage"

if not ONNX_PATH.exists():
    raise FileNotFoundError(
        f"ONNX model not found at {ONNX_PATH}. "
        "Download from: https://huggingface.co/deepghs/insightface/resolve/main/buffalo_s/w600k_mbf.onnx"
    )

print(f"Converting {ONNX_PATH} ...")

print("Loading ONNX model via onnx2torch ...")
torch_model = onnx2torch_convert(str(ONNX_PATH))
torch_model.eval()

example_input = torch.randn(1, 3, 112, 112)
traced_model = torch.jit.trace(torch_model, example_input)

model = ct.convert(
    traced_model,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112))],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT32,
)

model.author = "InsightFace (MIT License)"
model.short_description = "MobileFaceNet face recognition embedding model (128-dim output, 112x112 RGB input)"
model.license = "MIT"

model.save(str(OUTPUT_PATH))
print(f"\nSaved to {OUTPUT_PATH}")
size_mb = sum(f.stat().st_size for f in OUTPUT_PATH.rglob("*") if f.is_file()) / 1024 / 1024
print(f"Size: {size_mb:.1f} MB")
print("\nNext steps:")
print("1. Drag MobileFaceNet.mlpackage into your Xcode project (check 'Copy items if needed')")
print("2. Verify the model appears in Xcode's model preview with input shape [1, 3, 112, 112]")
print("3. Build and run - FaceMatchingService will auto-detect the model")
