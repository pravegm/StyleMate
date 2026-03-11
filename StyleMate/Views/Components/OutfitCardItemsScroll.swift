import SwiftUI

struct OutfitCardItemsScroll: View {
    let allItems: [OutfitItem]
    @Binding var previewImage: PreviewImage?
    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(allItems, id: \.objectID) { item in
                        Button(action: {
                            if let img = item.croppedImage ?? item.image {
                                previewImage = PreviewImage(image: img)
                            }
                        }) {
                            OutfitCardItemView(item: item)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            // Right-facing triangle indicator if more than 2 items
            if allItems.count > 2 {
                Image(systemName: "chevron.right")
                    .font(.title3.bold())
                    .foregroundColor(.secondary)
                    .padding(.trailing, 6)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct OutfitCardItemView: View {
    let item: OutfitItem
    var body: some View {
        VStack(spacing: 6) {
            if let img = item.croppedImage ?? item.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 68, height: 68)
                    .overlay(Text("No Image").font(.caption2))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(item.displayName)
                .font(.caption.bold())
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
        .padding(4)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        .frame(width: 110)
    }
}

// Helper for display name, matching WardrobeItem logic
extension OutfitItem {
    var displayName: String {
        let colorsString: String = (self.colors as? [String])?.joined(separator: ", ") ?? ""
        let patternString: String = (self.pattern as? String) ?? ""
        let brandString: String = self.brand ?? ""
        let productString: String = self.product ?? ""
        return ([colorsString, patternString, brandString, productString])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
} 