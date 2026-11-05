# Getting StyleMate onto your iPhones (TestFlight)

Builds are made in the cloud by `.github/workflows/testflight.yml`, so no Mac is needed. You do
three one-time things, then every new build is one button press.

## One-time setup (about 15 minutes)

### 1. Register the app's ID (developer.apple.com)
1. Go to https://developer.apple.com/account/resources/identifiers/list and sign in.
2. Press the blue **+**, choose **App IDs**, then **Continue**. Choose **App**, then **Continue**.
3. **Description**: `StyleMate`. **Bundle ID**: choose *Explicit* and type `com.stylemates.StyleMate`.
4. Under **Capabilities**, tick **iCloud** (choose "Include CloudKit support"). There's no login any
   more, so Sign In with Apple isn't needed.
5. Press **Continue**, then **Register**.
6. Open the new ID again. Next to iCloud, press **Edit** (or **Configure**), press **+** to add a
   container named `iCloud.com.stylemates.StyleMate`, tick it, and press **Save**.

If it says the bundle ID is already taken, it was registered earlier under your account. That's
fine: just make sure those two capabilities are ticked.

### 2. Create the app in App Store Connect
1. Go to https://appstoreconnect.apple.com, then **Apps**, the **+** button, and **New App**.
2. **Platform**: iOS. **Name**: `StyleMate` (any available name works; you can change it later).
   **Primary language**: English (U.K.). **Bundle ID**: pick `com.stylemates.StyleMate`. **SKU**: `stylemate`.
3. Press **Create**.

### 3. Give GitHub the same signing key your other apps use
On https://github.com/pravegm/StyleMate/settings/secrets/actions press **New repository secret**
four times. Use the same values you entered for Squish, Brim and the other Duo games:

| Name | Value |
|---|---|
| `ASC_KEY_ID` | Your App Store Connect API key ID (10 characters) |
| `ASC_ISSUER_ID` | The Issuer ID shown above the keys list in App Store Connect › Users and Access › Integrations |
| `ASC_PRIVATE_KEY` | The whole text of the `.p8` file, including the BEGIN/END lines |
| `APPLE_TEAM_ID` | Your 10-character Team ID (developer.apple.com › Account › Membership details) |

### 4. Publish the privacy policy (one click)
On https://github.com/pravegm/StyleMate/settings/pages, under **Build and deployment**, choose
**Deploy from a branch**, branch `main`, folder `/docs`, then **Save**. After a minute the policy is
live at https://pravegm.github.io/StyleMate/privacy.html, the link the app already uses. App Store
Connect asks for the same link.

### 5. Switch on iCloud backup (about 5 minutes, once)
TestFlight builds use Apple's *Production* iCloud environment, which needs the app's data layout
("schema") uploaded once. Until you do this, the app works fully but the wardrobe isn't backed up.
1. Go to https://icloud.developer.apple.com and sign in with the developer team's Apple ID. Choose
   the container **iCloud.com.stylemates.StyleMate** (it appears after step 1 above).
2. Open **Settings**, then **Tokens**. Next to **Management Tokens** press **+**, name it
   `GitHub schema import`, create it, and copy the token. It is shown only once.
3. On https://github.com/pravegm/StyleMate/settings/secrets/actions add a secret named
   `CK_MANAGEMENT_TOKEN` with that token.
4. Open https://github.com/pravegm/StyleMate/actions/workflows/cloudkit-schema.yml and press
   **Run workflow**. Wait for the green tick. If it fails, the log shows why, and it can be fixed
   from there.
5. Back in the iCloud console, choose the **Development** environment, then **Schema → Record
   Types**, and check that **WardrobeItem** is listed. Press **Deploy Schema Changes…** and confirm
   the deployment to **Production**.
6. Open StyleMate again. Backup starts on the next launch, including everything added before.

## Making a build (every time)
1. Open https://github.com/pravegm/StyleMate/actions/workflows/testflight.yml.
2. Press **Run workflow**, then the green **Run workflow** button. You can type a note about what to test.
3. After about 30–45 minutes the run turns green. App Store Connect then takes 10–30 minutes to process the build.
4. In App Store Connect › StyleMate › **TestFlight**, add yourself under **Internal Testing** (first time only).
5. Install **TestFlight** from the App Store on your iPhone 17 Pro and your iPhone Duo, and install StyleMate there.

## What to test
- **Onboarding**: the selfie (3 quick frames), "Find yourself", and the first scan starting.
- **Wardrobe**: items appear while the scan runs. Studio photos replace the cutouts over the next minutes, and longer overnight while charging.
- **Today's Outfit**: pick a mood, look through the 5 options, swap a piece, and save.
- **Outfits calendar**: the saved look is on today's date.
- **iPhone Duo**: try each screen open flat, half-open, and on the cover screen when closed.

The app is large (about 1.5 GB, mostly the on-device AI models), so install it on Wi-Fi.
