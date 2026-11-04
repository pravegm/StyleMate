# StyleMate launch readiness (audit of `main` @ f843e59, 2026-11-04)

This audit was checked against the code, not the README. The README still describes the
Gemini pipeline and is stale; its owner should sweep it.

Status legend: **BLOCKER** (rejection or legal exposure), **HIGH** (likely rejection or bad
first reviews), **MED**, **LOW**. "Owner" is whoever holds the file. This doc only
reports problems; it does not change those files.

## 0. Top blockers in priority order

1. **Model licences (legal).** Three of the five bundled models (SCRFD, FASHN, the Fashionpedia
   SegFormer) are non-commercial-only, and AdaFace's training data is research-only. Do not
   ship the current model set. Plan: docs/MODEL-LICENSING.md §5. Ask InsightFace for a
   licence today, retrain the garment segmenter, and keep YuNet + SFace as the fallback.
2. **Placeholder Terms and Privacy links, and no privacy policy.**
   - `Views/LoginView.swift:117,120` link to `https://your-terms-url.com` and `https://your-privacy-url.com`.
   - Guideline 5.1.1(i) needs a real policy in App Store Connect *and* in the app, covering face data (§3.1).
   - Guideline 2.1 rejects broken links.
3. **Gemini is still live on `main`.**
   - `ImageAnalysisService` sends wardrobe metadata and gender to `generativelanguage.googleapis.com` for outfits and shuffles (`HomeViewModel` lines 109, 224, 291, 328, 367).
   - `StyleMateApp` still gates scan and add on `GeminiConsentView`.
   - Branch `feat/outfit-engine` ("remove Gemini") is in flight. Until it merges, the "on-device" claim, the privacy manifest, the label "Data Not Collected" and the onboarding line "Everything stays on your device" are all false (guideline 2.3, 5.1.1).
4. **Sign-in wall with no account-based features, plus incomplete account deletion (5.1.1(v)).**
   - Every feature is local or in the user's own iCloud, yet `StyleMateApp` shows `LoginView` until the user signs in.
   - Apple: "If your app doesn't include significant account-based features, let people use it without a login."
   - If sign-in stays:
     - "Delete Profile & All Data" does not delete the Core Data outfit history (`ProfileView.deleteProfile` never touches `PersistenceController`), even though its alert promises "saved outfits".
     - Sign in with Apple tokens must be revoked through Apple's REST API on deletion, which needs a server the app does not have.
   - **Recommendation: drop the login (and Google Sign-In) for 1.0.** CloudKit already uses the device's iCloud account.
5. **Reviewer cannot experience the core feature (2.1 / 4.2).**
   - The review device's photo library is near-empty and contains nobody's outfits, so auto-scan finds nothing and the wardrobe stays empty.
   - Ship a **sample-wardrobe / demo-photos path** (for example "Try with sample photos" in onboarding, using CC0 images) and describe it in Review Notes.
   - Also put a screen recording of the real flow in the notes.

Also important, but below the top five:
- App size is about 420 MB, over the 200 MB cellular prompt (§4).
- The CloudKit schema must be deployed to Production before TestFlight (§6).
- Unused permission strings and background modes (§2).
- The iPad is targeted but probably not designed for (§2).
- The 1024 icon has an alpha channel (§6).

## 1. App Review guidelines likely to bite

