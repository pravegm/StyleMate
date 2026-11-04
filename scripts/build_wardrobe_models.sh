#!/usr/bin/env bash
# Builds the git-ignored on-device wardrobe models into StyleMate/ML/
# (see convert_wardrobe_models.py). Used by CI; also works on a dev Mac.
set -euo pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3.11}
command -v "$PY" >/dev/null || PY=python3
"$PY" -m venv .wardrobe_venv
# shellcheck disable=SC1091
source .wardrobe_venv/bin/activate
pip install -q --upgrade pip
pip install -q "numpy<2" "torch==2.5.1" "torchvision==0.20.1" "coremltools==8.3.0" "transformers==4.46.3" \
  "open_clip_torch==2.29.0" "timm==1.0.11" pillow scikit-learn
python convert_wardrobe_models.py
du -sh ../StyleMate/ML/*
