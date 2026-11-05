import SwiftUI

struct AddItemReviewView: View {
    let images: [UIImage]
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService

    @State private var isAnalyzing = true
    @State private var photoSections: [PhotoSection] = []
    @State private var expandedImage: UIImage? = nil
    @State private var editingRef: ReviewRef? = nil

    struct PhotoSection: Identifiable {
        let id = UUID()
        let imageIndex: Int
        let sourceImage: UIImage
        var items: [ReviewItem]
        var isLoading: Bool
    }

    struct ReviewItem: Identifiable {
        let id = UUID()
        let sourceImageIndex: Int
        var category: Category
        var product: String
        var colors: [String]
        var pattern: Pattern
        var brand: String
        var isSelected: Bool = true
        var duplicateMatch: DuplicateMatch?
        var garmentImage: UIImage?

        var material: String
        var fit: Fit?
        var neckline: Neckline?
        var sleeveLength: SleeveLength?
        var garmentLength: GarmentLength?
        var details: String
        /// FashionSigLIP embedding of the cutout (visual duplicate matching).
        var featurePrint: [Float]? = nil
        var quality: Float = 0
        var truncated: Bool = false

        var isDuplicate: Bool { duplicateMatch != nil }
    }

    /// Which detected item the editor sheet is open for.
    struct ReviewRef: Identifiable {
        let sectionID: UUID
        let itemID: UUID
        var id: UUID { itemID }
    }

    private var allReviewItems: [ReviewItem] {
        photoSections.flatMap(\.items)
    }

    private var selectedCount: Int {
        allReviewItems.filter(\.isSelected).count
    }

