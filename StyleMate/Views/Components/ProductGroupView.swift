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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(product)
                    .font(.headline)
                    .foregroundColor(.accentColor)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(.accentColor)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \ .id) { item in
                        ItemRowView(item: item, selectedItems: $selectedItems, previewImage: $previewImage)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(.vertical, 2)
    }
} 