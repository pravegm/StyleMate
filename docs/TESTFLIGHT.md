# Getting StyleMate onto your iPhones (TestFlight)

Builds are made in the cloud by `.github/workflows/testflight.yml`, so no Mac is needed. You do
a few one-time things, then every new build is one button press.

**Already done (checked 6 Nov 2026 with the read-only `asc-check.yml` workflow).** StyleMate has
existed in your account since 2025, so steps 1–3 are mostly complete:
- App ID `com.stylemates.StyleMate` (team KZN5G7M9J3) has Sign In with Apple and iCloud, plus
  In-App Purchase, Push Notifications and WeatherKit, which are harmless and can stay.
- App record **StyleMate** (Apple ID 6746056410, SKU `com.stylemates.StyleMate`, English (U.K.)),
  version 1.0 "Prepare for Submission", builds 1–9 from 2025–26 (all expired), and an
  **Internal testers** TestFlight group.
- The 4 repository secrets.

The new builds are numbered from 104 upwards (run number + 100), so they always sort above the old
ones. To re-check what App Store Connect holds, run
https://github.com/pravegm/StyleMate/actions/workflows/asc-check.yml.

## One-time setup

### 1. Check the iCloud container (developer.apple.com, 2 minutes)
Apple's API can't show which iCloud container the App ID uses, so check it by hand:
1. Go to https://developer.apple.com/account/resources/identifiers/list and open
   **com.stylemates.StyleMate**.
2. Next to **iCloud**, press **Edit** (or **Configure**). Make sure `iCloud.com.stylemates.StyleMate`
   is ticked. If it isn't listed, press **+**, add it, tick it, and press **Save**.

### 2. App Store Connect app record
Done: it already exists (see above). Nothing to do.

### 3. Give GitHub the same signing key your other apps use (done)
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

**Run steps 4 and 5 again whenever the data layout changes.** The account build (Sign in with Apple)
adds four fields to each wardrobe record (`createdAt`, `tier`, `isSample`, `isLocked`, so the 50 free
pieces and the waiting ones are the same on every iPhone). Until the updated layout is deployed to
Production, TestFlight builds keep working but don't back up.

