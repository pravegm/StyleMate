#!/usr/bin/env bash
# Regenerates the git-ignored on-device face models into StyleMate/FaceModels/ (a synchronized
# Xcode folder: every .mlpackage in it is compiled into the app, no project edits needed):
#   FaceDetectYuNet.mlpackage  YuNet 2023mar detector + 5 landmarks (MIT), fp32, BGR 640x640
#   FaceEmbedSFace.mlpackage   SFace 2021dec 128-d embedder (Apache-2.0), fp16, RGB 112x112
# Both from OpenCV Zoo at a pinned commit, SHA-256 checked. Licences and hashes:
# docs/MODEL-LICENSING.md. Used by CI (.github/workflows/*.yml) on a macOS runner; works on a Mac.
#
# This script builds ONLY commercially usable face models. It deliberately has no path to the
# InsightFace (non-commercial) weights; plugging those in after a signed licence is a manual,
# documented change (docs/MODEL-LICENSING.md §7, scripts/face_legacy/README.md).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/StyleMate/FaceModels"

PY=${PYTHON:-python3.11}
command -v "$PY" >/dev/null || PY=python3
"$PY" -m venv .models_venv
# shellcheck disable=SC1091
source .models_venv/bin/activate
pip install -q --upgrade pip
pip install -q "numpy<2" "torch==2.5.1" "coremltools==8.3.0" onnx==1.17.0 onnx2torch==1.5.15 \
  onnxruntime==1.20.1 pillow

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT"/*.mlpackage
mkdir -p "$OUT"

fetch() {   # url sha256 dest
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | shasum -a 256 -c - || { echo "::error::SHA-256 mismatch for $1"; exit 1; }
}

FIXTURES=("$ROOT"/StyleMateTests/Fixtures/photos/{kurta_dhoti_turban,street_coat_cap,flannel_shirt_group,casual_denim_jacket_hat}.jpg)

ZOO=https://github.com/opencv/opencv_zoo/raw/48b10fa505aeb51fbd127fc60a5c660040e823b7/models
fetch "$ZOO/face_detection_yunet/face_detection_yunet_2023mar.onnx"   8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4 "$WORK/yunet.onnx"
fetch "$ZOO/face_recognition_sface/face_recognition_sface_2021dec.onnx"   0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79 "$WORK/sface.onnx"
python convert_face_models.py "$WORK/yunet.onnx" "$WORK/sface.onnx" "$OUT" "${FIXTURES[@]}"
ls -la "$OUT"
echo "Face models ready (YuNet + SFace)."
