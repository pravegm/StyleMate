# StyleMate pre-TestFlight product review (4 Nov 2026)

**Verdict.** The concept is right: a private closet built automatically from the camera roll, which no one ships on iOS. The first run is not ready. Users hit a login wall, 7 onboarding steps and a 420 MB download, then watch a closet fill slowly with visible errors. The demo hides this, because the seeded closet is clean vector art and real imports are rough cutouts.

## 1. Value as experienced

**First 10 minutes (the cliff)**
- **Friction before value:** Sign in with Apple/Google (`StyleMateApp:66`), then welcome, about you, explainer, selfie, permission, reference builder, scan range and a coach-mark tour.
- **Speed:** one photo took about 60 s at "Finding clothes…" on CI's M-series simulator. Older phones add Core ML first-load compiles, so items trickle in.
- **The first scan finds almost nothing if:**
  - The user grants Limited Photos access.
  - The library is mostly mirror selfies. The phone hides the face, `FaceMatchingService` returns `.noFaces` and the photo is skipped, yet these are *the* outfit photos.
  - The user is usually the one behind the camera.
  - The user wears sunglasses or is in profile. Those photos go to "Is this you?", not the closet.
- **Shoes:** half-body shots leave the footwear shelf thin. Home copy still says "You need at least a top, bottom, and shoes" (`HomeView:125`).
- **Quality (the real CI import):**
  - The coat cutout carries a patch of hair.
  - A "Ties" false positive made of hair and sunglasses fragments is *pre-selected*.
  - The boots are lumpy, and the grey coat is called "Silver".

**First week**
- **Win:** "Today's Outfit". The weather-aware notes and fast lock/swap work.
- **Repetition:** with fewer than 20 items, all 5 looks reuse the same 2 bottoms and 1 pair of shoes. It feels repetitive by day 3.
- **The card is a list, not a look:**
  - Items sit in one column and the right half is empty.
  - The bag falls below the fold.
  - "Save" and the calendar icon are ambiguous.
  - The occasion was "Everyday Casual", but the note says "Built to own the room".
  - VoiceOver reads every swap button as "Syncing".
- **No pull back:** there is no notification and no widget.

**First month**
- The calendar fills only if the user taps Save daily, and most won't.
- There are no insights.
- Auto-importing new photos, the core advantage, happens invisibly.

## 2. Critical path to the "aha" moment

**The aha:** at least 15 real, recognisable items within 3 minutes of granting permission.

**Blockers:**
1. The login wall (also an App Review 5.1.1(v) risk).
2. 7 steps before the scan starts.
3. The 12-month scan runs newest-first with no prioritisation, so the first minutes go on non-outfit photos.
4. Faceless outfit photos are dropped.
5. Pre-selected fragments erode trust.
6. A 420 MB download sits over the cellular prompt; the SD studio branch would add about 1 GB more.

## 3. Top 10 changes (impact × effort)

1. **Remove the login (impact H, effort S).**
   - Drop Google Sign-In, the "about you" step (ask in Profile later) and the tour.
   - Target: 4 screens to scanning: welcome/privacy, selfie, permission, scanning.
2. **"First 40" fast scan (H, M).**
   - Rank the last 90 days by Vision full-body person detection; exclude screenshots and documents.
   - Extract the top 40 first, with a live counter: "11 items found in 23 photos".
   - Hand off to Home at 8 or more items, or after 90 s. The rest continues in the existing banner.
3. **Auto-deselect fragments (H, S).**
   - In `AddItemReviewView` and scan intake, deselect masks that split into several pieces, items with a low quality score, and low-confidence tie/belt/jewelry.
   - Copy: "We weren't sure about 1 item — tap to add."
4. **Faceless outfit photos (H, M–L).**
   - Covers one-person photos with no face whose outfit embedding matches 2 or more closet items, and mirror selfies (phone in hand).
   - Route them to "Is this you?" as "Your outfit?". This unlocks OOTD shots.
