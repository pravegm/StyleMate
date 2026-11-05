"""
Garment segmentation head on frozen DINOv2 ViT-S/14 features (trained from scratch on
Fashionpedia by scripts/garment/train.py; no third-party segmentation weights).

Inputs
  feats: [B, C, 48, 32]   the backbone layers' token maps, projected onto their principal
                          components and divided by a per-component scale (~[-1, 1])
  rgb:   [B, 3, 672, 448] the same image in [0, 1]; a small conv stem trained here
                          recovers the edge detail the 14-px patches lose
Outputs (1/4 of the input, 168 x 112)
  logits: [B, 27, 168, 112]  0 = not a garment, 1..26 = Fashionpedia whole garments
  parts:  [B, 4, 168, 112]   hood, collar, lapel, sleeve (independent, sigmoid)
  person: [B, 1, 168, 112]   a person (body, hair, worn clothes) vs the scene (sigmoid)
  aux:    [B, 27, 48, 32]    deep supervision on the token grid (training only)
"""
import torch
import torch.nn as nn
import torch.nn.functional as F


class CBA(nn.Sequential):
    def __init__(self, cin, cout, k=3, stride=1, groups=1):
        super().__init__(nn.Conv2d(cin, cout, k, stride, k // 2, groups=groups, bias=False),
                         nn.BatchNorm2d(cout), nn.ReLU(inplace=True))


class SepBlock(nn.Module):
    """1x1 in -> depthwise 3x3 -> 1x1 out (MobileNet style), cheap at high resolution."""

    def __init__(self, cin, cout):
        super().__init__()
        self.a = CBA(cin, cout, 1)
        self.dw = CBA(cout, cout, 3, groups=cout)
        self.b = CBA(cout, cout, 1)

    def forward(self, x):
        y = self.a(x)
        return y + self.b(self.dw(y))


class GarmentHead(nn.Module):
    def __init__(self, in_ch, mid=256, num_classes=27, num_parts=4):
        super().__init__()
        self.inp = CBA(in_ch, mid, 1)
        self.ctx = nn.Sequential(CBA(mid, mid, 3), CBA(mid, mid, 3, groups=mid // 32 if mid >= 64 else 1))
        self.aux = nn.Conv2d(mid, num_classes, 1)
        # RGB stem: 336x224 -> 168x112 -> 84x56
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
        self.s2 = CBA(3, 16, 3, 2)
        self.s4 = nn.Sequential(CBA(16, 32, 3, 2), SepBlock(32, 32))
        self.s8 = nn.Sequential(CBA(32, 64, 3, 2), SepBlock(64, 64))
        # decoder
        self.red = CBA(mid, 96, 1)
        self.d8 = nn.Sequential(SepBlock(96 + 64, 96), SepBlock(96, 96))
        self.d4 = nn.Sequential(SepBlock(96 + 32, 64), SepBlock(64, 64))
        self.cls = nn.Conv2d(64, num_classes, 1)
        self.part = nn.Conv2d(64, num_parts, 1)
        self.person = nn.Conv2d(64, 1, 1)

    def forward(self, feats, rgb):
        f = self.inp(feats)
        f = f + self.ctx(f)
        x = (rgb - self.mean) / self.std
        s4 = self.s4(self.s2(x))
        s8 = self.s8(s4)
        y = F.interpolate(self.red(f), size=s8.shape[-2:], mode="bilinear", align_corners=False)
        y = self.d8(torch.cat([y, s8], 1))
        y = F.interpolate(y, size=s4.shape[-2:], mode="bilinear", align_corners=False)
        y = self.d4(torch.cat([y, s4], 1))
        return self.cls(y), self.part(y), self.person(y), self.aux(f)
