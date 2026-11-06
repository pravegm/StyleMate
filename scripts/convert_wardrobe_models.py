#!/usr/bin/env python3
"""
Builds the on-device wardrobe models + the attribute vocabulary into StyleMate/ML/
(git-ignored; the Xcode synchronized group bundles whatever is there). Every model here is
licensed for commercial use (docs/MODEL-LICENSING.md):

  GarmentNet.mlpackage      StyleMate's own garment segmenter: frozen DINOv2 ViT-S/14-reg4
                            backbone (Meta, Apache-2.0) + a head trained from scratch on
                            Fashionpedia (annotations CC BY 4.0) and COCO people (CC BY 4.0)
                            by .github/workflows/garment-model.yml. In 448x672 (W x H) RGB.
                            Out: `classes` [1,1,576,384] (0 scene, 1..26 Fashionpedia garment,
                            27 person-not-garment), `probs` [1,27,144,96] garment softmax,
                            `aux` [1,5,144,96] hood/collar/lapel/sleeve/person sigmoid.
  FashionEncoder.mlpackage  Marqo-FashionSigLIP image tower (Apache-2.0). 224x224
                            RGB -> L2-normalized 768-d embedding. Zero-shot product
                            / pattern / material / sleeve... and duplicate matching.
  FashionVocabulary.json    Text embeddings for every label the app classifies
                            into, precomputed so no text tower ships.

GARMENT_HEAD=path/to/garment_head.pt (the `garment-head` artifact of the training run pinned
in scripts/garment/model.json; CI downloads it). fp16 compute; GarmentNet has int8 weights,
the encoder stays fp16; both parity-checked against PyTorch.

The FASHN / SegFormer converter this replaced is in scripts/research/ (non-commercial, unused).
"""
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "StyleMate" / "ML"
OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(ROOT / "scripts" / "garment"))


def quantize_int8(ml):
    # 8-bit symmetric weight quantization: half the size of fp16; masks checked by `parity`.
    cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    return cto.linear_quantize_weights(ml, cfg)


def fixture_images(w, h, n=4):
    from PIL import Image
    p = ROOT / "StyleMateTests" / "Fixtures" / "photos"
    files = sorted(p.glob("*.jpg"))[:n] if p.exists() else []
    if not files:
        return [Image.fromarray((np.random.rand(h, w, 3) * 255).astype(np.uint8))]
    return [Image.open(f).convert("RGB").resize((w, h)) for f in files]


def to_tensor(img):
    return torch.from_numpy(np.array(img)).permute(2, 0, 1).float().unsqueeze(0) / 255.0


def save(ml, name):
    dst = OUT / name
    if dst.exists():
        shutil.rmtree(dst)
    ml.save(str(dst))
    print(f"  saved {dst}")


# ---------------------------------------------------------------- garment segmenter
def build_garment_net():
    head_path = os.environ.get("GARMENT_HEAD", str(ROOT / "scripts" / "garment" / ".artifacts" / "garment_head.pt"))
    pin = json.loads((ROOT / "scripts" / "garment" / "model.json").read_text())
    digest = hashlib.sha256(Path(head_path).read_bytes()).hexdigest()
    if pin.get("sha256") and digest != pin["sha256"]:
        sys.exit(f"garment head {head_path} sha256 {digest} != pinned {pin['sha256']}")
    print(f"Converting GarmentNet (head {head_path}, sha256 {digest[:16]}...)")
    import timm.layers
    timm.layers.set_fused_attn(False)      # plain matmul attention converts cleanly
    import export as gx
    ckpt = torch.load(head_path, map_location="cpu", weights_only=False)
    net = gx.GarmentNet(ckpt).eval()
    imgs = fixture_images(448, 672)
    ex = to_tensor(imgs[0])
    with torch.no_grad():
        traced = torch.jit.trace(net, ex)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 672, 448), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="classes", dtype=np.float16), ct.TensorType(name="probs", dtype=np.float16),
                 ct.TensorType(name="aux", dtype=np.float16)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    ml = quantize_int8(ml)
    ml.short_description = ("StyleMate GarmentNet: DINOv2 ViT-S/14 (Apache-2.0) + head trained on Fashionpedia (CC BY 4.0) "
                            "and COCO people (CC BY 4.0). Garment class per pixel on a 576x384 grid.")
    ml.author = "StyleMate"
    ml.license = "Backbone: Apache-2.0 (Meta DINOv2). Head: StyleMate, trained on CC BY 4.0 annotations."
    ml.user_defined_metadata.update({"head_sha256": digest, "training_run": str(pin.get("run_id", "")),
                                     "backbone": "timm/vit_small_patch14_reg4_dinov2.lvd142m"})
    # Parity on the fixture photos: Core ML (fp16 compute, int8 weights) vs PyTorch fp32.
    agree, pagree = [], []
    for img in imgs:
        with torch.no_grad():
            rc, rp, ra = net(to_tensor(img))
        out = ml.predict({"image": img})
        gc = np.array(out["classes"]).astype(np.int32)
        agree.append(float((gc == rc.numpy().astype(np.int32)).mean()))
        gp = np.array(out["probs"]).astype(np.float32)
        pagree.append(float((gp.argmax(1) == rp.numpy().argmax(1)).mean()))
    print(f"  GarmentNet parity: classes agreement {np.round(agree, 4).tolist()}, low-res argmax {np.round(pagree, 4).tolist()}")
    assert min(agree) > 0.97 and min(pagree) > 0.97, "GarmentNet Core ML diverges from PyTorch"
    save(ml, "GarmentNet.mlpackage")


