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
   - **GarmentLabeler** — a Fashionpedia SegFormer-B3: the garment *type* per pixel. `GarmentSegmenter` votes inside each region, which splits an open coat or jacket from the top underneath it.
3. **Cuts each item out** at full resolution (`GarmentCutout`): edge-aware mask upsampling guided by the photo, colour decontamination of soft edges (no halos), and a pyramid fill of small holes where a hand, arm, hair, strap or belt covered the fabric. Every cutout is trimmed and centred on a transparent square, and shown on a soft studio backdrop (`ItemCutoutTile`).
4. **Names it** (`FashionClassifier`): **Marqo-FashionSigLIP** (Apache-2.0) embeds the cutout and is compared zero-shot against precomputed text embeddings (`FashionVocabulary.json`) for product (and therefore category), pattern, material, fit, sleeve, neckline and length; colours are *measured* by k-means over the fabric pixels in CIELAB. On Apple Intelligence devices (iOS 27+), Apple's **on-device** foundation model (`SystemLanguageModel`, never Private Cloud Compute) adds a short details line and any clearly readable brand (`GarmentDescriber`).
5. **Scores the view** (size, sharpness, not cut off by the frame, little occlusion). Items too small or too poor to make a good wardrobe image are skipped — a better photo will catch them.

Then `DuplicateDetector` compares the item with the wardrobe using the visual embeddings (`ItemEmbeddingStore`) plus attribute gates. The same garment seen again in a **better** photo **upgrades** the wardrobe image instead of adding a duplicate.

There are three ways to add items, all through the same pipeline: **Auto-scan** of a date range, **Photo picker** (up to 15 photos, with "which one is you?" when several people are in a shot), and **Camera**.

### 3. "What should I wear today?" (on-device stylist — `Services/Outfits/`)

`OutfitEngine` builds **five distinct outfits** from your wardrobe:

- **Inputs**: today's weather (met.no, Open-Meteo fallback; city via `CoreLocation`), the occasion (`OutfitType`) or free text ("dinner date, nothing black"), your **mood** (`OutfitMood`: confident, cozy, relaxed, playful, polished, bold, minimal, romantic), your saved style preferences, and your **recent wear history** from the outfit calendar.
- **Rules + scoring**: slot-based construction (top + bottom or a one-piece, optional mid-layer and outerwear, shoes, 0–2 accessories), temperature bands and rain rules, formality fit per occasion, colour harmony on a colour wheel (neutral base + accents, tonal, analogous, complementary; at most one bold pattern), mood and preference fit, classic do-not-pairs, and a recency penalty. A diversity pass keeps the five looks genuinely different.
- **Everything is changeable**: each look is shown as a composed outfit board (layers and top on the left, bottom on the right, shoes and accessories below). Tap a piece to **Keep** it or **Swap** it for the next best alternative, shuffle the rest around kept pieces, add a missing piece, or regenerate. "Wear today" logs the look (or drag the board right; left skips). With a small closet a tip says what to add for more variety.
- Each look comes with a short stylist note built from the scoring reasons. On Apple Intelligence devices the on-device model can interpret free text and polish the note (`OnDeviceStylist`), always with a silent deterministic fallback.

### 4. Outfit calendar

Kept outfits are logged to Core Data (`DatedOutfit` + `OutfitItem`) and appear in **My Outfits** as a week strip (or month grid) with each day's outfits as cutout collages (edit, delete, manual composer). The log feeds the stylist's recency signal, so you aren't offered what you wore yesterday.

## Major features

- **Onboarding**: welcome → about you → photo-scan explainer → three-frame selfie → photo permission → Find yourself → initial library scan (pause/resume from the home banner). A one-time coach-mark tour introduces the main features.
- **Home**: greeting, weather, a "Today's look" card (the stylist's pick for today's weather as a small outfit board, with Wear today / More options; once you've logged a look it shows what you're wearing), "Style me" with occasion and mood chips, wardrobe summary, scan progress, "Is this you?" review banner, last-scan results.
- **My Wardrobe**: a closet of cutout tiles on shelves (tops & layers, bottoms, dresses, footwear, bags, accessories, jewelry); filter by shelf, colour and pattern; sort by newest, colour or how often you wear it; search; tap to zoom into an item page (attributes, wear history, edit, "Remove from Wardrobe"); multi-select to remove misidentified items. Add via the + button: Camera / Gallery / Auto-scan.
- **My Outfits**: week strip or month calendar of logged outfits.
- **Large displays (iPhone Duo inner display)**: two panes via `FoldAwareSplit` (split exactly on the crease when half-open): the closet grid beside the item page; Today's Outfit's board beside the note, a Keep / Swap list and all five options; Home and Outfits in two columns. The cover display and other iPhones keep the phone layout.
- **Profile**: name, email, gender/age, preferred styles, cloud sync status, tour replay, data deletion.
- **Authentication**: Sign in with Apple and Sign in with Google.
- **CloudKit sync**: private database, custom `WardrobeZone`, per-item records with image assets.

## Architecture