    private var allDoneNoItems: Bool {
        !photoSections.isEmpty
        && photoSections.allSatisfy { !$0.isLoading }
        && allReviewItems.isEmpty
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: DS.Spacing.sm, alignment: .top)]

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                if allDoneNoItems {
                    DSEmptyState(
                        icon: "eye.slash",
                        title: "No clothes found",
                        message: "Try a photo where your outfit is clearly visible, or a photo of the item on its own.",
                        actionTitle: "Close",
                        action: { isPresented = false }
                    )
                    .padding(.horizontal, DS.Spacing.screenH)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                            if authService.user?.gender == nil || (authService.user?.gender ?? "").isEmpty {
                                genderTip
                            }
                            if !allReviewItems.isEmpty {
                                selectionSummary
                                UncertainItemsNote(deselected: allReviewItems.filter { !$0.isSelected }.compactMap { $0.garmentImage })
                            }
                            ForEach($photoSections) { $section in
                                photoSectionView($section)
                            }
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.top, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.lg)
                    }
                    .safeAreaInset(edge: .bottom) { addBar }
                }
            }
            .overlay {
                if let expandedImg = expandedImage {
                    ZStack {
                        Color.black.opacity(0.7)
                            .ignoresSafeArea()
                            .onTapGesture { expandedImage = nil }

                        VStack(spacing: DS.Spacing.md) {
                            ItemCutoutTile(image: expandedImg, height: 320, cornerRadius: DS.Radius.hero, inset: 24)
                                .frame(maxWidth: 320)
                                .shadow(radius: 10)

                            Text("Tap anywhere to close")
                                .font(DS.Font.caption1)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .onTapGesture { expandedImage = nil }
                    }
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { expandedImage = nil }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: expandedImage != nil)
            .navigationTitle("Review Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(item: $editingRef, onDismiss: { markAllDuplicates() }) { ref in
                if let binding = reviewBinding(for: ref) {
                    ReviewItemEditor(item: binding)
                }
            }
            .interactiveDismissDisabled()
            .onAppear { analyzeAllImages() }
        }
    }

    // MARK: - Pieces

    private var genderTip: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(DS.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Improve detection accuracy")
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Add your gender in Profile for better results")
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var selectionSummary: some View {
        let allSelected = selectedCount == allReviewItems.count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedCount) of \(allReviewItems.count) selected")
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .monospacedDigit()
                Text("Tap an item to include or skip it. Tap the pencil to fix details.")
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: DS.Spacing.sm)
            Button(allSelected ? "Select none" : "Select all") {
                Haptics.light()
                for s in photoSections.indices {
                    for i in photoSections[s].items.indices { photoSections[s].items[i].isSelected = !allSelected }
                }
            }
            .font(DS.Font.subheadline.weight(.semibold))
            .foregroundStyle(DS.Colors.accent)
        }
    }

    private func photoSectionView(_ section: Binding<PhotoSection>) -> some View {
        let value = section.wrappedValue
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(uiImage: value.sourceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Photo \(value.imageIndex + 1)")
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(value.isLoading
                         ? "Finding clothes…"
                         : "\(value.items.count) item\(value.items.count == 1 ? "" : "s") found")
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .accessibilityElement(children: .combine)

                Spacer()

                if !value.isLoading {
                    Button {
                        reanalyzePhoto(sectionIndex: value.imageIndex)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(DS.Font.caption1.weight(.semibold))
                            .foregroundStyle(DS.Colors.accent)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(DS.Colors.accentSoft, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(DSTapBounce())
                    .accessibilityLabel("Analyze photo \(value.imageIndex + 1) again")
                }
            }

            if value.isLoading {
                LazyVGrid(columns: gridColumns, spacing: DS.Spacing.sm) {
                    ForEach(0..<2, id: \.self) { _ in SkeletonItemCard() }
                }
            } else if value.items.isEmpty {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(DS.Colors.textTertiary)
                    Text("No clothes found in this photo")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity)
                .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            } else {
                LazyVGrid(columns: gridColumns, spacing: DS.Spacing.sm) {
                    ForEach(section.items) { $item in
                        ReviewItemCard(
                            item: $item,
                            onEdit: { editingRef = ReviewRef(sectionID: value.id, itemID: item.id) },
                            onCompare: { existing in showExisting(existing) }
                        )
                    }
                }
            }
        }
    }

    private var addBar: some View {
        let disabled = selectedCount == 0 || photoSections.allSatisfy(\.isLoading)
        return VStack(spacing: 0) {
            Divider()
            Button(action: addSelectedItems) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add \(selectedCount) Item\(selectedCount == 1 ? "" : "s") to Wardrobe")
                }
            }
            .buttonStyle(DSPrimaryButton(isDisabled: disabled))
            .disabled(disabled)
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(.bar)
    }

    private func showExisting(_ item: WardrobeItem) {
        Task {
            let image = await ClosetImageLoader.shared.load(item.fullImagePath)
            await MainActor.run { expandedImage = image }
        }
    }

    /// A binding to one detected item by id, safe if the photo is re-analyzed
    /// while the editor is open (writes to a vanished item are dropped).
    private func reviewBinding(for ref: ReviewRef) -> Binding<ReviewItem>? {
        guard let s = photoSections.firstIndex(where: { $0.id == ref.sectionID }),
              let i = photoSections[s].items.firstIndex(where: { $0.id == ref.itemID }) else { return nil }
        let snapshot = photoSections[s].items[i]
        return Binding(
            get: {
                guard let s = photoSections.firstIndex(where: { $0.id == ref.sectionID }),
                      let i = photoSections[s].items.firstIndex(where: { $0.id == ref.itemID }) else { return snapshot }
                return photoSections[s].items[i]
            },
            set: { newValue in
                guard let s = photoSections.firstIndex(where: { $0.id == ref.sectionID }),
                      let i = photoSections[s].items.firstIndex(where: { $0.id == ref.itemID }) else { return }
                photoSections[s].items[i] = newValue
            }
        )
    }

    // MARK: - Analysis

    /// Every extraction goes through the shared `ExtractionGate` (also meant for the library
    /// scan), so adding 15 photos runs 1–2 extractions at a time instead of 15 at once — each
    /// holds ~100–200 MB, which is what got the app jetsammed.
    private static func gatedAnalysis(_ image: UIImage, userGender: String?) async -> [ImageAnalysisService.SegmentedItem] {
        await ExtractionGate.shared.acquire()
        let results = await ImageAnalysisService.shared.analyzeAndSegment(
            image: image, userGender: userGender, describe: true)
        await ExtractionGate.shared.release()
        return results
    }

    private func analyzeAllImages() {
        isAnalyzing = true

        Task {
            await MainActor.run {
                photoSections = images.enumerated().map { idx, img in
                    PhotoSection(imageIndex: idx, sourceImage: img, items: [], isLoading: true)
                }
                isAnalyzing = false
            }

            let userGender = authService.user?.gender

            await withTaskGroup(of: (Int, [ReviewItem]).self) { group in
                for (idx, image) in images.enumerated() {
                    group.addTask {
                        let results = await Self.gatedAnalysis(image, userGender: userGender)
                        var items = results.compactMap { seg -> ReviewItem? in
                            guard let cat = seg.category, let prod = seg.product,
                                  let pattern = seg.pattern, !seg.colors.isEmpty else { return nil }
                            return ReviewItem(
                                sourceImageIndex: idx,
                                category: cat,
                                product: prod,
                                colors: seg.colors,
                                pattern: pattern,
                                brand: seg.brand,
                                isSelected: ItemTrust.isConfident(seg),
                                garmentImage: seg.maskImage,
                                material: seg.material ?? "",
                                fit: seg.fit,
                                neckline: seg.neckline,
                                sleeveLength: seg.sleeveLength,
                                garmentLength: seg.garmentLength,
                                details: seg.details ?? "",
                                featurePrint: seg.featurePrint,
                                quality: seg.quality,
                                truncated: seg.truncated
                            )
                        }

                        let footwearIndices = items.indices.filter { items[$0].category == .footwear }
                        if footwearIndices.count > 1 {
                            items = items.enumerated().filter { i, item in
                                item.category != .footwear || i == footwearIndices.first
                            }.map(\.element)
                        }

                        items = self.deduplicateAccessories(items)
                        return (idx, items)
                    }
                }

                for await (idx, items) in group {
                    await MainActor.run {
                        if idx < photoSections.count {
                            photoSections[idx].items = items
                            photoSections[idx].isLoading = false
                            markAllDuplicates()
                        }
                    }
                }
            }
        }
    }

    private func reanalyzePhoto(sectionIndex: Int) {
        guard sectionIndex < photoSections.count else { return }
        Haptics.light()

        photoSections[sectionIndex].isLoading = true
        photoSections[sectionIndex].items = []

        Task {
            let image = images[sectionIndex]
            let results = await Self.gatedAnalysis(image, userGender: authService.user?.gender)

            var items = results.compactMap { seg -> ReviewItem? in
                guard let cat = seg.category, let prod = seg.product,
                      let pattern = seg.pattern, !seg.colors.isEmpty else { return nil }
                return ReviewItem(
                    sourceImageIndex: sectionIndex,
                    category: cat,
                    product: prod,
                    colors: seg.colors,
                    pattern: pattern,
                    brand: seg.brand,
                    isSelected: ItemTrust.isConfident(seg),
                    garmentImage: seg.maskImage,
                    material: seg.material ?? "",
                    fit: seg.fit,
                    neckline: seg.neckline,
                    sleeveLength: seg.sleeveLength,
                    garmentLength: seg.garmentLength,
                    details: seg.details ?? "",
                                featurePrint: seg.featurePrint,
                                quality: seg.quality,
                                truncated: seg.truncated
                )
            }

            let footwearIndices = items.indices.filter { items[$0].category == .footwear }
            if footwearIndices.count > 1 {
                items = items.enumerated().filter { i, item in
                    item.category != .footwear || i == footwearIndices.first
                }.map(\.element)
            }
            items = deduplicateAccessories(items)

            await MainActor.run {
                photoSections[sectionIndex].items = items
                photoSections[sectionIndex].isLoading = false
                markAllDuplicates()
            }
        }
    }

    private func markAllDuplicates() {
        let existingItems = wardrobeViewModel.items
        for sectionIdx in photoSections.indices {
            for itemIdx in photoSections[sectionIdx].items.indices {
                let item = photoSections[sectionIdx].items[itemIdx]
                photoSections[sectionIdx].items[itemIdx].duplicateMatch =
                    DuplicateDetector.shared.findBestMatch(
                        category: item.category,
                        product: item.product,
                        colors: item.colors,
                        pattern: item.pattern,
                        material: item.material.isEmpty ? nil : item.material,
                        fit: item.fit,
                        neckline: item.neckline,
                        sleeveLength: item.sleeveLength,
                        brand: item.brand,
                        existingItems: existingItems,
                        featurePrint: item.featurePrint
                    )
            }
        }
    }

    private func deduplicateAccessories(_ items: [ReviewItem]) -> [ReviewItem] {
        var result = items
        let imageGroups = Dictionary(grouping: result.indices.filter { result[$0].category == .accessories },
                                      by: { result[$0].sourceImageIndex })

        var indicesToRemove: Set<Int> = []

        for (_, indices) in imageGroups {
            let accessoryItems = indices.map { (index: $0, item: result[$0]) }

            // Rule 1: If both "Watches" and a wrist jewelry item exist, drop the jewelry if colors overlap
            let watchIndices = accessoryItems.filter { $0.item.product == "Watches" }
            let wristJewelry = accessoryItems.filter { ["Bracelets", "Jewelry", "Chains"].contains($0.item.product) }
            if !watchIndices.isEmpty && !wristJewelry.isEmpty {
                for wj in wristJewelry {
                    let watchColors = Set(watchIndices.first!.item.colors.map { $0.lowercased() })
                    let jewelryColors = Set(wj.item.colors.map { $0.lowercased() })
                    if !watchColors.intersection(jewelryColors).isEmpty {
                        indicesToRemove.insert(wj.index)
                    }
                }
            }

            // Rule 2: Same product type with overlapping colors = duplicate (e.g., two "Earrings" with "Gold")
            let productGroups = Dictionary(grouping: accessoryItems, by: { $0.item.product })
            for (_, productItems) in productGroups where productItems.count > 1 {
                let colorSets = productItems.map { Set($0.item.colors.map { $0.lowercased() }) }
                for i in 1..<productItems.count {
                    let overlap = colorSets[0].intersection(colorSets[i])
                    if !overlap.isEmpty {
                        indicesToRemove.insert(productItems[i].index)
                    }
                }
            }

            // Rule 3: If multiple glasses types exist from same image, keep only the first
            let glassesProducts = ["Sunglasses", "Eyeglasses", "Reading Glasses"]
            let glassesItems = accessoryItems.filter { glassesProducts.contains($0.item.product) }
            if glassesItems.count > 1 {
                for item in glassesItems.dropFirst() {
                    indicesToRemove.insert(item.index)
                }
            }
        }

        for idx in indicesToRemove.sorted(by: >) {
            result.remove(at: idx)
        }

        return result
    }

    // MARK: - Save

    private func addSelectedItems() {
        let selected = allReviewItems.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        Haptics.success()

        for item in selected {
            let fullImage = item.garmentImage ?? images[item.sourceImageIndex]
            let imagePath = WardrobeImageFileHelper.saveImageAsPNG(fullImage) ?? WardrobeImageFileHelper.saveImage(fullImage) ?? ""
            let croppedImagePath = imagePath
            let thumbnailPath = WardrobeImageFileHelper.saveThumbnail(fullImage)

            let wardrobeItem = WardrobeItem(
                category: item.category,
                product: item.product,
                colors: item.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                brand: item.brand,
                pattern: item.pattern,
                imagePath: imagePath,
                croppedImagePath: croppedImagePath,
                thumbnailPath: thumbnailPath,
                material: item.material.isEmpty ? nil : item.material,
                fit: item.fit,
                neckline: item.neckline,
                sleeveLength: item.sleeveLength,
                garmentLength: item.garmentLength,
                details: item.details.isEmpty ? nil : item.details
            )
            if let fp = item.featurePrint {
                ItemEmbeddingStore.shared.set(fp, quality: item.quality, truncated: item.truncated, for: wardrobeItem.id)
            }
            wardrobeViewModel.items.append(wardrobeItem)
            wardrobeViewModel.syncItemToCloud(wardrobeItem)
        }

        isPresented = false
    }
}

