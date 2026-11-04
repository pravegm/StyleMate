import SwiftUI

/// A wardrobe item presented like a catalog product shot: the transparent
/// cutout fitted (never cropped) on a soft studio backdrop with a gentle
/// contact shadow. Used wherever items appear in grids so the whole wardrobe
/// reads as one consistent, shoppable-looking collection.
struct ItemCutoutTile: View {
    let image: UIImage?
    var height: CGFloat = 150
    var cornerRadius: CGFloat = 0
    var inset: CGFloat = 12

    var body: some View {
        ZStack {
            LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(inset)
                    .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 4)
            } else {
                Image(systemName: "tshirt")
                    .font(.system(size: 26))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
