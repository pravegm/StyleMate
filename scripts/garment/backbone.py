"""
Frozen DINOv2 ViT-S/14 (with registers) backbone for the garment segmenter.

Weights: Meta's DINOv2, Apache-2.0 ("DINOv2 code and model weights are released under
the Apache License 2.0", https://github.com/facebookresearch/dinov2). Loaded through timm
(Apache-2.0) from the timm mirror of the same checkpoint,
https://huggingface.co/timm/vit_small_patch14_reg4_dinov2.lvd142m (licence: apache-2.0).
"""
import torch
import timm

BACKBONE = "vit_small_patch14_reg4_dinov2.lvd142m"
IN_H, IN_W = 672, 448                  # portrait 2:3, same aspect as the app's 384x576 grid
PATCH = 14
TOK_H, TOK_W = IN_H // PATCH, IN_W // PATCH   # 48 x 32
LAYERS = (7, 11)                       # block outputs fed to the head (0-based; 11 = last, normed)
EMBED = 384
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


def load_backbone(pretrained=True):
    m = timm.create_model(BACKBONE, pretrained=pretrained, img_size=(IN_H, IN_W), num_classes=0, dynamic_img_size=False)
    m.eval()
    for p in m.parameters():
        p.requires_grad_(False)
    return m


class Backbone(torch.nn.Module):
    """RGB in [0,1], [B,3,672,448] -> list of [B, 384, 48, 32] token maps for LAYERS."""

    def __init__(self, vit):
        super().__init__()
        self.vit = vit
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, x):
        v = self.vit
        x = (x - self.mean) / self.std
        x = v.patch_embed(x)
        x = v._pos_embed(x)
        x = v.norm_pre(x)
        outs = []
        skip = v.num_prefix_tokens
        for i, blk in enumerate(v.blocks):
            x = blk(x)
            if i in LAYERS:
                y = v.norm(x) if i == len(v.blocks) - 1 else x
                y = y[:, skip:, :]
                b = y.shape[0]
                outs.append(y.transpose(1, 2).reshape(b, EMBED, TOK_H, TOK_W))
            if i >= max(LAYERS):
                break
        return outs
