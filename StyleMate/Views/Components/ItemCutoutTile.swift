import SwiftUI

/// A wardrobe item presented like a catalog product shot: the transparent
/// cutout fitted (never cropped) on a soft studio backdrop with a gentle
/// contact shadow. Used wherever items appear in grids so the whole wardrobe
/// reads as one consistent, shoppable-looking collection.
///
/// `height: nil` makes the tile square (it takes its width from the grid).
/// `isLoading` shows a shimmer instead of the placeholder glyph while an image
/// is still being read (see `AsyncItemTile`).
struct ItemCutoutTile: View {
    let image: UIImage?
    var height: CGFloat? = 150
    var cornerRadius: CGFloat = 0
    var inset: CGFloat = 12
    var isLoading: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let height {
                tile.frame(maxWidth: .infinity).frame(height: height)
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { tile }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(image == nil)
    }

    private var tile: some View {
        // The studio stays a light "print" in dark mode (DS.Colors.studioTop), so the
        // glow and contact shadow are the light ones; only the backdrop dims.
        ZStack {
            LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                           startPoint: .top, endPoint: .bottom)
            // A faint floor glow so the cutout sits on the backdrop, not in front of it.
            RadialGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.22 : 0.35), .clear],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 140)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(inset)
                    .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 4)
                    .transition(.opacity)
            } else if isLoading {
                Rectangle()
                    .fill(Color.black.opacity(0.05))
                    .shimmering()
            } else {
                Image(systemName: "tshirt")
                    .font(.system(size: 26))
                    .foregroundColor(Color.black.opacity(0.25))
            }
        }
        .animation(.easeOut(duration: 0.18), value: image != nil)
    }
}
