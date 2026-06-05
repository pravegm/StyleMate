# StyleMate

An iOS app that turns your camera roll into an organized digital wardrobe and gives you AI-generated outfit suggestions for the day — built with SwiftUI, on-device computer vision, and the Gemini API.

You take (or already have) photos of your clothes. StyleMate detects the individual garments in each photo, removes the background, classifies category / product / colors / fit / material, deduplicates against what's already there, and stores everything locally with CloudKit sync. When you want to get dressed, it suggests outfits scoped to the occasion, today's weather, and your own wardrobe.

## How it works

### Wardrobe building

There are three ways to add items, all funneled through the same analysis pipeline:

1. **Camera** — capture a single item.
2. **Photo picker** — bulk-select up to 15 photos from your library.
3. **Auto-scan** — point the app at a date range of your library and let it find outfits automatically.

Each photo is run through:

- **Photo-mode detection** (`Vision` / `VNDetectHumanRectanglesRequest`) — is this a person wearing the item, or a flat product shot?
- **Segmentation + classification** — the image is sent to Gemini (3.x Flash family), which identifies every distinct garment and returns structured metadata (category, product, colors, pattern, material, fit, neckline, sleeve length, garment length, brand, details).
- **Background removal** (`VNGenerateForegroundInstanceMaskRequest`) — per-item mask composited onto a clean background.
- **Category-aware cropping** — `BodyZone` crops the segmented image to the right vertical region for the category (tops, bottoms, footwear, etc.) so thumbnails look right.
- **Duplicate detection** — `DuplicateDetector` scores the new item against your existing wardrobe across category, product, colors, pattern, material, fit, neckline, sleeves, gated so unrelated categories never collide. Matches over a score of 55 prompt you before adding.

Originals, cropped images, and thumbnails are stored under `Documents/wardrobe_images/`. Metadata is persisted as JSON in `UserDefaults` per signed-in user, with parallel sync to a private CloudKit zone.

### Auto-scan and face matching

The auto-scan walks `PHAssetCollection` chronologically across the date range you pick (last month / 6 months / year / custom / all). Before any photo is sent to Gemini, it's filtered by an on-device face check:

- During onboarding you capture a reference selfie (`SelfieCameraService` → `FaceMatchingService`), and can optionally confirm more of your own faces from your library ("tap which photos are you") to strengthen the reference gallery.
- Faces are detected and 5-point-landmarked by the bundled **InsightFace SCRFD-10G** detector (Core ML), aligned to a canonical 112×112, then embedded with **AdaFace IR-101 (WebFace12M)** (bundled as `MobileFaceNet.mlpackage`, filename kept for history). SCRFD's precise landmarks are essential — ArcFace-family alignment is extremely sensitive, and imprecise landmarks collapse same-person similarity. Embeddings are tagged with the model version so an upgrade auto-rebuilds the gallery.
- Each candidate photo is embedded the same way and compared by **cosine similarity** against the reference gallery, with tiered confidence (high / borderline / none) and a runner-up margin. When a photo has several people, the scan only keeps it if *you* are matched with high confidence and a clean margin, then isolates your garments via a person-instance mask — so other people's clothes are never extracted.

Scan progress is checkpointed to `Application Support/ScanProgress/` so you can resume after backgrounding or a crash.

### Outfit suggestions

The Home screen's "Style Me" flow combines:

- your full wardrobe (sent to Gemini as indexed metadata, not raw images),
- the occasion you pick (`OutfitType`: Everyday Casual, Formal, Date Night, Sports, Party, Business, Loungewear, Vacation, Ethnic, Streetwear) or a free-text description,
- the current weather (met.no primary, Open-Meteo fallback — both free, no auth required, reverse-geocoded city via `CoreLocation`),
- your gender preference, if set.

Gemini returns a batch of outfit suggestions — each is a set of wardrobe item indices and a short markdown explanation. The `TodayOutfitSheet` presents them as a swipeable card stack: swipe to keep, skip the rest. You can shuffle individual slots ("show me a different top") or ask the model to add a missing piece, and both call back into Gemini with narrowed scope.

