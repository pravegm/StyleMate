import SwiftUI

struct ScanReviewView: View {
    @ObservedObject var scanService: PhotoScanService
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel

    private var currentUserId: String? {
        let email = wardrobeViewModel.currentUserEmail
        return email.isEmpty ? nil : email
    }

    private var scannedWardrobeItems: [WardrobeItem] {
        let ids: Set<UUID>
        if !scanService.scanAddedItemIDs.isEmpty {
            ids = Set(scanService.scanAddedItemIDs)
        } else if let userId = currentUserId {
            ids = Set(scanService.loadLastScanItemIDs(forUser: userId))
        } else {
            ids = []
        }
        return wardrobeViewModel.items.filter { ids.contains($0.id) }
    }

    private let columns = [
        GridItem(.flexible(), spacing: DS.Spacing.sm),
        GridItem(.flexible(), spacing: DS.Spacing.sm)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                if scannedWardrobeItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Spacing.md) {
                            headerSection
                            gridSection
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.bottom, DS.Spacing.xxxl + DS.ButtonSize.height)
                    }
                }

                if !scannedWardrobeItems.isEmpty {
                    bottomBar
                }
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
            Text("Review Scanned Items")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)

            Text("These items were added from your photos. Remove any that don't belong.")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)

            Text("\(scannedWardrobeItems.count) items from scan")
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, DS.Spacing.xs)
        }
        .padding(.top, DS.Spacing.md)
    }

    // MARK: - Grid

    private var gridSection: some View {
        LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
            ForEach(scannedWardrobeItems) { item in
                itemCard(item: item)
            }
        }
    }

    private func itemCard(item: WardrobeItem) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = item.croppedImage ?? item.image {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(DS.Colors.backgroundSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))

                Button {
                    Haptics.medium()
                    removeItem(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(DS.Colors.error.opacity(0.8))
                        .background(Circle().fill(DS.Colors.backgroundPrimary).frame(width: 18, height: 18))
                }
                .padding(DS.Spacing.xs)
                .accessibilityLabel("Remove \(item.product)")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.product), \(item.category.rawValue)")
        .accessibilityHint("Double tap the remove button to remove this item")
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(DS.Colors.textTertiary)
            Text("All scanned items removed")
                .font(DS.Font.headline)
                .foregroundColor(DS.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isPresented = false
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            Button {
                Haptics.success()
                if let userId = currentUserId {
                    scanService.clearLastScanIDs(forUser: userId)
                }
                isPresented = false
            } label: {
                HStack {
                    Spacer()
                    Text("Done")
                    Spacer()
                }
            }
            .buttonStyle(DSPrimaryButton())
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
            .accessibilityLabel("Done reviewing scanned items")
        }
        .background(DS.Colors.backgroundPrimary)
    }

    // MARK: - Remove Item

    private func removeItem(_ item: WardrobeItem) {
        withAnimation(.easeInOut(duration: 0.25)) {
            wardrobeViewModel.items.removeAll { $0.id == item.id }
        }

        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
        WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
        WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)

        scanService.scanAddedItemIDs.removeAll { $0 == item.id }

        if let userId = currentUserId {
            scanService.removeFromLastScanIDs(item.id, forUser: userId)
        }

        wardrobeViewModel.deleteItemFromCloud(item)

        print("[StyleMate] Removed scan item: \(item.product)")
    }
}
