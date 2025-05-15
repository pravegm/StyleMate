# StyleMate

StyleMate is your AI-powered wardrobe and outfit assistant for iOS.

## Features

- **Add Items:** Scan clothing items with AI, or add manually. Supports category, product, multiple colors, pattern, brand, and photo.
- **Pattern & Color Detection:** Gemini AI detects category, product, all main colors, and pattern from your photos.
- **My Wardrobe:** Browse, edit, and delete your wardrobe items. See all details in a clean, accessible UI. Instantly empty your wardrobe with a confirmation dialog.
- **Outfit Suggestions:** Get daily outfit suggestions based on color harmony and pattern rules.
- **Accessibility:** Fully accessible with VoiceOver and large text support.
- **Data Persistence:** Your wardrobe is saved locally on your device.

## How to Build

1. Open `StyleMate.xcodeproj` in Xcode 15 or later.
2. Set your Gemini API key in `ImageAnalysisService.swift` (if not already set).
3. Build and run on Simulator or a real device (iOS 17+ recommended).

## Project Structure

- `Models/` — Data models (Category, Pattern, WardrobeItem, etc.)
- `ViewModels/` — App state and business logic.
- `Views/` — All SwiftUI screens and components.
- `Services/` — AI integration and persistence logic.
- `StyleMateTests/` — Unit tests.
- `StyleMateUITests/` — UI tests.

## Contributing

Pull requests are welcome! Please open an issue first to discuss any major changes.

## License

MIT

---

**Note:** Images are stored in UserDefaults for demo purposes. For production, use the file system or Core Data for large data.

**StyleMate** — Your AI-powered, privacy-first fashion assistant for iOS. 