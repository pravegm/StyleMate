"""
Fashionpedia -> training samples for StyleMate's GarmentSegmenter model.

Fashionpedia (https://fashionpedia.github.io) annotations are CC BY 4.0. The images
belong to their photographers (Flickr, Unsplash, Pexels, ... terms of use); they are
only read here to compute training samples and are never redistributed.

A sample mimics what the app feeds the model (WardrobeExtractor):
  * a *person crop*: the person grown to the grid's 2:3 portrait aspect, padded with
    neutral grey past the photo edge, or
  * a *close-up*: a head / hand / feet / small-item crop with 2-4x context, upsampled
    to the full input (the app's zoom passes for sunglasses, watches, bags, shoes).

Output per sample (H x W = 672 x 448 input):
  rgb    uint8 [672, 448, 3]
  label  uint8 [336, 224]   app channel: 0 = not a garment (skin, hair, scene), 1..26 =
                             Fashionpedia whole-garment classes 0..25 (+1); umbrella -> 0
  parts  uint8 [336, 224]   bit 0 hood, 1 collar, 2 lapel, 3 sleeve
"""
import json
import random

import cv2
import numpy as np
from pycocotools import mask as mask_utils

IN_H, IN_W = 672, 448
LAB_H, LAB_W = 336, 224
GREY = 128

# Fashionpedia category ids.
GARMENTS = list(range(0, 26))          # shirt .. scarf (umbrella = 26 is not worn)
PART_BITS = {27: 0, 28: 1, 29: 2, 31: 3}   # hood, collar, lapel, sleeve
SMALL_ITEMS = {13, 14, 15, 16, 17, 18, 19, 23, 24, 25}   # glasses hat headband tie glove watch belt shoe bag scarf
NUM_CLASSES = 27   # app channels 0..26
NUM_PARTS = 4


def load_annotations(path):
    d = json.load(open(path))
    by_image = {}
    for a in d["annotations"]:
        by_image.setdefault(a["image_id"], []).append(a)
    images = {im["id"]: im for im in d["images"]}
    return images, by_image


def _grow_to_aspect(x0, y0, x1, y1, aspect=IN_W / IN_H):
    w, h = x1 - x0, y1 - y0
    if w / h < aspect:
        nw = h * aspect
        x0 -= (nw - w) / 2; x1 += (nw - w) / 2
    else:
        nh = w / aspect
        y0 -= (nh - h) / 2; y1 += (nh - h) / 2
    return x0, y0, x1, y1


def _affine(rect, out_w, out_h):
    x0, y0, x1, y1 = rect
    sx, sy = out_w / (x1 - x0), out_h / (y1 - y0)
    return np.array([[sx, 0, -x0 * sx], [0, sy, -y0 * sy]], dtype=np.float64)


def _ann_mask_in_rect(a, im, rect, out_w, out_h):
    """Annotation mask rasterised straight into the crop rectangle at (out_w, out_h)."""
    seg = a["segmentation"]
    M = _affine(rect, out_w, out_h)
    if isinstance(seg, list):
        m = np.zeros((out_h, out_w), np.uint8)
        polys = []
        for p in seg:
            if len(p) < 6:
                continue
            pts = np.array(p, np.float64).reshape(-1, 2)
            pts = pts @ M[:, :2].T + M[:, 2]
            polys.append(np.round(pts * 8).astype(np.int32))   # 3 bits of sub-pixel precision
        if polys:
            cv2.fillPoly(m, polys, 1, lineType=cv2.LINE_8, shift=3)
        return m
    rle = seg
    if isinstance(rle["counts"], list):
        rle = mask_utils.frPyObjects(rle, rle["size"][0], rle["size"][1])
    full = mask_utils.decode(rle)
    return cv2.warpAffine(full, M, (out_w, out_h), flags=cv2.INTER_NEAREST, borderValue=0)


def person_box(anns, W, H):
    """Union of the worn items, grown for the head and feet the way the app's person
    crop (from the body mask) includes them."""
    boxes = [a["bbox"] for a in anns if a["category_id"] in GARMENTS]
    if not boxes:
        return None
    x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes); y1 = max(b[1] + b[3] for b in boxes)
    w, h = x1 - x0, y1 - y0
    has_head_item = any(a["category_id"] in (13, 14, 15) and a["bbox"][1] < y0 + 0.15 * h for a in anns)
    top = 0.04 if has_head_item else 0.24
    return (x0 - 0.06 * w, y0 - top * h, x1 + 0.06 * w, y1 + 0.03 * h)


def crop_rects(anns, im, rng, closeups=True):
    """Yields (kind, rect) crops for one image: one person crop, plus maybe a close-up."""
    W, H = im["width"], im["height"]
    pb = person_box(anns, W, H)
    if pb is None:
        return []
    out = []
    # Person crop with a little jitter in margins and position.
    x0, y0, x1, y1 = pb
    w, h = x1 - x0, y1 - y0
    j = lambda s: rng.uniform(-s, s)
    r = (x0 + j(0.04) * w, y0 + j(0.03) * h, x1 + j(0.04) * w, y1 + j(0.03) * h)
    out.append(("person", _grow_to_aspect(*r)))
    if closeups:
        small = [a for a in anns if a["category_id"] in SMALL_ITEMS and a["area"] > 64]
        if small and rng.random() < 0.8:
            a = rng.choice(small)
            bx, by, bw, bh = a["bbox"]
            side = min(max(bw, bh) * rng.uniform(2.0, 4.5), 0.6 * h)
            cx, cy = bx + bw / 2 + j(0.25) * bw, by + bh / 2 + j(0.25) * bh
            out.append(("closeup", _grow_to_aspect(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)))
        else:
            # Head or feet band of the person.
            if rng.random() < 0.5:
                rr = (x0, y0, x1, y0 + 0.3 * h)
            else:
                rr = (x0, y0 + 0.75 * h, x1, y1)
            out.append(("closeup", _grow_to_aspect(*rr)))
    return out


