#!/usr/bin/env python3
"""
How much 5-point error does AdaFace tolerate? Decides whether we can salvage
Apple Vision's landmarks (if it tolerates a few px) or must bundle InsightFace's
own detector (if it needs sub-pixel accuracy).

Takes properly-aligned faces, then re-aligns the SAME face with the 5 keypoints
perturbed in controlled ways, and measures the resulting same-face cosine.
"""
import cv2
import numpy as np
import torch
from pathlib import Path
import adaface_net as net
import insightface
from insightface.app import FaceAnalysis
from insightface.utils import face_align

SCRIPT_DIR = Path(__file__).parent
model = net.build_model("ir_101")
sd = torch.load(str(SCRIPT_DIR / "adaface_ir101_webface12m.ckpt"), map_location="cpu")["state_dict"]
model.load_state_dict({k[6:]: v for k, v in sd.items() if k.startswith("model.")})
model.eval()

def embed(a):
    t = (a.astype(np.float32) - 127.5) / 127.5
    t = torch.from_numpy(np.ascontiguousarray(t.transpose(2, 0, 1))[None])
    with torch.no_grad():
        return (lambda f: f / (np.linalg.norm(f) + 1e-9))(model(t)[0][0].numpy())

def cos(a, b): return float(np.dot(a, b))

app = FaceAnalysis(name="buffalo_l", allowed_modules=["detection"])
app.prepare(ctx_id=-1, det_size=(640, 640))
img = insightface.data.get_image("t1")
faces = sorted(app.get(img), key=lambda f: f.bbox[0])
rng = np.random.RandomState(0)

# baseline: proper embedding per face
base = [(f, embed(face_align.norm_crop(img, f.kps))) for f in faces]

def avg_cos_with(transform):
    out = []
    for f, e0 in base:
        kp = transform(f.kps.copy())
        e1 = embed(face_align.norm_crop(img, kp))
        out.append(cos(e0, e1))
    return np.mean(out)

print("Gaussian jitter on all 5 points (no swap):")
for px in [1, 2, 3, 4, 6, 8, 10]:
    # average over a few noise draws
    scores = [avg_cos_with(lambda k, p=px: k + rng.randn(*k.shape) * p) for _ in range(3)]
    print(f"   +/- {px:2d}px  -> same-face cos {np.mean(scores):.3f}")

print("\nSingle-point errors (one keypoint off by N px, others perfect):")
for name, idx in [("L-eye", 0), ("R-eye", 1), ("nose", 2), ("L-mouth", 3), ("R-mouth", 4)]:
    for px in [5, 10]:
        def t(k, i=idx, p=px):
            k = k.copy(); k[i] = k[i] + np.array([p, p]); return k
        print(f"   {name} off {px:2d}px -> cos {avg_cos_with(t):.3f}")

print("\nEye swap only (no jitter):")
def swap(k): k = k.copy(); k[[0, 1]] = k[[1, 0]]; k[[3, 4]] = k[[4, 3]]; return k
print(f"   eyes+mouth swapped -> cos {avg_cos_with(swap):.3f}")
def swapeyes(k): k = k.copy(); k[[0, 1]] = k[[1, 0]]; return k
print(f"   eyes only swapped  -> cos {avg_cos_with(swapeyes):.3f}")
