# StyleMate

StyleMate is your AI-powered fashion wardrobe and stylist app for iOS, built with SwiftUI.

## Features

- **AI-Powered Outfit Suggestions:**
  - Uses Google Gemini to suggest outfits based on your wardrobe, following real fashion rules, color theory, and item compatibility.
  - Gemini is strictly prompted to use only the exact product, category, and pattern strings from your provided lists—no synonyms, no singular/plural variants, no typos.
  - Robust product detection and canonicalization: all detected product names are mapped to the exact, canonical product in your wardrobe list, handling singular/plural/case/typos. Picker selection is always valid and never defaults to an unrelated product.

- **Multi-Image Add Flow:**
  - Select multiple images from your gallery at once.
  - All images are analyzed in parallel in the background.
  - Review each image, edit detected details, and choose to save or remove each item individually.
  - "Add All" button lets you instantly add all analyzed items without reviewing each one.
  - Flexible: Save any, all, or none of the batch.

- **Remove Individual Detected Items:**
  - While reviewing detected items (in both single and batch add flows), you can remove any specific item you don't want to add to your wardrobe, before saving.
  - Only the "Remove Item" button deletes an item—tapping elsewhere on the item does nothing, for a safer and more intuitive review experience.

- **Batch Review & Summary:**
  - Swipe between images in a modern, card-based UI.
  - See a **celebratory summary screen** after adding, with confetti and a colorful background—making adding to your wardrobe feel joyful!
  - Works for both single and multi-image add, from camera or gallery.

- **Wardrobe Management:**
  - Browse your wardrobe by category.
  - Tap any item to see a full-screen image preview.
  - Delete items with swipe-to-delete and Edit mode.
  - **Empty Wardrobe** deletes all items and their images from storage.

- **Modern SwiftUI Architecture:**
  - Uses NavigationStack, TabView, and best practices for state management.
  - Accessibility labels and large tap targets for inclusive design.

- **Camera & Gallery Support:**
  - Add items via camera or gallery, with a tip for multi-select.

- **Accurate Item Cropping:**
  - After AI detection, each wardrobe item's image is automatically cropped to show only the detected item (e.g. just the shirt, jeans, or shoes from a group photo).
  - The cropping uses the detected bounding box, but always ensures a minimum crop size (50% of the image) for clarity and consistency, so even small or imprecise detections are always visible.
  - Cropping is performed during analysis for maximum efficiency.

- **Efficient Image Storage:**
  - All images and cropped images are stored in the app's file system (`wardrobe_images` folder), not in UserDefaults.
  - Deleting items or emptying the wardrobe also deletes their images from storage.

- **Performance Optimizations:**
  - Analysis and cropping are parallelized and happen up front, so saving is instant—even for large batches.
  - The UI is responsive and robust, with no crashes or delays for large image sets.

- **Up-to-date Product List:**
  - 'Coats' has been removed from Tops. 'Overcoats' remain in Seasonal/Layering. 'Shackets' have been added to Tops.

## New: AI Outfit Shuffle & Celebratory UI

- **Shuffle Feature:**
  - When you tap "Get Today's Outfit", Gemini suggests a batch of 5 different, fashion-savvy outfits.
  - Tap **Shuffle** to cycle through the batch—never see the same outfit twice in a row!
  - When you reach the end, a friendly popup lets you cycle through the batch again.

- **Today's Outfit View:**
  - Visually exciting, with a colorful gradient background, random celebratory emoji, and a positive, randomized subheading.
  - Suggested items are shown in a center-aligned, uniform grid—no awkward spacing, always balanced.
  - Each item is a beautiful card; tap to see a zoomable, full-screen preview.
  - **Shuffle** and **Love it!** buttons are always fixed at the bottom for easy access.
  - The entire experience is designed to make users feel happy, confident, and excited about their look!

## Getting Started

1. Clone the repo and open `StyleMate.xcodeproj` in Xcode.
2. Build and run on iOS 16+.
3. Sign up or use as guest to start adding wardrobe items.

## Project Structure

- `Models/` — Data models (Category, Pattern, WardrobeItem, etc.)
- `ViewModels/` — App state and business logic.
- `Views/` — All SwiftUI screens and reusable components.
    - `TodayOutfitSheet.swift` — The celebratory sheet for outfit suggestions (split from HomeView for modularity and performance).
    - `WardrobeSummaryWidget.swift` — The wardrobe summary widget (split from HomeView for modularity and performance).
    - (Other files: HomeView, MyWardrobeView, AddNewItemView, etc.)
- `Services/` — AI integration and persistence logic.
- `StyleMateTests/` — Unit tests.
- `StyleMateUITests/` — UI tests.

### Modularization & Performance
- Large SwiftUI files have been split into smaller, focused components (e.g., TodayOutfitSheet, WardrobeSummaryWidget) for faster builds and easier maintenance.
- The `Views/` directory now contains both full screens and reusable SwiftUI components.

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.

## License

[MIT](LICENSE)

---

**StyleMate** — Your AI-powered, privacy-first fashion assistant for iOS. 