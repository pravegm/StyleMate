# "On you": outfit try-on (Nov 2026)

The outfit deck ("What should I wear today?") can show each look **on the user's own body**, not just
as pieces. Everything runs on the iPhone; no photo, face or wardrobe data leaves it.

## Status: Beta (lead decision, 5 Nov 2026)

"On you" ships as a **Beta opt-in**: the deck opens on **Pieces**; the toggle's "On you" segment carries
a Beta tag, and the choice is remembered. Home's "Today's look" shows pieces only (the on-body thumbnail,
`TryOnLookThumbnail`, comes back when quality is premium). Nothing renders in the background until the
user has selected On you. `TryOnAvailability` stays the one switch. Quality work continues on
`feat/tryon-quality`.

### Known limits (what a Beta user can see)

- A thin **hard seam** along a garment's edge where the relit garment meets the diffusion-repainted fill.
- **Ghosts of the old garment** just outside the parser's coarse outline (e.g. a coat's outline beside
  the hips), which the fill doesn't cover.
- **Leftover sleeves under sleeveless pieces**: an old cap or short sleeve beside a sleeveless dress can
  be repainted as a dark sleeve-like shape.
- **Crossed legs** merge into one wide trouser block (legs are mapped per joint chain, not separated).
- **CI arms come from the parser estimate**, not Vision: the simulator has no Vision body pose, so CI
  sheets show arms assumed by the sides; on a device Vision supplies the joints (to be checked there).
- **More of each composite is repainted with GarmentNet** (the commercial segmenter that replaced the
  FASHN parser): composite-only passes the gate on 4/20 CI looks vs ~12/20 before (invented share
  0.12-0.21 on tee and coat looks vs the 0.09 limit). The harmonised pass hides it, and only harmonised
  looks are shown; TryOnTests reports the composite-only rate and asserts the harmonised look.
- A **translucent sliver** beside the shoulder and hip of a slim piece (the dress look): the old outfit's
  edge, half repainted by the diffusion pass.
- *Fixed on feat/tryon-quality (merged 8eca4e0, runs 42128045859 / 42156002782)*: garment and fill now cross-fade on a soft coverage weight
  (seam); a thin band around the old clothing's coarse outline is filled too (ghosts); the prompt says
  "bare arms / bare legs" and the negative prompt "sleeves / leggings" when the new pieces leave them bare
  (leftover sleeves).
- Plus: garments are mapped, not draped; shoes are recoloured, not reshaped; bags, hats and jewelry are
  not drawn on the body.

## What the user sees

- Each option in the deck has a **Pieces | On you (Beta)** toggle (remembered; Pieces by default). In On
  you the pieces stay interactive with a status chip ("Dressing you…") until the try-on is ready, then it
  fades in. Swapping a piece changes
  the look's cache key, so that look renders again.
- Tap the try-on for a full-screen view (pinch / double-tap to zoom).
- (After Beta) Home's "Today's look" card shows the look on you beside the pieces once it's ready.
- On the Duo's inner display the deck shows **on you | pieces side by side** (`FoldAwareSplit`, nothing
  on the crease).
- The body is the user's best full-length, front-facing, standing photo among the photos the scan
  matched to them by face (re-checked with face matching on that frame). "Change photo" (the person
  icon on the image) offers: find the best photo of me, choose a photo, take one, use a model, or turn
  On you off. With no usable photo, a neutral model body (profile gender, or neutral) is generated
  once on the device with the studio's diffusion model and shown **neck-down** (no invented face).
- A look that doesn't pass the quality gate shows its pieces with "This one shows best as pieces".

## How it works (`Services/TryOn/`)

