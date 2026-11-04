# StyleMate App Store listing (draft, 2026-11-04)

**The hook is on-device privacy.** The camera roll already *is* the wardrobe, and StyleMate
builds it without sending a single photo to a server.

**Every claim below must be true in the build that ships.** Check these before you paste:

- **Gemini is gone.** Branch `feat/outfit-engine` must be merged. While it is not, "no AI
  servers" is false and must be cut.
- **Google Sign-In is removed.** That is what makes the privacy label "Data Not Collected".
  If Google Sign-In stays, remove "Data Not Collected" from the copy (see LAUNCH-READINESS.md §7).
- **Use the final face model's real behaviour.** Do not promise accuracy numbers.

Other rules:

- Guideline 2.3.7 / 5.2: no competitor or third-party brand names. Do not mention "Google
  Photos" or "Pinterest" in any field, including keywords.

## Name (≤ 30 characters)

| Option | Length | Note |
|---|---|---|
| **StyleMate: AI Closet & Outfits** | 30 | Recommended. Brand + two top search terms. |
| StyleMate – Private Wardrobe | 28 | Leans on the hook, but "private" is a weak search term. |

The name must be unique on the App Store. Check that "StyleMate" is free when creating the
App Store Connect record; fall back to "StyleMate Closet" if it is taken.

## Subtitle (≤ 30 characters)

| Option | Length |
|---|---|
| **Your closet, built from photos** | 30 |
| Private Outfit Planner & Diary | 30 |

## Keywords (≤ 100 bytes, comma-separated, no spaces after commas)

```
wardrobe,planner,what to wear,clothes,fashion,stylist,ootd,organizer,calendar,weather,capsule,dress
```

The line above is 99 bytes.

- Words already in the name or subtitle are indexed automatically, so they are not repeated here: StyleMate, AI, closet, outfits, photos.
- Revisit after 2–4 weeks of App Store Connect search data.

## Promotional text (≤ 170 characters, editable without review)

> Your camera roll already holds your wardrobe. StyleMate finds the clothes you wear, builds your closet and plans outfits - all on your iPhone, never on our servers.

That is 164 characters.

## Description (≤ 4,000 characters)

> **Your wardrobe is already in your camera roll. StyleMate finds it — privately, on your iPhone.**
>
> Take one selfie. StyleMate recognises you in your photos, picks out the clothes you're actually wearing, and turns them into a clean, organised digital closet. No photographing every item on the bed. No typing in brands. No uploading your life to someone's server.
>
> **BUILT FROM YOUR PHOTOS**
> • Auto-scan your library: start with last month, go back as far as you like
> • Finds you in group shots and keeps only *your* outfits, never your friends'
> • "Is this you?" lets you confirm unsure photos so it learns your face better
> • Every piece becomes a clean cutout: tops, layers, jackets, dresses, shoes, bags, sunglasses and more
> • Detects type, colours, pattern, material, fit, sleeves and neckline automatically
> • Spots duplicates and keeps the best photo of each item
> • Add anything by camera or from your gallery, too
>
> **WHAT SHOULD I WEAR TODAY?**
> • Five outfit ideas from your own clothes, matched to the day, your mood and the weather
> • Lock the pieces you love and swap the rest
> • Pick an occasion (everyday, work, date night, party, travel and more) or describe it in your own words
>
> **YOUR OUTFIT DIARY**
> • Log what you wore on a calendar
> • See your history and rediscover forgotten favourites
>
> **PRIVATE BY DESIGN**
> • Face recognition, clothing detection and outfit ideas all run on your iPhone
> • Your photos, your selfie and your face data are never sent to us or to any AI service
> • Your wardrobe syncs only to your own private iCloud, so we can't see it
> • No ads. No tracking. No account to create.
> • Delete everything at any time from Profile
>
> StyleMate works best with photos that show your outfit. Scans run while the app is open; you can pause and resume anytime.

Sentence-level dependencies:

- "No account to create" assumes the login wall is removed (LAUNCH-READINESS.md blocker 4).
- "Five outfit ideas … mood" matches `feat/outfit-engine`. Re-check it when that branch merges.

## What's New (1.0)

> The first release of StyleMate: your private, on-device wardrobe and outfit planner.

## Category, rating, URLs

- **Primary category:** Lifestyle. **Secondary:** Photo & Video.
- **Age rating:** no user-generated content sharing, no web views, no mature content, so expect the lowest rating. Answer the questionnaire honestly about camera and photo use.
- **Privacy policy URL** and **Support URL** are required. See LAUNCH-READINESS.md §6.
- **App Privacy label:** "Data Not Collected". This holds only when the conditions in LAUNCH-READINESS.md §7 are met.

## Screenshot plan

**Required sizes:**

- iPhone 6.9" (1320 × 2868 portrait, or 1290 × 2796). App Store Connect scales these down for smaller iPhones.
- iPad 13" (2064 × 2752) **only if** the app stays universal (`TARGETED_DEVICE_FAMILY = "1,2"`). The recommendation is iPhone-only for 1.0.

**Rules:**

- Up to 10 screenshots; the first three carry the page.
- Use CC0 or model-released photos only. **Never** use a real person's library without a written release.
- The founder's own photos are fine with consent.
- No other brands' logos visible on the clothing.

| # | Screen | Caption (short, big type) | Notes |
|---|---|---|---|
| 1 | Wardrobe grid, full of cutouts | **Your closet, built from your photos** | The money shot: lots of clean cutouts, varied categories. |
| 2 | Scan in progress: a photo with the user found and garments outlined, plus the progress banner | **It finds you. Then your clothes.** | Show a group photo where only the user's outfit is extracted. |
| 3 | Privacy panel (a designed slide over the onboarding "on-device" screen) | **Private by design. Nothing leaves your iPhone.** | Lock icon, "No ads · No tracking · Your own iCloud". Keep it literally true (see the rules at the top of this doc). |
| 4 | "Today's Outfit" card stack with weather chip | **5 outfit ideas for today's weather** | Real weather card visible. |
| 5 | Lock + swap interaction | **Keep what you love. Swap the rest.** | Mid-swap state with one piece locked. |
| 6 | Item detail (cutout + attributes) | **Colour, fabric, fit, detected for you** | Attributes visible: pattern, material, sleeves. |
| 7 | "Is this you?" review | **Not sure? Just tap "That's me".** | Builds trust in the face feature. |
| 8 | Calendar of logged outfits | **Your outfit diary** | A full month of logged looks. |
| 9 | Add sheet (camera / gallery / auto-scan) | **Add anything in seconds** | Optional. |

**App preview video** (optional, 15–30 s, recommended): scan → wardrobe fills → today's outfit → swap → log. Record it on a real device from the same CC0 or released library.

**Production:**

- Produce the screenshots from a seeded simulator run, the same CC0 fixtures CI uses, extended. The CI already uploads cutouts as the `ci-report` artifact, so a screenshot UI test can follow the same pattern.
- Frame them in Figma: background tint from the design system, captions in SF Pro Display Bold.
