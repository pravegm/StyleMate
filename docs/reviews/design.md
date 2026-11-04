# StyleMate: HIG design review before TestFlight

Sources: the code and the 22 screenshots from e2e run 41871811764 (iPhone 17 Pro simulator, iOS 26, light mode).

**Verdict:** The foundation is sound: semantic tokens, text styles, continuous corners, the closet's zoom transition and the studio backdrop. Three things hold it back:
- The outfit screen, which is the product, looks unfinished.
- The brand is split three ways: a teal app, an Instagram-gradient icon, and blue/purple accents.
- Nothing adapts to large displays. `horizontalSizeClass` is read nowhere.

## 1. Critique

**Home**
- The CTA's sparkle and arrow touch the button edges. `DSPrimaryButton` has no horizontal padding (DesignSystem.swift:247-251), and HomeView.swift:371-378 adds a Spacer.
- Disabled is applied twice, giving about 17% opacity (HomeView.swift:380-382).
- The mood chips are hard-clipped inside the card (623).
- "Alex" is a fixed 40pt and doesn't scale with Dynamic Type (DesignSystem.swift:157).
- `textTertiary` (#AEAEB2, about 2.1:1 on white) is used for real labels (DesignSystem.swift:69; HomeView.swift:613, 649).
- The shelf cards are a fixed 130pt with `.fill`, so the sneakers are cropped (HomeView.swift:508, 524).
- The weather alert's "Yes" uses the `.destructive` role (135).
- The entrance animations ignore Reduce Motion (40-42).

**Wardrobe** is the strongest screen.
- The FAB overlaps the tiles and the glass tab bar (MyWardrobeView.swift:268-285).
- The category icons are wrong: Outerwear `cloud.rain`, Mid-layers `wind`, One-pieces `figure.dance`, Innerwear `bed.double` (385-397).
- The colour swatches are 34pt targets (ClosetComponents.swift:238).

**Item page**
- Edit and Remove appear twice: in the ⋯ menu (ItemDetailSheet.swift:56-60) and as two full-width slabs (180-205). The pink "Not mine — remove" slab is the loudest thing on the page.
- The attribute chips are ragged (157), with odd glyphs: Sleeve = `hand.raised`, Neckline = `person.crop.circle` (ClosetLogic.swift:430-439).

**Today's Outfit** is the weakest screen.
- The flat-lay puts three tops in a row, then the skirt, boots and bag left-aligned, leaving the right half empty (TodayOutfitSheet.swift:476-528).
- The lock and swap badges are 10pt glyphs (about 22pt targets) with no accessibility labels (538-561). The close button is also unlabelled (307).
- The bag is hidden under the action bar.
- There are four equal-weight actions, and their stroke radii don't match (Radius.card on 14pt buttons; 707, 732, 748).
- The swipe stamps read like Tinder: SAVE/SKIP, 48pt black, rotated (404-437).
- The grey "1 of 5" pill repeats the page dots (297-314).
- A leftover cloud-era "Too Many Requests" alert (209-213).

**Outfits calendar**
- A stray "• Today" row (MyOutfitsView.swift:18-28).
- The month grid takes about 60% of the screen.
- Outfits are 72pt thumbnails in an unmarked horizontal scroll, labelled with taxonomy plurals ("Tote Bags", 492-520).
- Images are loaded from disk in `body` (629-636).
- The year wheel runs 1970–2100 (424).

**Composer**
- Nothing shows what is selected.
- The category icons are the same wrong ones as the closet.

**Import**
- The source sheet's icons are blue, teal and pink (StyleMateApp.swift:285, 304), and it uses a fixed `.height(380)` (87).
- The button reads "Add 0 Items" while analysing (AddItemReviewView.swift:267).
- Items are titled with plurals (595).
- Three fragment masks are labelled "Ties": add a fragment-rejection check.

**Profile**
- A dead toggle (ProfileView.swift:172).
- A placeholder "Plan: Free" row (220).
- The version is hard-coded (319).
- Sign Out sits mid-list (287).

**Dark mode** hasn't been tested. The always-light `styleBoard` (DesignSystem.swift:118) may glare.

## 2. Top 15 fixes, in order of impact

1. **Outfit board**
   - Use a centred `Grid`: outer layer over top on the left, bottom on the right, then a centred row with footwear and accessories.
   - Make cells `.frame(maxWidth: .infinity)` and add a contact shadow: `.shadow(.black.opacity(0.1), radius: 6, y: 4)`.
   - Size the board to fit the card. Don't scroll for 6 items or fewer.
2. **Piece controls**
   - Tap a piece to select it. Show a glass capsule under it with **Keep** and **Swap** buttons, each 44×44, labelled "Keep/Swap \(name)".
   - Also add a `.contextMenu` to each piece.
3. **Actions**
   - Two buttons: `Skip` (`.bordered`) and `Wear today` (`.borderedProminent`).
   - Put "Log another day…" and "Add a piece" in a ⋯ menu.
   - Remove the stamps. Tint the card edge while dragging and play a selection haptic at the threshold.
4. **Header**
   - Title "Option 2 of 5". Drop the pill and keep the dots.
   - Put the close `xmark` in the toolbar with a label.
5. **Primary button**
   - Add `.padding(.horizontal, 20)` to `DSPrimaryButton` and delete HomeView.swift:382.
   - The CTA becomes "Style me" with one leading sparkle.
6. **Contrast**
   - Use `textSecondary` for all text. Keep tertiary for glyphs only.
   - Map the text tokens to `.label`, `.secondaryLabel` and `.tertiaryLabel` so Increase Contrast works.
7. **Dynamic Type**
   - `display = .system(.largeTitle, design: .rounded).bold()`.
   - Use `@ScaledMetric` for HomeView.swift:305/325/508 and TodayOutfitSheet.swift:477-479.
8. **Garment icons**
   - Draw a custom SF Symbol set: coat, trousers, dress, handbag.
   - Until then, use `shoe`, `handbag` and `square.stack`. Use text only for neckline and material.
9. **Item page**
   - Keep only the ⋯ menu, plus one plain `role: .destructive` "Remove from Wardrobe" row at the bottom.
   - Show attributes in a two-column label/value `Grid`.
10. **Display names**
    - Use `ClosetText.displayProduct` at MyOutfitsView.swift:517, AddItemReviewView.swift:595, TodayOutfitSheet.swift:958 and ScanReviewView.swift:119.
11. **Outfits tab**
    - Default to a week strip, with a month toggle in the toolbar.
    - Show each day's outfit as a 2×2 cutout collage (160pt), with Edit/Delete in the context menu and swipe actions.
    - Use `DatePicker(.graphical)` instead of the year wheel.
12. **Composer**
    - Pin a "Selected (3)" thumbnail tray above Save.
    - Replace the accordion with shelf tabs over a 3-column grid.
13. **Add flow**
    - Make the add sheet's icons teal monochrome and size it with `.presentationDetents([.medium])`.
    - Replace the FAB with a toolbar `plus` button.
14. **Reduce Motion**
    - Gate HomeView.swift:40-97, MyOutfitsView.swift:403 and OnboardingWelcomeView.swift:203 through `DSMotionEnv.resolve`.
15. **Blockers and cleanup**
    - The Terms and Privacy links are `https://your-terms-url.com` (LoginView.swift:117, 120). This blocks App Review.
    - Remove the rate-limit alert, the dead toggle and the "Free" row.
    - Read the version from the bundle.
    - Rename the weather alert buttons "Style anyway" / "Cancel".

## 3. iPhone Duo and large displays

**Code that breaks on the Duo**
- MainTabView.swift:11-37 uses `.tabItem`. Switch to `Tab(...)` with `.tabViewStyle(.sidebarAdaptable)`.
- `UIScreen.main` at TodayOutfitSheet.swift:605.
- Fixed column grids: FaceReviewView.swift:20, ScanReviewView.swift:25, AddItemFlowView.swift:148 (plus `height: 200` at 166), ProfileView.swift:546, FaceReferenceBuilderView.swift:13.
- Fixed sizes: HomeView.swift:508, OnboardingWelcomeView.swift:60 (500×500), OnboardingPhotoExplanationView.swift:31, OutfitLoadingOverlay.swift:55/86, StyleMateApp.swift:87.
- The iPhone orientation list leaves out upside-down (project.pbxproj:447, 482). Add it so the Duo's square inner display rotates freely.
- There is no `UIRequiresFullScreen`. That is correct: keep it out.
- Fine as they are: the adaptive grids (MyWardrobeView.swift:28, AddItemReviewView.swift:68).

**Layouts**

| Screen | iPhone 17 Pro / cover display | Duo inner (≈square, regular width) |
|---|---|---|
| Shell | Glass tab bar | Sidebar (`sidebarAdaptable`), with shelves nested under Wardrobe |
| Wardrobe | 3 columns | `NavigationSplitView`: grid (min 120, at most 5 columns) next to `ItemDetailView`; filters in the sidebar |
| Today's Outfit | Full-screen card deck | Two panes: the square board (≈55%) next to the stylist note, the Keep/Swap list, "Wear today" and a 5-up strip of options. Present with `.presentationSizing(.page)`, not `fullScreenCover` (HomeView.swift:110) |
| Home | One column | Two columns: greeting and Style me / hero and shelves; text capped at about 560pt wide |
| Outfits | Week strip and list | Month grid next to a 2-column grid of the day's boards |

**Fold rules**
- Use `onHingeChange`. When the status is `.partiallyOpen`:
  - **Book pose (vertical crease):** split 50/50 exactly on the crease, with a 24pt gutter. Never centre the board across the fold.
  - **Tabletop (horizontal crease):** put the board on the top half and the controls on the bottom.
- The Duo blurs one fixed half for about 2 seconds as it starts to fold. Keep text off that half during the fold.
- The cover display is compact, so use the iPhone layout there.

## 4. Icon and first impression

**Icon**
- Problems:
  - The orange-to-purple "Instagram" gradient and the clip-art hanger and star share nothing with the teal app.
  - The PNG has pre-rounded corners with a halo, so iOS masks it twice.
  - The dark and tinted slots are empty (Contents.json:10-30).
- Fix: rebuild it in Icon Composer as a layered Liquid Glass `.icon`:
  - a teal background (#0E5E54 to #127D6F);
  - a single cream hanger or folded-garment "S" with a glass highlight;
  - dark and tinted variants.

**Login**
- Problems:
  - The logo is an SF Symbol in a circle (LoginView.swift:28).
  - The tagline appears three times in different words (40-47).
  - The Google logo is hand-drawn in a `Canvas` (138-182), which breaks Google's brand rules.
- Fix:
  - Background: a full-bleed, slowly drifting flat-lay of real garment renders.
  - Wordmark in SF Pro Display Semibold.
  - One line: "Your closet, styled every morning. Entirely on your iPhone."
  - The official Google button.

**Welcome**
- Problems:
  - The fan of SF Symbols on cards (OnboardingWelcomeView.swift:25-31) looks like a template.
  - The "AI-powered" and "iCloud sync" pills (114, 130) undercut the on-device message.
- Fix: a 3-step demo using the real cutout renderer (photo to cutout, cutout to closet, closet to board), headlined "Get dressed in one tap."
