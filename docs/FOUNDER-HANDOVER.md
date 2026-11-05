# StyleMate: where things stand (founder handover)

Plain-language summary of the unsupervised rebuild (4–5 Nov 2026). Technical detail lives in
`docs/PROJECT-LOG.md`, the reviews in `docs/reviews/`, and launch/legal detail in
`docs/LAUNCH-READINESS.md` and `docs/MODEL-LICENSING.md`.

## What the app does now

Everything runs **on the iPhone**. No API keys, no servers, and no login. The only thing that
leaves the phone is the user's own iCloud backup.

1. **First run (about 1 minute to something useful)**: welcome, a 3-frame selfie, photo access,
   then "Find yourself": the app groups the faces in your library and asks "Is this you?". You tap
   your face once.
2. **Digital wardrobe, built automatically**: the scan looks for photos of *you* (face matching:
   SCRFD + AdaFace), separates you from other people, and cuts out every garment and accessory
   (FASHN human parser + Fashionpedia labeler, hidden parts filled in). Each piece is named by
   Marqo-FashionSigLIP ("Olive pique polo", "Black Chelsea boots") and its colours are read off the
   photo. It starts with the "First 40": your 40 best recent outfit photos, so the closet fills
   within a minute. Then it works through the rest in the background. When it isn't sure, a piece
   waits behind a "We weren't sure about 2 items" card instead of cluttering the closet.
3. **Lifelike product photos**: a background "studio" queue redraws each cutout as a clean
   product shot, using an on-device image model (Stable Diffusion 1.5, converted for Apple's Neural
   Engine). Every render is checked against your real garment, and colours are matched back to it;
   a render that doesn't look like your item is thrown away and the cutout stays. "From your photo"
   on the item page always shows the original. *Status: jackets and shirts look like real product
   photos; bottoms are still being tuned (see "Still open").*
4. **"What should I wear today?"**: 5 complete outfits from your closet, using today's weather
   (location rounded to roughly 1 km), the occasion, your mood (8 moods) and any typed request
   ("something for an outdoor wedding"). Every piece can be swapped or locked, and options can be
   skipped. An optional 7:30 am notification shows the morning's look with a picture.
5. **Calendar**: "Wear today" logs the outfit to the date. New photos of you wearing closet pieces
   prompt "Wore this on Tue? Log it".
6. **iPhone Duo**: the app runs natively on both screens. Open flat, the main screens split at the
   fold (closet | item, outfit board | pieces, calendar | day). Nothing sits across the crease.
   Half-open in book pose, the split follows the hinge. On the closed cover screen it's the normal
   iPhone layout. Your place is kept when you fold and unfold.
7. **Try with sample photos**: 6 bundled sample photos let anyone (including Apple's reviewer)
   see a full wardrobe without their own photos. Samples are removed with one tap.

How it was checked: every change runs through GitHub Actions on a Mac. Each push runs the full unit-test
suite, including real-model extraction on 13 real photos, face matching, outfit engine,
reliability and the studio render with a parity check against the reference implementation.
UI tests then walk every flow on an iPhone simulator, and a dedicated workflow screenshots every
screen on an iPhone Duo simulator, flat, half-open and closed.

## Getting it on your phones

Follow `docs/TESTFLIGHT.md` (about 15 minutes, once). In short:
1. Register the bundle ID `com.stylemates.StyleMate` with iCloud, and create the App Store
   Connect record.
2. Add the 4 repository secrets you already use for the Duo games.
3. Turn on GitHub Pages (publishes the privacy policy).
4. Press **Run workflow** on the TestFlight action. Install from TestFlight on the iPhone 17 Pro
   and the Duo.

Install on Wi-Fi: the on-device models make the app large.

**What to try first**: grant photo access to your full library (not "Selected photos") and let
the first scan run with the phone unlocked for a few minutes. Studio photos keep arriving in the
background, and fastest when the phone is charging.

## Decisions only you can make (before App Store launch, not before TestFlight)

1. **Model licences: the one real launch blocker.** Three of the bundled models are licensed for
   non-commercial use only: the face detector (InsightFace SCRFD), and both garment segmenters
   (NVIDIA SegFormer licence). The face recogniser (AdaFace) was trained on research-only data.
   TestFlight testing is fine; selling the app is not. Options, in `docs/MODEL-LICENSING.md` §5:
   email InsightFace for a commercial licence (address in the doc), retrain the garment segmenter
   on a commercial-friendly backbone (about one engineer-week plus ~$50–300 of GPU time), or use the
   weaker free face models. Have a lawyer look at face data rules (BIPA, GDPR Art. 9) before launch.
2. **Which developer account.** Apple flagged several Duo games from the same account for 4.3
   "spam" recently. Space StyleMate's submission away from any new game submission.
3. **App Store listing**: a draft name, subtitle, keywords, description and screenshot plan are in
   `docs/APP-STORE-LISTING.md`.

## Still open (being worked on, or next)

- Studio renders for trousers and skirts: the quality gate correctly rejects bad renders today,
  so these still show the cutout more often than tops do.
- Real-device checks the simulator can't do: scan speed on a 10,000-photo library, render time on
  the Neural Engine, Duo hinge accuracy and the seated pose, the morning notification and
  background refresh.
- New iPhone restore: done. A fresh install signed into the same iCloud account restores the
  wardrobe (items and photos; outfit history and face data stay on the old phone).
- iCloud schema: TestFlight builds use Apple's "Production" iCloud environment, which needs the
  app's data layout uploaded once (5 minutes, `docs/TESTFLIGHT.md` §5). Until then everything works,
  but the backup doesn't.
