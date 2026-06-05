#!/usr/bin/env python3
"""
Convert InsightFace SCRFD-10G face detector (det_10g.onnx, buffalo_l) to Core ML.

This replaces Apple Vision's imprecise face landmarks — proven to be the root
cause of low same-person similarity (offline test: proper SCRFD alignment gives
AdaFace same-person 0.988; the app's Vision landmarks gave ~0.2). SCRFD outputs
the 5-point landmarks ArcFace/AdaFace alignment needs.

Fixed 640x640 input. Outputs (per stride 8/16/32): score, bbox-distance, kps.
Swift decodes these with anchor centers + NMS, then aligns with the 5 kps.
"""
import numpy as np
import torch
import coremltools as ct
from pathlib import Path
from onnx2torch import convert as onnx2torch_convert

SRC = Path.home() / ".insightface/models/buffalo_l/det_10g.onnx"
OUT = Path(__file__).parent / "SCRFD10G.mlpackage"

print("Loading SCRFD ONNX via onnx2torch ...")
tmodel = onnx2torch_convert(str(SRC)).eval()
example = torch.randn(1, 3, 640, 640)
with torch.no_grad():
    outs = tmodel(example)
print(f"  torch produced {len(outs)} outputs: {[tuple(o.shape) for o in outs]}")

traced = torch.jit.trace(tmodel, example)
print("Converting to Core ML (fp16) ...")
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 640, 640))],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
)
ml.short_description = "InsightFace SCRFD-10G face detector — 640x640 in, scores/bbox/kps per stride 8/16/32"
ml.save(str(OUT))

# Report Core ML output names + shapes so the Swift decoder can map them.
spec = ml.get_spec()
print("Core ML outputs (name: shape):")
for o in spec.description.output:
    shp = [d for d in o.type.multiArrayType.shape]
    print(f"   {o.name}: {shp}")
print(f"Saved {OUT}")
