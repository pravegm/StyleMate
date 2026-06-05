#!/usr/bin/env python3
"""
End-to-end verification of the Core ML SCRFD detector + a hand-written decoder
(the exact logic I'll port to Swift). If this reproduces InsightFace-level
same-person scores (~0.9), the Core ML model + decoder are correct and safe to
port. SCRFD input: RGB, (x-127.5)/128, 640x640 letterbox (top-left, zero-pad).
"""
import cv2
import numpy as np
import torch
import coremltools as ct
from pathlib import Path
import adaface_net as net
import insightface
from insightface.utils import face_align

SCRIPT_DIR = Path(__file__).parent
ml = ct.models.MLModel(str(SCRIPT_DIR / "SCRFD10G.mlpackage"))
in_name = list(ml.get_spec().description.input)[0].name
# Map outputs by (length, inner-dim): scores=*,1 / bbox=*,4 / kps=*,10 ; stride by length.
out_meta = {o.name: [d for d in o.type.multiArrayType.shape] for o in ml.get_spec().description.output}
def pick(length, inner):
    for name, shp in out_meta.items():
        if shp[0] == length and shp[1] == inner:
            return name
    raise KeyError((length, inner))
STRIDES = [8, 16, 32]
LEN = {8: 12800, 16: 3200, 32: 800}

amodel = net.build_model("ir_101")
sd = torch.load(str(SCRIPT_DIR / "adaface_ir101_webface12m.ckpt"), map_location="cpu")["state_dict"]
amodel.load_state_dict({k[6:]: v for k, v in sd.items() if k.startswith("model.")})
amodel.eval()
def aembed(a112_bgr):
    t = (a112_bgr.astype(np.float32) - 127.5) / 127.5
    t = torch.from_numpy(np.ascontiguousarray(t.transpose(2, 0, 1))[None])
    with torch.no_grad():
        f = amodel(t)[0][0].numpy()
    return f / (np.linalg.norm(f) + 1e-9)

# ---- anchor centers per stride (2 anchors/location), cached ----
def anchor_centers(stride):
    hw = 640 // stride
    ac = np.stack(np.mgrid[:hw, :hw][::-1], axis=-1).astype(np.float32)  # (hw,hw,2) = (x,y)
    ac = (ac * stride).reshape(-1, 2)
    ac = np.stack([ac, ac], axis=1).reshape(-1, 2)  # 2 anchors/loc, interleaved
    return ac
AC = {s: anchor_centers(s) for s in STRIDES}

def detect(img_bgr, thresh=0.5):
    h, w = img_bgr.shape[:2]
    scale = min(640 / w, 640 / h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(img_bgr, (nw, nh))
    canvas = np.zeros((640, 640, 3), dtype=np.uint8)
    canvas[:nh, :nw] = resized
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32)
    blob = ((rgb - 127.5) / 128.0).transpose(2, 0, 1)[None]
    out = ml.predict({in_name: blob})
    boxes, kpss, scores = [], [], []
    for s in STRIDES:
        sc = np.array(out[pick(LEN[s], 1)]).reshape(-1)
        bb = np.array(out[pick(LEN[s], 4)]).reshape(-1, 4) * s
        kp = np.array(out[pick(LEN[s], 10)]).reshape(-1, 10) * s
        ac = AC[s]
        keep = np.where(sc >= thresh)[0]
        for i in keep:
            cx, cy = ac[i]
            x1, y1 = cx - bb[i, 0], cy - bb[i, 1]
            x2, y2 = cx + bb[i, 2], cy + bb[i, 3]
            pts = []
            for j in range(5):
                pts.append([cx + kp[i, j * 2], cy + kp[i, j * 2 + 1]])
            boxes.append([x1, y1, x2, y2]); kpss.append(pts); scores.append(sc[i])
    if not boxes:
        return []
    boxes = np.array(boxes); kpss = np.array(kpss); scores = np.array(scores)
    # NMS
    order = scores.argsort()[::-1]
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = (x2 - x1) * (y2 - y1)
    keep = []
    while order.size > 0:
        i = order[0]; keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]]); yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]]); yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0, xx2 - xx1) * np.maximum(0, yy2 - yy1)
        ovr = inter / (areas[i] + areas[order[1:]] - inter)
        order = order[1:][ovr <= 0.4]
    return [(kpss[i] / scale, scores[i]) for i in keep]  # kps back to original coords

def cos(a, b): return float(np.dot(a, b))

img = insightface.data.get_image("t1")
h, w = img.shape[:2]
M = cv2.getRotationMatrix2D((w / 2, h / 2), 12, 0.92)
img2 = cv2.warpAffine(img, M, (w, h), borderMode=cv2.BORDER_REPLICATE)

d1 = sorted(detect(img), key=lambda t: t[0][:, 0].min())
d2 = sorted(detect(img2), key=lambda t: t[0][:, 0].min())
print(f"Core ML SCRFD detected {len(d1)} faces (img), {len(d2)} (transformed)")
n = min(len(d1), len(d2))
same = []
for i in range(n):
    a0 = face_align.norm_crop(img, d1[i][0])
    a1 = face_align.norm_crop(img2, d2[i][0])
    same.append(cos(aembed(a0), aembed(a1)))
    print(f"   person {i}: same-person cos = {same[-1]:.3f}")
print(f"\n=== Core ML SCRFD + AdaFace same-person mean = {np.mean(same):.3f} ===")
print("If ~0.9, the Core ML detector + this decoder are correct -> port to Swift.")