| Step | File | What |
|---|---|---|
| Body analysis | `TryOnBody.swift` | Apple Vision `VNDetectHumanBodyPoseRequest` (free, part of iOS) on the photo and on a 2:3 person crop; the app's garment parser (`WardrobeML.parse`) for face / hair / hands / skin / clothing. Working size 1280 px tall. A parser-only pose estimate is the fallback where Vision has no body pose (the simulator). |
| Garment geometry | `TryOnGarment.swift` | From the item image's silhouette: torso box (median run width over 55–85% of the height), hem, sleeves (pixels outside the torso columns: root + far end), bottoms' waist width and crotch. |
| Composite | `TryOnCompositor.swift` | Each piece is split into parts and each part is mapped onto the skeleton with an affine transform: torso → shoulder line (width = chest × fit, length from product + length attribute: tee to the hip, cropped to the waist, coats to the knee, dresses by Short / Knee / Midi / Full); sleeves → upper arm and forearm (bent at the elbow; long sleeves end at the wrist); trousers → hips box + thigh / shin per leg (full-length ones end at the ankle). Drawn bottom → one-piece → top → outer layer. Shading = the photo's lighting (luminance ratio at two coarse scales, clamped 0.8–1.04) so the old garment's texture never prints through. Old clothing the new outfit doesn't cover becomes skin on the limbs / neck (median skin tone from the face and hands, shaded) or background elsewhere (push-pull fill). Shoes: the photo's footwear is recoloured toward the new pair (shape stays the photo's). Face, hair, hands, glasses, hat, bag and jewelry are copied back byte for byte. |
| Harmonise | `TryOnHarmonizer.swift` | **Differential diffusion** (training-free per-pixel strength) with the studio's own dreamshaper-8 Core ML model: a 512×512 square around the person, DPM-Solver++ 2M Karras, 20 scheduled steps, guidance 5. Strength 0 on face / hands / background, 0.25 on garments (relight), 0.45 on their edges, 0.6 around fills, 0.75 on uncovered skin, 0.85 on uncovered background — so about 17 UNet steps run. Garments then take only the diffusion's **light** (a low-pass luminance ratio, clamped 0.75–1.25); their colour and texture stay the composite's. Uncovered skin / background take the diffusion's pixels (this is what turns a flat skin fill into real legs). |
| Gate | `TryOnGate.swift` | Per worn piece: visible share ≥ 0.30 (an inner top under an outer layer is exempt), FashionSigLIP similarity of the piece as it appears on the body (masked crop on white) vs the item ≥ 0.50, median Lab chroma shift ≤ 12 and lightness shift ≤ 30. Whole image: face / hair / hands byte-identical (0 changed pixels), filled share of the person ≤ 0.09 without the diffusion pass / ≤ 0.35 with it. Any failure → the pieces. |
| Queue + cache | `TryOnQueue.swift`, `TryOnStore.swift` | User requests (the look on screen) first; background requests (the morning look on Home, the next deck options) wait for the studio queue's rules (no scan or studio render running, not hot, not Low Power, battery) and never run beside a studio render (two ~1 GB UNets). Cache key = SHA-256 of (pipeline version, body photo id, worn item ids + image paths), so a new studio render or a swap re-renders. Renders and the body photo live in `Application Support/TryOn/` (excluded from backup, protected). Stops and unloads in the background. `PerfLog.Metric.tryOn` times every render. |
| Availability | `TryOnStore.swift` → `TryOnAvailability` | One switch (`isAvailable`); making it a Premium perk is a one-line change. |

The scan's only change is one line in `PhotoScanService.consume`: a confidently matched photo of the
user is recorded as a body candidate (`TryOnBodyLibrary.noteUserPhoto`). Users who scanned before this
build get a fallback search over their newest 150 photos (pose score first, then the face check).

## Why this approach (measured)

Approaches considered (see "Licences" for why the off-the-shelf VTON models were out):

- **(a) Diffusion inpainting of the clothing region conditioned on each garment** (IP-Adapter + a pose
  ControlNet). Needs two more models (IP-Adapter's OpenCLIP ViT-H image encoder ~1.2 GB fp16 and a
  ControlNet ~700 MB) on top of the 1 GB UNet, another Core ML conversion, and SD 1.5 at 512 px redraws
  prints, logos and exact colours from an embedding: the item would be *similar*, not *the same*. Not
  shipped.
- **(b) Deterministic warp-and-composite of the item's own image onto the skeleton** + a light
  diffusion pass. The pieces keep their exact colour, print and texture (gate on the lab set: colour
  shift ΔC 0–2 for every correctly drawn piece). The diffusion pass fixes what the composite can't:
  uncovered skin and background, edges, light.
- **Chosen: (b) as a hybrid**: the composite carries the garment, the differential-diffusion pass
  only relights it (luminance ratio) and repaints what the old outfit leaves uncovered.

Lab (`C:/Users/59527/StyleMate/tryon-lab/`, CPU, diffusers reference of the Swift code: `tryon.py`,
`harmonize.py`, `gate_cal.py`; bodies = the CC0 fixture photos, items = studio renders made by the app's
pipeline from CC0 photos, now `StyleMateTests/Fixtures/tryon/items`):

- **Gate calibration** (`gate_cal.py`, composite, 90 pieces = 6 bodies × 7 outfits): a correctly drawn
  piece's FashionSigLIP similarity on the body vs its own image: min 0.513, p10 0.574, median 0.742
  (bottoms lowest: only the legs show). The best-scoring *other* item: median 0.683, p90 0.759, max
  0.856 (navy vs black tee). Colour shift of correct pieces: ΔC ≤ 2.0, ΔL ≤ 15. Hence similarity ≥ 0.50
  (gross failures), ΔC ≤ 12 (tells a navy tee from a black one, ΔC ≈ 20).
- **Diffusion pass** (`harmonize.py`, CPU, 20 scheduled / 16–17 run steps, 8–13 min per look on the lab
  CPU): turns flat skin fills into real legs and arms and hides seams; the first version (strength 0.45
  on garments, colour from the diffusion) drifted a black dress toward navy and softened jeans, hence
  the light-only relight and 0.25 on garments.
- **Swift pipeline on CI** (run 42055248642, simulator, Debug, CPU): Apple Vision body pose is not
  available on the simulator, so CI exercises the parser-only pose fallback (arms assumed by the sides;
  on a device Vision supplies the real joints). Composite + gate 7.5–20.7 s per outfit, body analysis
  3–5 s. Composite-only gate: 15 / 20 looks passed at the then 0.12 invented-share limit (every dress
  over leggings correctly went to "pieces": 0.26–0.39 of the body would be invented); the limit is now
  0.09 after reviewing the sheets (old-jacket remnants at 0.10–0.12). Pieces on the body vs their items:
  similarity 0.59–0.95, ΔC ≤ 1.6. The wrong-item check: a navy tee measured against the pink coat's
  image → rejected on colour (ΔC 23.4). Harmonised render (pink coat body, tee + jeans): 9 UNet steps,
  506 s on the CI CPU, passed the gate (sim 0.60 / 0.76, ΔC 0.6 / 0.1, face unchanged).
- See the CI `ci-report/_temp/report/tryon/` sheets for the Swift pipeline's own output.

## Review fixes (Nov 2026, after the first CI / Duo sheets)

- **Only finished try-ons are shown.** A look whose render ran without the diffusion pass is re-queued
  for it (twice at most, then "pieces"); raw composites — flat skin fills, blurred background fills —
  never reach a user (the DEBUG UI-test seed is the exception, it has no diffusion model).
- **Soft occluder edges.** Face / hair / hands / accessories come back through a matte upsampled
  bilinearly from the parser grid and feathered ~1.5 px (exact inside), instead of a nearest-neighbour
  staircase.
- **Neck / collarbones become skin** where a scarf, high collar or lapels are removed (a wider neck
  capsule + the shoulder line), not a smeared background fill.
- **Inner top's sleeves are hidden under an outer layer** (they stuck out beside the coat's sleeves).
- CI sheets: `composite__<body>.jpg` = the gate's input (never shown as is); `shown__<body>__<outfit>.jpg`
  = photo | composite | the finished try-on a user sees.