### 6. Set up StyleMate Premium (subscriptions, about 30 minutes, once)
The app is free for the first 50 wardrobe pieces (sample clothes don't count); StyleMate Premium
(monthly or yearly) makes the wardrobe unlimited. Every other feature is free. The app reads the
plans, prices and trial from App Store Connect, so nothing in the code changes when you change a
price. Until this step is done, the paywall in TestFlight says "Couldn't reach the App Store";
everything else works.

**a. Paid Apps agreement (needed before any subscription can be sold, or tested in TestFlight)**
1. App Store Connect › **Business** (older accounts: **Agreements, Tax, and Banking**).
2. Next to **Paid Apps**, press **View and Agree to Terms** (only the Account Holder can).
3. Add a **bank account** and complete the **tax forms** (from the UK: the U.S. form W-8BEN as an
   individual, or W-8BEN-E as a company). Wait until the agreement's status says **Active**; that
   can take a day or two after the bank details go in.

**b. The subscription group and the two plans**
1. App Store Connect › **Apps** › StyleMate › **Monetization › Subscriptions** (left column).
2. Under **Subscription Groups** press **Create**. Reference name: `StyleMate Premium`.
3. In the group, press **Create** for each plan. Type the product IDs *exactly*: the app looks for
   these two.

| | Reference name | Product ID | Duration | Suggested price |
|---|---|---|---|---|
| 1 | Premium Annual | `com.stylemates.StyleMate.premium.annual` | 1 year | £24.99 |
| 2 | Premium Monthly | `com.stylemates.StyleMate.premium.monthly` | 1 month | £3.99 |

4. For each plan:
   - **Subscription Prices** › **Add Subscription Price**: United Kingdom, the price above; let
     Apple fill in the other countries. (£24.99 a year is about 48% less than 12 × £3.99. The app
     works the saving out from the real prices and shows it on the annual plan, rounded down:
     "Save 47%".)
   - **App Store Localization** › English (U.K.): display name `Premium Annual` /
     `Premium Monthly` (the paywall shows this name), description
     `Unlimited wardrobe, billed yearly` / `Unlimited wardrobe, billed monthly`.
   - **Review Information**: upload a screenshot of the paywall (from the latest green CI run's
     `e2e-screens` artifact, the file ending `-paywall.png`) and paste the review note from
     `docs/APP-STORE-LISTING.md` ("In-App Purchase review notes").
5. **1-week free trial on the annual plan**: Premium Annual › **Subscription Prices** › **View all
   Subscription Pricing** › **Introductory Offers** › **Create Introductory Offer**: all countries,
   starts today, no end date, **Free**, **1 week**. The paywall shows the trial only to people who
   can still get it.
6. Group **levels**: Premium Annual at level 1, Premium Monthly at level 2 (moving from monthly to
   annual then counts as an upgrade).
7. Group **App Store Localization** › English (U.K.): display name `StyleMate Premium`.
8. Recommended: group › **Billing Grace Period** › on (6 days, all renewals). If someone's card
   fails, they keep Premium while Apple retries; the app already handles this.
9. The first time, the subscriptions go to review **with an app version**: when you submit
   StyleMate, tick both plans under the version's **In-App Purchases and Subscriptions**. Until
   then they say "Ready to Submit", which is fine for TestFlight.

**c. Buying Premium in TestFlight (free)**
- TestFlight purchases use Apple's test system: no money is charged, and the purchase sheet says
  it's a test. You use your normal Apple Account.
- Renewals are sped up. Apple's current TestFlight rule is that any plan renews about once a day,
  up to six times, then it stops by itself (Apple has changed this rule before). So within a week
  you can see a renewal and the end: when Premium ends, Profile says "Premium ended", new pieces
  past 50 wait again, and every piece you already have stays in the closet.
- Premium belongs to the StyleMate account you're signed in with (the purchase carries it). The
  50 free pieces are per account too: two iPhones on the same account share them. If both add pieces
  offline past 50, the next sync keeps the 50 oldest and says how many moved to Premium.
- What to try: get the closet to 50 pieces (your own photos; sample clothes don't count) and let
  the scan keep going. Home shows "N more pieces found — Unlock with Premium". Tap it, pick
  Annual, **Start free trial**: the waiting pieces appear in the closet at once. Profile › StyleMate
  Premium shows the plan and renewal date, **Manage subscription** and **Restore Purchases**.
  Delete and reinstall the app, then **Restore Purchases**: Premium comes back.

## Making a build (every time)
1. Open https://github.com/pravegm/StyleMate/actions/workflows/testflight.yml.
2. Press **Run workflow**, then the green **Run workflow** button. You can type a note about what to test.
3. After about 30–45 minutes the run turns green. App Store Connect then takes 10–30 minutes to process the build.
4. In App Store Connect › StyleMate › **TestFlight** › **Internal testers** (the group already exists), check you're listed and that the new build is added to the group (first time only).
5. Install **TestFlight** from the App Store on your iPhone 17 Pro and your iPhone Duo, and install StyleMate there.

## What to test
- **Onboarding**: the selfie (3 quick frames), "Find yourself", and the first scan starting.
- **Wardrobe**: items appear while the scan runs. Studio photos replace the cutouts over the next minutes, and longer overnight while charging.
- **Today's Outfit**: pick a mood, look through the 5 options, swap a piece, and save.
- **Outfits calendar**: the saved look is on today's date.
- **iPhone Duo**: try each screen open flat, half-open, and on the cover screen when closed.
- **Premium** (after step 6): the paywall from Home's "more pieces found" card, a free-trial
  purchase, the pieces unlocking, and Profile › StyleMate Premium.
- **Diagnostics (once on each phone, about 10 minutes)**: plug the phone in, then open **Profile → About →
  Diagnostics** and press **Run benchmark**. Keep StyleMate on screen until it says Done. On the Duo, also do the
  **iPhone Duo hinge** check on the same screen (open flat, hold at about 90°, close, tapping **Record** each
  time). Then press **Share report** and send it to us (Mail, Messages or Notes all work). The report has
  timings and phone facts only: no photos, faces or clothes.

The app is large (about 1.3 GB, mostly the on-device AI models), so install it on Wi-Fi.