// MARK: - Review Item Card

/// A detected item as a closet tile: tap to include / skip, pencil to edit.
/// A "Similar" badge and a mini tile of the matching wardrobe item flag
/// probable duplicates.
private struct ReviewItemCard: View {
    @Binding var item: AddItemReviewView.ReviewItem
    var onEdit: () -> Void
    var onCompare: (WardrobeItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button {
                Haptics.selection()
                withAnimation(DS.Motion.snappy) { item.isSelected.toggle() }
            } label: {
                ItemCutoutTile(image: item.garmentImage, height: nil, cornerRadius: DS.Radius.control, inset: 12)
                    .saturation(item.isSelected ? 1 : 0.15)
                    .opacity(item.isSelected ? 1 : 0.55)
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Colors.accent, lineWidth: item.isSelected ? 2.5 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, item.isSelected ? DS.Colors.accent : Color.black.opacity(0.25))
                            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                            .padding(8)
                    }
                    .overlay(alignment: .topLeading) {
                        if item.isDuplicate {
                            Label("Similar", systemImage: "square.on.square")
                                .font(DS.Font.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(DS.Colors.warning, in: Capsule(style: .continuous))
                                .padding(8)
                        }
                    }
            }
            .buttonStyle(DSTapBounce())
            .accessibilityLabel("\(item.colors.joined(separator: " ")) \(item.product)")
            .accessibilityValue(item.isSelected ? "Will be added" : "Skipped")
            .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(item.isDuplicate ? "Similar to an item already in your wardrobe" : "Double-tap to include or skip")

            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.product)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach(Array(item.colors.prefix(3).enumerated()), id: \.offset) { _, c in
                            Circle()
                                .fill(ColorMapping.color(for: c))
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                        }
                        Text(item.colors.joined(separator: ", "))
                            .font(DS.Font.caption1)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Colors.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(item.product)")
            }

            if let match = item.duplicateMatch {
                Button {
                    onCompare(match.existingItem)
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        AsyncItemTile(path: match.existingItem.gridImagePath, height: 34,
                                      cornerRadius: 8, inset: 3)
                            .frame(width: 34)
                        Text("Looks like one you have")
                            .font(DS.Font.caption1)
                            .foregroundStyle(DS.Colors.warning)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(DS.Colors.warning.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(DSTapBounce())
                .accessibilityLabel("Similar to your \(ClosetText.displayName(match.existingItem)). Show it")
            }
        }
        .padding(DS.Spacing.xs)
        .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
    }
}

