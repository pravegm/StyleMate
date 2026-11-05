import SwiftUI

// MARK: - Item cell

/// One closet tile: the item's cutout on the studio backdrop. In select mode it
/// shows a check and shrinks slightly when picked (like Photos).
struct ClosetItemCell: View {
    let item: WardrobeItem
    var isSelecting = false
    var isSelected = false
    var showsCaption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncItemTile(path: item.gridImagePath, cornerRadius: DS.Radius.control, inset: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Colors.accent, lineWidth: isSelected ? 3 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(isSelected ? DS.Colors.onAccent : Color.white, isSelected ? DS.Colors.accent : Color.black.opacity(0.18))
                            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(isSelected ? 0.92 : 1)
                .animation(DS.Motion.snappy, value: isSelected)
                .animation(DS.Motion.snappy, value: isSelecting)

            if showsCaption {
                Text(ClosetText.displayProduct(item.product))
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClosetText.displayName(item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelecting ? "Double-tap to select or deselect" : "Opens item details")
    }
}

// MARK: - Filter bar

/// The pinned bar under the title: shelf chips with counts, then sort, pattern
/// and colour swatches.
struct ClosetFilterBar: View {
    @Binding var filter: ClosetFilter
    @Binding var sort: ClosetSort
    @Binding var groupBySection: Bool
    @Binding var largeTiles: Bool
    let counts: [ClosetSection: Int]
    let total: Int
    let swatches: [String]
    let patterns: [Pattern]
    let hasWearLog: Bool

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ClosetChip(title: "All", count: total, isSelected: filter.section == nil) {
                        filter.section = nil
                    }
                    ForEach(ClosetSection.allCases) { section in
                        if let n = counts[section], n > 0 {
                            ClosetChip(title: section.chipTitle, systemImage: section.iconName, count: n,
                                       isSelected: filter.section == section) {
                                filter.section = filter.section == section ? nil : section
                            }
                            .accessibilityIdentifier("closet.filter.\(section.rawValue)")
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    sortMenu
                    if patterns.count > 1 { patternMenu }
                    if !swatches.isEmpty {
                        Rectangle().fill(DS.Colors.separator).frame(width: 1, height: 22)
                            .accessibilityHidden(true)
                        ForEach(swatches, id: \.self) { name in
                            ColorSwatchButton(name: name, isSelected: filter.colors.contains(name)) {
                                if filter.colors.contains(name) { filter.colors.remove(name) }
                                else { filter.colors.insert(name) }
                            }
                        }
                    }
                    if filter.hasFacets {
                        ClosetChip(title: "Clear", systemImage: "xmark", isSelected: false) {
                            filter.section = nil
                            filter.colors = []
                            filter.patterns = []
                        }
                        .accessibilityLabel("Clear filters")
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .background(.bar)
        .animation(DS.Motion.snappy, value: filter)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(ClosetSort.allCases) { s in
                    Label(s.title, systemImage: s.iconName).tag(s)
                }
            }
            if !hasWearLog && sort.usesWearLog {
                Text("Log outfits in Outfits to see what you wear most")
            }
            Divider()
            Toggle(isOn: $groupBySection) { Label("Group by type", systemImage: "square.stack.3d.up") }
            Toggle(isOn: $largeTiles) { Label("Larger tiles", systemImage: "square.grid.2x2") }
        } label: {
            ChipLabel(title: sort.title, systemImage: "arrow.up.arrow.down", isSelected: sort != .newest)
        }
        .accessibilityLabel("Sort, currently \(sort.title)")
    }

    private var patternMenu: some View {
        Menu {
            ForEach(patterns) { p in
                Button {
                    if filter.patterns.contains(p) { filter.patterns.remove(p) } else { filter.patterns.insert(p) }
                } label: {
                    if filter.patterns.contains(p) { Label(p.rawValue, systemImage: "checkmark") }
                    else { Text(p.rawValue) }
                }
            }
            if !filter.patterns.isEmpty {
                Divider()
                Button("Any pattern") { filter.patterns = [] }
            }
        } label: {
            let title: String = {
                switch filter.patterns.count {
                case 0: return "Pattern"
                case 1: return filter.patterns.first!.rawValue
                default: return "\(filter.patterns.count) patterns"
                }
            }()
            ChipLabel(title: title, systemImage: "circle.hexagongrid", isSelected: !filter.patterns.isEmpty)
        }
        .accessibilityLabel("Pattern filter")
    }
}

/// Capsule filter chip with an optional count.
struct ClosetChip: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            ChipLabel(title: title, systemImage: systemImage, count: count, isSelected: isSelected)
        }
        .buttonStyle(DSTapBounce())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(DS.Font.footnote.weight(.semibold))
            }
            Text(title)
                .font(DS.Font.subheadline.weight(isSelected ? .semibold : .regular))
            if let count {
                Text("\(count)")
                    .font(DS.Font.caption1)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textSecondary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textPrimary)
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                Capsule(style: .continuous).fill(DS.Colors.accentSoft)
                Capsule(style: .continuous).strokeBorder(DS.Colors.accent.opacity(0.35), lineWidth: 1)
            } else {
                Capsule(style: .continuous).fill(DS.Colors.backgroundCard)
                Capsule(style: .continuous).strokeBorder(DS.Colors.separator, lineWidth: 0.5)
            }
        }
        .contentShape(Capsule())
    }
}

