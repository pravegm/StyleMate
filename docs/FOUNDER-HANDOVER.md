# StyleMate: where things stand (founder handover)

Plain-language summary as of 7 Nov 2026. Technical detail lives in
`docs/PROJECT-LOG.md`, reviews in `docs/reviews/`, launch and legal detail in
`docs/LAUNCH-READINESS.md` and `docs/MODEL-LICENSING.md`, and the setup steps in `docs/TESTFLIGHT.md`.

## Latest (7 Nov, afternoon): TestFlight build 115

**Why 113 and 114 still stuck on your Duo, and what 115 changes.** Your Diagnostics showed "Now: Picking the
best outfit photos" with "Person check: Vision": Apple's Vision body detector blocked and never returned
during the first-run ranking, and the ranking only checked its 20 s budget between batches, so the scan
stayed at 8 photos. Build 115:
- uses the app's own face detector (the one Find yourself already uses on your Duo) as the person check,
  with no Vision body detector in the scan at all;
- enforces the ranking's 20 s limit even if a check never returns, then scans anyway;
- runs every remaining Vision call (multi-person photos, manual add, studio, try-on) with a 10–20 s limit
  and a fallback.
The real-first-run test now freezes Vision on purpose: without the fix it fails with "stood still at 0 of
261 photos" (your symptom), with it the closet fills (CI 42361035610, 42361076929; main 42365113583).
- Hats and turbans: the cutout no longer includes the face under them.
- AI catalogue photos: on phones with room for both (your Duo, the 17 Pro) the studio redraws pieces as
  product photos *while* the first scan runs, instead of only after it finished (hours on a big library).

**What changed since build 112 (113/114, still in 115)**
- The scan no longer waits forever on photos that iCloud hasn't delivered: it uses the preview already on
  the phone, gives up on a slow download after 20 s and tries that photo again later. Weather never spins
  forever: after 20 s it shows Retry, and asks again when you come back to the app.
- Find yourself looks at your whole recent library (it saw 1 photo in 267 before); a failed person check
  no longer counts as "nobody in this photo".
- Diagnostics › **Photo scan** shows what the scan is doing right now and how long each step takes.
- From the every-flow tests: "Take a Photo" no longer crashes without a camera; "Is this you?" photos are
  reachable from Home; Empty my wardrobe clears Today's look; the paywall's close button works after a big
  gallery add; Profile no longer shows a previous account's name; Location denied says "Location required".
- Premium is live in TestFlight: both plans are Ready to Submit with prices, the annual trial and review
  screenshots. Purchases in TestFlight are free.

**How it was checked:** every user flow now has an end-to-end test on the simulator that does what a user
does and checks the result (often after quitting the app): the real first run with nothing pre-granted,
selfie, Find yourself, a 260-photo library with photos that never load, closet edit/delete/search, the
outfit deck (keep, swap, skip, wear), calendar, Premium purchase/restore/limit, profile, sign out, delete
account, dark mode, landscape and the Duo screens. The test of the first run fails on build 112's code with
your exact symptom. Main CI 42344238439 is green.

**What the simulator can't check (please try on the Duo):** real iCloud downloads and Neural Engine speed,
real Sign in with Apple, the camera, notifications arriving, the overnight scan, iCloud backup/restore.

**To test on your Duo:** delete StyleMate, install build 115 from TestFlight, go through the first run
(selfie, Find yourself) and let the scan run on Wi-Fi with the app open. If it stalls, open Profile › About ›
Diagnostics, Share report, and send it: the Photo scan section says exactly where it waits.

**Two small decisions for you:** the "Not my style / Not today" prompt closes itself after 6 s (longer with
VoiceOver): keep or lengthen? Without a camera "Take a Photo" opens the photo library: keep, or hide the row?
Also still yours: turn on GitHub Pages (privacy policy, needed for the App Store listing) and the CloudKit
token for iCloud backup (`docs/TESTFLIGHT.md` step 5).

## What the app does now

Everything runs **on the iPhone**: no API keys and no StyleMate server. What leaves the phone is the
user's own iCloud backup, Apple's sign-in and payments, and a rounded (~1 km) location for the weather.

