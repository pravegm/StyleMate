#!/usr/bin/env bash
# Licence gate for the face models inside a built StyleMate.app (CI and TestFlight call it).
# The app must contain exactly the commercially usable pair, YuNet (MIT) + SFace (Apache-2.0),
# and none of the non-commercial InsightFace / AdaFace models (docs/MODEL-LICENSING.md).
#   usage: scripts/check_face_models.sh path/to/StyleMate.app
set -euo pipefail
APP="${1:?usage: check_face_models.sh StyleMate.app}"
[ -d "$APP" ] || { echo "::error::No app at $APP"; exit 1; }
fail=0
for m in FaceDetectYuNet.mlmodelc FaceEmbedSFace.mlmodelc; do
  if [ -e "$APP/$m" ]; then du -sh "$APP/$m"; else echo "::error::$m missing from the app"; fail=1; fi
done
# Non-commercial weights, by every name they have had. A signed InsightFace licence (§7) is the
# only reason to remove FaceDetectSCRFD / FaceEmbedArcFaceR50 from this list.
for m in SCRFD10G MobileFaceNet AdaFaceR100 FaceNetR50 FaceDetectSCRFD FaceEmbedArcFaceR50; do
  if [ -e "$APP/$m.mlmodelc" ] || [ -e "$APP/$m.mlpackage" ]; then
    echo "::error::$m is a non-commercial face model and must not ship (docs/MODEL-LICENSING.md)"; fail=1
  fi
done
exit $fail
