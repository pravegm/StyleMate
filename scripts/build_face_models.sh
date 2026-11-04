#!/usr/bin/env bash
# Regenerates the two git-ignored on-device face models at the repo root:
#   MobileFaceNet.mlpackage  AdaFace IR-101 (WebFace12M) embedder, fp16, BGR 112x112
#   SCRFD10G.mlpackage       InsightFace SCRFD-10G detector + 5-point landmarks, fp16, RGB 640x640
# Used by CI (.github/workflows/ci.yml) on a macOS runner; also works on a dev Mac.
set -euo pipefail
cd "$(dirname "$0")"

PY=${PYTHON:-python3.11}
command -v "$PY" >/dev/null || PY=python3
"$PY" -m venv .models_venv
# shellcheck disable=SC1091
source .models_venv/bin/activate
pip install -q --upgrade pip
pip install -q "numpy<2" "torch==2.5.1" "coremltools==8.3.0" gdown onnx==1.17.0 onnx2torch==1.5.15 huggingface_hub

# AdaFace IR-101 WebFace12M checkpoint (official Google Drive id from the AdaFace README).
if [ ! -f adaface_ir101_webface12m.ckpt ]; then
  gdown 1dswnavflETcnAuplZj1IOKKP0eM8ITgT -O adaface_ir101_webface12m.ckpt || true
fi
test -s adaface_ir101_webface12m.ckpt || { echo "::error::Could not download the AdaFace checkpoint"; exit 1; }
python convert_adaface.py
rm -rf ../MobileFaceNet.mlpackage && cp -R AdaFaceR100.mlpackage ../MobileFaceNet.mlpackage

# SCRFD-10G from the InsightFace buffalo_l release (det_10g.onnx).
DET="$HOME/.insightface/models/buffalo_l/det_10g.onnx"
if [ ! -f "$DET" ]; then
  mkdir -p "$HOME/.insightface/models"
  curl -fsSL -o /tmp/buffalo_l.zip https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
  mkdir -p "$HOME/.insightface/models/buffalo_l"
  unzip -o -q /tmp/buffalo_l.zip -d "$HOME/.insightface/models/buffalo_l"
  # Some zips nest a folder; flatten it.
  [ -f "$DET" ] || find "$HOME/.insightface/models/buffalo_l" -name det_10g.onnx -exec mv {} "$DET" \;
fi
python convert_scrfd.py
rm -rf ../SCRFD10G.mlpackage && cp -R SCRFD10G.mlpackage ../SCRFD10G.mlpackage
echo "Face models ready."
