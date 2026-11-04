#!/usr/bin/env python3
"""
Builds the three on-device wardrobe models + the attribute vocabulary, into
StyleMate/ML/ (git-ignored; the Xcode synchronized group bundles whatever is there).

  GarmentParser.mlpackage   FASHN human parser (SegFormer-B4). Pixel-accurate
                            clothing-vs-body regions: top, dress, skirt, pants,
                            belt, bag, hat, scarf, glasses, feet(shoes), jewelry,
                            plus face/hair/arms/hands/legs/torso (so skin is never
                            part of a garment). In 384x576 (W x H) RGB, out
                            softmax `probs` [1,18,576,384].
  GarmentLabeler.mlpackage  Fashionpedia SegFormer-B3. Garment TYPE per pixel —
                            separates a jacket from the top under it, coat vs
                            dress, shoes, watch... In 512x512 RGB (the same crop,
                            stretched, as in training), out `logits` for the 27
                            whole-garment classes, resized to [1,27,576,384] so
                            both maps share one grid.
  FashionEncoder.mlpackage  Marqo-FashionSigLIP image tower (Apache-2.0). 224x224
                            RGB -> L2-normalized 768-d embedding. Zero-shot product
                            / pattern / material / sleeve... and duplicate matching.
  FashionVocabulary.json    Text embeddings for every label the app classifies
                            into, precomputed so no text tower ships.

All three: fp16 compute, int8 weights, parity-checked vs PyTorch.
"""
import json, os, sys
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "StyleMate" / "ML"
OUT.mkdir(parents=True, exist_ok=True)
MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
GRID_H, GRID_W = 576, 384


def palettize(ml):
    # 8-bit symmetric weight quantization: half the size of fp16, visually
    # identical masks (checked by `parity` below), and fast to apply.
    cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    return cto.linear_quantize_weights(ml, cfg)


def parity(name, ml, torch_out, feed, key, kind):
    got = np.array(ml.predict(feed)[key]).astype(np.float32)
    ref = torch_out.detach().numpy().astype(np.float32)
    if kind == "argmax":
        agree = float((got.argmax(1) == ref.argmax(1)).mean())
        print(f"  {name}: per-pixel argmax agreement Core ML vs torch = {agree:.4f}")
        assert agree > 0.97, f"{name} diverges"
    else:
        cos = float((got.ravel() @ ref.ravel()) / (np.linalg.norm(got) * np.linalg.norm(ref) + 1e-9))
        print(f"  {name}: cosine Core ML vs torch = {cos:.4f}")
        assert cos > 0.99, f"{name} diverges"


def sample_image(w, h):
    from PIL import Image
    p = ROOT / "StyleMateTests" / "Fixtures" / "photos"
    files = sorted(p.glob("*.jpg")) if p.exists() else []
    if files:
        return Image.open(files[0]).convert("RGB").resize((w, h))
    return Image.fromarray((np.random.rand(h, w, 3) * 255).astype(np.uint8))


def to_tensor(img):
    return torch.from_numpy(np.array(img)).permute(2, 0, 1).float().unsqueeze(0) / 255.0


# ---------------------------------------------------------------- parser
from transformers import SegformerForSemanticSegmentation

def build_segformer(repo, in_w, in_h, out_name, channels, softmax, out_file, desc):
    print(f"Converting {repo} ...")
    m = SegformerForSemanticSegmentation.from_pretrained(repo).eval()

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__(); self.m = m
        def forward(self, x):                       # x: RGB in [0,1]
            x = (x - MEAN) / STD
            lg = self.m(pixel_values=x, return_dict=False)[0]
            if channels is not None:
                lg = lg[:, channels]
            lg = torch.nn.functional.interpolate(lg, size=(GRID_H, GRID_W), mode="bilinear", align_corners=False)
            return torch.softmax(lg, 1) if softmax else lg

    w = Wrap(m).eval()
    ex = to_tensor(sample_image(in_w, in_h))
    with torch.no_grad():
        ref = w(ex)
    tr = torch.jit.trace(w, ex)
    ml = ct.convert(
        tr,
        inputs=[ct.ImageType(name="image", shape=(1, 3, in_h, in_w), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name=out_name, dtype=np.float16)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    ml = palettize(ml)
    ml.short_description = desc
    from PIL import Image
    parity(out_file, ml, ref, {"image": sample_image(in_w, in_h)}, out_name, "argmax")
    dst = OUT / out_file
    if dst.exists():
        import shutil; shutil.rmtree(dst)
    ml.save(str(dst))
    print(f"  saved {dst}")


build_segformer("fashn-ai/fashn-human-parser", 384, 576, "probs", None, True, "GarmentParser.mlpackage",
                "FASHN human parser (SegFormer-B4): 18-class clothing/body parsing, softmax on a 576x384 grid")
build_segformer("sayeed99/segformer-b3-fashion", 512, 512, "logits", list(range(27)), False, "GarmentLabeler.mlpackage",
                "Fashionpedia SegFormer-B3: whole-garment class logits 0..26 on a 576x384 grid")

# ---------------------------------------------------------------- encoder + vocabulary
import open_clip
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
ex = to_tensor(sample_image(224, 224))
with torch.no_grad():
    ref = enc(ex)
ml = ct.convert(
    torch.jit.trace(enc, ex),
    inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
ml = palettize(ml)
ml.short_description = "Marqo-FashionSigLIP image encoder: 224x224 RGB -> normalized 768-d embedding"
parity("FashionEncoder", ml, ref, {"image": sample_image(224, 224)}, "embedding", "cos")
dst = OUT / "FashionEncoder.mlpackage"
if dst.exists():
    import shutil; shutil.rmtree(dst)
ml.save(str(dst))

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
print("Wardrobe models ready in", OUT)
