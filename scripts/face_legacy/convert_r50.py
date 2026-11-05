#!/usr/bin/env python3
"""
LICENSED-ONLY. Convert InsightFace w600k_r50 (ArcFace ResNet-50, WebFace600K, from buffalo_l)
to Core ML (fp16).

InsightFace's models are for non-commercial research only. This script is used ONLY by
`FACE_MODEL_SET=buffalo_l scripts/build_face_models.sh`, which refuses to run without a signed
InsightFace licence (docs/MODEL-LICENSING.md §7). Nothing in the shipping build calls it.

I/O: [1,3,112,112] RGB, (px-127.5)/127.5 (FaceModelProfile.insightFaceBuffaloL), 512-d out.

Usage: python convert_r50.py <w600k_r50.onnx> <out.mlpackage>
"""
import sys

import coremltools as ct
import numpy as np
import onnxruntime as ort
import torch
from onnx2torch import convert as onnx2torch_convert

src, out = sys.argv[1], sys.argv[2]
torch_model = onnx2torch_convert(src).eval()
example = torch.randn(1, 3, 112, 112)
traced = torch.jit.trace(torch_model, example)
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112))],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
)
ml.short_description = "InsightFace w600k_r50 (buffalo_l) 512-d face embedding, RGB 112x112. LICENSED USE ONLY."
ml.save(out)

sess = ort.InferenceSession(src, providers=["CPUExecutionProvider"])
ref = sess.run(None, {sess.get_inputs()[0].name: example.numpy()})[0].ravel()
got = np.asarray(ml.predict({"input": example.numpy()})["embedding"]).ravel()
c = float(np.dot(ref, got) / (np.linalg.norm(ref) * np.linalg.norm(got) + 1e-12))
assert got.size == 512 and c > 0.999, f"R50 Core ML diverges: cos {c}"
print(f"Saved {out} (parity vs onnxruntime cos {c:.5f})")
