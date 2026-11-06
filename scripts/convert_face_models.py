#!/usr/bin/env python3
"""
Convert StyleMate's commercially usable face models (OpenCV Zoo) to Core ML, with parity checks.

  YuNet 2023mar  face_detection_yunet_2023mar.onnx  -> FaceDetectYuNet.mlpackage  (MIT)
  SFace 2021dec  face_recognition_sface_2021dec.onnx -> FaceEmbedSFace.mlpackage   (Apache-2.0)

Sources (OpenCV Zoo, pinned commit; scripts/build_face_models.sh downloads them and checks
their SHA-256 before calling this script):
  https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet    "All files in this directory are licensed under MIT License"
  https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface  "All files in this directory are licensed under Apache 2.0 License"

Route: ONNX -> PyTorch (onnx2torch) -> TorchScript trace -> coremltools ML program.
Parity (must pass, or the script fails and CI goes red):
  1. onnx2torch vs onnxruntime on random input          (conversion of the graph)
  2. Core ML vs onnxruntime on random input and on real face photos (the test fixtures):
     YuNet: every output channel cos > 0.9999, decoded faces identical (landmarks within 1 px);
     SFace: embedding cos > 0.999 (fp16 weights).

I/O contracts (Swift: YuNetDetector, FaceMatchingService.createInputMultiArray):
  YuNet: input "input" [1,3,640,640] float32 BGR raw 0..255; outputs cls_/obj_ [N,1],
         bbox_ [N,4], kps_ [N,10] for strides 8/16/32. fp32 (0.2 MB, no reason to round).
  SFace: input "data" [1,3,112,112] float32 RGB raw 0..255 (the graph does (x-127.5)/128);
         output "embedding" [1,128]. fp16.

Usage: python convert_face_models.py <yunet.onnx> <sface.onnx> <out_dir> [fixture_photo ...]
"""
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnx2torch import convert as onnx2torch_convert
from PIL import Image

YUNET_OUTPUTS = [f"{k}_{s}" for k in ("cls", "obj", "bbox", "kps") for s in (8, 16, 32)]
ort.set_default_logger_severity(3)   # SFace lists its weights as graph inputs; ORT warns per weight
rng = np.random.default_rng(0)


def cos(a, b):
    a, b = np.asarray(a, np.float64).ravel(), np.asarray(b, np.float64).ravel()
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def strip_initializer_inputs(model):
    """Old exporters list weights as graph inputs too (SFace); onnx2torch wants real inputs only."""
    init = {i.name for i in model.graph.initializer}
    keep = [i for i in model.graph.input if i.name not in init]
    del model.graph.input[:]
    model.graph.input.extend(keep)
    return model


def to_torch(onnx_path, shape):
    m = strip_initializer_inputs(onnx.load(str(onnx_path)))
    t = onnx2torch_convert(m).eval()
    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    in_name = [i.name for i in m.graph.input][0]
    x = (rng.random(shape) * 255).astype(np.float32)
    ref = sess.run(None, {in_name: x})
    with torch.no_grad():
        out = t(torch.from_numpy(x))
    out = out if isinstance(out, (list, tuple)) else [out]
    for r, o in zip(ref, out):
        c = cos(r, o.numpy())
        assert c > 0.99999, f"onnx2torch diverges from onnxruntime ({onnx_path.name}): cos {c}"
    print(f"  onnx2torch == onnxruntime on {len(ref)} outputs")
    traced = torch.jit.trace(t, torch.from_numpy(x))
    return traced, sess, in_name


# ----------------------------------------------------------------------------- YuNet decode

def letterbox_bgr(img: Image.Image, size=640):
    w, h = img.size
    s = min(size / w, size / h)
    nw, nh = max(1, round(w * s)), max(1, round(h * s))
    rgb = np.asarray(img.convert("RGB").resize((nw, nh), Image.BILINEAR), np.float32)
    canvas = np.zeros((size, size, 3), np.float32)
    canvas[:nh, :nw] = rgb[:, :, ::-1]
    return canvas.transpose(2, 0, 1)[None], s


def decode(outs, scale, thr=0.6):
    faces = []
    for s in (8, 16, 32):
        cls = np.clip(np.asarray(outs[f"cls_{s}"]).reshape(-1), 0, 1)
        obj = np.clip(np.asarray(outs[f"obj_{s}"]).reshape(-1), 0, 1)
        bb = np.asarray(outs[f"bbox_{s}"]).reshape(-1, 4)
        kp = np.asarray(outs[f"kps_{s}"]).reshape(-1, 10)
        sc = np.sqrt(cls * obj)
        cols = 640 // s
        for i in np.where(sc >= thr)[0]:
            r, c = divmod(int(i), cols)
            k = np.array([[(kp[i, 2 * j] + c) * s, (kp[i, 2 * j + 1] + r) * s] for j in range(5)]) / scale
            faces.append((float(sc[i]), k))
    faces.sort(key=lambda f: -f[0])
    kept = []
    for f in faces:   # crude NMS by nose distance: enough to compare two decoders
        if all(np.linalg.norm(f[1][2] - g[1][2]) > 8 for g in kept):
            kept.append(f)
    return kept


