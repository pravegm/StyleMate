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
        ZStack {
            LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                           startPoint: .top, endPoint: .bottom)
            // A faint floor glow so the cutout sits on the backdrop, not in front of it.
            RadialGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.05 : 0.35), .clear],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 140)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(inset)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 6, x: 0, y: 4)
                    .transition(.opacity)
            } else if isLoading {
                Rectangle()
                    .fill(DS.Colors.backgroundSecondary.opacity(0.35))
                    .shimmering()
            } else {
                Image(systemName: "tshirt")
                    .font(.system(size: 26))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.18), value: image != nil)
    }
}
