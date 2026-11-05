#!/usr/bin/env python3
"""
LICENSED-ONLY. Convert InsightFace SCRFD-10G (det_10g.onnx from buffalo_l) to Core ML.

InsightFace's models are for non-commercial research only. No build script calls this or
downloads the weights; run it by hand only after a signed InsightFace licence
(docs/MODEL-LICENSING.md §7).

Fixed 640x640 input, RGB (px-127.5)/128. Outputs per stride 8/16/32: score, bbox-distance, kps.
`SCRFDDetector.swift` decodes them (anchor centres, 2 anchors per cell, NMS 0.4).

Usage: python convert_scrfd.py <det_10g.onnx> <out.mlpackage>
"""
import sys

import coremltools as ct
import numpy as np
import onnxruntime as ort
import torch
from onnx2torch import convert as onnx2torch_convert

src, out = sys.argv[1], sys.argv[2]
tmodel = onnx2torch_convert(src).eval()
example = torch.randn(1, 3, 640, 640)
traced = torch.jit.trace(tmodel, example)
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 640, 640))],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
)
ml.short_description = "InsightFace SCRFD-10G face detector (buffalo_l). LICENSED USE ONLY."
ml.save(out)

sess = ort.InferenceSession(src, providers=["CPUExecutionProvider"])
ref = sess.run(None, {sess.get_inputs()[0].name: example.numpy()})
got = ml.predict({"input": example.numpy()})
for r in ref:   # match Core ML outputs by shape (names differ after tracing)
    cand = [np.asarray(v) for v in got.values() if np.asarray(v).size == r.size and np.asarray(v).shape[-1] == r.shape[-1]]
    best = max(float(np.dot(r.ravel(), c.ravel()) / (np.linalg.norm(r) * np.linalg.norm(c) + 1e-12)) for c in cand)
    assert best > 0.999, f"SCRFD Core ML diverges: cos {best}"
print(f"Saved {out} (parity vs onnxruntime OK)")