1. **Sign in with Apple, then the first run.** Welcome → Sign in with Apple (the only way in; name
   only, never email) → a 3-frame selfie → photo access → "Find yourself" (tap your face once) → the
   first scan. Skip the selfie and you land on Home with a card offering a selfie or the sample photos.
2. **Digital wardrobe, built automatically.** The scan finds photos of *you* (face models YuNet +
   SFace), separates you from other people, and cuts out every garment and accessory with
   StyleMate's own garment model, **GarmentNet**. Each piece is named ("Olive pique polo", "Black
   Chelsea boots") and its colours are read off the photo. Pieces it isn't sure about wait in "We
   weren't sure" instead of cluttering the closet. "Your closet is ready: N pieces" notifications
   arrive at 10, 25 and 50 pieces (only if notifications are already allowed).
3. **Product photos.** A background studio redraws cutouts as catalogue shots on the phone: jackets,
   shirts, tees, coats, dresses, jeans and all trousers, sneakers, boots, heels and sandals, wide-brim
   hats and beanies. Every render is checked against your real piece; one that doesn't match, has an
   invented logo, or shows a pair of shoes is thrown away and the clean cutout stays. Caps and low
   shoes (loafers, oxfords, boat shoes) keep their cutout. Light-grey coats are named "Silver".