def warp_image(img_bgr, rect):
    """The crop rectangle of the photo at the model input size, grey past the photo edge
    (area-averaged first when shrinking, as the app's Core Graphics resize does)."""
    x0, y0, x1, y1 = rect
    s = IN_W / (x1 - x0)
    if s < 0.7:
        h, w = img_bgr.shape[:2]
        k = s / 0.9
        img_bgr = cv2.resize(img_bgr, (max(1, round(w * k)), max(1, round(h * k))), interpolation=cv2.INTER_AREA)
        kx = img_bgr.shape[1] / w; ky = img_bgr.shape[0] / h
        rect = (x0 * kx, y0 * ky, x1 * kx, y1 * ky)
    M = _affine(rect, IN_W, IN_H)
    rgb = cv2.warpAffine(img_bgr, M, (IN_W, IN_H), flags=cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_CONSTANT, borderValue=(GREY, GREY, GREY))
    return cv2.cvtColor(rgb, cv2.COLOR_BGR2RGB)


def photo_mask(im, rect):
    """1 inside the real photo, 0 on the grey padding, at label resolution."""
    m = np.ones((im["height"], im["width"]), np.uint8)
    return cv2.warpAffine(m, _affine(rect, LAB_W, LAB_H), (LAB_W, LAB_H), flags=cv2.INTER_NEAREST, borderValue=0)


def render_sample(img_bgr, anns, im, rect):
    """Crop + label maps for one rectangle (photo pixels, may extend past the photo).

    person: 1 = a worn garment (so certainly a person), 0 = grey padding, 2 = unknown
    (Fashionpedia has no person / skin masks; COCO samples teach that channel)."""
    rgb = warp_image(img_bgr, rect)
    label = np.zeros((LAB_H, LAB_W), np.uint8)
    parts = np.zeros((LAB_H, LAB_W), np.uint8)
    garments = sorted([a for a in anns if a["category_id"] in GARMENTS], key=lambda a: -a["area"])
    for a in garments:     # big first: belts, watches, bags, glasses paint over the garment they sit on
        m = _ann_mask_in_rect(a, im, rect, LAB_W, LAB_H)
        label[m != 0] = a["category_id"] + 1
    for a in anns:
        b = PART_BITS.get(a["category_id"])
        if b is not None:
            m = _ann_mask_in_rect(a, im, rect, LAB_W, LAB_H)
            parts[m != 0] |= (1 << b)
    person = np.where(photo_mask(im, rect) != 0, 2, 0).astype(np.uint8)
    worn = (label != 0) & (label != 25)          # a bag may be carried away from the body
    person[worn] = 1
    return rgb, label, parts, person


def samples_for(img_bgr, anns, im, rng, closeups=True):
    for kind, rect in crop_rects(anns, im, rng, closeups):
        rgb, label, parts, person = render_sample(img_bgr, anns, im, rect)
        yield kind, rgb, label, parts, person


# ------------------------------------------------------------------ COCO people
# COCO 2017 (https://cocodataset.org): annotations CC BY 4.0, images under the Flickr terms of
# use (read for training only, never redistributed). Person masks teach the person channel;
# outside every person nothing is a worn garment, so the garment channel learns "none" there
# and ignores (255) the people, whose clothes are not annotated.

IGNORE = 255


def coco_person_images(ann_path, min_share=0.04):
    d = json.load(open(ann_path))
    images = {im["id"]: im for im in d["images"]}
    by = {}
    for a in d["annotations"]:
        if a["category_id"] == 1:
            by.setdefault(a["image_id"], []).append(a)
    keep = {}
    for iid, anns in by.items():
        im = images[iid]
        big = [a for a in anns if not a["iscrowd"] and a["area"] >= min_share * im["width"] * im["height"]]
        if big:
            keep[iid] = anns
    return images, keep


def coco_samples_for(img_bgr, anns, im, rng):
    """One person crop (a random large person, grown to 2:3 like the app's crop)."""
    big = [a for a in anns if not a["iscrowd"]]
    a = max(big, key=lambda a: a["area"]) if rng.random() < 0.7 else rng.choice(big)
    x, y, w, h = a["bbox"]
    j = lambda s: rng.uniform(-s, s)
    rect = _grow_to_aspect(x - (0.06 + j(0.04)) * w, y - (0.04 + j(0.03)) * h, x + w * (1.06 + j(0.04)), y + h * (1.04 + j(0.03)))
    rgb = warp_image(img_bgr, rect)
    inside = photo_mask(im, rect)
    person = np.zeros((LAB_H, LAB_W), np.uint8)
    crowd = np.zeros((LAB_H, LAB_W), np.uint8)
    for b in anns:
        m = _ann_mask_in_rect(b, im, rect, LAB_W, LAB_H)
        if b["iscrowd"]:
            crowd |= m
        else:
            person |= m
    # Polygon edges are rough: ignore a 1-px band around each person in both channels.
    edge = cv2.dilate(person, np.ones((3, 3), np.uint8)) - cv2.erode(person, np.ones((3, 3), np.uint8))
    label = np.where(person != 0, IGNORE, 0).astype(np.uint8)
    label[(crowd != 0) | (edge != 0)] = IGNORE
    label[inside == 0] = 0
    pers = person.copy()
    pers[(crowd != 0) | (edge != 0)] = 2
    pers[inside == 0] = 0
    parts = np.full((LAB_H, LAB_W), IGNORE, np.uint8)     # parts unknown on COCO
    yield "coco", rgb, label, parts, pers
