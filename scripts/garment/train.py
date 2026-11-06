#!/usr/bin/env python3
"""
Trains the garment head (head.py) on precomputed chunks (extract.py), CPU only.

  python train.py --train 'chunks/train_*' 'chunks/coco_*' --val 'chunks/val_*' --pca pca.npz \
      --out garment_head.pt --epochs 6 --hours 4.5

Loss (at the model's 1/4 resolution, labels nearest-downsampled):
  * cross-entropy over the 27 garment channels, class-balanced (1/sqrt(freq), capped),
    255 = ignore (the people on COCO images, whose clothes are not annotated);
  * BCE for the 4 part channels (Fashionpedia only) and the person channel (COCO person
    masks; on Fashionpedia only worn garments are known to be person);
  * 0.4 x CE on the token-grid auxiliary output.
Augmentation: horizontal flip (features, image and labels together) and mild colour jitter
on the stem's image input. Saves the best checkpoint by val garment mIoU.
"""
import argparse
import glob
import json
import os
import sys
import time

import cv2
import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backbone as bb    # noqa: E402
from head import GarmentHead   # noqa: E402

NUM_CLASSES, NUM_PARTS = 27, 4
NAMES = ["none", "shirt", "top", "sweater", "cardigan", "jacket", "vest", "pants", "shorts", "skirt", "coat", "dress",
         "jumpsuit", "cape", "glasses", "hat", "headband", "tie", "glove", "watch", "belt", "leg warmer", "tights",
         "sock", "shoe", "bag", "scarf"]


class Chunks(torch.utils.data.Dataset):
    def __init__(self, dirs, flip=False, jitter=False):
        self.items = []
        self.feats, self.rgb, self.lab = [], [], []
        for d in sorted(dirs):
            f = np.load(os.path.join(d, "feats.npy"), mmap_mode="r")
            if len(f) == 0:
                continue
            self.feats.append(f)
            self.rgb.append((np.memmap(os.path.join(d, "rgb.bin"), np.uint8, "r"), np.load(os.path.join(d, "rgb_off.npy"))))
            self.lab.append((np.memmap(os.path.join(d, "lab.bin"), np.uint8, "r"), np.load(os.path.join(d, "lab_off.npy"))))
            self.items += [(len(self.feats) - 1, i) for i in range(len(f))]
        self.flip, self.jitter = flip, jitter

    def __len__(self):
        return len(self.items)

    @staticmethod
    def _blob(b, i):
        data, off = b
        return cv2.imdecode(np.asarray(data[off[i]:off[i + 1]]), cv2.IMREAD_UNCHANGED)

    def __getitem__(self, k):
        c, i = self.items[k]
        feat = torch.from_numpy(np.asarray(self.feats[c][i], np.float32) / 127.0).permute(2, 0, 1)   # C,48,32
        rgb = cv2.cvtColor(self._blob(self.rgb[c], i), cv2.COLOR_BGR2RGB)
        lab = self._blob(self.lab[c], i)          # channels as written: [label, parts, person]
        label, parts, person = lab[..., 0], lab[..., 1], lab[..., 2]
        rgb = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
        if self.jitter:
            g = 1 + (torch.rand(3, 1, 1) - 0.5) * 0.2
            rgb = (rgb * g * (1 + (torch.rand(1) - 0.5) * 0.3)).clamp(0, 1)
        label = torch.from_numpy(label.astype(np.int64))
        bits = torch.from_numpy(parts.astype(np.int64))
        parts = torch.stack([(bits >> b) & 1 for b in range(NUM_PARTS)]).float()
        if (bits == 255).any():
            parts[:, bits == 255] = -1                                     # unknown (COCO)
        person = torch.from_numpy(person.astype(np.float32)).unsqueeze(0)  # 0 / 1 / 2 = unknown
        if self.flip and torch.rand(1).item() < 0.5:
            feat, rgb, label, parts, person = feat.flip(-1), rgb.flip(-1), label.flip(-1), parts.flip(-1), person.flip(-1)
        return feat, rgb, label, parts, person


def class_weights(ds, n=800):
    counts = np.zeros(NUM_CLASSES)
    idx = np.random.RandomState(0).choice(len(ds), min(n, len(ds)), replace=False)
    for k in idx:
        c, i = ds.items[k]
        lab = Chunks._blob(ds.lab[c], i)[..., 0]
        counts += np.bincount(lab.ravel(), minlength=256)[:NUM_CLASSES]
    freq = counts / counts.sum()
    w = 1 / np.sqrt(np.maximum(freq, 1e-5))
    w = w / w[1:].mean()
    return torch.tensor(np.clip(w, 0.05, 4.0), dtype=torch.float32), freq


