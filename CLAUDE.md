# Working agreements for StyleMate

## Documentation
- **Keep the README honest in the same commit.** Whenever a change alters
  user-facing behavior or setup — architecture, the face/ML model, the Gemini
  version, the weather provider, permissions, or the build/setup steps — update
  `README.md` in that same commit. Pure bugfix/internal commits don't need it.
  Before pushing such a change, sweep the README for stale references.

## Delivery
- Verify a fix actually builds/works before delivering it. Don't claim a fix
  works on inspection alone.

## Face recognition (the app's USP — must be error-less)
- Embedding model: **AdaFace IR-101 (WebFace12M)**, Core ML fp16 (~125 MB),
  bundled as `MobileFaceNet.mlpackage` (filename kept for history). Regenerate via
  `scripts/convert_adaface.py`. The `.mlpackage` is git-ignored.
- **AdaFace input is BGR** (cv2 convention), `(px-127.5)/127.5`, 112×112 — NOT RGB.
  `createInputMultiArray` feeds B→plane0, R→plane2. A model swap back to an
  InsightFace/ArcFace model must restore RGB.
- **Face detection + 5-point landmarks come from bundled InsightFace SCRFD-10G**
  (`SCRFDDetector`, `SCRFD10G.mlpackage`), NOT Apple Vision — Vision's landmarks
  were too imprecise and collapsed same-person similarity (proven: SCRFD→0.988 vs
  Vision→~0.2). SCRFD input is **RGB**, `(px-127.5)/128`, 640×640 letterboxed
  top-left. It outputs 5 points in canonical ArcFace order, fed to `warpAligned`.
  Regenerate via `scripts/convert_scrfd.py`. Don't reintroduce Vision landmarks.
- Embeddings are model-specific. Persisted galleries are tagged with
  `FaceMatchingService.modelVersion`; a mismatch auto-discards and rebuilds from
  the selfie. Bump that constant on any model swap.
- Matching is cosine similarity with tiered confidence + runner-up margin.
  Auto-scan identity resolution is strict (high confidence + clean margin) and
  isolates the user's garments via a person-instance mask so other people's
  clothes are never extracted. Keep upload / camera / auto-scan consistent.

## Secrets
- `StyleMate/Secrets.swift` holds the real Gemini key and is git-ignored. Never
  commit it or echo the key.
