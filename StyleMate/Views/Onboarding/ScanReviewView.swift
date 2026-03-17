import SwiftUI

struct ScanReviewView: View {
    @ObservedObject var scanService: PhotoScanService
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel

    private var selectedCount: Int {
        scanService.foundItems.filter(\.isSelected).count
    }

    private let columns = [
        GridItem(.flexible(), spacing: DS.Spacing.sm),
        GridItem(.flexible(), spacing: DS.Spacing.sm)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        headerSection
                        gridSection
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.xxxl + DS.ButtonSize.height)
                }

                bottomBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(DS.Colors.backgroundSecondary)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Review Found Items")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)

            Text("\(scanService.foundItems.count) items detected from your photos")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)

            HStack {
                Text("\(selectedCount) selected")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                Button {
                    Haptics.selection()
                    let allSelected = scanService.foundItems.allSatisfy(\.isSelected)
                    for i in scanService.foundItems.indices {
                        scanService.foundItems[i].isSelected = !allSelected
                    }
                } label: {
                    Text(scanService.foundItems.allSatisfy(\.isSelected) ? "Deselect All" : "Select All")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.accent)
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
        .padding(.top, DS.Spacing.md)
    }

    // MARK: - Grid

    private var gridSection: some View {
        LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
            ForEach(scanService.foundItems.indices, id: \.self) { index in
                itemCard(index: index)
            }
        }
    }

    private func itemCard(index: Int) -> some View {
        let item = scanService.foundItems[index]
        return Button {
            Haptics.selection()
            scanService.foundItems[index].isSelected.toggle()
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: item.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .background(DS.Colors.backgroundCard)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))

                    if item.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(DS.Colors.success)
                            .background(Circle().fill(Color.white).frame(width: 18, height: 18))
                            .padding(DS.Spacing.xs)
                    }
                }

                Text(item.product)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Text(item.category.rawValue)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                colorDots(for: item.colors)
            }
            .padding(DS.Spacing.xs)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow()
            .opacity(item.isSelected ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.2), value: item.isSelected)
        }
        .buttonStyle(.plain)
    }

    private func colorDots(for colors: [String]) -> some View {
        HStack(spacing: DS.Spacing.micro) {
            ForEach(colors.prefix(5), id: \.self) { colorName in
                Circle()
                    .fill(ColorMapping.color(for: colorName))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(DS.Colors.textTertiary.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            Button {
                addSelectedItems()
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(DS.Font.headline)
                    Text("Add \(selectedCount) Items")
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(DS.Font.headline)
                }
            }
            .buttonStyle(DSPrimaryButton(isDisabled: selectedCount == 0))
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.5 : 1.0)
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(DS.Colors.backgroundPrimary)
    }

    // MARK: - Add Items

    private func addSelectedItems() {
        let selected = scanService.foundItems.filter(\.isSelected)

        for item in selected {
            let imagePath = WardrobeImageFileHelper.saveImageAsPNG(item.image) ?? WardrobeImageFileHelper.saveImage(item.image) ?? ""
            let thumbnailPath = WardrobeImageFileHelper.saveThumbnail(item.image)

            let wardrobeItem = WardrobeItem(
                category: item.category,
                product: item.product,
                colors: item.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                brand: item.brand,
                pattern: item.pattern,
                imagePath: imagePath,
                croppedImagePath: imagePath,
                thumbnailPath: thumbnailPath,
                material: item.material,
                fit: item.fit,
                neckline: item.neckline,
                sleeveLength: item.sleeveLength,
                garmentLength: item.garmentLength,
                details: item.details
            )

            wardrobeViewModel.items.append(wardrobeItem)
            wardrobeViewModel.syncItemToCloud(wardrobeItem)
        }

        Haptics.success()
        scanService.dismissCompleted()
        isPresented = false
    }
}
