# StyleMate project log

## 2026-11-04 — fully on-device rebuild (unsupervised run)

**Founder brief:** the app couldn't find the user in their gallery, isolate them, or
extract their clothes and accessories into the wardrobe. The bar is Google Photos'
"Wardrobe" feature. Then: "make this app fully on device", "work without the
[Gemini] API key", "think about these pipelines from scratch". The three features
to work end to end: gallery → automatic digital wardrobe; "what should I wear
today" (5 options, swappable, from day / mood / preferences / weather); log outfits
to calendar dates.

**Root causes found in the old pipeline**
- `PhotoScanService.loadFullImage` used `isNetworkAccessAllowed = false`. With
  iCloud Photos "Optimize Storage" (the default), most originals aren't on the
  phone, so nearly every photo silently came back nil and was skipped.
- Every photo between the borderline (0.30) and high (0.55) face bars was dropped.
  With a selfie-only gallery that is most real photos of the user (profile,
  sunglasses, other lighting).
- The gallery cap removed from the front, which evicted the selfie anchors first.
- "Extraction" was a Gemini bounding box cropped out of a background-removed
  person: skin, arms and neighbouring garments came with every item.
- Transparent cutouts were saved as JPEG thumbnails, which turned their backgrounds black.
- The face models are git-ignored and there was no CI, so no build could have
  been verified anywhere but the founder's old Mac.

**What's new**
- CI on GitHub's `xcode-27` macOS runner: it regenerates all models into the
  Actions cache, builds the app, and runs simulator tests on CC0 street photos.
  Cutouts are uploaded as the `ci-report` artifact.
- On-device wardrobe engine (`Services/Wardrobe/`):
  - FASHN human parser (clothing vs body).
  - Fashionpedia labeler (garment type, splitting an open jacket from the top under it).
  - Edge-aware full-resolution cutouts with hand and strap holes filled.
  - FashionSigLIP zero-shot product, pattern, material, fit, sleeve, neckline and length.
  - Measured colours.
  - A per-view quality score; a better photo replaces a worse one.
  - Visual duplicate matching.
- Identity:
  - iCloud downloads, with timeouts.
  - Retries next scan when a load fails.
  - An "Is this you?" review queue: confirmed faces teach the gallery and are extracted.
  - Self-learning from very confident matches.
- No Gemini consent is needed: nothing leaves the device.

**Prototype benchmark** (Python, 10 Commons street photos): FASHN edges are excellent
but it merges layers. Fashionpedia separates layers but its edges are rough. Fusing
the two gives clean per-item cutouts. Zero-shot naming got leggings, leather
jacket, overcoat, crop top, jeans, sneakers, sunglasses, crossbody bag and scarf right.

**Open risks for launch**
- Licences:
  - SegFormer weights are under NVIDIA's non-commercial licence.
  - InsightFace SCRFD / buffalo_l is non-commercial research only.
  - AdaFace was trained on WebFace (research only).
  - Commercial use needs sign-off, or retrained / commercially licensed weights.
- App size is roughly 400 MB of models before any compression of the face model.
- Item images are cutouts of the worn garment, not generated product renders
  like Google's. That is the trade-off of staying fully on-device.

### Studio renders (lifelike item images, on-device)

The founder's bar is lifelike catalog images, as Google Photos Wardrobe shows them
("shirts need to look like shirts"), not cutouts. The decision is fully on-device: Apple cloud
would be acceptable, but **iOS 27 has no headless Apple image API**. `ImageCreator` is
discontinued, and Image Playground's photoreal mode is sheet-only, runs on PCC, needs a user
confirmation per image and is rate-limited. So we run our own diffusion model on the Neural
Engine.

**Local experiments** (dreamshaper-8 = SD 1.5, CreativeML OpenRAIL-M):
- **Image-to-image from the cutout at about 0.5:**
  - Great for trousers and shoes: ripped white jeans and a blurry sneaker both became studio shots that keep their look.
  - Bad for worn tops: the pose is kept and the model invents a mannequin.
- **Text-to-image flat-lay from the measured description:** gives true catalog shirts and jackets. Four out of four denim jacket candidates were lifelike. Ranking by FashionSigLIP similarity to the real cutout picks the closest one (0.70–0.78).
- **Text-to-image without negatives, or with "ghost mannequin" in the prompt:** draws people. The negatives and the "flat lay, top-down" wording are what make it work.

**Pipeline** (`Services/Wardrobe/Studio/`):
1. Plan: generate or refine.
2. Render N candidates.
3. Isolate the product (Vision foreground mask, largest object, so props are dropped).
4. Match its Lab colours to the real garment.
5. Score it: similarity minus body and cut-off penalties.
6. Keep the best one, or keep the cutout if nothing reaches a similarity of 0.6.

`StudioQueue` re-renders new and upgraded items in the background. The original cutout is kept as "From your photo".
