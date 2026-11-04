# StyleMate

An iOS app that turns your camera roll into an organized digital wardrobe and styles you every day — **entirely on your iPhone**. No photo, face or wardrobe data is sent to any AI service.

StyleMate finds the photos of *you* in your library, cuts out every garment and accessory you're wearing, names it (category, product, colours, pattern, material, fit…), de-duplicates it against what you already own, and files it into your closet. When you want to get dressed, it builds five outfits for today from your own clothes — tuned to the weather, the occasion, your mood and what you've worn recently — and lets you log the look on a calendar.

## How it works

### 1. Finding you in your photos (on-device face matching)

- During onboarding you take a **three-frame selfie** (straight on, then a slight turn each way; `SelfieCameraService`). Each frame is checked on-device (one face, big enough, centred, lit, no sunglasses) before it's accepted.
- Then **Find yourself** (`Services/Identity/`, `FindYourselfView`) looks through up to ~1,500 recent photos, embeds every usable face, groups faces of the same person (greedy centroid clustering), ranks the groups by similarity to your selfie and asks "Is this you?" with one tap to confirm. The confirmed faces become your reference **gallery**, so the scan recognises you across angles, lighting and years.
- Faces are detected and 5-point-landmarked by the bundled **InsightFace SCRFD-10G** detector (Core ML), aligned to a canonical 112×112, and embedded with **AdaFace IR-101 (WebFace12M)** (bundled as `MobileFaceNet.mlpackage`, filename kept for history). Embeddings are tagged with the model version so an upgrade rebuilds the gallery.
- Each library photo is matched by **cosine similarity** against the gallery with tiered confidence and a runner-up margin:
  - **confident** → analysed straight away (in a multi-person photo only *your* body is isolated via a person-instance mask, so other people's clothes are never extracted); very confident matches also **teach the gallery** a new angle of your face;
  - **probably you** → queued for an **"Is this you?"** review (home banner → `FaceReviewView`); confirming teaches the gallery and extracts those outfits;
  - anyone else → skipped.
- The scan (`PhotoScanService` + `Services/Scan/`) starts with the **last 12 months**, newest first, with items appearing live ("All photos" is one tap away). It skips screenshots, tiny images and panoramas, keeps only the best frame of a burst / same-moment group, pipelines loading and identity ahead of extraction, and paces itself by thermal state and Low Power Mode.
- It downloads iCloud-only originals when needed ("Optimize iPhone Storage"), retries photos that failed to load, and checkpoints progress to `Application Support/ScanProgress/` so it resumes exactly. It keeps going briefly when you leave the app, continues **overnight while charging** (`BGProcessingTask`), and picks up **new photos automatically** when you come back (PhotoKit persistent change history).

### 2. Building the wardrobe (on-device garment extraction — `Services/Wardrobe/`)

For each photo of you, `WardrobeExtractor`:

1. **Finds and crops the person** at a 2:3 portrait aspect so the garments fill the analysis grid.
2. **Parses** the crop with two Core ML segmentation models on a shared 384×576 grid:
   - **GarmentParser** — the FASHN human parser (SegFormer-B4): which pixels are clothing vs face/hair/arms/hands/legs/torso, and the coarse region (top, dress, skirt, pants, shoes, bag, hat, scarf, glasses, belt, jewelry). Skin never leaks into a garment.
   - **GarmentLabeler** — a Fashionpedia SegFormer-B3: the garment *type* per pixel, plus its hood / collar / lapel / sleeve *part* channels. `GarmentSegmenter` votes inside each region, which splits an open coat or jacket from the top underneath it, a black top from black jeans the parser merged into one "jumpsuit", and black boots from black trousers or tights. The part channels confirm hoods (no "hoodie" without one), sleeves and tailored lapels.
   - Grey padding past the photo's edge is masked out, so it never becomes garment. **Close-up passes** re-parse the head, each hand and the feet at full resolution to find what the full-body pass missed (sunglasses, a cap or turban, a watch, a bag, shoes).
3. **Cuts each item out** at full resolution (`GarmentCutout`): edge-aware mask upsampling guided by the photo, colour decontamination of soft edges (no halos), and a pyramid fill of small holes where a hand, arm, hair, strap or belt covered the fabric. Every cutout is trimmed and centred on a transparent square, and shown on a soft studio backdrop (`ItemCutoutTile`).
4. **Names it** (`FashionClassifier`): **Marqo-FashionSigLIP** (Apache-2.0) embeds the cutout and is compared zero-shot against precomputed text embeddings (`FashionVocabulary.json`) for product (and therefore category), pattern, material, fit, sleeve, neckline and length. Tops, layers and one-pieces are ranked across all three groups (a back-view coat the labeler called a dress becomes a coat); a top seen only between jacket halves or cut off by the frame is limited to everyday tops; rare prints need a clear margin over "Solid". Colours are *measured*: k-means (k=5, merged shades) over the fabric pixels in CIELAB after a damped white balance / exposure correction from the scene, named by hue family then lightness and chroma (so denim is Blue and a dusty-pink coat Pink, not Charcoal and Gray). On Apple Intelligence devices (iOS 27+), Apple's **on-device** foundation model (`SystemLanguageModel`, never Private Cloud Compute) adds a short details line and any clearly readable brand (`GarmentDescriber`).
5. **Scores the view** (size, sharpness, not cut off by the frame, little occlusion). Items too small or too poor to make a good wardrobe image are skipped — a better photo will catch them.

6. **Studio image** (`Services/Wardrobe/Studio/`): every item gets a lifelike catalog photo made **on the iPhone** by a Stable Diffusion 1.5-class model (dreamshaper-8, Core ML on the Neural Engine). Tops, layers and dresses are *generated* by image-to-image (0.65) from a **flat-lay silhouette filled with the garment's own fabric** (`StudioTemplate`: t-shirt, shirt, jacket, coat, tunic, dress or tank; trousers for bottoms cut off by the frame), which locks one whole garment, centred, in its real colour and texture. Text-to-image is only the fallback; without a template the model tends to draw a person wearing the garment. Trousers, shoes, bags and hats are *refined* from the cutout (image-to-image at ~0.5), which keeps their exact look. Anything cut off by the photo frame, or with occluded parts left unfilled, is generated. Several candidates are rendered in one batch and cut out of their white background. A candidate is rejected outright for a second object, a white panel, a body or mannequin, touching the frame, a "failed render" look (zero-shot), or too little FashionSigLIP similarity to your item (0.80 for a refine, 0.70 text-to-image, 0.55 template). The best of the rest wins; if none is left, the clean cutout stays. Renders run in the background (`StudioQueue`), always from the original cutout, and wait while a photo scan runs, the phone is hot, in Low Power Mode, low on battery or memory; they stop when the app is backgrounded. The item page can flip between **Studio** and **From your photo**.

Then `DuplicateDetector` compares the item with the wardrobe using the visual embeddings (`ItemEmbeddingStore`) plus attribute gates. The same garment seen again in a **better** photo **upgrades** the wardrobe image instead of adding a duplicate.

**Studio render (infrastructure, not yet in the UI)** — `Services/Studio/StudioRenderer` makes a lifelike product photo of an item with an on-device Stable Diffusion 1.5-class model — **img2img** from the cutout composited on white (keeps the exact shape; bottoms, shoes, bags) or **text-to-image** from a flat-lay prompt built from the attributes (tops, jackets, dresses), several seeds per model load (**Lykon/dreamshaper-8**, CreativeML OpenRAIL-M): Core ML, 6-bit palettized, `SPLIT_EINSUM_V2` attention for the Neural Engine, 512×512, DPM-Solver++ (Karras), run by Apple's ml-stable-diffusion Swift pipeline (vendored, MIT, `Vendor/StableDiffusion/`). It loads each model only while it's used (`reduceMemory`), renders one image at a time off the main thread, and `unload()` frees it after a batch. Prompts / strength are still being tuned, so nothing calls it yet.

There are three ways to add items, all through the same pipeline: **Auto-scan** of a date range, **Photo picker** (up to 15 photos, with "which one is you?" when several people are in a shot), and **Camera**.

### 3. "What should I wear today?" (on-device stylist — `Services/Outfits/`)

`OutfitEngine` builds **five distinct outfits** from your wardrobe:

- **Inputs**: today's weather (met.no, Open-Meteo fallback; city via `CoreLocation`), the occasion (`OutfitType`) or free text ("dinner date, nothing black"), your **mood** (`OutfitMood`: confident, cozy, relaxed, playful, polished, bold, minimal, romantic), your saved style preferences, and your **recent wear history** from the outfit calendar.
- **Rules + scoring**: slot-based construction (top + bottom or a one-piece, optional mid-layer and outerwear, shoes, 0–2 accessories), temperature bands and rain rules, formality fit per occasion, colour harmony on a colour wheel (neutral base + accents, tonal, analogous, complementary; at most one bold pattern), mood and preference fit, classic do-not-pairs, and a recency penalty. A diversity pass keeps the five looks genuinely different.
- **Everything is changeable**: lock pieces, shuffle any slot to the next best alternative, add a missing piece, or regenerate.
- Each look comes with a short stylist note built from the scoring reasons. On Apple Intelligence devices the on-device model can interpret free text and polish the note (`OnDeviceStylist`), always with a silent deterministic fallback.

### 4. Outfit calendar

Kept outfits are logged to Core Data (`DatedOutfit` + `OutfitItem`) and appear in **My Outfits** as a calendar history (day detail, edit, delete, manual composer). The log feeds the stylist's recency signal, so you aren't offered what you wore yesterday.

## Major features

- **Onboarding**: welcome → about you → photo-scan explainer → three-frame selfie → photo permission → Find yourself → initial library scan (pause/resume from the home banner). A one-time coach-mark tour introduces the main features.
- **Home**: greeting, weather, wardrobe summary, "Style Me" with mood chips, scan progress, "Is this you?" review banner, last-scan results.
- **My Wardrobe**: a closet of cutout tiles on shelves (tops & layers, bottoms, dresses, footwear, bags, accessories, jewelry); filter by shelf, colour and pattern; sort by newest, colour or how often you wear it; search; tap to zoom into an item page (attributes, wear history, edit, "Not mine — remove"); multi-select to remove misidentified items. Add via Camera / Gallery / Auto-scan.
- **My Outfits**: calendar of logged outfits.
- **Profile**: name, email, gender/age, preferred styles, cloud sync status, tour replay, data deletion.
- **Authentication**: Sign in with Apple and Sign in with Google.
- **CloudKit sync**: private database, custom `WardrobeZone`, per-item records with image assets.

## Architecture

- **Language / UI**: Swift, SwiftUI (UIKit interop for `ImagePicker` and camera capture). MVVM.
- **On-device ML (Core ML)**: SCRFD-10G face detector, AdaFace IR-101 face embedder, FASHN human parser, Fashionpedia garment labeler, Marqo-FashionSigLIP encoder, and the studio-render diffusion model (DreamShaper 8 img2img: text encoder, UNet, VAE encoder/decoder). Plus Apple Vision (person-instance masks, human detection) and, where available, Apple's on-device Foundation Models.
- **Local persistence**: `UserDefaults` (wardrobe items per user), files under `Documents/wardrobe_images/`, item embeddings under `Application Support/WardrobeEmbeddings/items.bin` (compact binary, written off the main thread, debounced), Core Data (outfit history).
- **Cloud**: CloudKit private DB only (your own iCloud). No third-party AI services.
- **Weather**: met.no primary with Open-Meteo fallback (no key).

```
StyleMate/
├── Models/                      # WardrobeItem, Category (+ WardrobeViewModel), ProductType, OutfitType, User, Core Data model
├── ML/                          # git-ignored: GarmentParser / GarmentLabeler / FashionEncoder .mlpackage + FashionVocabulary.json;
│                                #   Studio/StudioModels.bundle (compiled diffusion .mlmodelc + tokenizer)
├── Services/
│   ├── Wardrobe/                # WardrobeExtractor, WardrobeML, GarmentSegmenter, GarmentCutout, FashionClassifier, ColorNamer, GarmentDescriber, ItemEmbeddingStore
│   ├── Studio/                  # StudioRenderer (on-device img2img product render)
│   ├── Outfits/                 # OutfitEngine, StyleKnowledge, OutfitMood, StyleIntentParser, OnDeviceStylist
│   ├── ImageAnalysisService     # thin entry point to the wardrobe pipeline
│   ├── SCRFDDetector / FaceMatchingService   # face detection, alignment, AdaFace embeddings, identity resolution
│   ├── Identity/                # "Find yourself": face clustering + ranking, library pass, selfie frame checks
│   ├── PhotoScanService         # library scan, identity gate, "Is this you?" queue
│   ├── DuplicateDetector        # visual + attribute duplicate matching
│   ├── OutfitValidator / OutfitLogic
│   ├── AuthService, CloudKitService, PersistenceController, OnboardingManager
│   ├── SelfieCameraService, WeatherService, LocationService
├── ViewModels/                  # HomeViewModel, MyOutfitsViewModel, FaceReferenceViewModel
├── Vendor/StableDiffusion/      # Apple ml-stable-diffusion Swift pipeline (MIT, vendored; see its README)
├── Views/                       # Home, TodayOutfitSheet, MyWardrobe, ItemDetail, AddItem*, MyOutfits, Profile, Login, Onboarding/, Components/
├── DesignSystem.swift
└── StyleMateApp.swift
```

## Permissions

Declared in `Info.plist`: **Photos** (wardrobe building and scan), **Camera** (selfie and item capture), **Location** (optional, weather only); `UIBackgroundModes` `remote-notification` + `processing`, and `BGTaskSchedulerPermittedIdentifiers` = `com.stylemates.StyleMate.photoscan` (overnight scan). Entitlements: Sign in with Apple, iCloud / CloudKit. Core ML runs on CPU + Neural Engine only (no GPU, which iOS forbids in the background).

## Setup

Nobody needs a local Mac build to work on StyleMate: **every branch push runs `.github/workflows/ci.yml`** on GitHub's Apple-silicon `xcode-27` runner. It regenerates all models into the Actions cache, builds the app, and runs the simulator tests (including end-to-end garment extraction on CC0 street photos in `StyleMateTests/Fixtures/`, whose cutouts are uploaded in the `ci-report` artifact).

**Wardrobe benchmark**: `WardrobeBenchmarkTests` scores extraction against hand labels (`StyleMateTests/Fixtures/labels/<photo>.json`: every garment's kind, accepted products and colours, pattern, sleeve and box). Predictions are matched to labels by box overlap; precision / recall, category, product and colour accuracy, pattern errors, fragment rate, seconds per photo and the duplicate-threshold check go to `benchmark.json` and `duplicates.json` in the report. The test fails if a headline metric drops more than 3 points below `labels/baseline.json`; update that file when a change is a real improvement. The studio tests save every render candidate with its scores (`studio_pipeline/`) and compare a Core ML render with a diffusers reference of the same request.

**End-to-end UI tests**: the `ui-tests` CI job drives the real app in the simulator with XCUITest (`StyleMateUITests/`). It covers the closet, "Style Me" (mood → 5 options → swap a piece → save → the look appears on today's date in the calendar), manual outfit logging, and a gallery import through the system photo picker into on-device extraction. DEBUG-only launch arguments (`-uiTestResetState`, `-uiTestDemoUser`, `-uiTestSkipOnboarding`, `-uiTestSeedWardrobe`, in `StyleMate/Debug/DebugLaunchSupport.swift`) sign in a demo user and seed a wardrobe. Screenshots of every step are uploaded as the `e2e-screens` artifact. The simulator build is ad-hoc signed so CloudKit's entitlements survive.

To build on a Mac (Xcode 27+, iOS 18.4+ device or simulator):

1. `git clone https://github.com/pravegm/StyleMate.git`
2. Configure Google Sign-In: update `GIDClientID` and the matching `CFBundleURLSchemes` in `StyleMate/Info.plist`.
3. Generate the git-ignored models (Python 3.11):
   ```bash
   bash scripts/build_face_models.sh       # -> MobileFaceNet.mlpackage + SCRFD10G.mlpackage at the repo root
   bash scripts/build_wardrobe_models.sh   # -> StyleMate/ML/*.mlpackage + FashionVocabulary.json
   bash scripts/build_studio_models.sh     # -> StyleMate/ML/Studio/StudioModels.bundle (macOS + Xcode, 30-90 min)
   ```
   The face embedder takes **BGR** input (handled in `createInputMultiArray`); see `scripts/convert_adaface.py`, `convert_scrfd.py` and `convert_wardrobe_models.py` (each parity-checks Core ML against PyTorch).
4. `open StyleMate.xcodeproj`, set your signing team, and run (a real device for the selfie camera).

## Privacy

- Face matching, garment extraction, classification and outfit styling all run **on the device**. Selfies, face embeddings and photos never leave the phone.
- Apple's Foundation Models are used only through the on-device `SystemLanguageModel`.
- Wardrobe data syncs only to the user's own private CloudKit database.

## Licensing note

The bundled model weights come with their own licences, several of which are research / non-commercial (SCRFD, AdaFace's training data, the SegFormer-based parsers). The studio-render model (DreamShaper 8) is CreativeML OpenRAIL-M: commercial use is allowed, but its use restrictions must be passed on in the app's terms. They must be cleared or replaced before a commercial release — see `docs/MODEL-LICENSING.md`.

## License

No license has been declared for this repository.
