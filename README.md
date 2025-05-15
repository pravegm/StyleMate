# StyleMate

StyleMate is your AI-powered fashion wardrobe and stylist app for iOS, built with SwiftUI.

## Features

- **Multi-Image Add Flow:**
  - Select multiple images from your gallery at once.
  - All images are analyzed in parallel in the background.
  - Review each image, edit detected details, and choose to save or remove each item individually.
  - "Add All" button lets you instantly add all analyzed items without reviewing each one.
  - Flexible: Save any, all, or none of the batch.

- **Batch Review & Summary:**
  - Swipe between images in a modern, card-based UI.
  - See a summary screen after adding, e.g. "2 Shirts, 1 Jeans added to your wardrobe."

- **Wardrobe Management:**
  - Browse your wardrobe by category.
  - Tap any item to see a full-screen image preview.
  - Delete items with swipe-to-delete and Edit mode.

- **Modern SwiftUI Architecture:**
  - Uses NavigationStack, TabView, and best practices for state management.
  - Accessibility labels and large tap targets for inclusive design.

- **Camera & Gallery Support:**
  - Add items via camera or gallery, with a tip for multi-select.

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

**Note:** Images are stored in UserDefaults for demo purposes. For production, use the file system or Core Data for large data.

**StyleMate** — Your AI-powered, privacy-first fashion assistant for iOS. 