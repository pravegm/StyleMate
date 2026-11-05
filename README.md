# StyleMate

An iOS app that turns your camera roll into an organized digital wardrobe and styles you every day — **entirely on your iPhone**. No photo, face or wardrobe data is sent to any AI service.

StyleMate finds the photos of *you* in your library, cuts out every garment and accessory you're wearing, names it (category, product, colours, pattern, material, fit…), de-duplicates it against what you already own, and files it into your closet. When you want to get dressed, it builds five outfits for today from your own clothes — tuned to the weather, the occasion, your mood and what you've worn recently — and lets you log the look on a calendar.

## How it works

### 1. Finding you in your photos (on-device face matching)

- During onboarding you take a **three-frame selfie** (straight on, then a slight turn each way; `SelfieCameraService`). Each frame is checked on-device (one face, big enough, centred, lit, no sunglasses) before it's accepted.
- Then **Find yourself** (`Services/Identity/`, `FindYourselfView`) looks through up to ~1,500 recent photos, embeds every usable face, groups faces of the same person (greedy centroid clustering), ranks the groups by similarity to your selfie and asks "Is this you?" with one tap to confirm. The confirmed faces become your reference **gallery**, so the scan recognises you across angles, lighting and years.
- Faces are detected and 5-point-landmarked by the bundled **InsightFace SCRFD-10G** detector (Core ML), aligned to a canonical 112×112, and embedded with **AdaFace IR-101 (WebFace12M)** (bundled as `MobileFaceNet.mlpackage`, filename kept for history). Embeddings are tagged with the model version so an upgrade rebuilds the gallery.
- Each library photo is matched by **cosine similarity** against the gallery with tiered confidence and a runner-up margin:
  - **confident** → analysed straight away (in a multi-person photo only *your* body is isolated via a person-instance mask, so other people's clothes are never extracted); very confident matches that also match your **selfie** (and clearly beat anyone else in the shot) **teach the gallery** a new angle of your face — learned faces are capped at half the gallery and never displace the selfie or faces you confirmed;
  - **probably you** → queued for an **"Is this you?"** review (home banner → `FaceReviewView`); confirming teaches the gallery and extracts those outfits;
  - anyone else → skipped.
- The scan (`PhotoScanService` + `Services/Scan/`) starts with the **last 12 months**, with items appearing live ("All photos" is one tap away). The very first scan begins with a **"First 40" pass** (`FirstLook`): it ranks the last 90 days by Vision full-body person detection on small thumbnails (one person, whole body in view, a face to recognise; screenshots, documents and scenery drop out) and extracts the best ~40 first, so the closet fills within minutes; then it continues newest first. It skips screenshots, tiny images and panoramas, keeps only the best frame of a burst / same-moment group, pipelines loading and identity ahead of extraction, and paces itself by thermal state and Low Power Mode.
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
6. **Trust before volume** (`ItemTrust`): the scan only adds items it's sure about. Cutouts that split into several pieces (hair + lens "ties"), views with quality under 0.4, and small jewelry / ties / belts without a clear view are held back — Home shows "We weren't sure about 1 item — tap to add" — and start deselected in the manual review screen.

Then `DuplicateDetector` compares the item with the wardrobe using the visual embeddings (`ItemEmbeddingStore`) plus attribute gates. The same garment seen again in a **better** photo **upgrades** the wardrobe image instead of adding a duplicate.

There are three ways to add items, all through the same pipeline: **Auto-scan** of a date range, **Photo picker** (up to 15 photos, with "which one is you?" when several people are in a shot), and **Camera**. Picked photos are downsampled to 2048 px, and every extraction (manual or scan) goes through one shared gate (`ExtractionGate`, 1–2 at a time) so memory stays bounded.

### 3. "What should I wear today?" (on-device stylist — `Services/Outfits/`)

`OutfitEngine` builds **five distinct outfits** from your wardrobe:

- **Inputs**: today's weather (met.no, Open-Meteo fallback; city via `CoreLocation`), the occasion (`OutfitType`) or free text ("dinner date, nothing black"), your **mood** (`OutfitMood`: confident, cozy, relaxed, playful, polished, bold, minimal, romantic), your saved style preferences, and your **recent wear history** from the outfit calendar.
- **Rules + scoring**: slot-based construction (top + bottom or a one-piece, optional mid-layer and outerwear, shoes, 0–2 accessories), temperature bands and rain rules, formality fit per occasion, colour harmony on a colour wheel (neutral base + accents, tonal, analogous, complementary; at most one bold pattern), mood and preference fit, classic do-not-pairs, and a recency penalty. A diversity pass keeps the five looks genuinely different.
- **Everything is changeable**: lock pieces, shuffle any slot to the next best alternative, add a missing piece, or regenerate.
- Each look comes with a short stylist note built from the scoring reasons. On Apple Intelligence devices the on-device model can interpret free text and polish the note (`OnDeviceStylist`), always with a silent deterministic fallback.

### 4. Outfit calendar

Kept outfits are logged to Core Data (`DatedOutfit` + `OutfitItem`) and appear in **My Outfits** as a calendar history (day detail, edit, delete, manual composer). The log feeds the stylist's recency signal, so you aren't offered what you wore yesterday.

The calendar also **fills itself** (`Services/Insights/WearLogSuggestions`): when the scan finds a photo of you from the last week (new photos are picked up automatically), its garments are matched to your closet and Home asks "Wore this on Tue? Camel coat + navy cardigan — **Log it**".

### 5. Morning outfit

`Services/Notifications/MorningLook`: an optional local notification at 7:30 (time editable in Profile) — "9° and cloudy — your camel coat look is ready" — with a picture of the look. The look is precomputed on the device by `OutfitEngine` when the app last ran and again in a `BGAppRefreshTask` before the alarm (with that morning's forecast), and tapping the notification opens Today's Outfit on exactly that look. Permission is asked only after the first saved outfit.

## Major features

- **No account**: the app creates a local profile (a UUID) on first launch; there is no sign-in. Users of earlier builds that signed in with Apple or Google keep their user id, so their wardrobe stays.
- **Onboarding** (4 screens to scanning): welcome & privacy → three-frame selfie → photo permission (Limited access explained, "Select more photos", whatever is shared still gets scanned) → Find yourself → a live scan screen ("11 items found in 23 photos") that hands over to Home at 8 items or 90 s while the scan continues in the banner. **"Try with sample photos"** on the welcome screen (and on an empty closet) runs the same pipeline on bundled CC0 photos (`StyleMate/Resources/SamplePhotos`, credits in `SAMPLE-PHOTO-CREDITS.md` and in Profile); sample clothes are labelled and removable in one tap. No coach-mark tour auto-starts (replay it from Profile).
- **Home**: greeting, weather, wardrobe summary, "Style Me" with mood chips, scan progress, "Is this you?" review banner, last-scan results, and the first-run / habit cards (`HomeFirstRunCards`: sample clothes, "We weren't sure about 1 item — tap to add", "Wore this on Tue? — Log it", the morning-outfit ask).
- **My Wardrobe**: a closet of cutout tiles on shelves (tops & layers, bottoms, dresses, footwear, bags, accessories, jewelry); filter by shelf, colour and pattern; sort by newest, colour or how often you wear it; search; tap to zoom into an item page (attributes, wear history, edit, "Not mine — remove"); multi-select to remove misidentified items. Add via Camera / Gallery / Auto-scan.
- **My Outfits**: calendar of logged outfits.
- **Profile**: about you (name, gender/age — optional), preferred styles, morning-outfit notification + time, cloud sync status, recognition tools, privacy policy, sample-clothes removal, tour replay, data deletion (wardrobe, outfit log, selfie/face data, scan state, iCloud zone; then a fresh local profile).
- **Privacy policy**: `docs/privacy.html`, published at https://pravegm.github.io/StyleMate/privacy.html (GitHub Pages from `docs/`).
- **CloudKit sync**: private database, custom `WardrobeZone`, per-item records with image assets. Incremental: a persisted server change token, metadata-only pulls, image assets fetched lazily off the main thread. The phone is the source of truth — local changes are queued in a per-user ledger (pending uploads + tombstones) and retried until iCloud confirms them, local edits win, and a local item is only removed when the server reports its deletion. Pulls restore every record in the zone whatever profile id uploaded it (the private database is the iCloud account's own), so a reinstall or a new iPhone — which gets a new local profile id — restores the whole wardrobe; "Delete Everything" blocks all pulls until iCloud confirms the zone deletion.

## Architecture

- **Language / UI**: Swift, SwiftUI (UIKit interop for `ImagePicker` and camera capture). MVVM.
- **On-device ML (Core ML)**: SCRFD-10G face detector, AdaFace IR-101 face embedder, FASHN human parser, Fashionpedia garment labeler, Marqo-FashionSigLIP encoder. Plus Apple Vision (person-instance masks, human detection) and, where available, Apple's on-device Foundation Models.
- **Local persistence**: `UserDefaults` (wardrobe items per user, sync ledger), wardrobe images / thumbnails / outfit-history snapshots under `Application Support/wardrobe_images/`, the selfie under `Application Support/Selfie/`, the face gallery under `Application Support/FaceReference/` (with per-entry provenance: selfie / confirmed / learned), item embeddings under `Application Support/WardrobeEmbeddings/`, Core Data (outfit history, scoped per user; a damaged store is moved to `Application Support/CoreDataBackups/` instead of crashing). Personal files are excluded from iCloud Backup and use `completeUntilFirstUserAuthentication` file protection (`LocalStore`); older builds' `Documents/` files are moved there automatically.
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
│   ├── Scan/                    # planner, First 40 ranking, ItemTrust, held items, sample library, background coordinator
│   ├── Notifications/           # MorningLook (scheduler, store, forecast, tap router)
│   ├── Insights/                # WearLogSuggestions ("Wore this on Tue?")
│   ├── AuthService (local profile), CloudKitService, PersistenceController, OnboardingManager
│   ├── SelfieCameraService, WeatherService, LocationService
├── ViewModels/                  # HomeViewModel, MyOutfitsViewModel, FaceReferenceViewModel
├── Views/                       # Home, TodayOutfitSheet, MyWardrobe, ItemDetail, AddItem*, MyOutfits, Profile, Onboarding/, Components/
├── DesignSystem.swift
└── StyleMateApp.swift
```

## Permissions

Declared in `Info.plist`: **Photos** (wardrobe building and scan; `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`, since the app offers "Select more photos" itself), **Camera** (selfie and item capture), **Location** (optional, weather only); **Notifications** are requested at run time (morning outfit, after the first saved outfit). `UIBackgroundModes` `processing` + `fetch`, and `BGTaskSchedulerPermittedIdentifiers` = `com.stylemates.StyleMate.photoscan` (overnight scan) and `com.stylemates.StyleMate.morninglook` (morning-look refresh). Entitlements: iCloud / CloudKit only (no sign-in). Core ML runs on CPU + Neural Engine only (no GPU, which iOS forbids in the background).

## Setup

Nobody needs a local Mac build to work on StyleMate: **every branch push runs `.github/workflows/ci.yml`** on GitHub's Apple-silicon `xcode-27` runner. It regenerates all models into the Actions cache, builds the app, and runs the simulator tests (including end-to-end garment extraction on CC0 street photos in `StyleMateTests/Fixtures/`, whose cutouts are uploaded in the `ci-report` artifact).

To build on a Mac (Xcode 27+, iOS 18.4+ device or simulator):

1. `git clone https://github.com/pravegm/StyleMate.git`
2. Generate the git-ignored models (Python 3.11):
   ```bash
   bash scripts/build_face_models.sh       # -> MobileFaceNet.mlpackage + SCRFD10G.mlpackage at the repo root
   bash scripts/build_wardrobe_models.sh   # -> StyleMate/ML/*.mlpackage + FashionVocabulary.json
   ```
   The face embedder takes **BGR** input (handled in `createInputMultiArray`); see `scripts/convert_adaface.py`, `convert_scrfd.py` and `convert_wardrobe_models.py` (each parity-checks Core ML against PyTorch).
3. `open StyleMate.xcodeproj`, set your signing team, and run (a real device for the selfie camera).

### iPhone Duo

StyleMate runs natively full screen on the iPhone Duo's inner and cover displays (no `UIRequiresFullScreen`, all iPhone orientations; build with **Xcode 27.1+** so the binary carries the iOS 27.1 SDK, or the Duo letterboxes it). `StyleMate/Views/Components/DuoLayout.swift` publishes `\.duoLayout` (wide layout, posture — flat / book / tabletop / closed — hinge angle and the fold's position, from `onHingeChange` and the `.division` reserved region) and provides `FoldAwareSplit`, a two-pane container that splits at the crease when the phone is half-open.

`.github/workflows/duo.yml` (every push to `feat/duo`, or **Actions → Duo → Run workflow**) downloads the iOS 27.1 runtime, builds for an iPhone Duo simulator and runs `StyleMateUITests/DuoScreensTests`: the test navigates on the cover display and calls `scripts/duo_bridge.py`, which moves the simulated hinge (`brew install artemnovichkov/tap/hinge`) and captures every screen on the cover, inner flat (180°) and inner half-open (110°, book pose) displays, and copies the app's own posture / crease log. (Seated / tabletop pose can only be checked on a device: the simulator shows the inner display sideways and refuses programmatic rotation.) Frames land in the `duo-screens` artifact with a `MANIFEST.txt`.

## Privacy

- Face matching, garment extraction, classification and outfit styling all run **on the device**. Selfies, face embeddings and photos never leave the phone — they are also kept out of iCloud Backup. Release builds log no user or photo identifiers (verbose logs are DEBUG-only, `dlog`).
- Apple's Foundation Models are used only through the on-device `SystemLanguageModel`.
- Wardrobe data syncs only to the user's own private CloudKit database. There is no account and no StyleMate server.
- Policy: `docs/privacy.html` (https://pravegm.github.io/StyleMate/privacy.html).

## Licensing note

The bundled model weights come with their own licences, several of which are research / non-commercial (SCRFD, AdaFace's training data, the SegFormer-based parsers). They must be cleared or replaced before a commercial release — see `docs/MODEL-LICENSING.md`.

## License

No license has been declared for this repository.
