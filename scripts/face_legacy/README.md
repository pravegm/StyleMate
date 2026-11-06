# Legacy face-model scripts: not used by any shipping build

StyleMate ships **YuNet + SFace** (OpenCV Zoo, MIT / Apache-2.0), built by
`scripts/build_face_models.sh` → `scripts/convert_face_models.py`. Everything in this folder is
kept for history and for one licensed plug-in path. See `docs/MODEL-LICENSING.md`.

| Script | What it was | Status |
|---|---|---|
| `convert_scrfd.py` | InsightFace SCRFD-10G (`buffalo_l/det_10g.onnx`) → Core ML | **Licensed use only. Not called by any build script**, and no script downloads InsightFace weights. InsightFace models are non-commercial research only unless InsightFace signs a licence; the manual plug-in steps are in `docs/MODEL-LICENSING.md` §7. |
| `convert_r50.py` | InsightFace ArcFace `w600k_r50` → Core ML | **Licensed use only**, as above. |
| `convert_adaface.py`, `adaface_net.py` | AdaFace IR-101 (WebFace12M), the embedder until Nov 2026 | **Research only. Never ship.** The training data (WebFace260M family) is research-only and no commercial licence exists. |
| `convert_model.py`, `SETUP_MOBILEFACENET.md` | InsightFace `w600k_mbf` (buffalo_s), the first embedder | **Research only.** Same InsightFace policy. |
| `diagnose_alignment*.py`, `verify_*.py`, `run_debug.py` | One-off debugging of the SCRFD + AdaFace pipeline (needs the `insightface` package) | Historical. Not maintained. |

None of these is hashed into the CI model cache keys, so editing them never rebuilds the
shipping models.
