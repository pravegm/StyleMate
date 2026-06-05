#!/usr/bin/env python3
"""
Ground-truth test: is the AdaFace model + preprocessing fine (so the APP's
Vision-based alignment is the bug), or is something about our AdaFace usage wrong?

Uses InsightFace's proper detector + canonical 5-point alignment, embeds with the
SAME AdaFace model + SAME preprocessing the app uses (BGR, (x-127.5)/127.5), and
measures:
  1. same-person cosine with PROPER alignment           (expect HIGH, ~0.5-0.8)
  2. impostor cosine                                     (expect LOW,  ~0.0)
  3. same-person cosine with a PERTURBED alignment       (shows how alignment
     error alone collapses the score — the app's failure mode)

If (1) is high, the model/preprocessing is correct and the app's alignment is the
problem. If (1) is low, our AdaFace integration (channel order / normalization)
is wrong.
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

def embed(aligned_bgr_112):
    """aligned face, BGR uint8 112x112 -> normalized AdaFace embedding (app preprocessing)."""
    t = (aligned_bgr_112.astype(np.float32) - 127.5) / 127.5   # already BGR
    t = torch.from_numpy(np.ascontiguousarray(t.transpose(2, 0, 1))[None])
    with torch.no_grad():
        f = model(t)[0][0].numpy()
    return f / (np.linalg.norm(f) + 1e-9)

def cos(a, b):
    return float(np.dot(a, b))

app = FaceAnalysis(name="buffalo_l", allowed_modules=["detection"])
app.prepare(ctx_id=-1, det_size=(640, 640))

img = insightface.data.get_image("t1")  # group photo, several distinct people

def faces_of(image):
    fs = app.get(image)
    return sorted(fs, key=lambda f: f.bbox[0])  # left-to-right, stable order

base = faces_of(img)
print(f"detected {len(base)} faces in sample image")

# Same-person pair: transform the whole image (rotate+scale), re-detect, pair by order.
h, w = img.shape[:2]
M = cv2.getRotationMatrix2D((w / 2, h / 2), 12, 0.92)
img2 = cv2.warpAffine(img, M, (w, h), borderMode=cv2.BORDER_REPLICATE)
trans = faces_of(img2)

n = min(len(base), len(trans))
print(f"\n[1] SAME-PERSON, proper alignment (each person across the 12deg/0.92 transform):")
same_scores = []
for i in range(n):
    a0 = face_align.norm_crop(img, base[i].kps)     # proper canonical align
    a1 = face_align.norm_crop(img2, trans[i].kps)
    s = cos(embed(a0), embed(a1))
    same_scores.append(s)
    print(f"    person {i}: cos = {s:.3f}")
print(f"    -> mean same-person = {np.mean(same_scores):.3f}")

print(f"\n[2] IMPOSTOR, proper alignment (distinct people):")
imp = []
for i in range(n):
    for j in range(i + 1, n):
        a_i = face_align.norm_crop(img, base[i].kps)
        a_j = face_align.norm_crop(img, base[j].kps)
        imp.append(cos(embed(a_i), embed(a_j)))
print(f"    -> mean impostor = {np.mean(imp):.3f}, max = {np.max(imp):.3f}")

print(f"\n[3] SAME-PERSON, PERTURBED alignment (swap+jitter the 5 keypoints ~6px):")
def perturb(kps):
    k = kps.copy()
    k[[0, 1]] = k[[1, 0]]            # swap eyes (the bug we fixed)
    k += np.random.RandomState(0).randn(*k.shape) * 6.0  # landmark noise
    return k
pert = []
for i in range(n):
    a0 = face_align.norm_crop(img, base[i].kps)
    a1 = face_align.norm_crop(img, perturb(base[i].kps))  # same photo, bad align
    pert.append(cos(embed(a0), embed(a1)))
print(f"    -> mean same-photo, perturbed-align = {np.mean(pert):.3f}")

print("\n=== VERDICT ===")
print(f"proper same-person {np.mean(same_scores):.3f} | impostor {np.mean(imp):.3f} | perturbed {np.mean(pert):.3f}")
if np.mean(same_scores) > 0.45:
    print("Model+preprocessing are GOOD. The app's low scores must be ALIGNMENT.")
else:
    print("Even proper alignment is low -> our AdaFace channel order / normalization is wrong.")
