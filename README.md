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
- **Segmentation + classification** — the image is sent to Gemini 2.5, which identifies every distinct garment and returns structured metadata (category, product, colors, pattern, material, fit, neckline, sleeve length, garment length, brand, details).
- **Background removal** (`VNGenerateForegroundInstanceMaskRequest`) — per-item mask composited onto a clean background.
- **Category-aware cropping** — `BodyZone` crops the segmented image to the right vertical region for the category (tops, bottoms, footwear, etc.) so thumbnails look right.
- **Duplicate detection** — `DuplicateDetector` scores the new item against your existing wardrobe across category, product, colors, pattern, material, fit, neckline, sleeves. Matches over a score of 60 prompt you before adding.

Originals, cropped images, and thumbnails are stored under `Documents/wardrobe_images/`. Metadata is persisted as JSON in `UserDefaults` per signed-in user, with parallel sync to a private CloudKit zone.

### Auto-scan and face matching

The auto-scan walks `PHAssetCollection` chronologically across the date range you pick (last month / 6 months / year / custom / all). Before any photo is sent to Gemini, it's filtered by an on-device face check:

- During onboarding you capture a reference selfie (`SelfieCameraService` → `FaceMatchingService`).
- A reference embedding is generated from that selfie using **MobileFaceNet** (Core ML, bundled in `MobileFaceNet.mlpackage`) on top of `Vision` face landmarks and quality filtering.
- Each candidate photo is embedded the same way and compared by Euclidean distance against the reference. Photos that don't contain you are skipped — so the scan finds *your* outfit photos and ignores everything else.

Scan progress is checkpointed to `Application Support/ScanProgress/` so you can resume after backgrounding or a crash.

### Outfit suggestions

The Home screen's "Style Me" flow combines:

- your full wardrobe (sent to Gemini as indexed metadata, not raw images),
- the occasion you pick (`OutfitType`: Everyday Casual, Formal, Date Night, Sports, Party, Business, Loungewear, Vacation, Ethnic, Streetwear) or a free-text description,
- the current weather (Open-Meteo, no auth required, reverse-geocoded city via `CoreLocation`),
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
- **On-device ML**: Core ML (`MobileFaceNet.mlpackage`), `Vision` (face landmarks, foreground instance mask, human detection).
- **Remote AI**: Google Gemini 2.5 Flash / Pro for classification, segmentation, and outfit reasoning.
- **Weather**: Open-Meteo (free, no key).

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
│   ├── FaceMatchingService      # MobileFaceNet + Vision landmarks
│   ├── SelfieCameraService      # onboarding selfie capture
│   ├── PhotoScanService         # date-range library scan + face filter
│   ├── OnboardingManager        # per-user completion flags
│   ├── OutfitLogic              # Outfit value type
│   ├── WeatherService           # Open-Meteo client
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
- iOS 17+ device or simulator (face matching needs a real device for camera capture during onboarding)
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

4. **Bundle the MobileFaceNet model**

   `MobileFaceNet.mlpackage` is included at the repo root. See `scripts/SETUP_MOBILEFACENET.md` if you want to regenerate it from `scripts/w600k_mbf.onnx` via `scripts/convert_model.py`.

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
