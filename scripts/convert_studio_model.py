#!/usr/bin/env python3
"""Converts the "studio render" diffusion model (Stable Diffusion 1.5-class img2img) to Core ML.

Output: StyleMate/ML/Studio/StudioModels.bundle/
    TextEncoder.mlmodelc  Unet.mlmodelc  VAEEncoder.mlmodelc  VAEDecoder.mlmodelc
    vocab.json  merges.txt  studio_manifest.json

This wraps Apple's `python_coreml_stable_diffusion.torch2coreml` (apple/ml-stable-diffusion, pinned in
build_studio_models.sh) with the iPhone-recommended settings: SPLIT_EINSUM_V2 attention (Neural Engine
friendly), 6-bit k-means palettized weights for the UNet and text encoder (the VAE stays fp16, as Apple
ships it), a fixed 64x64 latent (512x512 image), batch-2 UNet for classifier-free guidance.

Why a wrapper rather than calling `python -m ...torch2coreml` directly:
  * torch2coreml's get_pipeline() passes `use_auth_token=True`, which current huggingface_hub turns into
    "token required" for a public repo with no HF token configured (CI has none). We load the pipeline
    ourselves, pinned to an exact Hugging Face revision, without the safety checker (never shipped).
  * torch2coreml imports `diffusionkit` (only for SD3) at module level; we stub it instead of installing
    MLX & co.
  * Palettization loads each fp16 .mlpackage (which compiles it, ~2 GB of RAM for the UNet) only to read
    its spec; we skip the load.
  * The Swift CLI resource layout is a folder at the repo root; the app wants it inside a `.bundle`
    directory, which Xcode's synchronized group copies into the .app verbatim (a plain folder would be
    flattened and the .mlmodelc internals would collide).

Model: Lykon/dreamshaper-8 (CreativeML OpenRAIL-M; its use restrictions must be passed on to users).
"""
import argparse
import json
import logging
import os
import shutil
import sys
import time
import types

MODEL_ID = "Lykon/dreamshaper-8"
MODEL_REVISION = "a7e52b98680b1ba8ff7bce97c7f9f2e2e5337917"  # HF commit, 2024; diffusers layout, fp16 variant
LATENT = 64  # 512x512
NBITS = 6
ATTENTION = "SPLIT_EINSUM_V2"
DEPLOYMENT_TARGET = "iOS17"  # app is iOS 18.4+; iOS17 opset is the newest torch2coreml maps without warnings
MODEL_NAMES = ["TextEncoder", "Unet", "VAEEncoder", "VAEDecoder"]

# WARNING globally: coremltools logs every converted op at INFO (tens of thousands of lines).
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("convert_studio_model")
log.setLevel(logging.INFO)


def _stub_diffusionkit():
    # torch2coreml: `from diffusionkit.tests.torch2coreml import convert_mmdit_to_mlpackage, convert_vae_to_mlpackage`
    # Only the SD3 path uses them.
    def _unused(*_a, **_k):
        raise RuntimeError("diffusionkit is stubbed: SD3 conversion is not supported by this script")

    for name in ["diffusionkit", "diffusionkit.tests", "diffusionkit.tests.torch2coreml"]:
        sys.modules[name] = types.ModuleType(name)
    sys.modules["diffusionkit.tests.torch2coreml"].convert_mmdit_to_mlpackage = _unused
    sys.modules["diffusionkit.tests.torch2coreml"].convert_vae_to_mlpackage = _unused


