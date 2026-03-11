import SwiftUI

struct ProductGroupView: View {
    let category: Category
    let product: String
    let items: [WardrobeItem]
    let isExpanded: Bool
    let onToggle: () -> Void
    @Binding var selectedItems: Set<WardrobeItem>
    @Binding var previewImage: PreviewImage?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(product)
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.accent)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(DS.Colors.accent)
            }
            .padding(.vertical, DS.Spacing.micro)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(items, id: \.id) { item in
                        ItemRowView(item: item, selectedItems: $selectedItems, previewImage: $previewImage)
                    }
                }
                .padding(.leading, DS.Spacing.xs)
            }
        }
    }
}