/// A round colour swatch filter; a ring marks it selected.
struct ColorSwatchButton: View {
    let name: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Circle()
                .fill(ColorMapping.color(for: name))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(DS.Colors.accent, lineWidth: isSelected ? 2 : 0))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(DSTapBounce())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Filters by this color")
    }
}

// MARK: - Colour picker (editors)

/// Pick an item's colours from the on-device palette (plus any custom names it
/// already has). Order matters — the first pick is the main colour — so each
/// selected swatch shows its number.
struct ColorSwatchPicker: View {
    @Binding var colors: [String]

    private var options: [String] {
        ClosetColor.order + colors.filter { !ClosetColor.order.contains($0) && !$0.isEmpty }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: DS.Spacing.xs)], spacing: DS.Spacing.xs) {
            ForEach(options, id: \.self) { name in
                swatch(name, index: colors.firstIndex(of: name))
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func swatch(_ name: String, index: Int?) -> some View {
        Button {
            Haptics.selection()
            if let index { colors.remove(at: index) } else { colors.append(name) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(ColorMapping.color(for: name))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .padding(4)
                    .overlay(Circle().strokeBorder(DS.Colors.accent, lineWidth: index != nil ? 2.5 : 0))
                    .frame(width: 40, height: 40)
                if let index {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Colors.onAccent)
                        .frame(width: 16, height: 16)
                        .background(DS.Colors.accent, in: Circle())
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityValue(index.map { $0 == 0 ? "Selected, main color" : "Selected" } ?? "")
        .accessibilityAddTraits(index != nil ? .isSelected : [])
    }
}

// MARK: - Shelf header

struct ClosetShelfHeader: View {
    let title: String
    var systemImage: String? = nil
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(title)
                .font(DS.Font.title3)
                .foregroundStyle(DS.Colors.textPrimary)
            Text("\(count)")
                .font(DS.Font.subheadline)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(count) item\(count == 1 ? "" : "s")")
    }
}

// MARK: - Scan status

/// Shows the gallery scan's progress inside the closet. Observes the scan
/// service in its own small view so its frequent updates don't re-render the grid.
struct ClosetScanStatus: View {
    @ObservedObject private var scan = PhotoScanService.shared

    var body: some View {
        if scan.scanState == .scanning {
            HStack(spacing: DS.Spacing.sm) {
                ProgressView().tint(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.isPaused ? "Scan paused" : "Finding clothes in your photos")
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(detail)
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.sm)
            .background(DS.Colors.backgroundCard,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var detail: String {
        let found = "\(scan.itemsFound) new item\(scan.itemsFound == 1 ? "" : "s")"
        guard scan.totalPhotosToScan > 0 else { return found }
        return "\(scan.photosScanned) of \(scan.totalPhotosToScan) photos · \(found)"
    }
}

/// True while a gallery scan runs (for the empty closet's loading state).
struct ClosetScanGate<Scanning: View, Idle: View>: View {
    @ObservedObject private var scan = PhotoScanService.shared
    private let scanning: () -> Scanning
    private let idle: () -> Idle

    init(@ViewBuilder scanning: @escaping () -> Scanning, @ViewBuilder idle: @escaping () -> Idle) {
        self.scanning = scanning
        self.idle = idle
    }

    var body: some View {
        if scan.scanState == .scanning { scanning() } else { idle() }
    }
}

// MARK: - Loading skeleton

struct ClosetSkeletonGrid: View {
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SkeletonBlock(width: 140, height: 20)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                                             startPoint: .top, endPoint: .bottom))
                        .aspectRatio(1, contentMode: .fit)
                        .shimmering()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your wardrobe")
    }
}
