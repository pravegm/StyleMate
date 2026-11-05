#!/usr/bin/env bash
# Regenerates the git-ignored on-device face models into StyleMate/FaceModels/ (a synchronized
# Xcode folder: every .mlpackage in it is compiled into the app, no project edits needed):
#   FaceDetectYuNet.mlpackage  YuNet 2023mar detector + 5 landmarks (MIT), fp32, BGR 640x640
#   FaceEmbedSFace.mlpackage   SFace 2021dec 128-d embedder (Apache-2.0), fp16, RGB 112x112
# Both from OpenCV Zoo at a pinned commit, SHA-256 checked. Licences and hashes:
# docs/MODEL-LICENSING.md. Used by CI (.github/workflows/*.yml) on a macOS runner; works on a Mac.
#
# FACE_MODEL_SET=buffalo_l builds the InsightFace SCRFD-10G + w600k_r50 pair instead. InsightFace's
# models are NON-COMMERCIAL unless InsightFace grants a licence, so that branch refuses to run
# without INSIGHTFACE_COMMERCIAL_LICENSE=granted. See docs/MODEL-LICENSING.md §7 for the other steps.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/StyleMate/FaceModels"
SET="${FACE_MODEL_SET:-opencv_zoo}"

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

case "$SET" in
  opencv_zoo)
    ZOO=https://github.com/opencv/opencv_zoo/raw/48b10fa505aeb51fbd127fc60a5c660040e823b7/models
    fetch "$ZOO/face_detection_yunet/face_detection_yunet_2023mar.onnx" \
      8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4 "$WORK/yunet.onnx"
    fetch "$ZOO/face_recognition_sface/face_recognition_sface_2021dec.onnx" \
      0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79 "$WORK/sface.onnx"
    python convert_face_models.py "$WORK/yunet.onnx" "$WORK/sface.onnx" "$OUT" "${FIXTURES[@]}"
    ;;
  buffalo_l)
    if [ "${INSIGHTFACE_COMMERCIAL_LICENSE:-}" != "granted" ]; then
      echo "::error::buffalo_l is licensed for non-commercial research only. Build it only with a signed InsightFace licence (set INSIGHTFACE_COMMERCIAL_LICENSE=granted). docs/MODEL-LICENSING.md §7"
      exit 1
    fi
    curl -fsSL -o "$WORK/buffalo_l.zip" https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
    unzip -o -q "$WORK/buffalo_l.zip" -d "$WORK/buffalo_l"
    python face_legacy/convert_scrfd.py "$(find "$WORK/buffalo_l" -name det_10g.onnx | head -1)" "$OUT/FaceDetectSCRFD.mlpackage"
    python face_legacy/convert_r50.py "$(find "$WORK/buffalo_l" -name w600k_r50.onnx | head -1)" "$OUT/FaceEmbedArcFaceR50.mlpackage"
    ;;
  *) echo "::error::Unknown FACE_MODEL_SET=$SET"; exit 1 ;;
esac
ls -la "$OUT"
echo "Face models ready ($SET)."