5. **Morning notification plus widget (H, M).**
   - A local `UNCalendarNotificationTrigger` at 7:30, editable: "9° and cloudy — your camel coat look is ready", with a thumbnail. No server needed.
   - A Home/Lock Screen widget that opens `TodayOutfitSheet`.
   - Ask for notification permission after the first saved outfit.
6. **Auto-log from photos (H, M; the unique loop).**
   - When the incremental scan finds a new photo of the user, match its garments with `DuplicateDetector`.
   - Prompt: "Wore this Tue? Camel coat + navy cardigan — Log it".
   - The calendar fills itself and the recency scoring gets real data. Nobody else can do this.
7. **Thin-wardrobe mode (M, S).**
   - Under 20 items, or under 3 bottoms/shoes: show 3 looks.
   - Add a gap card: "Add 2 pairs of shoes → 4× more outfits", which opens the camera.
   - Fix the shoes copy; the engine needs only a top and bottom.
8. **Outfit card redesign (M, S–M).**
   - A composed flat-lay with no scrolling: layers and top on the left, bottom on the right, shoes and bag below.
   - One primary button, "Wear this today" (logs it). Move the date to a long-press.
   - Labels: "Keep navy cardigan" / "Swap navy cardigan".
9. **Sunday "Wardrobe Wrapped" (M, S).**
   - Most worn, 5 items unworn for 60 days (each with "Style it"), colour split.
   - Cost-per-wear in 1.1.
10. **"Try with sample photos" (M, S).**
    - A CC0 library on the welcome screen and as the empty-state fallback. It is also App Review blocker 5.

**Cut or defer**
- Cut Google Sign-In, the "Plan: Free" row and the gender/age step.
- Cut moods from 8 to 4. Keep Confident, Cozy, Polished and Relaxed.
- Make it iPhone-only.
- Defer the SD studio renders to 1.1. They are off `main`, add size and heat on older phones, and clean cutouts come first.

## 4. Positioning, pitch, pricing, metrics

**Competitors**

| App | Price | Notes |
|---|---|---|
| Google Photos Wardrobe | Free (cloud) | Eligible accounts in the US, India and Brazil. Renders and try-on. Import is one-time: adding items means a reset. No daily stylist. |
| Whering | Free | Manual, no weather. |
| Acloset | $3.99/mo | Free tier capped at 100 items, with ads. |
| Indyx | $74.99/yr | No AI outfits. |
| Stylebook | $4.99 once | Manual. |
| Cladwell | $7.99/mo | Free tier is 1 outfit a day. |
| Alta | Free | Affiliate-funded. |

All except Google need manual photographing; users complain about "days" of setup.

**Own:** an automatic, continuously updating closet, a daily stylist and a self-filling diary, all private. Avoid the try-on fight.

**Pitch:** "Your camera roll already knows your wardrobe. StyleMate builds it and dresses you every morning, without a single photo leaving your iPhone."

**Pricing**
- No upfront price: face matching can't be proven in screenshots.
- Zero marginal cost lets it undercut the subscriptions.
- **Free:** unlimited scan and closet, 1 look a day, calendar.
- **Plus:** 5 looks, lock/swap, occasions, auto-log and Wrapped. $19.99/yr or **$39.99 lifetime**, with a 7-day trial; ₹499/yr in India.
- Run TestFlight fully unlocked.
- Submit from an account separate from the Duo games (4.3 exposure).

**TestFlight metrics**

"Data Not Collected" rules out an analytics SDK. Add an opt-in "Share diagnostics" JSON export.

1. **Time to 15 kept items:** median, and the share of users under 10 minutes. Target above 60%.
2. **Extraction precision:** items still in the closet after 7 days (not deleted, "Not mine" or deselected). Target 85% or more.
3. **D7 habit:** opens of Today's Outfit on 3 or more of the first 7 days, plus the logging rate.

Sources: 9to5Google, Android Authority, getwardrobe.com/compare (self-reported pricing), Good On You, r/capsulewardrobe.