## Quality — honest status

- **Good** on a body photo in fitted clothes (the leather-tunic + leggings fixture): tees, shirts,
  jackets, dresses and jeans read as the real pieces, lit like the photo; with the diffusion pass bare
  legs under a dress look real.
- **Weaker** when the photo shows a long, wide coat: the composite must invent a lot (background beside
  the hips, legs); the gate's filled-share limit sends many of those to the pieces without the
  diffusion pass, and the diffusion pass is soft at 512 px over a full body. Crossed legs merge the
  trousers into one wide block. The body-photo choice therefore prefers front-facing, arms-by-the-sides
  photos **in fitted clothes** (`clothingBulk`: clothing outside a close body envelope, weighted 0.6).
- **Poor** on a leaning / arm-raised pose (the street-cap fixture): garments stay rectangular and the
  raised arm's sleeve floats. The gate catches part of this (visibility, invented share), not all; such
  photos score lower as bodies (a wrist above the shoulders costs 0.25 of the 0-1 body score).
- Garment geometry is template-like: a flat-lay's sleeves are rotated onto the arms, not draped; arms
  crossing the body, sitting, side views and strong perspective aren't handled (the body score rejects
  side and back views and needs head-to-ankle joints).
- Shoes are recoloured, not reshaped (a boot stays boot-shaped in a sneaker look); bags, hats and
  jewelry are not drawn on the body (they stay as pieces).

## Timing

- CI (simulator, CPU only, Debug build): composite + gate per outfit and the harmonised render are in
  `ci-report/_temp/report/tryon/timing.txt` (`[Report] tryon` lines in `test.log`).
- iPhone estimate per outfit: ~17 UNet steps × ~1 s on the Neural Engine (Apple's ml-stable-diffusion
  figures for SD 1.5, the same model class as the studio renders; not yet measured on a device) + ~3 s
  for body analysis (cached), composite, VAE and the gate ≈ **20 s**, first render after launch +
  model load / ANE compile. The composite alone (shown only if it passes the stricter gate) ≈ 1–2 s.

## Testing

- `StyleMateTests/TryOnTests.swift`: body-photo scoring (full-length vs waist-down crop), composite +
  gate on 4 bodies × 5 outfits (sheets + `report.json`), the gate rejecting a navy tee checked against a
  pink coat, a harmonised render (12-step schedule for the CI budget), cache keys.
- `StyleMateUITests/TryOnE2ETests.swift` (+ dark): the deck's toggle, On you (seeded body via the
  DEBUG-only `-uiTestSeedTryOn`, composite only), full screen + pinch, Pieces, swap. Screenshots in
  `e2e-screens`. The hook lives in `StyleMate/Debug/TryOnDebugSeed.swift` under `#if DEBUG`.

## Licences

No new weights ship. The try-on uses Apple Vision (part of iOS), the app's garment parser (see
MODEL-LICENSING.md — being replaced on `feat/garment-commercial`; the try-on only reads its standard
FASHN classes through `GarmentSegmenter.P`), FashionSigLIP (Apache-2.0) for the gate and dreamshaper-8
(CreativeML OpenRAIL-M, already shipped for studio renders) for the harmonise pass and the model body.
Details and the rejected VTON models: MODEL-LICENSING.md §10.
