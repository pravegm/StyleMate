# StyleMate wardrobe ML review (4 Nov)

Evidence: CI run 41850231766 (13 fixtures, 46 cutouts; 41873014417 identical) and the lab render sheets. No Swift studio_pipeline renders yet (run 41894132379 still running). Lines are on `origin/feat/studio-pipeline`.

## Baseline, hand-scored (56 core GT items; necklaces/rings excluded)

- Item precision 44/46 = **96%** (FPs: "Jumpsuits" = black top + black jeans; "Ties", since fixed at GarmentSegmenter:235)
- Item recall 44/56 = **79%**
- Category 42/44 = 95%; product 35/44 = **80%**
- Primary colour 31/44 = **70%** (chromatic items about 5/11)
- False print pattern 5/44
- Renders (render3, strict): 3/12 candidates acceptable; the gate would still ship the failed tee

## Errors by stage

**Crop/parse.** Letterbox grey is segmented as garment: a grey bar on the white shirt, a grey block under the white jeans. `makeCrop` pads past the photo (WardrobeExtractor:120-123).

**Fusion.** 12 misses:
- Small items: sunglasses ×3, turban, sneakers ×2, bags ×2. The zoom pass only refines items already found (WardrobeExtractor:53,155).
- Black-on-black merges: ankle boots into tights; top + jeans into "Jumpsuits". Non-top regions take one majority vote (:136-137).
- A black drape absorbed into the coat.

Fragments:
- Up to 4 components at 12% each are kept (:229-232), giving floating sleeves (denim, flannel) and a two-piece scarf.
- Push-pull fill puts flat blotches on patterns (skin-coloured blocks in the paisley scarf).
- A hand bite on the jeans, because the hull radius for lower is 5 (:272).

**Classification.**
- Zero-shot on partial silhouettes. Inner tops seen between jacket halves or cut off by the frame read as sleeveless: "Halter Tops" (white tee), "Tube Tops" ×2, "Hoodies/Mesh" (black tee).
- Other wrong products: back-view coat → "Dresses"; leather joggers → "Leggings" ×2; hood/hijab → "Berets"; leather tunic → "Hooded, Sleeveless".
- False prints: distressed denim and a printed scarf → "Tie-Dye"; black cap → "Camouflage"; grey coat → "Houndstooth". The 0.02 margin (:41) is too low.
- The labeler's part channels (hood, collar, lapel, sleeve) are dropped at conversion (`list(range(27))`, convert_wardrobe_models.py:117).

**Colour.** Measured cluster → name given (should be):
- Pink coat L59 a13 b−5 → Gray/Tan (Pink)
- Denim L37 a−7 b−9 → Charcoal (Blue)
- Red plaid L40 a46 b13 → Burgundy, plus a dark mix → Charcoal (Red/Black)
- Kurta and white jeans L74–79 → Silver (White)
- Hat L60 C8 → Gray (Tan)

Causes:
- White needs L≥88 (:207-214).
- Saturated anchors lose to neutrals.
- No scene white balance or exposure correction.
- The scarf coat's mask includes scarf pixels, so it comes out "Charcoal".

**Render.**
- Failures: props, stacked tees, white panels, crops off the frame, invented inner tee or sherpa lining (all 4 denim candidates), a hallucinated logo (sneaker refine).
- The gate doesn't separate: failed tees score 0.646–0.669, good renders 0.69–0.78, and `minSimilarity` is 0.6 (StudioPipeline:53).
- Vision instances are merged (:151); frame contact is only penalised (:98).
- `item.id.hashValue` seeds (StudioQueue:125) are randomised per launch.

## 12 highest-impact fixes

1. **Colour naming** (FashionClassifier:144-226).
   - If C≥6, take the hue family from `atan2(b,a)`, then L/C within it. Navy L<30, Blue 30–58, Light Blue >58; Pink at 330–20° with L>50.
   - Neutrals: White ≥76, Silver 62–76.
   - Anchors: Denim, Dusty Pink, Camel, Ivory.
   - Gray-world white balance and 98th-percentile exposure from the scene.
   - k=5, merge clusters within ΔE<12, drop same-hue shadow clusters, erode the mask 3 px.
2. **Mask the padding.** Pass `crop.photoInGrid` into `segment` (WardrobeExtractor:97-104) and zero labels outside it; clip `maskFull` (GarmentCutout:41).
3. **Part-zoom passes** after WardrobeExtractor:45.
   - Re-segment head (face∪hair ×2.2), hands (×4) and feet (bottom 22%) with `minHeight: gh`.
   - Add eyewear, headwear, bag, jewelry or footwear kinds not already found.
   - Zero-shot check of the hair region: turban/headscarf vs hair.
   - Footwear `minSide` 110 → 64 (:60).