| Guideline | Where it bites | Status | Fix |
|---|---|---|---|
| **5.1.1(i)** privacy policy | No policy, and the in-app links are placeholders | BLOCKER | Host a policy (GitHub Pages is fine) and link it in ASC and in `LoginView` / Profile. Contents in §3.1. |
| **5.1.1(ii)/(iv)** permission | Photo access is requested after an explainer. If denied, manual add still works (`OnboardingPhotoPermissionView` copy) | OK | Keep. Test the **Limited** library selection path too. |
| **5.1.1(v)** sign-in | Login is required for an app with no server account | HIGH | Remove the login, or make it optional. See blocker 4. |
| **5.1.1(v)** deletion | Outfit history is not deleted, and SIWA tokens are not revoked | HIGH (if the login stays) | Delete the Core Data store / `DatedOutfit` rows. Revoking needs a server, which is another reason to drop the login. |
| **5.1.2(vi)** facial mapping | Data from Photo/Camera APIs "may not be used for marketing, advertising or use-based data mining" | OK in code | State it in the privacy policy, and answer the reviewer's face-data questions (§3.2) in Review Notes. |
| **5.1.1 / 2.3** accuracy of privacy claims | "Everything stays on your device" (`OnboardingPhotoExplanationView:193`), "Your data stays private on this device" (`LoginView:102`) | HIGH | CloudKit uploads item photos to the user's iCloud. Say instead: "Analysed on your iPhone. Synced only to your own iCloud. Never sent to us." |
| **2.5.13** facial recognition | Applies only to face *authentication*. StyleMate does identification in photos, not log-in | OK | Don't describe it as Face ID-like. |
| **4.8** login services | Google Sign-In is offered, and Sign in with Apple is present (`AuthService`, `com.apple.developer.applesignin`) | OK | If Google stays, SIWA must stay as an equal option. |
| **2.1** completeness | Empty wardrobe on the reviewer's device. Any crash in a model path on an older device | HIGH | Sample wardrobe (blocker 5). Run TestFlight on the oldest supported device (A12, 3–4 GB RAM). |
| **4.2** minimum functionality | Fine once the pipeline works. The risk is the empty first run | MED | Same as above. |
| **2.3.1(a)** Review Notes | New face-matching behaviour must be "described with specificity" | MED | Use the Review Notes template in §3.2. |
| **2.5.4** background modes | `UIBackgroundModes: remote-notification` and `aps-environment` are unused (no `CKSubscription`, no `registerForRemoteNotifications`) | MED | Remove both (§2). |
| **2.3.7 / 5.2** metadata | Don't name "Google Photos" or other brands in the listing | LOW | See APP-STORE-LISTING.md. |
| **Paid-app trust** | Paid upfront with no trial, and Profile shows "Plan: Free" (`ProfileView:222-224`) | LOW | Remove the "Plan" row. Read the version from `Bundle.main` instead of the hard-coded "1.0.0" (`ProfileView:297`). |

Guideline 4.3 (spam) does not apply to StyleMate itself. But if it goes out from the same
developer account as the Duo hinge games, that account is under 4.3 scrutiny: Swoop and
Snapjaw were rejected on 29 Oct.
- Space this submission at least a few days from any new Duo-game submission.
- Give StyleMate distinct metadata and a distinct icon.

## 2. Info.plist and build settings (owner: Info.plist engineer)

Current `StyleMate/Info.plist`, plus `INFOPLIST_KEY_*` build settings in `project.pbxproj`:

1. **Remove `NSPhotoLibraryAddUsageDescription`.** Current text:
   "StyleMate saves diagnostic face crops to your Photos so recognition issues can be inspected."
   - No code writes to Photos (no `PHAssetChangeRequest` or `UIImageWriteToSavedPhotosAlbum`).
   - It reads as a debug feature that exports *face crops*, which is the worst possible impression for a face-data review.
2. **Camera: one string, not two.**
   - The Info.plist value: "StyleMate uses your camera to capture clothing items and take a reference selfie for finding your outfit photos."
   - The build-setting duplicate `INFOPLIST_KEY_NSCameraUsageDescription`: "This app needs access to your camera to let you add photos of your clothes to your wardrobe."
   - Delete the build-setting one and use:
     > StyleMate uses the camera to photograph clothes for your wardrobe and to take a one-time selfie. The selfie is used only on this iPhone to recognise you in your photos.
3. **Photos:** "StyleMate scans your photo library to automatically find and catalog your clothing items. Face matching happens entirely on your device." This is good. A stronger version:
   > StyleMate looks through your photos to find outfits you've worn and adds those clothes to your wardrobe. It recognises you with face matching that runs only on this iPhone. Your photos and face data are never sent to StyleMate or any AI service.
   - Keep the second sentence only once Gemini is gone.