4. **"What should I wear today?"** 5 outfits from your closet for today's weather, occasion and mood,
   with stylist notes that don't repeat. It **learns your taste** on the phone from Wear, Keep, Swap
   and Skip ("Not my style / Not today") and says why ("Picked because you often wear navy with
   grey"); Profile → Your style → Reset clears it. Until the closet can make an outfit, Home says
   what's missing.
5. **Outfit on you (Beta).** Today's Outfit opens on "Pieces"; "On you · BETA" draws the outfit on
   your own full-length photo. Good on straight, arms-down photos; weak on crossed legs and leaning
   poses (known limits in `docs/TRY-ON.md`).
6. **Wardrobe insights** (Profile → Your style): share of the closet worn, most and never worn,
   colour balance, pieces per shelf, look-alikes. Free for now; one switch (`InsightsAvailability`)
   makes it Premium.
7. **Calendar**: "Wear today" logs the outfit; new photos of you prompt "Wore this on Tue?".
8. **iPhone Duo**: both screens, natively. Open flat or half-open, screens split either side of the
   fold and nothing sits on it; an automatic test now fails the build if any control lands on the
   fold. Closed, the cover screen is the normal iPhone layout.
9. **Dark mode** everywhere; **sample photos** let anyone (including Apple's reviewer) try it.
10. **StyleMate Premium.** The first 50 pieces per account are free (samples don't count), then
    monthly or yearly through Apple. The count is per account across all its phones: if two phones go
    over 50 together, the 50 oldest stay free and the rest wait for Premium, the same on every phone.
    Nothing already in the closet is ever removed. Restore, Terms and Privacy are always visible on
    the paywall.

## How good the wardrobe is now (measured on every push)

13 real street photos, 56 hand-labelled garments. The build fails if any number drops more than 3
points below the baseline.

| | Start of the rebuild | Old non-commercial models | Now (GarmentNet, ours) |
|---|---|---|---|
| Garments found | 82% | 95% | 98% |
| Right category | – | 96% | 100% |
| Right product ("polo", "Chelsea boot") | 76% | 89% | 91% |
| Right exact colour | 74% | 91%* | 89% |
| Wrong garments added | 0 | ~1 in 50 | ~1 in 56 |
| Seconds per photo (cloud test Mac) | – | ~120 | ~10 |

\* With the "Silver" colour fix that landed alongside.

## Licences: the launch blocker is cleared

Every bundled model may now be used in a paid app:

| Job | Model | Licence |
|---|---|---|
| Faces | YuNet + SFace (OpenCV Zoo) | MIT, Apache-2.0 |
| Garments | GarmentNet: our own head on Meta's DINOv2, trained on Fashionpedia + COCO | Apache-2.0; data CC BY 4.0 |
| Naming | Marqo-FashionSigLIP | Apache-2.0 |
| Product photos, outfit on you | Stable Diffusion 1.5 (dreamshaper-8) | OpenRAIL-M |

The build refuses to ship if any old non-commercial model comes back, and the old models are deleted
from the build caches. Credits are in Profile → About → Acknowledgements.

Trade-off: the free face models are a step below the old research ones. Ordinary photos match about
as well (~98% at the same strict bar), but sunglasses and tiny faces are harder, so more of your
photos go to "Is this you?" instead of being added automatically. To get the stronger face models
back, a draft email to InsightFace for a commercial licence is in `docs/MODEL-LICENSING.md` §9; the
app switches over with one setting.

## Your actions

TestFlight (`docs/TESTFLIGHT.md`). Done on 6 Nov: the App ID (iCloud container, Sign In with
Apple), the App Store Connect record from 2025, the 4 secrets, and build 112 uploaded. Left:
1. Turn on GitHub Pages (the privacy policy; needed for the App Store listing, not TestFlight).
2. Run the CloudKit schema workflow, then deploy the schema to Production (otherwise backup is off).
3. For Premium: the Paid Apps agreement, bank and tax details, then the subscription group and its
   two plans (§6). Purchases in TestFlight are free. Claude can create the group and plans through
   Apple's API on your go-ahead.
4. For each new build, press **Run workflow** on the TestFlight action.

On your phones (about 20 minutes):
- Profile → About → Diagnostics → **Run benchmark** (plugged in), the Duo hinge check, then **Share
  report**.
- Sign in with Apple for real (the simulator can only use a test stand-in), one test purchase, and
  Delete Account.
- The device-only checks in `docs/LAUNCH-READINESS.md`: overnight background scan, Replace photo,
  the midnight refresh of Today's look, the location prompt ("Precise: Off"), landscape.
- Run **Improve Recognition** once after updating: the new face models rebuild your face set.

Before App Store launch:
- A lawyer's view on face data (BIPA, GDPR Art. 9) and on the face models' research training data.
- Account deletion: the app deletes everything and shows how to stop Apple sign-in in Settings.
  Apple prefers the app to revoke the sign-in itself, which needs a tiny server holding your sign-in
  key. Optional; see `docs/LAUNCH-READINESS.md`.
- Space the submission away from new Duo-game submissions (4.3 risk on the account).
- Prices: suggested £3.99/month and £24.99/year with a 1-week trial; changeable at any time in App
  Store Connect.

## Still open

- **Outfit on you is Beta.** Seams and leftovers of the old outfit show on some photos, crossed legs
  merge, and a translucent sliver can appear beside slim pieces. With GarmentNet more of each first
  draft is repainted; only the polished (checked) image is ever shown.
- **Accessory cutouts** (sunglasses, watch) can carry a little skin until the product photo replaces
  them. A fix limited to eyewear and jewellery is on `feat/garment-cutouts`: every quality number
  matches main, but some sunglasses come out patchy (shaded skin isn't recognised), so it is held,
  not merged. A real fix needs a finer mask than the model's quarter-resolution grid.
- **Fragmented pieces**: a coat crossed by a bag or scarf can come out in parts. Sending heavily
  broken pieces to the product-photo studio would fix it, but changes what gets rendered; your call.
- **Product photos follow the item's name and colour**, so a misnamed item gets the wrong style; heels
  and sandals have templates but no test photo yet.
- **Real-device numbers are still estimates**: scan speed, render time on the Neural Engine, try-on
  time (~20 s per outfit expected), Duo hinge accuracy. The Diagnostics report gives us the real ones.
- After a restore to a new iPhone the "From your photo" original stays on the old phone.
- On the Duo's closed cover screen the system draws the cover camera as a black dot when a
  full-screen card is open; nothing is hidden behind it.
- A longer-trained garment model was tried and did not beat the shipped one; the shipped one stays.

## Proof

`main` at b9d31e4 has everything merged. Full CI 42186482845 (unit, UI light + dark, Release with the
licence gates) and the TestFlight archive check 42186576423 are green. The final iPhone Duo run
42193809511 (after raising its time limit in 83ffa9e) passed all four screenshot tests, including
the automatic "nothing on the fold" check; the frames were reviewed by hand.
