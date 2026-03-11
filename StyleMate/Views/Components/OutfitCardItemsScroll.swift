import SwiftUI

struct OutfitCardItemsScroll: View {
    let allItems: [OutfitItem]
    @Binding var previewImage: PreviewImage?

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
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
                .padding(.vertical, DS.Spacing.xs)
            }

            if allItems.count > 2 {
                Image(systemName: "chevron.right")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.trailing, DS.Spacing.xs)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct OutfitCardItemView: View {
    let item: OutfitItem

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            if let img = item.croppedImage ?? item.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.button)
                    .fill(DS.Colors.backgroundSecondary)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(DS.Colors.textTertiary)
                    )
            }

            Text(item.displayName)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 100)
        .padding(DS.Spacing.xs)
        .background(DS.Colors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}

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