build_garment_net()

# ---------------------------------------------------------------- encoder + vocabulary
import open_clip  # noqa: E402
print("Converting Marqo-FashionSigLIP image tower ...")
clip, _, _ = open_clip.create_model_and_transforms("hf-hub:Marqo/marqo-fashionSigLIP")
tok = open_clip.get_tokenizer("hf-hub:Marqo/marqo-fashionSigLIP")
clip.eval()


class Enc(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, x):                           # RGB in [0,1]
        e = self.m.encode_image((x - 0.5) / 0.5)
        return e / e.norm(dim=-1, keepdim=True)


enc = Enc(clip).eval()
img = fixture_images(224, 224, 1)[0]
ex = to_tensor(img)
with torch.no_grad():
    ref = enc(ex)
ml = ct.convert(
    torch.jit.trace(enc, ex),
    inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
# fp16, not int8: 8-bit weights moved the embedding (cos 0.989), and duplicate
# matching compares embeddings against fixed cosine bars.
ml.short_description = "Marqo-FashionSigLIP image encoder (Apache-2.0): 224x224 RGB -> normalized 768-d embedding"
got = np.array(ml.predict({"image": img})["embedding"]).astype(np.float32).ravel()
r = ref.numpy().astype(np.float32).ravel()
cos = float(got @ r / (np.linalg.norm(got) * np.linalg.norm(r) + 1e-9))
print(f"  FashionEncoder: cosine Core ML vs torch = {cos:.4f}")
assert cos > 0.99, "FashionEncoder diverges"
save(ml, "FashionEncoder.mlpackage")

vocab_spec = json.loads((ROOT / "scripts" / "fashion_vocabulary.json").read_text())
vocab = {"model": "marqo-fashionSigLIP", "groups": {}}
for group, spec in vocab_spec.items():
    # Each entry is [app label, prompt text]. Labels may repeat with different
    # prompts (e.g. "Scarves" as scarf and as headscarf).
    labels = [pair[0] for pair in spec["labels"]]
    prompts = [spec["template"].format(pair[1]) for pair in spec["labels"]]
    with torch.no_grad():
        t = clip.encode_text(tok(prompts))
        t = t / t.norm(dim=-1, keepdim=True)
    vocab["groups"][group] = {"labels": labels,
                              "embeddings": [[round(float(v), 5) for v in row] for row in t.numpy()]}
(OUT / "FashionVocabulary.json").write_text(json.dumps(vocab, separators=(",", ":")))
print(f"Saved vocabulary: {sum(len(g['labels']) for g in vocab['groups'].values())} labels in {len(vocab['groups'])} groups")
# Nothing non-commercial may sit next to the shipped models (a stale cache, a manual copy).
for stale in ("GarmentParser.mlpackage", "GarmentLabeler.mlpackage"):
    if (OUT / stale).exists():
        shutil.rmtree(OUT / stale)
        print(f"  removed stale {stale} (non-commercial)")
print("Wardrobe models ready in", OUT)