- **Language / UI**: Swift, SwiftUI (UIKit interop for `ImagePicker` and camera capture). MVVM.
- **On-device ML (Core ML)**: SCRFD-10G face detector, AdaFace IR-101 face embedder, FASHN human parser, Fashionpedia garment labeler, Marqo-FashionSigLIP encoder. Plus Apple Vision (person-instance masks, human detection) and, where available, Apple's on-device Foundation Models.
- **Local persistence**: `UserDefaults` (wardrobe items per user), files under `Documents/wardrobe_images/`, item embeddings under `Application Support/WardrobeEmbeddings/`, Core Data (outfit history).
- **Cloud**: CloudKit private DB only (your own iCloud). No third-party AI services.
- **Weather**: met.no primary with Open-Meteo fallback (no key).

```
StyleMate/
├── Models/                      # WardrobeItem, Category (+ WardrobeViewModel), ProductType, OutfitType, User, Core Data model
├── ML/                          # git-ignored: GarmentParser / GarmentLabeler / FashionEncoder .mlpackage + FashionVocabulary.json
├── Services/
│   ├── Wardrobe/                # WardrobeExtractor, WardrobeML, GarmentSegmenter, GarmentCutout, FashionClassifier, ColorNamer, GarmentDescriber, ItemEmbeddingStore
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
├── Views/                       # Home, TodayOutfitSheet, MyWardrobe, ItemDetail, AddItem*, MyOutfits, Profile, Login, Onboarding/, Components/
├── DesignSystem.swift
└── StyleMateApp.swift
```

## Permissions

Declared in `Info.plist`: **Photos** (wardrobe building and scan), **Camera** (selfie and item capture), **Location** (optional, weather only); `UIBackgroundModes` `remote-notification` + `processing`, and `BGTaskSchedulerPermittedIdentifiers` = `com.stylemates.StyleMate.photoscan` (overnight scan). Entitlements: Sign in with Apple, iCloud / CloudKit. Core ML runs on CPU + Neural Engine only (no GPU, which iOS forbids in the background).

## Setup

Nobody needs a local Mac build to work on StyleMate: **every branch push runs `.github/workflows/ci.yml`** on GitHub's Apple-silicon `xcode-27` runner. It regenerates all models into the Actions cache, builds the app, and runs the simulator tests (including end-to-end garment extraction on CC0 street photos in `StyleMateTests/Fixtures/`, whose cutouts are uploaded in the `ci-report` artifact).

To build on a Mac (Xcode 27+, iOS 18.4+ device or simulator):

1. `git clone https://github.com/pravegm/StyleMate.git`
2. Configure Google Sign-In: update `GIDClientID` and the matching `CFBundleURLSchemes` in `StyleMate/Info.plist`.
3. Generate the git-ignored models (Python 3.11):
   ```bash
   bash scripts/build_face_models.sh       # -> MobileFaceNet.mlpackage + SCRFD10G.mlpackage at the repo root
   bash scripts/build_wardrobe_models.sh   # -> StyleMate/ML/*.mlpackage + FashionVocabulary.json
   ```
   The face embedder takes **BGR** input (handled in `createInputMultiArray`); see `scripts/convert_adaface.py`, `convert_scrfd.py` and `convert_wardrobe_models.py` (each parity-checks Core ML against PyTorch).
4. `open StyleMate.xcodeproj`, set your signing team, and run (a real device for the selfie camera).

### iPhone Duo

StyleMate runs natively full screen on the iPhone Duo's inner and cover displays (no `UIRequiresFullScreen`, all iPhone orientations; build with **Xcode 27.1+** so the binary carries the iOS 27.1 SDK, or the Duo letterboxes it). `StyleMate/Views/Components/DuoLayout.swift` publishes `\.duoLayout` (wide layout, posture — flat / book / tabletop / closed — hinge angle and the fold's position, from `onHingeChange` and the `.division` reserved region) and provides `FoldAwareSplit`, a two-pane container that splits at the crease when the phone is half-open.

`.github/workflows/duo.yml` (every push to `feat/duo`, or **Actions → Duo → Run workflow**) downloads the iOS 27.1 runtime, builds for an iPhone Duo simulator and runs `StyleMateUITests/DuoScreensTests`: the test navigates on the cover display and calls `scripts/duo_bridge.py`, which moves the simulated hinge (`brew install artemnovichkov/tap/hinge`) and captures every screen on the cover, inner flat (180°) and inner half-open (110°, book pose) displays, and copies the app's own posture / crease log. (Seated / tabletop pose can only be checked on a device: the simulator shows the inner display sideways and refuses programmatic rotation.) Frames land in the `duo-screens` artifact with a `MANIFEST.txt`.

## Privacy

- Face matching, garment extraction, classification and outfit styling all run **on the device**. Selfies, face embeddings and photos never leave the phone.
- Apple's Foundation Models are used only through the on-device `SystemLanguageModel`.
- Wardrobe data syncs only to the user's own private CloudKit database.

## Licensing note

The bundled model weights come with their own licences, several of which are research / non-commercial (SCRFD, AdaFace's training data, the SegFormer-based parsers). They must be cleared or replaced before a commercial release — see `docs/MODEL-LICENSING.md`.

## License

No license has been declared for this repository.
