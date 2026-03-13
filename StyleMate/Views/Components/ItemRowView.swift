import SwiftUI

struct ItemRowView: View {
    let item: WardrobeItem
    @Binding var selectedItems: Set<WardrobeItem>
    @Binding var previewImage: PreviewImage?

    private func toggleSelection() {
        Haptics.light()
        if selectedItems.contains(item) {
            selectedItems.remove(item)
        } else if selectedItems.count < 10 {
            selectedItems.insert(item)
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: toggleSelection) {
                Image(systemName: selectedItems.contains(item) ? "checkmark.circle.fill" : "circle")
                    .font(DS.Font.title3)
                    .foregroundColor(selectedItems.contains(item) ? DS.Colors.accent : DS.Colors.textTertiary)
            }

            Button(action: {
                if let img = item.croppedImage ?? item.image {
                    previewImage = PreviewImage(image: img)
                }
            }) {
                if let img = item.thumbnailImage ?? item.croppedImage ?? item.image {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .fill(DS.Colors.backgroundSecondary)
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Text(item.name)
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textPrimary)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection() }

            Spacer()
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .fill(selectedItems.contains(item) ? DS.Colors.accent.opacity(0.08) : DS.Colors.backgroundSecondary)
        )
    }
}