4. **Location:**
   - Keep `NSLocationWhenInUseUsageDescription` (build setting: "This app uses your location to show local weather on the home screen."). Better:
     > StyleMate uses your approximate location to get today's weather, so outfit ideas suit it.
   - **Remove `NSLocationAlwaysAndWhenInUseUsageDescription`.** `LocationService` only calls `requestWhenInUseAuthorization`.
   - Add **`NSLocationDefaultAccuracyReduced = YES`**: city-level is enough for weather.
   - Round the coordinates sent to met.no and Open-Meteo to 2 decimals. `WeatherService` sends full precision today, and met.no's terms ask for at most 4 decimals.
5. **Remove `UIBackgroundModes` → `remote-notification`**, and `aps-environment` from `StyleMate.entitlements`. Nothing uses push.
6. **Add `ITSAppUsesNonExemptEncryption = NO`.** The app uses only Apple's HTTPS, which skips the export-compliance question on every build.
7. **Device family and orientation:**
   - `TARGETED_DEVICE_FAMILY = "1,2"` makes it an iPad app. That means iPad screenshots are required, and reviewers will test on iPad.
   - iPhone landscape orientations are enabled too.
   - Unless the iPad and landscape layouts are designed and tested, set `TARGETED_DEVICE_FAMILY = 1` and portrait-only for 1.0.
8. `CFBundleDisplayName`: not set, so it falls back to "StyleMate". Fine.
9. Google Sign-In keys (`GIDClientID`, URL scheme): remove them if Google Sign-In is dropped (recommended).

## 3. Face data: disclosure, policy, law

### 3.1 What the privacy policy must say (5.1.1(i), 5.1.2(vi))

- **What is processed:**
  - The reference selfie and face embeddings ("face templates") of the user.
  - Embeddings of *every face* in scanned photos, which are compared against the user's template.
- **Where:**
  - Only on the device.
  - The selfie is stored in `Documents/`. The gallery lives in `Application Support/FaceReference/`, which is excluded from backup.
  - Wardrobe items and their photos sync to the user's **own** iCloud private database, which the developer cannot read.
- **What is never done:**
  - No upload to the developer or third parties.
  - No marketing, advertising or data mining (quote 5.1.2(vi)).
  - No sharing.
- **Retention and deletion:**
  - Data stays until the user deletes it: Profile → Delete Profile & All Data, or deleting the app.
  - Faces of other people are discarded after matching, unless the user confirms them as themselves in "Is this you?".
- **Third parties:**
  - Weather providers (met.no, Open-Meteo) receive approximate coordinates.
  - Apple (Sign in with Apple, iCloud).
  - Google, only if Google Sign-In stays.
- **Code note:** the selfie in `Documents/` is included in device backups. Consider setting `isExcludedFromBackup` on it, as the face gallery already does (owner: `SelfieCameraService`).

### 3.2 Review Notes template (2.3.1(a))

> StyleMate builds a wardrobe from the user's photo library. During onboarding the user takes a selfie. StyleMate computes a face template from it **on the device**, using a bundled Core ML model, and compares it with faces in the user's photos to find pictures of the user. It then extracts the clothing in those photos into the wardrobe. No photo, face image or face template ever leaves the device. Nothing is sent to us or to any third party, and face data is never used for advertising, marketing or data mining. Wardrobe items sync only to the user's own iCloud private database. To try it without your own photos, tap "Try with sample photos" on the first screen. A screen recording of the full flow with a real library is attached. Users can delete all data in Profile → Delete Profile & All Data.

### 3.3 Biometric privacy law (needs counsel)

On-device processing greatly reduces exposure, but does not settle these laws:

- **Illinois BIPA:** written consent and a published retention policy. Class actions have targeted photo apps that do face grouping.
- **Texas CUBI** and **Washington's** biometric law.
- **GDPR Art. 9** and the UK GDPR for EU and UK users: biometric data used for identification.

Bystanders in the user's photos are scanned too.

Cheap mitigations:
- An explicit, separate "Face matching" consent screen before the first scan: what it does, that it is on-device, how to delete.
- The published retention policy from §3.1.
- Ask counsel whether to geo-limit or add stricter consent wording for Illinois.

## 4. App size

