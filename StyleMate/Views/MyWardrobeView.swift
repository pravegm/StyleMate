import SwiftUI

/// The closet: every item as a cutout on a studio backdrop, on shelves (Tops &
/// layers, Bottoms, Dresses, Footwear, Bags, Accessories, Jewelry), with pinned
/// filter chips (shelf, colour, pattern), sort (newest, colour, worn most /
/// least / recently — from the outfit log), search, multi-select removal and a
/// zoom into each item's page.
///
/// iPhone / Duo cover display: one stack (grid → item page).
/// Wide (Duo inner display, regular width): a split view — shelves, sort and
/// colours in the sidebar, the grid (up to 5 columns) beside the item page.
struct MyWardrobeView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var outfitsViewModel: MyOutfitsViewModel
    @Binding var showAddSheet: Bool
    @Environment(\.duoLayout) private var duo

    @State private var filter = ClosetFilter()
    @AppStorage("closet.sort") private var sort: ClosetSort = .newest
    @AppStorage("closet.groupBySection") private var groupBySection = true
    @AppStorage("closet.largeTiles") private var largeTiles = false

    @State private var wear: [UUID: WearStat] = [:]
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmBulkRemove = false
    @State private var pendingRemoval: WardrobeItem? = nil
    /// The pushed item page (phone / cover display).
    @State private var detailItem: WardrobeItem? = nil
    /// The item in the page pane (wide). Separate from `detailItem`, so folding
    /// to the cover display never finds a stale push waiting (the pane
    /// auto-shows the first item).
    @State private var paneItem: WardrobeItem? = nil
    /// The pane's item was picked by the person (not the automatic first one).
    @State private var paneIsChosen = false
    @State private var editingItem: WardrobeItem? = nil
    @Namespace private var zoomNS

    private var isWide: Bool { duo.isWideLayout }

    private var columns: [GridItem] {
        // Wide: an even count in the grid's pane (the crease falls between panes).
        if isWide {
            return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: largeTiles ? 2 : 4)
        }
        return [GridItem(.adaptive(minimum: largeTiles ? 150 : 100), spacing: 10, alignment: .top)]
    }

    var body: some View {
        Group {
            if isWide { splitCloset } else { stackCloset }
        }
        .sheet(item: $editingItem) { item in
            EditWardrobeItemView(item: item) { updated in
                ClosetActions.update(updated, in: wardrobeViewModel)
            }
        }
        .confirmationDialog(bulkTitle, isPresented: $confirmBulkRemove, titleVisibility: .visible) {
            Button("Remove \(selection.count) item\(selection.count == 1 ? "" : "s")", role: .destructive) {
                removeSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be removed from your wardrobe and iCloud. Your photos aren't touched.")
        }
        .confirmationDialog("Remove this item?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { item in
            Button("Remove from Wardrobe", role: .destructive) {
                Haptics.warning()
                if detailItem?.id == item.id { detailItem = nil }
                if paneItem?.id == item.id { paneItem = nil }
                ClosetActions.remove([item], from: wardrobeViewModel)
                pendingRemoval = nil
                showFirstItemIfNeeded()
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Use this when it isn't yours or was picked up by mistake. Your photos aren't touched.")
        }
        .onReceive(outfitsViewModel.$outfitsByDate) { wear = ClosetWear.stats(from: $0) }
        .onChange(of: wardrobeViewModel.items.count) { _ in
            // Drop selections of items that are gone.
            let ids = Set(wardrobeViewModel.items.map(\.id))
            selection.formIntersection(ids)
            if let d = detailItem, !ids.contains(d.id) { detailItem = nil }
            if let p = paneItem, !ids.contains(p.id) { paneItem = nil }
            if wardrobeViewModel.items.isEmpty { isSelecting = false }
        }
        // Unfolding keeps an open item page (it moves into the pane); folding to
        // the cover returns to the grid.
        .onChange(of: isWide) { wide in
            if wide {
                if let d = detailItem { paneItem = d; paneIsChosen = true }
                detailItem = nil
            } else {
                // Folding: a page the person opened stays open (pushed); the
                // pane's automatic first item doesn't.
                detailItem = paneIsChosen ? paneItem : nil
            }
        }
    }

    /// Opens an item: pushed on a phone, in the page pane when wide.
    private func open(_ item: WardrobeItem) {
        if isWide {
            paneItem = item
            paneIsChosen = true
        } else {
            detailItem = item
        }
    }

    // MARK: - Phone: one stack

    private var stackCloset: some View {
        NavigationStack {
            closetContent(showsFilterBar: true)
                .navigationTitle("Wardrobe")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $filter.query, placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "Search name, color, brand")
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) {
                    if isSelecting { selectionBar }
                }
                .navigationDestination(item: $detailItem) { item in
                    ItemDetailView(item: item, wear: wear[item.id]) { removed in
                        removeAfterPop(removed)
                    }
                    .navigationTransition(.zoom(sourceID: item.id, in: zoomNS))
                }
        }
    }

    // MARK: - Wide: grid | item page

    /// Grid (filters pinned on top) beside the item page. `FoldAwareSplit` puts
    /// the split on the crease when the Duo is half-open, so no tile or the page
    /// ever straddles the fold; flat it is an even two-pane split.
    private var splitCloset: some View {
        NavigationStack {
            FoldAwareSplit(gutter: DS.Spacing.md, stackedSpacing: 0) {
                closetContent(showsFilterBar: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom) {
                        if isSelecting { selectionBar }
                    }
            } trailing: {
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("Wardrobe")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter.query, prompt: "Search name, color, brand")
            .toolbar { toolbar }
            .onAppear { showFirstItemIfNeeded() }
            .onChange(of: wardrobeViewModel.items.count) { _ in showFirstItemIfNeeded() }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = paneItem {
            ItemDetailView(item: item, wear: wear[item.id], embedded: true) { removed in
                paneItem = nil
                withAnimation(DS.Motion.smooth) {
                    ClosetActions.remove([removed], from: wardrobeViewModel)
                }
                showFirstItemIfNeeded()
            }
            .id(item.id)
            .transition(.opacity)
        } else {
            ContentUnavailableView("Pick an item",
                                   systemImage: "hanger",
                                   description: Text("Its details, colors and wear history show here."))
        }
    }

    /// Wide layout: the page pane is never empty while there's something to show.
    private func showFirstItemIfNeeded() {
        guard isWide, paneItem == nil else { return }
        paneItem = ClosetEngine.apply(wardrobeViewModel.items, filter: filter, sort: sort, wear: wear).first
        paneIsChosen = false
    }

    // MARK: - Closet

    @ViewBuilder
    private func closetContent(showsFilterBar: Bool) -> some View {
        let all = wardrobeViewModel.items
        let visible = ClosetEngine.apply(all, filter: filter, sort: sort, wear: wear)
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()
            if all.isEmpty {
                emptyCloset
            } else {
                closet(all: all, visible: visible, showsFilterBar: showsFilterBar)
            }
        }
    }

    @ViewBuilder
    private func closet(all: [WardrobeItem], visible: [WardrobeItem], showsFilterBar: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                summaryHeader(all: all)
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.sm)
                    .padding(.top, showsFilterBar ? 0 : DS.Spacing.sm)

                Section {
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        ClosetScanStatus()
                        LockedItemsCard()   // "23 more pieces found — unlock with Premium"
                        if filter.isActive {
                            resultLine(count: visible.count, total: all.count)
                        }
                        if visible.isEmpty {
                            DSEmptyState(
                                icon: "magnifyingglass",
                                title: "No matches",
                                message: "Nothing in your wardrobe fits these filters. Try another color, type or search.",
                                actionTitle: "Clear filters",
                                action: { withAnimation(DS.Motion.snappy) { filter = ClosetFilter() } }
                            )
                        } else if groupBySection && filter.section == nil {
                            ForEach(ClosetEngine.grouped(visible)) { group in
                                shelf(title: group.section.title, items: group.items)
                            }
                        } else {
                            shelf(title: filter.section?.title ?? sort.title, items: visible)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.xxl)
                } header: {
                    if showsFilterBar {
                        ClosetFilterBar(
                            filter: $filter, sort: $sort, groupBySection: $groupBySection, largeTiles: $largeTiles,
                            counts: ClosetEngine.counts(all), total: all.count,
                            swatches: ClosetColor.swatches(for: all),
                            patterns: ClosetEngine.patterns(in: all),
                            hasWearLog: !wear.isEmpty
                        )
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func summaryHeader(all: [WardrobeItem]) -> some View {
        let shelves = ClosetEngine.counts(all).count
        return Text("\(all.count) \(all.count == 1 ? "piece" : "pieces") · \(shelves) \(shelves == 1 ? "shelf" : "shelves")")
            .font(DS.Font.subheadline)
            .foregroundStyle(DS.Colors.textSecondary)
            .monospacedDigit()
            .accessibilityIdentifier("closet.summary")
    }

    private func resultLine(count: Int, total: Int) -> some View {
        HStack {
            Text("Showing \(count) of \(total)")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .monospacedDigit()
            Spacer()
            Button("Clear all") {
                Haptics.light()
                withAnimation(DS.Motion.snappy) { filter = ClosetFilter() }
            }
            .font(DS.Font.footnote.weight(.semibold))
            .foregroundStyle(DS.Colors.accent)
            .frame(minHeight: 44)
        }
    }

    private func shelf(title: String, items: [WardrobeItem]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ClosetShelfHeader(title: title, count: items.count)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    cell(item)
                }
            }
        }
    }

    private func cell(_ item: WardrobeItem) -> some View {
        let selected = selection.contains(item.id)
        let isOpen = isWide && paneItem?.id == item.id
        return Button {
            if isSelecting {
                Haptics.selection()
                if selected { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
                open(item)
            }
        } label: {
            ClosetItemCell(item: item, isSelecting: isSelecting, isSelected: selected || isOpen,
                           showsCaption: largeTiles || isWide)
        }
        .buttonStyle(DSTapBounce())
        .matchedTransitionSource(id: item.id, in: zoomNS)
        .accessibilityIdentifier("closet.item.\(item.id.uuidString)")
        .contextMenu {
            if !isSelecting {
                Button { open(item) } label: { Label("View", systemImage: "eye") }
                Button { editingItem = item } label: { Label("Edit details", systemImage: "pencil") }
                Button {
                    withAnimation(DS.Motion.snappy) {
                        isSelecting = true
                        selection = [item.id]
                    }
                } label: { Label("Select", systemImage: "checkmark.circle") }
                Divider()
                Button(role: .destructive) { pendingRemoval = item } label: {
                    Label("Remove from Wardrobe", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Empty closet

    private var emptyCloset: some View {
        ScrollView {
            ClosetScanGate {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    ClosetScanStatus()
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Building your wardrobe")
                            .font(DS.Font.title3)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Clothes appear here as they're found in your photos.")
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    ClosetSkeletonGrid(columns: columns)
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.top, DS.Spacing.md)
            } idle: {
                VStack(spacing: DS.Spacing.lg) {
                    DSEmptyState(
                        icon: "hanger",
                        title: "Your wardrobe is empty",
                        message: "StyleMate finds the clothes you wear in your photos and lays them out here — all on your phone.",
                        actionTitle: "Add clothes",
                        action: { showAddSheet = true }
                    )
                    shelfPreview
                }
                .padding(.top, DS.Spacing.xl)
                .padding(.horizontal, DS.Spacing.screenH)
            }
        }
    }

    /// A row of the shelves-to-come, so the empty closet shows what it will be.
    private var shelfPreview: some View {
        FlowLayout(spacing: DS.Spacing.xs) {
            ForEach(ClosetSection.allCases) { s in
                Label(s.chipTitle, systemImage: s.iconName)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(DS.Colors.backgroundCard, in: Capsule(style: .continuous))
            }
        }
        .frame(maxWidth: 340)
        .accessibilityHidden(true)
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // One group, so Select and + always sit together (the Duo's cover
        // display otherwise floated + into its trailing rail).
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !wardrobeViewModel.items.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    Haptics.light()
                    withAnimation(DS.Motion.snappy) {
                        isSelecting.toggle()
                        selection = []
                    }
                }
                .fontWeight(isSelecting ? .semibold : .regular)
                .accessibilityIdentifier("closet.select")
            }
            if !isSelecting {
                Button {
                    Haptics.medium()
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Add clothes")
                .accessibilityIdentifier("closet.add")
            }
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let visible = ClosetEngine.apply(wardrobeViewModel.items, filter: filter, sort: sort, wear: wear)
                let allVisibleSelected = !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
                Button(allVisibleSelected ? "Deselect all" : "Select all") {
                    Haptics.light()
                    if allVisibleSelected { selection.subtract(visible.map(\.id)) }
                    else { selection.formUnion(visible.map(\.id)) }
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: DS.Spacing.md) {
            Text(selection.isEmpty ? "Select items" : "\(selection.count) selected")
                .font(DS.Font.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
            Spacer()
            Button(role: .destructive) {
                Haptics.medium()
                confirmBulkRemove = true
            } label: {
                Label("Remove", systemImage: "trash")
                    .font(DS.Font.headline)
                    .foregroundStyle(selection.isEmpty ? DS.Colors.textSecondary : DS.Colors.error)
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(height: 44)
                    .background((selection.isEmpty ? DS.Colors.fill : DS.Colors.error.opacity(0.12)),
                                in: Capsule(style: .continuous))
            }
            .buttonStyle(DSTapBounce())
            .disabled(selection.isEmpty)
            .accessibilityHint("Removes the selected items from your wardrobe")
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.vertical, DS.Spacing.sm)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var bulkTitle: String {
        "Remove \(selection.count) item\(selection.count == 1 ? "" : "s")?"
    }

    // MARK: - Removal

    private func removeSelected() {
        let doomed = wardrobeViewModel.items.filter { selection.contains($0.id) }
        Haptics.warning()
        withAnimation(DS.Motion.smooth) {
            ClosetActions.remove(doomed, from: wardrobeViewModel)
            selection = []
            isSelecting = false
        }
    }

    /// Pop the detail page first so the zoom animates back to the tile, then remove.
    private func removeAfterPop(_ item: WardrobeItem) {
        detailItem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(DS.Motion.smooth) {
                ClosetActions.remove([item], from: wardrobeViewModel)
            }
        }
    }
}

// MARK: - Wear stats from the outfit log

extension ClosetWear {
    /// Wear counts from the Core Data outfit log (`MyOutfitsViewModel.outfitsByDate`).
    static func stats(from outfitsByDate: [Date: [DatedOutfit]]) -> [UUID: WearStat] {
        let logs: [Log] = outfitsByDate.values.flatMap { $0 }.map { outfit in
            let ids: [UUID] = (outfit.items as? Set<OutfitItem>)?.compactMap { $0.id } ?? []
            return (date: outfit.date ?? .distantPast, itemIDs: ids)
        }
        return stats(from: logs)
    }
}

// MARK: - Category Icon Mapping

extension Category {
    /// SF Symbols that read as the garment (no weather / furniture glyphs).
    var iconName: String {
        switch self {
        case .tops:        return "tshirt"
        case .bottoms:     return "figure.walk"
        case .midLayers:   return "square.stack"
        case .outerwear:   return "hanger"
        case .onePieces:   return "figure.stand.dress"
        case .footwear:    return "shoe"
        case .accessories: return "handbag"
        case .innerwear:   return "tshirt"
        case .activewear:  return "figure.run"
        case .ethnicWear:  return "sparkles"
        }
    }
}

// MARK: - Preview Image Wrapper

struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Category page (opened from Home's wardrobe summary)

/// One category's items as closet tiles, with product chips (preselected when
/// Home opens it for a product). Tapping a tile zooms into the item's page.
struct CategoryDetailView: View {
    let category: Category
    var initialProduct: String? = nil
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var outfitsViewModel: MyOutfitsViewModel

    @State private var product: String? = nil
    @State private var didApplyInitial = false
    @State private var wear: [UUID: WearStat] = [:]
    @State private var detailItem: WardrobeItem? = nil
    @Namespace private var zoomNS

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10, alignment: .top)]

    private var items: [WardrobeItem] {
        Array(wardrobeViewModel.items.filter { $0.category == category }.reversed())
    }

    private static func key(_ product: String) -> String {
        ClosetText.wordList(product).joined(separator: " ")
    }

    /// Distinct products (merging "Jean"/"Jeans"), most common first.
    private var products: [String] {
        var counts: [String: (name: String, n: Int)] = [:]
        for item in items {
            let k = Self.key(item.product)
            counts[k] = (counts[k]?.name ?? item.product, (counts[k]?.n ?? 0) + 1)
        }
        return counts.values.sorted { ($0.n, $1.name) > ($1.n, $0.name) }.map(\.name)
    }

    private var shown: [WardrobeItem] {
        guard let product else { return items }
        let k = Self.key(product)
        return items.filter { Self.key($0.product) == k }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                DSEmptyState(
                    icon: category.iconName,
                    title: "No \(category.rawValue.lowercased()) yet",
                    message: "They'll appear here once they're found in your photos or added."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        if products.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: DS.Spacing.xs) {
                                    ClosetChip(title: "All", count: items.count, isSelected: product == nil) {
                                        product = nil
                                    }
                                    ForEach(products, id: \.self) { p in
                                        ClosetChip(title: ClosetText.displayProduct(p),
                                                   isSelected: product.map(Self.key) == Self.key(p)) {
                                            product = p
                                        }
                                    }
                                }
                                .padding(.horizontal, DS.Spacing.screenH)
                            }
                        }
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(shown) { item in
                                Button {
                                    detailItem = item
                                } label: {
                                    ClosetItemCell(item: item)
                                }
                                .buttonStyle(DSTapBounce())
                                .matchedTransitionSource(id: item.id, in: zoomNS)
                                .accessibilityIdentifier("closet.item.\(item.id.uuidString)")
                            }
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                    }
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.xxl)
                    .animation(DS.Motion.snappy, value: product)
                }
            }
        }
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
        .navigationTitle(category.rawValue)
        .onAppear {
            guard !didApplyInitial else { return }
            didApplyInitial = true
            if let initialProduct, items.contains(where: { Self.key($0.product) == Self.key(initialProduct) }) {
                product = initialProduct
            }
        }
        .onReceive(outfitsViewModel.$outfitsByDate) { wear = ClosetWear.stats(from: $0) }
        .navigationDestination(item: $detailItem) { item in
            ItemDetailView(item: item, wear: wear[item.id]) { removed in
                detailItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    ClosetActions.remove([removed], from: wardrobeViewModel)
                }
            }
            .navigationTransition(.zoom(sourceID: item.id, in: zoomNS))
        }
    }
}