def main():
    ap = argparse.ArgumentParser()
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    ap.add_argument("--work", default=os.path.join(repo, "scripts", ".studio_work"),
                    help="scratch dir for the intermediate .mlpackages (no spaces: torch2coreml shells out)")
    ap.add_argument("--out", default=os.path.join(repo, "StyleMate", "ML", "Studio", "StudioModels.bundle"))
    ap.add_argument("--attention", default=ATTENTION, help="SPLIT_EINSUM_V2 (ANE) or ORIGINAL (CPU/GPU)")
    ap.add_argument("--keep-work", action="store_true")
    opts = ap.parse_args()
    if " " in opts.work:
        sys.exit(f"--work must not contain spaces: {opts.work}")

    _stub_diffusionkit()
    import torch
    import coremltools as ct
    from diffusers import StableDiffusionPipeline
    from python_coreml_stable_diffusion import torch2coreml as t2c

    def get_pipeline(args):
        log.info(f"Loading {MODEL_ID}@{MODEL_REVISION[:10]} (fp16, no safety checker)")
        pipe = StableDiffusionPipeline.from_pretrained(
            MODEL_ID, revision=MODEL_REVISION, torch_dtype=torch.float16, variant="fp16",
            use_safetensors=True, safety_checker=None, feature_extractor=None,
            requires_safety_checker=False)
        log.info(f"Pipeline: {pipe.__class__.__name__}, unet sample_size={pipe.unet.config.sample_size}")
        return pipe

    def quantize_one(out_path, model_name, nbits):
        if not os.path.exists(out_path):
            log.info(f"Skip quantizing {model_name} (not converted)")
            return
        log.info(f"Palettizing {model_name} to {nbits} bits")
        t0 = time.time()
        mlmodel = ct.models.MLModel(out_path, compute_units=ct.ComputeUnit.CPU_ONLY, skip_model_load=True)
        # num_kmeans_workers > 1 breaks on the second model in coremltools 8.3 ("Pool not running": the
        # pass's process pool is shared and closed after the first model), so k-means stays single-process.
        op_config = ct.optimize.coreml.OpPalettizerConfig(mode="kmeans", nbits=nbits)
        config = ct.optimize.coreml.OptimizationConfig(
            global_config=op_config,
            op_type_configs={"gather": None},  # keep the token embedding table exact (as Apple does)
        )
        ct.optimize.coreml.palettize_weights(mlmodel, config=config).save(out_path)
        log.info(f"Palettized {model_name} in {time.time() - t0:.0f}s")

    t2c.get_pipeline = get_pipeline
    t2c._quantize_weights = quantize_one

    vocab_base = f"https://huggingface.co/{MODEL_ID}/resolve/{MODEL_REVISION}/tokenizer"
    os.makedirs(opts.work, exist_ok=True)
    args = t2c.parser_spec().parse_args([
        "--model-version", MODEL_ID,
        "--convert-text-encoder", "--convert-vae-decoder", "--convert-vae-encoder", "--convert-unet",
        "--attention-implementation", opts.attention,
        "--quantize-nbits", str(NBITS),
        "--latent-h", str(LATENT), "--latent-w", str(LATENT),
        "--min-deployment-target", DEPLOYMENT_TARGET,
        "--bundle-resources-for-swift-cli",
        "--text-encoder-vocabulary-url", f"{vocab_base}/vocab.json",
        "--text-encoder-merges-url", f"{vocab_base}/merges.txt",
        "-o", opts.work,
    ])
    t0 = time.time()
    t2c.main(args)
    log.info(f"torch2coreml finished in {(time.time() - t0) / 60:.1f} min")

    res = os.path.join(opts.work, "Resources")
    missing = [n for n in MODEL_NAMES if not os.path.isdir(os.path.join(res, f"{n}.mlmodelc"))]
    missing += [f for f in ["vocab.json", "merges.txt"] if not os.path.getsize(os.path.join(res, f)) > 1000]
    if missing:
        sys.exit(f"Conversion incomplete, missing: {missing}")
    with open(os.path.join(res, "vocab.json")) as f:
        assert len(json.load(f)) > 40000, "vocab.json is not the CLIP vocabulary"

    if os.path.exists(opts.out):
        shutil.rmtree(opts.out)
    os.makedirs(opts.out)
    for n in MODEL_NAMES:
        shutil.copytree(os.path.join(res, f"{n}.mlmodelc"), os.path.join(opts.out, f"{n}.mlmodelc"))
    for f in ["vocab.json", "merges.txt"]:
        shutil.copy(os.path.join(res, f), os.path.join(opts.out, f))
    manifest = {
        "model": MODEL_ID, "revision": MODEL_REVISION, "license": "CreativeML OpenRAIL-M",
        "attention": opts.attention, "nbits": NBITS, "latent": [LATENT, LATENT],
        "image": [LATENT * 8, LATENT * 8], "unet_batch": 2, "deployment_target": DEPLOYMENT_TARGET,
        "converter": "apple/ml-stable-diffusion " + os.environ.get("MLSD_REF", "?"),
        "coremltools": ct.__version__, "torch": torch.__version__,
    }
    with open(os.path.join(opts.out, "studio_manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    log.info(f"Wrote {opts.out}: {json.dumps(manifest)}")
    if not opts.keep_work:
        shutil.rmtree(opts.work, ignore_errors=True)


if __name__ == "__main__":
    main()