Kept outfits are logged to Core Data (`DatedOutfit` + `OutfitItem`) and show up in **My Outfits** as a calendar history. You can also log outfits manually from any date.

## Major features

- **Onboarding** — welcome → photo-permission explainer → selfie capture → photo library permission → optional initial library scan.
- **Home** — time-aware greeting, weather card, wardrobe-summary widget, "Style Me" launcher, scan progress banner, last-scan results.
- **My Wardrobe** — grid grouped by category (sorted by item count), tap into category → product subgroups → item detail. Add via the custom bottom sheet (Camera / Gallery / Auto-scan), edit any field, delete with CloudKit cleanup.
- **My Outfits** — calendar of logged outfits, day detail with edit/delete, manual outfit composer.
- **Profile** — name, email, optional gender/age, preferred styles, cloud sync status, data deletion.
- **Authentication** — Sign in with Apple and Sign in with Google.
- **CloudKit sync** — private database, custom `WardrobeZone`, per-item records with image assets. Local files win on conflict.
- **Gemini consent** — explicit per-user opt-in (`GeminiConsentView`) before any image leaves the device for classification. Face matching never does.
- **Design system** — `DesignSystem.swift` (DS): 8-pt grid, light/dark tokens, custom button styles, haptics, glass surfaces.

## Architecture

- **Language / UI**: Swift, SwiftUI (UIKit interop only for `ImagePicker` and camera capture).
- **Pattern**: MVVM. `HomeViewModel`, `MyOutfitsViewModel`, plus services published via `@Published`.
- **Local persistence**: `UserDefaults` (wardrobe items per user, scoped by sanitized email) + Core Data (`StyleMateDataModel.xcdatamodeld`, outfit history).
- **Cloud**: CloudKit private DB (zone `WardrobeZone`), `CKRecord` per wardrobe item with `CKAsset` image attachments.
- **On-device ML**: Core ML — InsightFace SCRFD-10G face detector (`SCRFD10G.mlpackage`) + AdaFace IR-101 embedder (`MobileFaceNet.mlpackage`) — plus `Vision` (person-instance mask, foreground mask, human detection). Face landmarks come from SCRFD, not Vision.
- **Remote AI**: Google Gemini (3.x Flash family) for classification, segmentation, and outfit reasoning.
- **Weather**: met.no primary with Open-Meteo fallback (both free, no key).

```
StyleMate/
├── Models/                      # WardrobeItem, Category, ProductType, OutfitType, User + Core Data model
├── Services/
│   ├── AuthService              # Apple + Google sign-in, session restore
│   ├── PersistenceController    # Core Data stack
│   ├── CloudKitService          # WardrobeZone sync
│   ├── ImageAnalysisService     # Gemini calls (classify, segment, suggest outfits)
│   ├── BackgroundRemovalService # Vision foreground mask + category crops
│   ├── DuplicateDetector        # similarity scoring
│   ├── SCRFDDetector            # InsightFace SCRFD-10G face detect + 5-pt landmarks
│   ├── FaceMatchingService      # SCRFD align + AdaFace IR-101 embeddings
│   ├── SelfieCameraService      # onboarding selfie capture
│   ├── PhotoScanService         # date-range library scan + face filter
│   ├── OnboardingManager        # per-user completion flags
│   ├── OutfitLogic              # Outfit value type
│   ├── WeatherService           # met.no + Open-Meteo client
│   └── LocationService          # CLLocationManager wrapper
├── ViewModels/                  # HomeViewModel, MyOutfitsViewModel
├── Views/
│   ├── HomeView / TodayOutfitSheet / WardrobeSummaryWidget
│   ├── MyWardrobeView / AddItemReviewView / EditWardrobeItemView / ItemDetailSheet
│   ├── MyOutfitsView
│   ├── ProfileView / LoginView
│   ├── MainTabView
│   ├── Onboarding/              # welcome, explainers, selfie, permission, scan range, scan review
│   └── Components/              # category cards, item rows, flow layout, weather card, scan banner, Gemini consent
├── DesignSystem.swift
├── Secrets.swift                # git-ignored, holds Gemini key
└── StyleMateApp.swift           # root, AddSourceSheet, app-wide migrations (thumbnails, background-removal, zone crops)
```