| Component | Size (CI `du -sh`) |
|---|---|
| FashionEncoder (FashionSigLIP, fp16) | 176 MB |
| MobileFaceNet (AdaFace IR-101, fp16) | 125 MB |
| GarmentParser (FASHN, int8) | 62 MB |
| GarmentLabeler (Fashionpedia SegFormer, int8) | 46 MB |
| SCRFD10G | 8.2 MB |
| FashionVocabulary.json | 1.2 MB |
| **Models total** | **≈ 418 MB** |
| Code, assets, GoogleSignIn | ≈ 10–20 MB |

**Estimates:**
- Install size is about 430–440 MB.
- App Store download size is about 380–420 MB, because quantized weights barely compress.
- Over 200 MB, iOS asks before downloading on cellular. The App Store Connect help page lists 200 MB as the over-the-air limit.
- The app is far under the 4 GB maximum.

**Options, in order of preference:**

1. **Shrink as a side effect of the licence fix** (docs/MODEL-LICENSING.md):
   - YuNet + SFace (about 0.3 MB + about 19–37 MB) instead of SCRFD + AdaFace (133 MB).
   - One retrained segmenter (about 25–90 MB) instead of two (108 MB).
   - FashionSigLIP's image tower at int8 (about 176 → 90 MB, parity-checked like the parsers).
   - That gives about **150–220 MB**, close to or under the cellular prompt.
2. **Self-hosted Background Assets** (`BackgroundAssets` framework, iOS 16+): download the big models after install.
   - Needs your own CDN, and a first-run "downloading models" state.
   - The privacy story still holds, because only models are downloaded.
3. **Apple-hosted Background Assets / asset packs.** Apple hosts them, but they need an **iOS 26** deployment target. The current target is 18.4.
4. **On-Demand Resources.** Do not adopt. A third-party summary of the iOS 27 release notes says ODR is deprecated, and an Apple engineer on the developer forums says new apps should use Background Assets instead.

## 5. Performance risks

| Risk | Where | Mitigation |
|---|---|---|
| Memory peak with 5 models resident (about 420 MB of weights, plus activations at 384×576 and 512×512) | `WardrobeML`, `FaceMatchingService`, `SCRFDDetector` all use `computeUnits = .all` | Load lazily and release the segmenters between scan batches. Test on the oldest supported device: iOS 18.4 runs on A12 iPhone XS/XR (3–4 GB RAM) and iPhone SE 2/3 (3–4 GB). Watch for jetsam in TestFlight crash logs. |
| First-load latency (Core ML specialises models for the ANE on first use, which can take seconds per model) | First scan after install or update | Warm models in the background after onboarding, and show progress. |
| Long scans of big libraries (detector + embedder per face, parser + labeler + encoder per kept photo) | `PhotoScanService` | Already checkpointed and thermal-aware (lines 316–320). Add an honest ETA. There is no `BGProcessingTask`, so scans stop when the app is backgrounded. Say so in the UI, or add `BGContinuedProcessingTask` (iOS 26+) later. |
| iCloud original downloads on cellular (`isNetworkAccessAllowed = true` at `PhotoScanService:592,636`, `FaceReferenceViewModel:76`) | iCloud Photos "Optimize Storage" users | Respect Low Data Mode (`NWPathMonitor` `isConstrained` / `isExpensive`). Offer a "Download iCloud photos on cellular" toggle. Otherwise a 1-year scan can burn gigabytes. |
| Battery and thermals | Long scans | Keep the existing thermal backoff. Pause when Low Power Mode is on. |
| Simulator ≠ device | CI runs on a simulator only | ANE and GPU numerics differ. Run a TestFlight build on a real device before submitting. |

## 6. Founder actions (only the founder can do these)

1. **Licences:** send the InsightFace email (docs/MODEL-LICENSING.md §5). Engage counsel on the §3 caveat and on biometric law (§3.3 above).
2. **Apple Developer portal** (team `KZN5G7M9J3`, as set in `project.pbxproj`):
   - App ID `com.stylemates.StyleMate` with **iCloud (CloudKit)**, container `iCloud.com.stylemates.StyleMate`.
   - **Sign in with Apple** on the same App ID.
   - Push notifications only if `aps-environment` stays (recommended: remove it).
