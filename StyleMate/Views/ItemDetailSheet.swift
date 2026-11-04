import SwiftUI

/// An item's page in the closet: the cutout large on the studio backdrop, its
/// attributes as tidy chips, how often it's been worn, and edit / remove.
/// Pushed with a zoom transition from the tile that opened it.
///
/// It reads the live item from the wardrobe by id, so an edit made here shows
/// immediately; `onDelete` is the caller's job (it pops first, then removes, so
/// the zoom can animate back to a tile that still exists).
struct ItemDetailView: View {
    let itemID: UUID
    private let fallback: WardrobeItem
    var wear: WearStat?
    var onDelete: (WardrobeItem) -> Void

    @EnvironmentObject private var wardrobeViewModel: WardrobeViewModel
    @State private var showEdit = false
    @State private var confirmRemove = false
    @State private var showFullImage = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: WardrobeItem, wear: WearStat?, onDelete: @escaping (WardrobeItem) -> Void) {
        self.itemID = item.id
        self.fallback = item
        self.wear = wear
        self.onDelete = onDelete
    }

    private var item: WardrobeItem {
        wardrobeViewModel.items.first { $0.id == itemID } ?? fallback
    }

    var body: some View {
        let item = self.item
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                hero(item)
                header(item)
                Group {
                    colors(item)
                    attributes(item)
                    notes(item)
                    actions
                }
                .dsAppear(appeared)
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.top, DS.Spacing.xs)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
        .accessibilityIdentifier("itemDetail.root")
        .navigationTitle(ClosetText.displayProduct(item.product))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit details", systemImage: "pencil") }
                        .accessibilityIdentifier("itemDetail.edit")
                    Divider()
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Remove from Wardrobe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More actions")
                .accessibilityIdentifier("itemDetail.more")
            }
        }
        .onAppear {
            withAnimation(DSMotionEnv.resolve(DS.Motion.gentle.delay(0.12), reduceMotion: reduceMotion)) {
                appeared = true
            }
        }
        .sheet(isPresented: $showEdit) {
            EditWardrobeItemView(item: item) { updated in
                ClosetActions.update(updated, in: wardrobeViewModel)
            }
        }
        .confirmationDialog("Remove this item?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from Wardrobe", role: .destructive) {
                Haptics.warning()
                onDelete(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this when it isn't yours or was picked up by mistake. Your photos aren't touched.")
        }
        .fullScreenCover(isPresented: $showFullImage) {
            FullItemImageViewer(path: item.fullImagePath, fallbackPath: item.gridImagePath, title: ClosetText.displayName(item))
        }
    }

    // MARK: - Hero

    private func hero(_ item: WardrobeItem) -> some View {
        Button {
            Haptics.light()
            showFullImage = true
        } label: {
            AsyncItemTile(path: item.gridImagePath, height: nil, cornerRadius: DS.Radius.hero,
                          inset: 28, upgradePath: item.fullImagePath)
                .dsCardShadow(cornerRadius: DS.Radius.hero)
        }
        .buttonStyle(DSTapBounce())
        .accessibilityLabel("Photo of \(ClosetText.displayName(item))")
        .accessibilityHint("Opens the photo full screen")
    }

    // MARK: - Header

    private func header(_ item: WardrobeItem) -> some View {
        let section = ClosetSection.of(item)
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(section.title, systemImage: section.iconName)
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
            Text(ClosetText.displayName(item))
                .font(DS.Font.title2)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Label(ClosetAttributes.wearSummary(wear), systemImage: "calendar")
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Colors

    @ViewBuilder
    private func colors(_ item: WardrobeItem) -> some View {
        let names = item.colors.map(ClosetColor.normalize).filter { !$0.isEmpty }
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                sectionLabel("Colors")
                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ColorMapping.color(for: name))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(DS.Colors.separator, lineWidth: 1))
                            Text(name)
                                .font(DS.Font.subheadline.weight(.medium))
                                .foregroundStyle(DS.Colors.textPrimary)
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(DS.Colors.backgroundCard, in: Capsule(style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Attributes

    /// Label / value pairs in a two-column grid, like Settings' "About".
    private func attributes(_ item: WardrobeItem) -> some View {
        let rows = ClosetAttributes.chips(for: item)
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            sectionLabel("Details")
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    GridRow(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .gridColumnAlignment(.leading)
                        Text(row.value)
                            .font(DS.Font.subheadline.weight(.medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(DS.Colors.backgroundCard,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private func notes(_ item: WardrobeItem) -> some View {
        if let details = item.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                sectionLabel("Notes")
                Text(details)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    /// One plain destructive row; editing lives in the ⋯ menu.
    private var actions: some View {
        Button(role: .destructive) {
            confirmRemove = true
        } label: {
            Text("Remove from Wardrobe")
                .font(DS.Font.body)
                .foregroundStyle(DS.Colors.error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.md)
                .frame(minHeight: 48)
                .background(DS.Colors.backgroundCard,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(DSTapBounce())
        .accessibilityHint("For items that aren't yours or were picked up by mistake")
        .accessibilityIdentifier("itemDetail.remove")
        .padding(.top, DS.Spacing.sm)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DS.Font.footnote.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(DS.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-screen, pinch-to-zoom view of an item's cutout on the studio backdrop.
struct FullItemImageViewer: View {
    let path: String
    var fallbackPath: String? = nil
    var title: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    init(path: String, fallbackPath: String? = nil, title: String = "") {
        self.path = path
        self.fallbackPath = fallbackPath
        self.title = title
        _image = State(initialValue: ClosetImageLoader.shared.cached(path)
                       ?? ClosetImageLoader.shared.cached(fallbackPath))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if let image {
                ZoomableImage(image: image)
                    .padding(DS.Spacing.lg)
                    .accessibilityLabel(title.isEmpty ? "Item photo" : "Photo of \(title)")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .frame(width: 40, height: 40)
                    .dsGlassCircle()
            }
            .padding(DS.Spacing.md)
            .accessibilityLabel("Close")
        }
        .task {
            if let big = await ClosetImageLoader.shared.load(path) { image = big }
            else if image == nil { image = await ClosetImageLoader.shared.load(fallbackPath) }
        }
    }
}
