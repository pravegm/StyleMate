# StyleMate

StyleMate is a modern iOS app that acts as your personal fashion assistant. It helps you organize your wardrobe, get AI-powered outfit suggestions, and add new items with smart image analysis—all while following Apple's Human Interface Guidelines (HIG) for a beautiful, accessible, and production-quality experience.

## Features

- **Wardrobe Management**: Add, view, and organize your clothing items with images, categories, products, colors, and brands.
- **Smart Add Item**: When you add a new item, the app uses Apple's Vision framework to automatically detect the clothing's category, product, and color from the photo. You only need to enter the brand.
- **Outfit Suggestion**: Get daily outfit suggestions based on color theory and fashion rules (neutrals, complementary, analogous, triadic, monochromatic, pattern limits, and more). No external APIs—everything is in-app logic.
- **Persistent Login**: The app remembers your last login and keeps you signed in until you explicitly sign out.
- **Modern UI/UX**: Clean, accessible, and HIG-compliant design with support for Dark Mode, Dynamic Type, and smooth animations.

## Architecture

- **SwiftUI** for all UI, following MVVM pattern.
- **Combine/async-await** for state management and async tasks.
- **Vision Framework** for image classification and color detection.
- **UserDefaults** for lightweight data persistence (users, wardrobe, login state).
- **No external dependencies**—all logic is in-app and on-device.

## Key Directories

- `Models/` — Data models (WardrobeItem, Category, User, etc.)
- `ViewModels/` — View models for each screen (HomeViewModel, WardrobeViewModel, etc.)
- `Views/` — SwiftUI screens and components
- `Services/` — Business logic and system integrations (ImageAnalysisService, OutfitLogic, AuthService)
- `StyleMateTheme.swift` — (Optional) Theme and style helpers

## Setup & Running

1. **Requirements**:
   - Xcode 14+
   - iOS 16+

2. **Clone the repo**:
   ```sh
   git clone <your-repo-url>
   cd StyleMate
   ```

3. **Open in Xcode**:
   - Open `StyleMate.xcodeproj` in Xcode.

4. **Build & Run**:
   - Select a simulator or device and hit Run (⌘R).

5. **Add Items & Try Features**:
   - Add wardrobe items with photos—category, product, and color will be auto-suggested.
   - Tap "Get Today's Outfit" for a smart, non-repeating outfit suggestion.
   - Enjoy persistent login and a beautiful, accessible UI.

## Tech Highlights

- **Image Analysis**: Uses Vision's saliency and classifier to detect the main clothing item's color, category, and product.
- **Outfit Logic**: Encodes fashion rules (color theory, pattern limits, statement pieces, etc.) for in-app outfit generation.
- **Accessibility**: All interactive elements have accessibility labels and hints. Dynamic Type and color contrast are supported.
- **Dark Mode**: All screens and components adapt to system appearance.

## Customization

- **Add more products/categories**: Edit `Models/ProductType.swift` and `Models/Category.swift`.
- **Tune color/product detection**: Update `Services/ImageAnalysisService.swift` for more advanced ML or custom mappings.
- **UI/UX tweaks**: All views are in `Views/` and can be easily customized.

## License

MIT License (or your preferred license)

---

**StyleMate** — Your AI-powered, privacy-first fashion assistant for iOS. 