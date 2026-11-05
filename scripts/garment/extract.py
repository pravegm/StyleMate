#!/usr/bin/env python3
"""
Precomputes frozen-backbone features for garment-head training (CPU; one chunk per CI job).

  fit-pca:  python extract.py fit-pca --ann A.json --zip I.zip --prefix train/ --n 300 --dims 96,160 --out pca.npz
  extract:  python extract.py extract --ann A.json --zip I.zip --prefix train/ --chunk 0 --chunks 16 \
                --max 24000 --closeups 0.5 --pca pca.npz --out chunk_00/

The backbone is frozen, so its token maps are computed once per sample. To keep a chunk
small, each layer is projected onto its top principal components (fit on training images,
folded into the head's first layer at export) and stored as int8.

A chunk directory holds feats.npy int8 [S, 48, 32, C], rgb.bin/rgb_off.npy (JPEG q92 of the
672x448 input), lab.bin/lab_off.npy (PNG at 336x224: label, parts, person), meta.npy.
"""
import argparse
import os
import random
import sys
import time
import zipfile

import cv2
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backbone as bb          # noqa: E402
import fashionpedia as fp      # noqa: E402


def image_ids(ann, chunk, chunks, max_images, seed=0, dataset="fashionpedia"):
    if dataset == "coco":
        images, by = fp.coco_person_images(ann)
        ids = sorted(by)
    else:
        images, by = fp.load_annotations(ann)
        ids = sorted(i for i in by if any(a["category_id"] in fp.GARMENTS for a in by[i]))
    random.Random(seed).shuffle(ids)
    if max_images:
        ids = ids[:max_images]
    return images, by, ids[chunk::chunks]


def read_image(z, prefix, name):
    buf = np.frombuffer(z.read(prefix + name), np.uint8)
    return cv2.imdecode(buf, cv2.IMREAD_COLOR)


def to_tensor(rgbs):
    x = torch.from_numpy(np.stack(rgbs)).permute(0, 3, 1, 2).float() / 255.0
    return x


def fit_pca(a):
    torch.set_num_threads(os.cpu_count() or 4)
    images, by, ids = image_ids(a.ann, 0, 1, a.n, seed=1)
    z = zipfile.ZipFile(a.zip)
    net = bb.Backbone(bb.load_backbone())
    rng = random.Random(1)
    samples = [[] for _ in bb.LAYERS]
    t0 = time.time()
    for k, iid in enumerate(ids):
        im = images[iid]
        img = read_image(z, a.prefix, im["file_name"])
        rgbs = [s[1] for s in fp.samples_for(img, by[iid], im, rng, closeups=k % 2 == 0)]
        with torch.inference_mode():
            outs = net(to_tensor(rgbs))
        for li, o in enumerate(outs):
            t = o.permute(0, 2, 3, 1).reshape(-1, bb.EMBED).numpy()
            samples[li].append(t[np.random.RandomState(k).choice(len(t), 400, replace=False)])
        if k % 50 == 0:
            print(f"pca {k}/{len(ids)} {time.time() - t0:.0f}s", flush=True)
    res = {}
    for li, s in enumerate(samples):
        x = np.concatenate(s).astype(np.float64)
        mu = x.mean(0)
        u, sv, vt = np.linalg.svd(x - mu, full_matrices=False)
        var = sv ** 2 / (len(x) - 1)
        dims = [int(x) for x in str(a.dims).split(",")]
        comps = vt[: dims[li] if len(dims) > 1 else dims[0]]   # [dims, 384]
        proj = (x - mu) @ comps.T
        scale = 4.0 * proj.std(0)   # int8 covers +-4 sigma per component
        res[f"mean{li}"] = mu.astype(np.float32)
        res[f"comps{li}"] = comps.astype(np.float32)
        res[f"scale{li}"] = scale.astype(np.float32)
        ev = np.cumsum(var) / var.sum()
        print(f"layer {bb.LAYERS[li]}: explained variance " +
              ", ".join(f"{d}:{ev[d - 1]:.3f}" for d in (32, 64, 96, 128, 192, 256) if d <= len(ev)))
    np.savez(a.out, layers=np.array(bb.LAYERS), **res)
    print("saved", a.out)