// MARK: - Review Item Editor

/// Fix a detected item's details before it's added.
private struct ReviewItemEditor: View {
    @Binding var item: AddItemReviewView.ReviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ItemCutoutTile(image: item.garmentImage, height: 200, cornerRadius: DS.Radius.card, inset: 18)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    Toggle("Add to wardrobe", isOn: $item.isSelected)
                }

                if let match = item.duplicateMatch {
                    Section {
                        HStack(spacing: DS.Spacing.sm) {
                            AsyncItemTile(path: match.existingItem.gridImagePath, height: 56,
                                          cornerRadius: 10, inset: 4)
                                .frame(width: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Similar item already in your wardrobe")
                                    .font(DS.Font.subheadline.weight(.semibold))
                                    .foregroundStyle(DS.Colors.warning)
                                Text(ClosetText.displayName(match.existingItem))
                                    .font(DS.Font.caption1)
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Section("Type") {
                    Picker("Category", selection: $item.category) {
                        ForEach(Category.allCases) { cat in Text(cat.rawValue).tag(cat) }
                    }
                    let standardProducts = productTypesByCategory[item.category] ?? []
                    Picker("Product", selection: $item.product) {
                        if !standardProducts.contains(item.product) && !item.product.isEmpty {
                            Text(item.product).tag(item.product)
                        }
                        ForEach(standardProducts, id: \.self) { prod in Text(prod).tag(prod) }
                    }
                }

                Section {
                    ColorSwatchPicker(colors: $item.colors)
                } header: {
                    Text("Colors")
                } footer: {
                    Text(item.colors.isEmpty ? "Pick at least one color." : "Main color first: \(item.colors.joined(separator: ", "))")
                }

                Section("Look") {
                    Picker("Pattern", selection: $item.pattern) {
                        ForEach(Pattern.allCases) { pat in Text(pat.rawValue).tag(pat) }
                    }
                    TextField("Material (e.g. Cotton, Denim, Wool)", text: $item.material)
                    TextField("Brand (e.g. Nike)", text: $item.brand)
                }

                let cat = item.category
                if cat.supportsFit || cat.supportsNeckline || cat.supportsSleeves || cat.supportsLength {
                    Section("Cut") {
                        if cat.supportsFit {
                            Picker("Fit", selection: Binding(get: { item.fit ?? .regular }, set: { item.fit = $0 })) {
                                ForEach(Fit.allCases) { f in Text(f.rawValue).tag(f) }
                            }
                        }
                        if cat.supportsNeckline {
                            Picker("Neckline", selection: Binding(get: { item.neckline ?? .crewNeck }, set: { item.neckline = $0 })) {
                                ForEach(Neckline.allCases) { n in Text(n.rawValue).tag(n) }
                            }
                        }
                        if cat.supportsSleeves {
                            Picker("Sleeve length", selection: Binding(get: { item.sleeveLength ?? .longSleeve }, set: { item.sleeveLength = $0 })) {
                                ForEach(SleeveLength.allCases) { s in Text(s.rawValue).tag(s) }
                            }
                        }
                        if cat.supportsLength {
                            Picker("Length", selection: Binding(get: { item.garmentLength ?? .fullLength }, set: { item.garmentLength = $0 })) {
                                ForEach(GarmentLength.allCases) { l in Text(l.rawValue).tag(l) }
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField("e.g. ribbed cuffs, front zip, logo on chest", text: $item.details, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .tint(DS.Colors.accent)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.backgroundPrimary)
            .navigationTitle(item.product)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Skeleton Placeholder

private struct SkeletonItemCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                                     startPoint: .top, endPoint: .bottom))
                .aspectRatio(1, contentMode: .fit)
            SkeletonBlock(width: 90, height: 12)
            SkeletonBlock(width: 60, height: 10)
        }
        .padding(DS.Spacing.xs)
        .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shimmering()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding clothes")
    }
}
