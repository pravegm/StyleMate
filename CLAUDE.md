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
- Embedding model: InsightFace ArcFace **ResNet-50 `w600k_r50`** (buffalo_L),
  Core ML fp16, bundled as `MobileFaceNet.mlpackage` (filename kept for history).
  Regenerate via `scripts/convert_r50.py`. The `.mlpackage` is git-ignored.
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