def evaluate(model, loader):
    model.eval()
    inter = np.zeros(NUM_CLASSES); union = np.zeros(NUM_CLASSES)
    pinter = np.zeros(NUM_PARTS); punion = np.zeros(NUM_PARTS)
    hinter = hunion = 0
    correct = total = 0
    with torch.inference_mode():
        for feat, rgb, label, parts, person in loader:
            lg, pl, ps, _ = model(feat, rgb)
            size = label.shape[-2:]
            lg = F.interpolate(lg, size=size, mode="bilinear", align_corners=False)
            pl = F.interpolate(pl, size=size, mode="bilinear", align_corners=False)
            ps = F.interpolate(ps, size=size, mode="bilinear", align_corners=False)
            pred = lg.argmax(1)
            valid = label != 255
            correct += ((pred == label) & valid).sum().item(); total += valid.sum().item()
            for c in range(NUM_CLASSES):
                p, t = (pred == c) & valid, label == c
                inter[c] += (p & t).sum().item(); union[c] += (p | t).sum().item()
            pp = pl > 0
            for c in range(NUM_PARTS):
                t = parts[:, c] > 0.5
                ok = parts[:, c] >= 0
                pinter[c] += (pp[:, c] & t).sum().item(); punion[c] += ((pp[:, c] & ok) | t).sum().item()
            known = person[:, 0] != 2
            hp, ht = (ps[:, 0] > 0) & known, person[:, 0] == 1
            hinter += (hp & ht).sum().item(); hunion += (hp | ht).sum().item()
    iou = inter / np.maximum(union, 1)
    present = union > 0
    model.train()
    return {"miou": float(iou[present].mean()), "miou_garments": float(iou[1:][present[1:]].mean()),
            "pixel_acc": correct / max(1, total), "iou": {NAMES[c]: round(float(iou[c]), 4) for c in range(NUM_CLASSES)},
            "part_iou": [round(float(x), 4) for x in pinter / np.maximum(punion, 1)],
            "person_iou": round(hinter / max(1, hunion), 4)}