## Permissions

Declared in `Info.plist`:

- **Photos** (`NSPhotoLibraryUsageDescription`) — required for wardrobe building and auto-scan.
- **Camera** (`NSCameraUsageDescription`) — onboarding selfie and direct item capture.
- **Location** — optional, used only to fetch weather for outfit context.

Declared in `StyleMate.entitlements`:

- Sign in with Apple
- iCloud / CloudKit (`iCloud.$(CFBundleIdentifier)`)

`UIBackgroundModes: remote-notification` is enabled for future push notifications.

## Setup

### Requirements

- Xcode 15+
- iOS 18+ device or simulator (face matching needs a real device for camera capture during onboarding)
- An Apple Developer team with iCloud + Sign in with Apple capabilities
- A Google OAuth client ID for Sign in with Google
- A Google Gemini API key

### Steps

1. **Clone**

   ```bash
   git clone https://github.com/pravegm/StyleMate.git
   cd StyleMate
   ```

2. **Add your Gemini key**

   ```bash
   cp Secrets.example.swift StyleMate/Secrets.swift
   ```

   Fill in the Gemini API key in `StyleMate/Secrets.swift`. The file is git-ignored.

3. **Configure Google Sign-In**

   Update `GIDClientID` and the matching `CFBundleURLSchemes` entry in `StyleMate/Info.plist` with your OAuth client ID.

4. **Generate the face-embedding model**

   The face model is **not** committed (large binary, git-ignored). Regenerate `MobileFaceNet.mlpackage` (~125 MB) at the repo root from the public AdaFace checkpoint:

   ```bash
   cd scripts
   python3 -m venv adaface_venv && source adaface_venv/bin/activate
   pip install "numpy<2" torch torchvision coremltools gdown
   gdown 1dswnavflETcnAuplZj1IOKKP0eM8ITgT -O adaface_ir101_webface12m.ckpt
   python convert_adaface.py   # converts + verifies Core ML matches PyTorch >0.99
   rm -rf ../MobileFaceNet.mlpackage && cp -R AdaFaceR100.mlpackage ../MobileFaceNet.mlpackage
   ```

   This produces the AdaFace IR-101 (WebFace12M) embedder the app loads by the historical name `MobileFaceNet` (**BGR** input, handled in `createInputMultiArray`). See `scripts/convert_adaface.py`.

   Also generate the face **detector** (`SCRFD10G.mlpackage`, ~8 MB), likewise git-ignored:

   ```bash
   pip install insightface onnxruntime           # downloads buffalo_l (incl. det_10g.onnx)
   python -c "from insightface.app import FaceAnalysis; FaceAnalysis(name='buffalo_l').prepare(ctx_id=-1)"
   python convert_scrfd.py                        # -> SCRFD10G.mlpackage
   cp -R SCRFD10G.mlpackage ../SCRFD10G.mlpackage
   ```

   (`scripts/convert_r50.py` remains for the prior InsightFace R50 embedder.)

5. **Open and run**

   ```bash
   open StyleMate.xcodeproj
   ```

   Set your signing team, ensure the bundle identifier matches your iCloud container, and run on a device for the full onboarding flow.

## Privacy notes

- The face-matching pipeline runs entirely on-device; selfies and embeddings never leave the phone.
- Image classification and outfit reasoning go to Google Gemini and require explicit per-user consent (`GeminiConsentView`) before any image is sent.
- Wardrobe data is synced only to the user's own private CloudKit database.

## License

No license has been declared for this repository.
