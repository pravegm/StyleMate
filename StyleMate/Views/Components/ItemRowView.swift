import SwiftUI

struct ItemRowView: View {
    let item: WardrobeItem
    @Binding var selectedItems: Set<WardrobeItem>
    @Binding var previewImage: PreviewImage?
    
    private func toggleSelection() {
        if selectedItems.contains(item) {
            selectedItems.remove(item)
        } else if selectedItems.count < 10 {
            selectedItems.insert(item)
        }
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleSelection) {
                Image(systemName: selectedItems.contains(item) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selectedItems.contains(item) ? .accentColor : .secondary)
            }
            Button(action: {
                if let img = item.croppedImage ?? item.image {
                    previewImage = PreviewImage(image: img)
                }
            }) {
                if let img = item.croppedImage ?? item.image {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Rectangle()
                        .fill(Color.gray)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .buttonStyle(PlainButtonStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.bold())
                    .foregroundColor(.primary)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleSelection() }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(selectedItems.contains(item) ? Color.accentColor.opacity(0.09) : Color(.systemGray6)))
        .shadow(color: selectedItems.contains(item) ? Color.accentColor.opacity(0.10) : Color.clear, radius: 2, x: 0, y: 1)
    }
}