def project(outs, pca):
    """[B,384,48,32] per layer -> int8 [B,48,32,sum(dims)]."""
    qs = []
    for li, o in enumerate(outs):
        t = o.permute(0, 2, 3, 1).numpy()                     # B,48,32,384
        p = (t - pca[f"mean{li}"]) @ pca[f"comps{li}"].T       # B,48,32,dims
        q = np.clip(np.round(p / pca[f"scale{li}"] * 127), -127, 127).astype(np.int8)
        qs.append(q)
    return np.concatenate(qs, -1)


def extract(a):
    torch.set_num_threads(os.cpu_count() or 4)
    images, by, ids = image_ids(a.ann, a.chunk, a.chunks, a.max, dataset=a.dataset)
    print(f"chunk {a.chunk}/{a.chunks}: {len(ids)} images", flush=True)
    z = zipfile.ZipFile(a.zip)
    pca = dict(np.load(a.pca))
    net = bb.Backbone(bb.load_backbone())
    rng = random.Random(1000 + a.chunk)
    os.makedirs(a.out, exist_ok=True)
    feats, rgb_bytes, lab_bytes, meta = [], [], [], []
    t0 = time.time()
    batch = []

    def flush():
        if not batch:
            return
        with torch.inference_mode():
            outs = net(to_tensor([b[1] for b in batch]))
        feats.append(project(outs, pca))
        for kind, rgb, label, parts, person, iid in batch:
            ok, j = cv2.imencode(".jpg", cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 92])
            rgb_bytes.append(j.tobytes())
            ok, p = cv2.imencode(".png", np.dstack([label, parts, person]))
            lab_bytes.append(p.tobytes())
            meta.append((iid, {"person": 0, "closeup": 1, "coco": 2}[kind]))
        batch.clear()

    for k, iid in enumerate(ids):
        im = images[iid]
        try:
            img = read_image(z, a.prefix, im["file_name"])
        except KeyError:
            continue
        if img is None:
            continue
        gen = fp.coco_samples_for(img, by[iid], im, rng) if a.dataset == "coco" else             fp.samples_for(img, by[iid], im, rng, closeups=rng.random() < a.closeups)
        for kind, rgb, label, parts, person in gen:
            batch.append((kind, rgb, label, parts, person, iid))
        if len(batch) >= 4:
            flush()
        if k % 100 == 0:
            el = time.time() - t0
            print(f"{k}/{len(ids)} images, {len(meta)} samples, {el:.0f}s ({el / max(1, k):.2f}s/img)", flush=True)
    flush()

    def save_blob(name, blobs):
        off = np.cumsum([0] + [len(b) for b in blobs]).astype(np.int64)
        with open(os.path.join(a.out, name + ".bin"), "wb") as f:
            for b in blobs:
                f.write(b)
        np.save(os.path.join(a.out, name + "_off.npy"), off)

    np.save(os.path.join(a.out, "feats.npy"), np.concatenate(feats) if feats else np.zeros((0, bb.TOK_H, bb.TOK_W, 1), np.int8))
    save_blob("rgb", rgb_bytes)
    save_blob("lab", lab_bytes)
    np.save(os.path.join(a.out, "meta.npy"), np.array(meta, np.int64).reshape(-1, 2))
    print(f"done: {len(meta)} samples in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["fit-pca", "extract"])
    ap.add_argument("--ann", required=True)
    ap.add_argument("--zip", required=True)
    ap.add_argument("--prefix", default="train/")
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--dims", default="96,160", help="principal components kept per layer")
    ap.add_argument("--chunk", type=int, default=0)
    ap.add_argument("--chunks", type=int, default=1)
    ap.add_argument("--max", type=int, default=0)
    ap.add_argument("--closeups", type=float, default=0.5)
    ap.add_argument("--pca")
    ap.add_argument("--dataset", choices=["fashionpedia", "coco"], default="fashionpedia")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    fit_pca(a) if a.mode == "fit-pca" else extract(a)
