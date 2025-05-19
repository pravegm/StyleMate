# StyleMate

StyleMate is your AI-powered fashion stylist, helping you organize your wardrobe and get daily outfit suggestions with a magical, modern UI.

## ✨ Magical Home Screen

The StyleMate box at the top of the home screen now features:
- **Animated Gradient Border:** A lively, magical border that gently animates around the box.
- **Animated Sparkles:** Sparkle (✨) effects in the corners for a premium, magical feel.
- **Soft Glow:** The shirt icon is highlighted with a soft, animated glow.
- **Animated Subheading:** The subheading fades and slides in with a beautiful gradient color.

All magical effects are implemented in a clean, modular way in `HomeView.swift`:
- `MagicalGradientBorder` for the animated border
- `MagicalSparkles` for the sparkles
- `MagicalSubheading` for the animated subheading

### Customization
- You can easily tweak the colors, animation speeds, or sparkle positions by editing the relevant SwiftUI views in `HomeView.swift`.
- All magical effects are self-contained and do not affect other app functionality.

## Features

- **Comprehensive Clothing Classification:**
  - **Categories:**
    - Tops (T-Shirts, Shirts, Blouses, Tank Tops, Tube Tops, Camisoles, Crop Tops, Off-Shoulder Tops, Bodysuits, Graphic Tees, Mesh Tops, Turtlenecks, Polo T-Shirts)
    - Bottoms (Jeans, Trousers, Leggings, Joggers, Cargo Pants, Shorts, Skirts, Skorts, Palazzo Pants)
    - Mid-Layers (Hoodies, Sweatshirts, Sweaters, Cardigans, Pullovers, Fleece Jackets, Vests, Shrugs, Gilets)
    - Outerwear (Jackets, Coats, Puffer Jackets, Trench Coats, Blazers, Overcoats, Raincoats)
    - One-Pieces (Dresses, Jumpsuits, Rompers, Playsuits, Dungarees, Overalls)
    - Footwear (Sneakers, Boots, Heels, Flats, Sandals, Slippers, Loafers, Formal shoes)
    - Accessories (Hats, Scarves, Gloves, Belts, Handbags, Jewelry, Watches, Sunglasses, Hair Accessories, Ties, Bowties)
    - Innerwear (Bras, Underwear, Boxers, Thongs, Socks, Thermal Wear, Shapewear, Lingerie)
    - Activewear (Sports Bras, Active Leggings, Athletic Tops, Track Pants, Athletic Shorts, Active Jackets, Compression Wear, Swimwear, Tennis Dresses)
    - Ethnic Wear (Kurta, Kurti, Sherwani, Nehru Jacket, Dupatta, Saree, Blouse (saree), Lehenga, Choli, Salwar, Patiala Pants, Anarkali, Angrakha, Dhoti, Lungis, Mundu, Jodhpuri Suit)

- **Add New Items:** Add clothing items to your wardrobe by selecting or capturing images.
- **Automatic detection of clothing category, product, color, and pattern using Gemini AI**
- **Robust error handling for Gemini API failures**
- **Automatic retries with exponential backoff for rate limiting (HTTP 429)**
- **User-friendly error messages for persistent failures (e.g., if Gemini cannot analyze an image after 3 attempts)**
- **Edit Items:** Swipe left on any item in a category to reveal Edit and Delete actions. Edit lets you change the category, product, color(s), pattern, and brand for any item (the image remains unchanged).
- **Delete Items:** Swipe left and tap Delete, or use multi-select delete (see below).
- **Category Organization:** Items are grouped by category (e.g., Tops, Bottoms, Footwear, etc.).
- **Product Grouping & Sections:** Within each category, items are further grouped by product (e.g., Shirts, Sweaters, Jeans). Each product group appears as a collapsible/expandable section. All sections are expanded by default when you open a category. Tap the section header to collapse or expand.
- **Multi-Select Delete:** Tap the Edit button in the top right of a category detail view to enter multi-select mode. Checkboxes appear next to each item. Select multiple items, then tap the red Delete button to remove them all at once. A Cancel button lets you exit edit mode without deleting. While in edit mode, swipe actions and item preview are disabled for clarity.
- **Image Preview:** Tap an item to preview its image in full screen (when not in edit mode).
- **Profile & Settings:** Access your profile and app settings from the main wardrobe view.

## Usage

1. **Add Items:** Use the add button to add new clothing items to your wardrobe.
2. **Browse by Category:** Tap a category tile to see all items in that category, grouped by product.
3. **Edit or Delete:** Swipe left on an item to edit or delete it. Or tap Edit to select and delete multiple items.
4. **Collapse/Expand Sections:** Tap a product section header to collapse or expand that group.
5. **Multi-Select Delete:** In edit mode, select items with checkboxes and tap Delete to remove them.
6. **Automatic detection of clothing category, product, color, and pattern using Gemini AI**
7. **Automatic retries with exponential backoff for rate limiting (HTTP 429)**
8. **User-friendly error messages for persistent failures (e.g., if Gemini cannot analyze an image after 3 attempts)**

## Requirements
- iOS 16+
- Xcode 14+

---

For more details, see the in-app help or contact the developer.

## AI-Powered Outfit Suggestions:
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

## Duplicate Detection & Footwear Handling

- **Footwear Deduplication:** When adding items from images (single or batch), if multiple footwear items are detected in a single image, only one will be kept and shown to the user. This ensures that pairs of shoes are not added as separate items.
- **Wardrobe Duplicate Warning:** If an item being added matches an existing item in your wardrobe (same category, product, pattern, brand, and colors), a warning will appear next to that item. You must acknowledge this warning before you can save or add the item(s) to your wardrobe.

## Multi-Image Add Flow Dot Indicators

When adding multiple images to your wardrobe, you will see a row of dots at the top of the review screen. These dots help you track the review status of each image:

- **Green dot:** The fit for this image has been saved.
- **Red dot:** The fit for this image has been rejected.
- **Yellow dot:** There is at least one item in this image that may be a duplicate of something already in your wardrobe. Review the warning(s) and acknowledge them to proceed.
- **Grey dot:** The image is pending review, or all duplicate warnings have been acknowledged but the image has not yet been saved or rejected.
- The dot for the currently viewed image is larger and outlined, so you always know which image you are reviewing.

This feature ensures you always know which images need your attention and which have already been reviewed or require action.

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