4. **Black-on-black splits** (GarmentSegmenter:69-81,131-138).
   - Allow class 24 in `.pants`; split shoe pixels in the bottom 25% when ≥0.0015n.
   - In `.dress`, if an unrestricted argmax gives top (1/2) and pants (7) ≥25% each, vertically separated, emit innerTop + lower.
5. **Part channels.** `list(range(47))` at convert:117.
   - Hoodies/Hooded only with hood (28) ≥1.5% of the top.
   - Sleeve length from sleeve (32) extent against the parser's arms.
   - Lapel (30) supports Coats/Blazers.
6. **Context-aware tops** (FashionClassifier:30).
   - Pass `occluded`/`truncated`. When set, restrict to {T-Shirts, Tank Tops, Shirts, Blouses, Turtlenecks, Sweaters} and skip sleeve/neckline.
   - Prior −0.03 for Tube/Halter/Corset/Mesh/Bodysuits.
7. **Cross-group re-rank.**
   - For innerTop/outerLayer/onePiece, score the union of the three groups, +0.02 for the own group, and switch kind if beaten (fixes coat → dress).
   - Prompt ensembles: "leather jogger pants with elastic cuffs" (Joggers), "skin-tight leggings" (Leggings).
8. **Pattern gate** (:38-43).
   - Margin 0.05 for Tie-Dye, Camouflage, Houndstooth, Paisley, Animal Print.
   - Solid synonyms: "acid wash denim", "distressed ripped denim", "plain dark fabric".
   - Force Solid when clusters span ΔE<15.
9. **Hole fill** (GarmentSegmenter:272-287, GarmentCutout:61).
   - No push-pull on patterned fabric or holes over 10%; send those items to generate.
   - Row-span fill for hands in `.lower`.
   - −0.1 quality per extra component for non-paired kinds (WardrobeExtractor:207).
10. **Template-guided img2img** for tops and layers (StudioPrompt:43-55, StudioPipeline:61-68).
    - Bundle about 12 flat-lay silhouette masks, fill them with tiled interior fabric from the cutout, img2img at 0.65.
    - Locks layout and colour: no stacks, props or crops.
11. **QC hard rejects** (StudioPipeline:86-108).
    - Reject on a second Vision instance ≥15% of the first, an interior white blob ≥3% of the mask, or frame contact.
    - Add a `render_qc` vocab group ("stack of folded clothes", "flat lay with accessories", "t-shirt with white rectangle"); reject if any beats the product prompt.
    - `minSimilarity` 0.70 for generate, 0.80 for refine.
12. **Prompts and seeds.**
    - Prompt: "{colour} {product}, {details}, isolated product photo, centered, plain white background, studio lighting". Drop "flat lay", "top-down" and "neatly arranged", which trigger knolling.
    - OuterLayer negatives: "shirt underneath, inner layer, sherpa lining, patch, logo".
    - Keep the prompt under 60 CLIP tokens.
    - Seed from the UUID bytes; bump `StudioStore.version` (:17).

## CI evaluation plan

**Labels.** `StyleMateTests/Fixtures/labels/<fixture>.json`, one entry per GT item:
- `kind`, `category`, `products` (accepted set)
- `colors_primary` (accepted set), `colors_all`
- `pattern`, `sleeve`, `core`
- `bbox` (normalised)

A draft of the 56 items exists. Grow to about 40 photos (colours, prints, back views, selfies, groups).

**Harness.** Add each item's photo-space bbox to the test JSON (from `inst.box` and `crop.rect`). A benchmark step matches predictions to GT by greedy IoU≥0.3 within a compatible kind and reports:
- Precision/recall (core) and category accuracy
- Product top-1 within the accepted set
- Primary colour (exact and by family) and colour Jaccard
- False patterns and sleeve accuracy
- Fragment rate, seconds per photo

**Gates.** Fail on a drop of more than 3 points against `benchmark/baseline.json`. Targets: recall ≥0.90, precision ≥0.95, product ≥0.90, colour ≥0.90, false patterns ≤1.

**Renders (nightly).**
- 20 items × 4 seeds, with a contact sheet.
- Hand-label each candidate once in `renders_gold.json`: single, whole, right type and colour, no props or panels, nothing invented.
- Report the acceptance of the chosen candidate (target ≥80%) and the auto-QC false-accept rate (target ≤5%; now 1 of 3 items).
- Recalibrate the thresholds in fix 11 from the gold set.

**Duplicates.** Same/different pairs from fixture crops plus flip, crop and ±15% exposure; ROC for 0.91/0.82 (DuplicateDetector:77-78).
