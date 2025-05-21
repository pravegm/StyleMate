# StyleMate

StyleMate is your AI-powered fashion stylist, helping you organize your wardrobe and get daily outfit suggestions with a magical, modern UI.

## ✨ Magical Home Screen

The StyleMate box at the top of the home screen now features:
- **Animated Gradient Border:** A lively, magical border that gently animates around the box.
- **Animated Sparkles:** Sparkle (✨) effects in the corners for a premium, magical feel.
- **Soft Glow:** The shirt icon is highlighted with a soft, animated glow.
- **Animated Subheading:** The subheading fades and slides in with a beautiful gradient color.

### 🌤️ Live Weather Card

- **Current Weather:** See today's weather for your location, including temperature, weather icon, and a short description.
- **City Name:** The card displays your current city using reverse geocoding.
- **Celsius/Fahrenheit Toggle:** Instantly switch between °C and °F with a modern, responsive toggle.
- **Location Permissions:** The app requests location access only as needed, and provides clear prompts if permission is denied.
- **Modern 4-Column Layout:** Weather icon, temperature, description, and unit toggle are neatly arranged for a compact, visually balanced look.

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

## My Outfits Page Features

- **Outfit Calendar:** View all your outfits mapped to specific dates in a beautiful, interactive calendar. Dates with outfits are highlighted for easy discovery.
- **Today's Outfits Card:** Instantly see all outfits mapped to today, with a modern card UI and vertical list of items.
- **Add Outfit:** Add a new outfit to any date using a visually rich, multi-step sheet. Select up to 10 items from your wardrobe, grouped by category and product, with category and product cards that expand/collapse for easy navigation.
- **Edit Outfit:** Edit any existing outfit. The add/edit sheet is pre-filled with the outfit's items and notes for quick changes.
- **Delete Outfit:** Remove any outfit with a single tap, with a confirmation alert to prevent accidental deletion.
- **Notes:** Add optional notes to any outfit (e.g., "Wore this to a wedding"). Notes are always visible and editable.
- **Item Grouping:** Items are grouped by category and product for fast selection. Product rows are fully clickable for expansion.
- **Scrollable Item Cards:** Each outfit displays its items as horizontally scrollable cards, with a right-facing chevron indicator if there are more than two items.
- **Full Item Names:** Item names are always fully visible, wrapping to multiple lines if needed, and are consistent with the wardrobe view.
- **Image Preview:** Tap any item image to see a full-screen, zoomable preview.
- **Modern UI/UX:** Gradient backgrounds, accent colors, and sticky save/cancel bars for a delightful, modern experience.
- **Performance Optimized:** All views are modularized for fast loading and smooth scrolling, even with a large wardrobe.
- **Accessibility:** Large tap targets, clear labels, and VoiceOver support for all interactive elements.

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

- **Save Suggested Outfits:**
  - After receiving a Gemini-suggested outfit, tap the **"Save this outfit"** button to add it to your My Outfits calendar.
  - Choose to save the outfit to today or select any other date using a date picker.
  - A green "Saved" overlay confirms the action, and the outfit instantly appears in your My Outfits page for the chosen date.
  - This makes it easy to keep track of AI-suggested looks and revisit them anytime.

- **Multi-Image Add Flow:**
  - Select multiple images from your gallery at once.
  - All images are analyzed in parallel in the background.
  - Review each image, edit detected details, and choose to save or remove each item individually.
  - "Add All" button lets you instantly add all analyzed items without reviewing each one.
  - Flexible: Save any, all, or none of the batch.
  - **Reanalyze Image:** For any image in the batch, you can tap the **"Reanalyze Image"** button to send just that image back to Gemini for a fresh analysis. This is useful if you accidentally delete a detected item and want to restore it, or if you want to retry detection. The progress overlay appears for that image while analyzing, and only the selected image's detected items are updated—other images/items remain unchanged.

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

## Weather-Aware Outfit Suggestions

- The app uses real-time weather data from Open-Meteo to help Gemini suggest seasonally/logically appropriate outfits (e.g., no coats in summer, no shorts in winter).
- If weather data is available, it is included as context for the AI stylist.
- If weather is still loading or unavailable, the "Get Today's Outfit" button remains enabled, but when pressed, the user is shown a warning popup:
  - If weather is still loading: "Weather is still loading. Outfit suggestions may not be seasonally appropriate. Continue?"
  - If weather is unavailable: "Weather information could not be retrieved. Outfit suggestions may not be seasonally appropriate. Would you like to continue?"
- The user can choose to proceed (outfit will be suggested without weather context) or cancel.
- This ensures the user is always informed and in control, and that outfit suggestions are as logical as possible given the available data.

## Style Preference Feature

- **Personalized Style Preferences:**
  - Users can select their preferred fashion styles (e.g., Everyday Casual, Formal Wear, Date Night, Sports / Active, Party, Business Casual, Loungewear, Vacation, Ethnic Wear, Streetwear) from a list in their profile.
  - You can edit your style preferences at any time by tapping 'Edit Style Preferences' in your profile.
  - The app uses your selected styles to tailor outfit suggestions, ensuring recommendations match your taste and lifestyle.
  - Gemini AI will prioritize your preferred styles when generating daily outfit suggestions, but you can also request outfits for any specific style from the home screen.
  - All style preference logic is privacy-first and stored locally on your device.

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

## Data Model

### WardrobeItem
Represents a single clothing item in your wardrobe. Each `WardrobeItem` includes:
- **id:** Unique identifier
- **category:** The main category (e.g., Tops, Bottoms, Footwear, etc.)
- **product:** The specific product type (e.g., T-Shirt, Jeans, Sneakers)
- **color(s):** One or more detected colors
- **pattern:** The detected pattern (e.g., Solid, Striped, Floral)
- **brand:** (Optional) Brand name
- **image:** Reference to the item's image in the app's file system

### Outfit (Updated)
An `Outfit` is now a flexible collection of any number of `WardrobeItem` objects. This enables:
- Outfits with any combination and count of items (no longer limited to 5 or to fixed slots like top/bottom/shoes/etc.)
- More realistic and creative outfit suggestions and user-created looks

**Outfit properties:**
- **id:** Unique identifier
- **items:** `[WardrobeItem]` — An array of wardrobe items that make up the outfit
- **(Optional) metadata:** Such as date created, user notes, or tags (if implemented)

This change supports the upcoming "My Outfits" calendar feature, where multiple outfits can be mapped to any date, and each outfit can contain as many items as needed for the look.

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.

## License

[MIT](LICENSE)

---

**StyleMate** — Your AI-powered, privacy-first fashion assistant for iOS.

### Add Product to Outfit (AI-powered)
- On the outfit result page, tap the **Add Product** button to add a new product type (e.g., Jacket, Coat, Accessory) to your current outfit.
- The app presents a collapsible menu showing only categories and products for which you have wardrobe items.
- Select a category, then a product type. The app will send your current outfit and your wardrobe's items of that type to Gemini AI.
- Gemini suggests the best way to add the new product, following fashion rules, color theory, and practical outfit guidelines.
- The new outfit is displayed, and you can save it, shuffle individual items, or add more products.
- The UI ensures only relevant categories/products are shown, and the loading overlay clearly indicates when a product is being added. 