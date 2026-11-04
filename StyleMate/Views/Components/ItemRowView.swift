import SwiftUI

struct ItemRowView: View {
    let item: WardrobeItem
    @Binding var selectedItems: Set<WardrobeItem>
    @Binding var previewImage: PreviewImage?

    private var isSelected: Bool { selectedItems.contains(item) }

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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Font.title3)
                    .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ClosetText.displayName(item))
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                Task {
                    if let img = await ClosetImageLoader.shared.load(item.fullImagePath) {
                        previewImage = PreviewImage(image: img)
                    }
                }
            } label: {
                AsyncItemTile(path: item.gridImagePath, height: 48, cornerRadius: DS.Radius.chip, inset: 4)
                    .frame(width: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(ClosetText.displayProduct(item.product))")

            Text(ClosetText.displayName(item))
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection() }
                .accessibilityHidden(true)
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSoft : DS.Colors.backgroundSecondary)
        )
    }
}
