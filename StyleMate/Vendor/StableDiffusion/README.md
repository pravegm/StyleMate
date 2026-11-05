# Vendored: Apple ml-stable-diffusion (Swift `StableDiffusion` library)

- Source: https://github.com/apple/ml-stable-diffusion, `swift/StableDiffusion/`
- Pinned commit: `ea2805dc1945be20561c77e5f6d1d9a5a637cda2` (main, 2026-09-11; after tag 1.1.1).
  Keep in sync with `MLSD_REF` in `scripts/build_studio_models.sh`, which converts the models with the
  Python half of the same commit.
- Licence: MIT (`LICENSE.md`, copied verbatim).

Vendored instead of added as a Swift Package so the Xcode project file doesn't change: the
`StyleMate/` folder is a synchronized group, so these files simply compile into the app module.

## What's here

The Stable Diffusion 1.x/2.x pipeline only (`StableDiffusionPipeline` + text encoder, UNet, VAE
encoder/decoder, schedulers, RNGs, BPE tokenizer, plus ControlNet / SafetyChecker / multilingual text
encoder because the pipeline references them). Left out: SDXL, SD3 (MMDiT, T5, DiscreteFlow is kept only
because `StableDiffusionScheduler` names it) and the CLI.

## Local changes

- `Encoder` -> `SDVAEEncoder`, `Decoder` -> `SDVAEDecoder` (types and file names). In a separate package
  module they were fine; inside the app module they shadowed `Swift.Encoder` / `Swift.Decoder` and broke
  every `Codable` conformance (`init(from decoder: Decoder)`).

Nothing else is modified. All other declarations keep their upstream names (`Unet`, `TextEncoder`,
`Scheduler`, ...) so updating is a copy + the rename above.

## Updating

```bash
git -C <ml-stable-diffusion> show <sha>:swift/StableDiffusion/pipeline/<File>.swift > <File>.swift
sed -i -E 's/\bEncoder\b/SDVAEEncoder/g; s/\bDecoder\b/SDVAEDecoder/g' *.swift
```

Used by `Services/Studio/StudioRenderer.swift`.
