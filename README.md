# StyleMate

StyleMate is your AI-powered fashion wardrobe and stylist app for iOS, built with SwiftUI.

## Features

- **Multi-Image Add Flow:**
  - Select multiple images from your gallery at once.
  - All images are analyzed in parallel in the background.
  - Review each image, edit detected details, and choose to save or remove each item individually.
  - "Add All" button lets you instantly add all analyzed items without reviewing each one.
  - Flexible: Save any, all, or none of the batch.

- **Remove Individual Detected Items:**
  - While reviewing detected items (in both single and batch add flows), you can remove any specific item you don't want to add to your wardrobe, before saving.

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

## Getting Started

1. Clone the repo and open `StyleMate.xcodeproj` in Xcode.
2. Build and run on iOS 16+.
3. Sign up or use as guest to start adding wardrobe items.

## Project Structure

- `Models/` — Data models (Category, Pattern, WardrobeItem, etc.)
- `ViewModels/` — App state and business logic.
- `Views/` — All SwiftUI screens and components.
- `Services/` — AI integration and persistence logic.
- `StyleMateTests/` — Unit tests.
- `StyleMateUITests/` — UI tests.

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.

## License

[MIT](LICENSE)

---

**StyleMate** — Your AI-powered, privacy-first fashion assistant for iOS. 