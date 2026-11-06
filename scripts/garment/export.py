"""
The deployable garment segmenter: frozen DINOv2 ViT-S/14 + PCA projection + trained head,
as one traceable module for Core ML (scripts/convert_wardrobe_models.py).

Input  image [1, 3, 672, 448] RGB in [0, 1]
Outputs (grid = the app's 384 x 576 analysis grid; low = 96 x 144, a quarter of it)
  classes [1, 1, 576, 384]  per-pixel label: 0 = scene, 1..26 = Fashionpedia whole garment
                            (app channel numbering), 27 = person but no garment (skin, hair)
  probs   [1, 27, 144, 96]  garment softmax (0 = none), for evidence and close-up triggers
  aux     [1, 5, 144, 96]   sigmoid: hood, collar, lapel, sleeve, person
"""
import os
import sys

import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backbone as bb          # noqa: E402
from head import GarmentHead   # noqa: E402

GRID_H, GRID_W = 576, 384
LOW_H, LOW_W = 144, 96
BODY = 27


class Projection(nn.Module):
    """(tokens - mean) @ comps.T / scale for each backbone layer, as 1x1 convs."""

    def __init__(self, pca, n_layers):
        super().__init__()
        self.convs = nn.ModuleList()
        for li in range(n_layers):
            mean = torch.as_tensor(pca[f"mean{li}"]).float()
            comps = torch.as_tensor(pca[f"comps{li}"]).float()
            scale = torch.as_tensor(pca[f"scale{li}"]).float()
            c = nn.Conv2d(comps.shape[1], comps.shape[0], 1)
            with torch.no_grad():
                c.weight.copy_((comps / scale[:, None])[:, :, None, None])
                c.bias.copy_(-(comps @ mean) / scale)
            self.convs.append(c)

    def forward(self, outs):
        return torch.cat([c(o) for c, o in zip(self.convs, outs)], 1)


class GarmentNet(nn.Module):
    def __init__(self, ckpt, pretrained_backbone=True):
        super().__init__()
        self.backbone = bb.Backbone(bb.load_backbone(pretrained=pretrained_backbone))
        self.proj = Projection(ckpt["pca"], len(ckpt["layers"]))
        self.head = GarmentHead(ckpt["in_ch"], mid=ckpt["mid"])
        self.head.load_state_dict(ckpt["state_dict"])
        self.eval()

    def raw(self, x):
        f = self.proj(self.backbone(x))
        return self.head(f, x)[:3]

    def forward(self, x):
        logits, parts, person = self.raw(x)
        up = F.interpolate(logits, size=(GRID_H, GRID_W), mode="bilinear", align_corners=False)
        cls = torch.argmax(up, dim=1, keepdim=True)
        per = F.interpolate(person, size=(GRID_H, GRID_W), mode="bilinear", align_corners=False) > 0
        cls = torch.where((cls == 0) & per, torch.full_like(cls, BODY), cls)
        low = F.interpolate(logits, size=(LOW_H, LOW_W), mode="bilinear", align_corners=False)
        probs = torch.softmax(low, dim=1)
        aux = torch.sigmoid(F.interpolate(torch.cat([parts, person], 1), size=(LOW_H, LOW_W), mode="bilinear",
                                          align_corners=False))
        return cls.float(), probs, aux