def losses(model, batch, w, part_pos):
    feat, rgb, label, parts, person = batch
    lg, pl, ps, aux = model(feat, rgb)
    hw = lg.shape[-2:]
    lab4 = label[:, 1::2, 1::2]
    par4 = parts[:, :, 1::2, 1::2]
    per4 = person[:, :, 1::2, 1::2]
    assert lab4.shape[-2:] == hw, (lab4.shape, hw)
    aux = F.interpolate(aux, size=hw, mode="bilinear", align_corners=False)
    pmask = (par4 >= 0).float()
    hmask = (per4 != 2).float()
    ce = F.cross_entropy(lg, lab4, weight=w, ignore_index=255)
    ce_aux = F.cross_entropy(aux, lab4, weight=w, ignore_index=255)
    bce_p = (F.binary_cross_entropy_with_logits(pl, par4.clamp(min=0), pos_weight=part_pos, reduction="none")
             * pmask).sum() / pmask.sum().clamp(min=1)
    bce_h = (F.binary_cross_entropy_with_logits(ps, per4.clamp(max=1), reduction="none") * hmask).sum() / hmask.sum().clamp(min=1)
    return ce + 0.4 * ce_aux + 0.5 * bce_p + 0.5 * bce_h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", nargs="+", required=True)
    ap.add_argument("--val", nargs="+", required=True)
    ap.add_argument("--pca", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=6, help="upper bound; the time budget usually ends training first")
    ap.add_argument("--hours", type=float, default=4.5, help="this job's training time")
    ap.add_argument("--budget_hours", type=float, default=0, help="the LR schedule's length over all stages (0 = --hours)")
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--mid", type=int, default=256)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--eval_every", type=int, default=1000)
    ap.add_argument("--resume", help="a previous stage's *_last.pt: continue its schedule")
    ap.add_argument("--init", help="start from these weights (a finished head) with a fresh schedule")
    ap.add_argument("--stages", type=int, default=1, help="(read by the workflow)")
    a = ap.parse_args()
    import math
    torch.set_num_threads(max(1, (os.cpu_count() or 4) - a.workers))
    torch.manual_seed(0)
    tr_dirs = [d for p in a.train for d in glob.glob(p)]
    va_dirs = [d for p in a.val for d in glob.glob(p)]
    train = Chunks(tr_dirs, flip=True, jitter=True)
    val = Chunks(va_dirs)
    print(f"train {len(train)} samples from {len(tr_dirs)} chunks, val {len(val)}", flush=True)
    in_ch = train.feats[0].shape[-1]
    model = GarmentHead(in_ch, mid=a.mid)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-4)
    done_s, step, best, history = 0.0, 0, -1.0, []
    if a.init and not a.resume:
        model.load_state_dict(torch.load(a.init, map_location="cpu", weights_only=False)["state_dict"])
        print(f"initialised from {a.init}", flush=True)
    if a.resume:
        ck = torch.load(a.resume, map_location="cpu", weights_only=False)
        model.load_state_dict(ck["state_dict"]); opt.load_state_dict(ck["opt"])
        done_s, step, best, history = ck["done_s"], ck["step"], ck["best"], ck["history"]
        torch.manual_seed(step)
        print(f"resumed at step {step}, {done_s / 3600:.2f} h done, best {best:.4f}", flush=True)
    w, freq = class_weights(train)
    print("class freq", {NAMES[c]: round(float(freq[c]), 5) for c in range(NUM_CLASSES)}, flush=True)
    tl = torch.utils.data.DataLoader(train, batch_size=a.batch, shuffle=True, num_workers=a.workers, drop_last=True,
                                     persistent_workers=a.workers > 0)
    vl = torch.utils.data.DataLoader(val, batch_size=a.batch, shuffle=False, num_workers=a.workers)
    budget = (a.budget_hours or a.hours) * 3600
    max_steps = a.epochs * len(tl)

    def set_lr(progress):
        # Linear warm-up over the first 3%, then cosine to zero at the end of the whole budget
        # (all stages), so the run anneals properly even when it is cut into 6-hour jobs.
        f = min(1.0, progress / 0.03) * 0.5 * (1 + math.cos(math.pi * min(1.0, progress)))
        for g in opt.param_groups:
            g["lr"] = a.lr * max(f, 0.0)
        return a.lr * f

    part_pos = torch.tensor([8.0, 4.0, 4.0, 2.0]).view(1, -1, 1, 1)
    t0 = time.time()
    stem = os.path.splitext(a.out)[0]

    def progress():
        return max(step / max_steps, (done_s + time.time() - t0) / budget)

    def checkpoint(final):
        nonlocal best
        m = evaluate(model, vl)
        m.update(step=step, hours=(done_s + time.time() - t0) / 3600)
        history.append(m)
        print(f"VAL step {step}: miou {m['miou']:.4f} garments {m['miou_garments']:.4f} acc {m['pixel_acc']:.4f} "
              f"parts {m['part_iou']} person {m['person_iou']}", flush=True)
        print(f"  {m['iou']}", flush=True)
        if m["miou_garments"] > best:
            best = m["miou_garments"]
            torch.save({"state_dict": model.state_dict(), "in_ch": in_ch, "mid": a.mid, "pca": dict(np.load(a.pca)),
                        "layers": list(bb.LAYERS), "backbone": bb.BACKBONE, "val": m}, a.out)
            print(f"  saved best -> {a.out}", flush=True)
        json.dump(history, open(stem + "_history.json", "w"), indent=1)
        if final:
            torch.save({"state_dict": model.state_dict(), "opt": opt.state_dict(), "done_s": done_s + time.time() - t0,
                        "step": step, "best": best, "history": history}, stem + "_last.pt")

    model.train()
    run, n, ep = 0.0, 0, 0
    stop = False
    while not stop:
        for batch in tl:
            pr = progress()
            if pr >= 1.0 or time.time() - t0 > a.hours * 3600:
                stop = True
                break
            lr = set_lr(pr)
            loss = losses(model, batch, w, part_pos)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step(); step += 1
            run += loss.item(); n += 1
            if step % 100 == 0:
                el = time.time() - t0
                print(f"ep {ep} step {step} loss {run / n:.4f} lr {lr:.2e} {el / 60:.1f} min ({el / max(1, n):.2f}s/step) "
                      f"progress {pr:.3f}", flush=True)
                run, n = 0.0, 0
            if step % a.eval_every == 0:
                checkpoint(False)
        ep += 1
    print("time budget reached" if progress() < 1.0 else "schedule complete", flush=True)
    checkpoint(True)


if __name__ == "__main__":
    main()