def convert_yunet(onnx_path, out_dir, photos):
    print("YuNet:")
    traced, sess, in_name = to_torch(onnx_path, (1, 3, 640, 640))
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, 640, 640))],
        outputs=[ct.TensorType(name=n) for n in YUNET_OUTPUTS],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT32,
    )
    ml.author = "Wei Wu, Hanyang Peng, Shiqi Yu (YuNet); OpenCV Zoo"
    ml.license = "MIT (https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet)"
    ml.short_description = ("YuNet 2023mar face detector + 5 landmarks. Input [1,3,640,640] BGR raw 0-255, "
                            "top-left letterbox. Converted to Core ML for StyleMate (unmodified weights).")
    ml.version = "2023mar"
    path = out_dir / "FaceDetectYuNet.mlpackage"
    ml.save(str(path))
    ml = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)

    names = [o.name for o in sess.get_outputs()]
    inputs = [((rng.random((1, 3, 640, 640)) * 255).astype(np.float32), None, "random")]
    for p in photos:
        x, s = letterbox_bgr(Image.open(p))
        inputs.append((x, s, Path(p).name))
    worst = 1.0
    for x, s, label in inputs:
        ref = dict(zip(names, sess.run(None, {in_name: x})))
        got = ml.predict({"input": x})
        for n in YUNET_OUTPUTS:
            c = cos(ref[n], got[n])
            worst = min(worst, c)
            assert c > 0.9999, f"YuNet Core ML {n} diverges on {label}: cos {c}"
        if s is not None:
            a, b = decode(ref, s), decode(got, s)
            assert len(a) == len(b), f"YuNet Core ML finds {len(b)} faces on {label}, onnxruntime {len(a)}"
            for fa, fb in zip(a, b):
                d = float(np.abs(fa[1] - fb[1]).max())
                assert d < 1.0 and abs(fa[0] - fb[0]) < 0.01, f"YuNet face differs on {label}: {d:.2f}px"
            print(f"  {label}: {len(a)} face(s), identical to onnxruntime")
    print(f"  Core ML vs onnxruntime: worst output cos {worst:.6f}. Saved {path}")
    return sess, in_name


def convert_sface(onnx_path, out_dir, photos, yunet_sess, yunet_in):
    print("SFace:")
    traced, sess, in_name = to_torch(onnx_path, (1, 3, 112, 112))
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="data", shape=(1, 3, 112, 112))],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )
    ml.author = "Yaoyao Zhong et al. (SFace); ONNX by Chengrui Wang; OpenCV Zoo"
    ml.license = "Apache-2.0 (https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)"
    ml.short_description = ("SFace 2021dec face embedding (MobileFaceNet, 128-d). Input [1,3,112,112] RGB raw 0-255 "
                            "aligned to the ArcFace 5-point template. Modified: converted to Core ML, fp16 weights.")
    ml.version = "2021dec"
    path = out_dir / "FaceEmbedSFace.mlpackage"
    ml.save(str(path))
    ml = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)

    crops = [((rng.random((1, 3, 112, 112)) * 255).astype(np.float32), "random")]
    for p in photos:   # real faces: YuNet's box on the photo, cropped square and resized
        img = Image.open(p).convert("RGB")
        x, s = letterbox_bgr(img)
        outs = dict(zip([o.name for o in yunet_sess.get_outputs()], yunet_sess.run(None, {yunet_in: x})))
        for score, k in decode(outs, s)[:2]:
            c = k.mean(0); half = max(16.0, float(np.linalg.norm(k[1] - k[0])) * 1.4)
            box = (int(c[0] - half), int(c[1] - half), int(c[0] + half), int(c[1] + half))
            face = np.asarray(img.crop(box).resize((112, 112), Image.BILINEAR), np.float32)
            crops.append((face.transpose(2, 0, 1)[None], Path(p).name))
    worst = 1.0
    for x, label in crops:
        ref = sess.run(None, {in_name: x})[0]
        got = np.asarray(ml.predict({"data": x})["embedding"])
        c = cos(ref, got)
        worst = min(worst, c)
        assert got.size == 128, f"SFace output has {got.size} values"
        assert c > 0.999, f"SFace Core ML diverges on {label}: cos {c}"
    print(f"  Core ML vs onnxruntime on {len(crops)} inputs ({len(crops) - 1} real faces): worst cos {worst:.5f}. Saved {path}")


if __name__ == "__main__":
    yunet, sface, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    photos = sys.argv[4:]
    out.mkdir(parents=True, exist_ok=True)
    ys, yin = convert_yunet(yunet, out, photos)
    convert_sface(sface, out, photos, ys, yin)
    print("Face models ready.")