// MARK: - Zoomable Image

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let frameSize = geometry.size
            let imageAspect = image.size.width / image.size.height
            let frameAspect = frameSize.width / frameSize.height
            let (displayWidth, displayHeight): (CGFloat, CGFloat) = {
                if imageAspect > frameAspect {
                    return (frameSize.width, frameSize.width / imageAspect)
                } else {
                    return (frameSize.height * imageAspect, frameSize.height)
                }
            }()
            let maxOffsetX = max(0, (displayWidth * scale - frameSize.width) / 2)
            let maxOffsetY = max(0, (displayHeight * scale - frameSize.height) / 2)
            let clampedOffset = CGSize(
                width: min(max(offset.width, -maxOffsetX), maxOffsetX),
                height: min(max(offset.height, -maxOffsetY), maxOffsetY)
            )

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: frameSize.width, height: frameSize.height)
                .scaleEffect(scale)
                .offset(scale > 1 ? clampedOffset : .zero)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = lastScale * value
                                scale = max(1.0, min(newScale, 5.0))
                                if scale == 1.0 { offset = .zero; lastOffset = .zero }
                            }
                            .onEnded { value in
                                lastScale = max(1.0, min(lastScale * value, 5.0))
                                if scale == 1.0 { offset = .zero; lastOffset = .zero }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                guard scale > 1 else { offset = .zero; lastOffset = .zero; return }
                                let clamped = CGSize(
                                    width: min(max(offset.width, -maxOffsetX), maxOffsetX),
                                    height: min(max(offset.height, -maxOffsetY), maxOffsetY)
                                )
                                offset = clamped
                                lastOffset = clamped
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(DS.Motion.snappy) {
                        if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                        else { scale = 2.5; lastScale = 2.5 }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scale)
        }
        .clipped()
    }
}

#Preview {
    MyWardrobeView(showAddSheet: .constant(false))
        .environmentObject(WardrobeViewModel())
        .environmentObject(MyOutfitsViewModel())
}