3. **CloudKit Console:** deploy the `WardrobeItem` schema in zone `WardrobeZone` **to Production**. TestFlight and App Store builds use the Production environment. Without this, sync fails for every tester.
4. **App Store Connect app record:**
   - Name, bundle ID `com.stylemates.StyleMate`, SKU (e.g. `stylemate-ios-1`), primary language.
   - Category: Lifestyle (primary), Photo & Video (secondary).
   - Price tier, age rating questionnaire.
   - Privacy policy URL, support URL.
   - App Privacy answers (§7).
5. **GitHub secrets on `pravegm/StyleMate`:** `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` (the .p8 text, **Admin** role so cloud-managed signing works) and `APPLE_TEAM_ID`.
   - These are the same four values as the sister apps, but **`APPLE_TEAM_ID` must be the team that owns the iCloud container** (`KZN5G7M9J3` unless that changes).
6. **Privacy policy page** (and optionally Terms; Apple's standard EULA is acceptable). Host it, then give the URLs to the `LoginView` / Profile owner.
7. **Icon:** `AppIcon.appiconset/stylemate.png` is 1024×1024 **RGBA** (PNG colour type 6). App Store Connect rejects an alpha channel (ITMS-90717). Either commit a flattened PNG or rely on the workflow's flatten step (§8).
8. **Screenshots and preview:** see APP-STORE-LISTING.md. Record the Review Notes video on a real device with a real library.

## 7. Privacy manifest and the App Privacy label

`StyleMate/PrivacyInfo.xcprivacy` (added on this branch):

- **`NSPrivacyTracking` = false, no tracking domains.** There are no ad, analytics or attribution SDKs.
- **`NSPrivacyAccessedAPITypes`:** only `NSPrivacyAccessedAPICategoryUserDefaults` with reason **CA92.1** (app-only defaults; no app group).
  - The app's own code calls `UserDefaults.standard` in about 15 files.
  - No file-timestamp APIs (`attributesOfItem`, `creationDateKey` and similar), no disk space, no `systemUptime` / `mach_absolute_time`, no active keyboards.
  - `PHAsset.creationDate` in fetch predicates is a Photos property, not a required-reason API.
  - Re-check after code changes:
    `rg "attributesOfItem|DateKey|systemUptime|mach_absolute_time|volumeAvailableCapacity|statfs|activeInputModes" StyleMate`
- **`NSPrivacyCollectedDataTypes`:** empty. Apple's definition of "collect": "transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time", and "Data that is processed only on device is not 'collected'".
  - Face templates, the selfie and garment analysis stay on the device, so they are not collected.
  - CloudKit private database: it is the user's own iCloud and the developer cannot read it. "You are not responsible for disclosing data collected by Apple." Not collected.
  - Sign in with Apple name and email are stored only in `UserDefaults` on the device. Not collected.
  - Weather coordinates go to met.no and Open-Meteo, and are serviced in real time. StyleMate keeps nothing. Not collected. Round them to 2 decimals (§2 item 4) so that even a conservative reading counts them only as Coarse Location.
- **Two conditions keep "Data Not Collected" true:**
  1. **Gemini removed.** While `ImageAnalysisService` sends wardrobe text and gender to Google, add Other User Content and Other Data Types (App Functionality) to the manifest and the label.
  2. **Google Sign-In removed.** The GoogleSignIn-iOS SDK bundles its own manifest. It declares Name, Email Address, Phone Number, User ID, Coarse Location and Other Data Types for App Functionality, plus Device ID, Other Usage Data, User ID and Other Data Types for Analytics, all *linked to the user*. Xcode merges it into the privacy report, and the label must include it.
     - Dropping Google Sign-In is what earns the "Data Not Collected" label, which is the listing's main selling point.
- **Bundling:**
  - The `StyleMate/` folder is a `PBXFileSystemSynchronizedRootGroup` whose only exception is `Info.plist`, so the manifest is copied into `StyleMate.app/` automatically.
  - CI build for this branch: see §9.
  - The TestFlight workflow (§8) also checks `StyleMate.app/PrivacyInfo.xcprivacy` with `plutil -lint`.

## 8. TestFlight workflow (proposal; do not add it to `.github` until the founder has done §6.2–6.5)

The workflow is adapted from `pravegm/glint/.github/workflows/testflight.yml` (read 2026-11-04). It reuses Glint's proven pattern:
- Release archive with **no development certificate**: ad-hoc, with an unsigned fallback.
- The **App Store signature comes from export**, using Apple's cloud-managed distribution certificate and an Admin API key.
- Build number = run number.
- Icon flattening, then upload.

StyleMate-specific changes:
- There is no XcodeGen step, because the `.xcodeproj` is committed.
- The models are restored from the same Actions caches as `ci.yml`. They are never rebuilt or uploaded anywhere public.
- The entitlements are resolved for the unsigned fallback, since `iCloud.$(CFBundleIdentifier)` must be expanded.
- iCloud and SIWA entitlements are verified in the exported signature.
- The bundle is checked for the compiled models and the privacy manifest.

```yaml
name: TestFlight

# Builds a signed Release of StyleMate with Xcode 27.1 on GitHub's Apple-silicon runner and uploads it to App Store
# Connect (TestFlight). Adapted from pravegm/glint's testflight.yml (cloud-managed App Store signing, no development
# certificate). Repository secrets: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (.p8 text, Admin key), APPLE_TEAM_ID
# (must own iCloud.com.stylemates.StyleMate). Prerequisites: docs/LAUNCH-READINESS.md section 6 (App ID with iCloud +
# Sign in with Apple, CloudKit schema deployed to Production, ASC app record for com.stylemates.StyleMate).
# The on-device models are git-ignored; this restores them from ci.yml's Actions cache, so run CI on main first.

on:
  workflow_dispatch:
    inputs:
      notes:
        description: "What to test (shown in the run summary)"
        type: string
        default: ""
      check_only:
        description: "Only build an unsigned Release archive (no secrets, no upload)"
        type: boolean
        default: false

concurrency:
  group: testflight
  cancel-in-progress: false

env:
  BUNDLE_ID: com.stylemates.StyleMate

jobs:
  build:
    runs-on: xcode-27
    timeout-minutes: 75
    env:
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
      ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }}
      APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
    steps:
      - name: Check the secrets
        if: ${{ !inputs.check_only }}
        run: |
          missing=""
          for s in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY APPLE_TEAM_ID; do [ -n "${!s}" ] || missing="$missing $s"; done
          [ -z "$missing" ] || { echo "::error::Missing repository secrets:$missing"; exit 1; }

      - uses: actions/checkout@v4

      # Keys must match ci.yml exactly (hashFiles is evaluated after checkout, in the step).
      - name: Restore face models
        uses: actions/cache/restore@v4
        with:
          path: |
            MobileFaceNet.mlpackage
            SCRFD10G.mlpackage
          key: face-models-v1-${{ hashFiles('scripts/build_face_models.sh', 'scripts/convert_adaface.py', 'scripts/convert_scrfd.py', 'scripts/adaface_net.py') }}
          fail-on-cache-miss: true
      - name: Restore wardrobe models
        uses: actions/cache/restore@v4
        with:
          path: StyleMate/ML
          key: wardrobe-models-v1-${{ hashFiles('scripts/build_wardrobe_models.sh', 'scripts/convert_wardrobe_models.py', 'scripts/fashion_vocabulary.json') }}
          fail-on-cache-miss: true

      - name: Select Xcode 27.1
        run: |
          sudo xcode-select -s /Applications/Xcode_27.1.app
          xcodebuild -version

      - name: Write Secrets.swift (compile-only stub; delete this step once Gemini code is gone)
        run: |
          [ -f StyleMate/Secrets.swift ] || printf 'enum Secrets {\n    static let geminiAPIKey = ""\n}\n' > StyleMate/Secrets.swift

      - name: Flatten the app icon (App Store rejects alpha, ITMS-90717)
        run: |
          cat > "$RUNNER_TEMP/flatten.swift" <<'EOF'
          import Foundation
          import CoreGraphics
          import ImageIO
          import UniformTypeIdentifiers
          for path in CommandLine.arguments.dropFirst() {
              let url = URL(fileURLWithPath: path) as CFURL
              guard let src = CGImageSourceCreateWithURL(url, nil),
                    let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot read \(path)") }
              let w = img.width, h = img.height
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
              ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
              ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
              ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
              let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
              CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
              guard CGImageDestinationFinalize(dst) else { fatalError("cannot write \(path)") }
              print("flattened \(path)")
          }
          EOF
          shopt -s nullglob
          icons=(StyleMate/Assets.xcassets/AppIcon.appiconset/*.png)
          (( ${#icons[@]} > 0 )) || { echo "::error::no app icon PNG"; exit 1; }
          xcrun swift "$RUNNER_TEMP/flatten.swift" "${icons[@]}"

      - name: Archive (unsigned check)
        if: ${{ inputs.check_only }}
        run: |
          set -o pipefail
          xcodebuild archive -project StyleMate.xcodeproj -scheme StyleMate -configuration Release \
            -destination 'generic/platform=iOS' -archivePath "$RUNNER_TEMP/StyleMate.xcarchive" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
            CURRENT_PROJECT_VERSION="${{ github.run_number }}" \
            2>&1 | tee archive.log | grep -E "error:|warning: .*StyleMate/|\*\* ARCHIVE" || true
          grep -q "\*\* ARCHIVE SUCCEEDED \*\*" archive.log

      - name: Write the API key
        if: ${{ !inputs.check_only }}
        run: |
          umask 077
          KEY="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
          printf '%s\n' "$ASC_PRIVATE_KEY" > "$KEY"
          echo "KEY_PATH=$KEY" >> "$GITHUB_ENV"

      - name: Archive (Release) without creating a development certificate
        if: ${{ !inputs.check_only }}
        run: |
          set -o pipefail
          common=(-project StyleMate.xcodeproj -scheme StyleMate -configuration Release -destination 'generic/platform=iOS'
                  -archivePath "$RUNNER_TEMP/StyleMate.xcarchive" CURRENT_PROJECT_VERSION="${{ github.run_number }}"
                  DEVELOPMENT_TEAM="$APPLE_TEAM_ID")
          if xcodebuild archive "${common[@]}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER= \
               2>&1 | tee archive.log | grep -E "error:|warning: .*StyleMate/|\*\* ARCHIVE"; \
             grep -q "\*\* ARCHIVE SUCCEEDED \*\*" archive.log; then
            echo "ARCHIVE_MODE=adhoc" >> "$GITHUB_ENV"
          else
            echo "::warning::ad-hoc archive failed; archiving unsigned"
            rm -rf "$RUNNER_TEMP/StyleMate.xcarchive"
            xcodebuild archive "${common[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
              2>&1 | tee archive.log | grep -E "error:|warning: .*StyleMate/|\*\* ARCHIVE" || true
            grep -q "\*\* ARCHIVE SUCCEEDED \*\*" archive.log
            # Export only carries over entitlements the archived binary declares (Glint run 40268420116), so stamp them
            # on with a local ad-hoc signature. Expand $(CFBundleIdentifier) first.
            sed "s/\$(CFBundleIdentifier)/$BUNDLE_ID/g" StyleMate/StyleMate.entitlements > "$RUNNER_TEMP/resolved.entitlements"
            APP="$RUNNER_TEMP/StyleMate.xcarchive/Products/Applications/StyleMate.app"
            codesign --force --sign - --timestamp=none --entitlements "$RUNNER_TEMP/resolved.entitlements" "$APP"
            echo "ARCHIVE_MODE=unsigned+adhoc-entitlements" >> "$GITHUB_ENV"
          fi

      - name: Check the archive
        run: |
          APP="$RUNNER_TEMP/StyleMate.xcarchive/Products/Applications/StyleMate.app"
          test -f "$APP/PrivacyInfo.xcprivacy" && plutil -lint "$APP/PrivacyInfo.xcprivacy"
          for m in MobileFaceNet SCRFD10G GarmentParser GarmentLabeler FashionEncoder; do
            test -d "$APP/$m.mlmodelc" || { echo "::error::$m.mlmodelc missing from the bundle"; exit 1; }
          done
          test -f "$APP/FashionVocabulary.json"
          BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")
          [ "$BUILT" = "${{ github.run_number }}" ] || { echo "::error::CFBundleVersion is $BUILT"; exit 1; }
          /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" "$APP/Info.plist"
          if strings "$APP/StyleMate" | grep -q "generativelanguage.googleapis.com"; then
            echo "::warning::Gemini endpoint still in the binary: the privacy manifest/label 'Data Not Collected' is not accurate"
          fi
          du -sh "$APP"

      - name: Export locally and check the App Store signature
        if: ${{ !inputs.check_only }}
        run: |
          set -o pipefail
          cat > "$RUNNER_TEMP/ExportLocal.plist" <<EOF
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>export</string>
            <key>manageAppVersionAndBuildNumber</key><false/>
            <key>teamID</key><string>${APPLE_TEAM_ID}</string>
            <key>signingStyle</key><string>automatic</string>
          </dict></plist>
          EOF
          xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/StyleMate.xcarchive" \
            -exportOptionsPlist "$RUNNER_TEMP/ExportLocal.plist" -exportPath "$RUNNER_TEMP/local" \
            -allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" \
            -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            2>&1 | tee export-local.log | grep -E "error:|EXPORT" || true
          grep -q "\*\* EXPORT SUCCEEDED \*\*" export-local.log
          mkdir -p "$RUNNER_TEMP/ipa" && cd "$RUNNER_TEMP/ipa" && unzip -q "$RUNNER_TEMP"/local/*.ipa
          APP=$(ls -d "$RUNNER_TEMP"/ipa/Payload/*.app)
          codesign -d --entitlements :- "$APP" > ent.plist 2>/dev/null || true
          cat ent.plist
          for e in com.apple.developer.icloud-services com.apple.developer.icloud-container-identifiers com.apple.developer.applesignin; do
            grep -q "$e" ent.plist || { echo "::error::$e missing from the App Store signature ($ARCHIVE_MODE)"; exit 1; }
          done
          grep -q "iCloud.$BUNDLE_ID" ent.plist || { echo "::error::iCloud container not iCloud.$BUNDLE_ID"; exit 1; }

      - name: Upload to App Store Connect
        if: ${{ !inputs.check_only }}
        run: |
          set -o pipefail
          cat > "$RUNNER_TEMP/ExportOptions.plist" <<EOF
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>manageAppVersionAndBuildNumber</key><false/>
            <key>teamID</key><string>${APPLE_TEAM_ID}</string>
            <key>signingStyle</key><string>automatic</string>
            <key>uploadSymbols</key><true/>
          </dict></plist>
          EOF
          xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/StyleMate.xcarchive" \
            -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist" -exportPath "$RUNNER_TEMP/export" \
            -allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" \
            -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            2>&1 | tee export.log | grep -E "error:|Upload|EXPORT|uploaded" || true
          grep -qE "\*\* EXPORT SUCCEEDED \*\*|Upload succeeded|Uploaded" export.log

      - name: Summary
        if: ${{ success() && !inputs.check_only }}
        env:
          NOTES: ${{ inputs.notes }}
        run: |
          {
            echo "### Uploaded StyleMate build ${{ github.run_number }} to App Store Connect"
            echo "Archive: $ARCHIVE_MODE (no development certificate created). Appears in TestFlight after processing (10-30 min)."
            [ -z "$NOTES" ] || { echo ""; echo "**What to test:** $NOTES"; }
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Remove the key
        if: always()
        run: rm -f "$RUNNER_TEMP"/AuthKey_*.p8

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: testflight-logs
          path: |
            archive.log
            export.log
            export-local.log
          if-no-files-found: ignore
```

Notes on the workflow:
- **Cache keys** must stay identical to `ci.yml`. If the model scripts change, run CI on `main` first so the cache exists.
  - GitHub lets a `workflow_dispatch` run on `main` restore caches saved on `main`.
- **When the model set changes** (MODEL-LICENSING.md), update the `for m in …` list and both cache keys.
- **The weights are never uploaded as artifacts.** The repo is public, and the logs contain no model files.
- **CloudKit environment:** App Store-signed builds use the CloudKit **Production** environment, hence founder action §6.3.

## 9. Branch status

- This branch adds `StyleMate/PrivacyInfo.xcprivacy`, this doc, docs/MODEL-LICENSING.md and docs/APP-STORE-LISTING.md.
- The manifest is well-formed XML with the four standard keys.
- Bundling is confirmed in the CI build log (`ci-report` → `build.log`) of the branch run.
