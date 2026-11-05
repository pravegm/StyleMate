#!/usr/bin/env bash
# Builds the git-ignored on-device "studio render" diffusion model (Stable Diffusion 1.5-class img2img,
# Lykon/dreamshaper-8) into StyleMate/ML/Studio/StudioModels.bundle/ (see convert_studio_model.py).
# Needs macOS + Xcode (torch2coreml compiles with `xcrun coremlcompiler`), ~10 GB free disk, and
# 30-90 min. Used by CI (cached); also works on a dev Mac.
set -euo pipefail
cd "$(dirname "$0")"
# apple/ml-stable-diffusion, main @ 2026-09-11 (after 1.1.1: pinned diffusers/transformers, --min-deployment-target).
# Keep in sync with StyleMate/Vendor/StableDiffusion/README.md.
export MLSD_REF=ea2805dc1945be20561c77e5f6d1d9a5a637cda2
PY=${PYTHON:-python3.11}
command -v "$PY" >/dev/null || PY=python3
"$PY" -m venv .studio_venv
# shellcheck disable=SC1091
source .studio_venv/bin/activate
pip install -q --upgrade pip
pip install -q "numpy<2" "torch==2.5.1" "coremltools==8.3.0" "diffusers==0.30.2" "transformers==4.44.2" \
  "huggingface_hub==0.24.6" "accelerate==0.34.2" "safetensors" "scipy" "scikit-learn==1.5.1" "pytest" "requests" pillow
# --no-deps: its setup.py pulls diffusionkit (SD3 only; stubbed in convert_studio_model.py) and unpinned extras.
pip install -q --no-deps "git+https://github.com/apple/ml-stable-diffusion.git@${MLSD_REF}"
python convert_studio_model.py "$@"
