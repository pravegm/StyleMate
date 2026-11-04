import SwiftUI

// MARK: - Outfit board
//
// One look as a composed flat-lay, like a stylist's board: layers over the top
// on the left, the bottom (or a one-piece) on the right, and shoes, bag and
// accessories in a centred row underneath. Every cell is sized from the space
// the board is given, so up to six pieces always fit without scrolling.
//
// Interactive boards show a selected piece's Keep / Swap controls in a glass
// capsule; thumbnail boards (the option strip) are plain pictures.

struct OutfitBoard: View {
    let items: [WardrobeItem]
    var selectedID: UUID? = nil
    var lockedIDs: Set<UUID> = []
    var isThumbnail = false
    /// Show Keep / Swap under the selected piece (phone). Off where a list next
    /// to the board carries those controls (wide layout).
    var showsControls = true
    var swapDisabled = false
    /// Room left free at the bottom (for a hint or chip drawn over the board).
    var bottomInset: CGFloat = 0
    var onTap: (WardrobeItem) -> Void = { _ in }
    var onKeep: (WardrobeItem) -> Void = { _ in }
    var onSwap: (WardrobeItem) -> Void = { _ in }
    var onPreview: (WardrobeItem) -> Void = { _ in }

    struct Arrangement: Equatable {
        var left: [WardrobeItem] = []
        var right: [WardrobeItem] = []
        var lower: [WardrobeItem] = []
    }

    /// Which piece goes where. Pure, so the layout is predictable.
    static func arrange(_ items: [WardrobeItem]) -> Arrangement {
        var a = Arrangement()
        var upper: [WardrobeItem] = []
        var bottoms: [WardrobeItem] = []
        var onePieces: [WardrobeItem] = []
        for item in items {
            switch ClosetSection.of(item) {
            case .tops: upper.append(item)
            case .bottoms: bottoms.append(item)
            case .dresses: onePieces.append(item)
            case .footwear, .bags, .accessories, .jewelry: a.lower.append(item)
            }
        }
        // Outer layer first (top of the column), then the mid-layer, then the top.
        upper.sort { $0.category.wearingOrder < $1.category.wearingOrder }
        if bottoms.isEmpty {
            a.left = upper
            a.right = onePieces
        } else {
            a.left = upper + onePieces
            a.right = bottoms
        }
        a.lower.sort { lowerRank($0) < lowerRank($1) }
        return a
    }

    private static func lowerRank(_ item: WardrobeItem) -> Int {
        switch ClosetSection.of(item) {
        case .footwear: return 0
        case .bags: return 1
        case .accessories: return 2
        default: return 3
        }
    }

    var body: some View {
        GeometryReader { geo in
            let a = Self.arrange(items)
            let pad: CGFloat = isThumbnail ? 5 : DS.Spacing.md
            let gap: CGFloat = isThumbnail ? 3 : DS.Spacing.sm
            let w = max(0, geo.size.width - pad * 2)
            let h = max(0, geo.size.height - pad * 2 - bottomInset)
            let split = Self.split(a, height: h, gap: gap)

            VStack(spacing: gap) {
                if split.upper > 0 {
                    upper(a, width: w, height: split.upper, gap: gap)
                }
                if split.lower > 0 {
                    row(a.lower, width: w, height: split.lower, gap: gap, maxCellWidth: max(0, (w - gap) / 2))
                }
            }
            .frame(width: w, height: h)
            .padding(pad)
            .padding(.bottom, bottomInset)
        }
    }

    /// Heights of the upper block and the lower row.
    private static func split(_ a: Arrangement, height: CGFloat, gap: CGFloat) -> (upper: CGFloat, lower: CGFloat) {
        let hasUpper = !a.left.isEmpty || !a.right.isEmpty
        if a.lower.isEmpty { return (hasUpper ? height : 0, 0) }
        if !hasUpper { return (0, height) }
        let lower = min(height * 0.28, 180)
        return (max(0, height - lower - gap), lower)
    }

    @ViewBuilder
    private func upper(_ a: Arrangement, width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        if !a.left.isEmpty && !a.right.isEmpty {
            let colW = max(0, (width - gap) / 2)
            HStack(spacing: gap) {
                column(a.left, width: colW, height: height, gap: gap)
                column(a.right, width: colW, height: height, gap: gap)
            }
        } else {
            row(a.left.isEmpty ? a.right : a.left, width: width, height: height, gap: gap,
                maxCellWidth: width * 0.62)
        }
    }

    private func column(_ list: [WardrobeItem], width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        let n = CGFloat(max(list.count, 1))
        let cellH = max(0, (height - gap * (n - 1)) / n)
        return VStack(spacing: gap) {
            ForEach(list) { item in
                piece(item).frame(width: width, height: cellH)
            }
        }
    }

    private func row(_ list: [WardrobeItem], width: CGFloat, height: CGFloat, gap: CGFloat,
                     maxCellWidth: CGFloat) -> some View {
        let n = CGFloat(max(list.count, 1))
        let cellW = max(0, min((width - gap * (n - 1)) / n, maxCellWidth))
        return HStack(spacing: gap) {
            ForEach(list) { item in
                piece(item).frame(width: cellW, height: height)
            }
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func piece(_ item: WardrobeItem) -> some View {
        if isThumbnail {
            BoardCutout(item: item, path: item.gridImagePath, shadowRadius: 2)
                .accessibilityHidden(true)
        } else {
            BoardPiece(
                item: item,
                isSelected: selectedID == item.id,
                isKept: lockedIDs.contains(item.id),
                showsControls: showsControls,
                swapDisabled: swapDisabled,
                onTap: { onTap(item) },
                onKeep: { onKeep(item) },
                onSwap: { onSwap(item) },
                onPreview: { onPreview(item) }
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}

// MARK: - A piece on the board

private struct BoardPiece: View {
    let item: WardrobeItem
    let isSelected: Bool
    let isKept: Bool
    let showsControls: Bool
    let swapDisabled: Bool
    let onTap: () -> Void
    let onKeep: () -> Void
    let onSwap: () -> Void
    let onPreview: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: onTap) {
                BoardCutout(item: item, path: item.fullImagePath)
                    .padding(isSelected ? 10 : 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .fill(isSelected ? DS.Colors.accentSoft : Color.clear)
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(isSelected ? DS.Colors.accent.opacity(0.55) : Color.clear, lineWidth: 1.5)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(DSTapBounce())
            .accessibilityLabel(ClosetText.displayName(item))
            .accessibilityValue(isKept ? "Kept" : "")
            .accessibilityHint(showsControls ? "Shows Keep and Swap" : "Opens a larger view")
            .accessibilityIdentifier("outfit.piece.\(item.id.uuidString)")
            .contextMenu { menu }

            if showsControls && isSelected {
                HStack(spacing: 2) {
                    PieceActionButton(kind: .keep, item: item, isOn: isKept, action: onKeep)
                    PieceActionButton(kind: .swap, item: item, disabled: swapDisabled || isKept, action: onSwap)
                }
                .padding(3)
                .dsGlassCapsule()
                .padding(.bottom, 6)
                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if isKept {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(DS.Colors.accent, in: Circle())
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(action: onKeep) {
            Label(isKept ? "Don't keep" : "Keep", systemImage: isKept ? "lock.open" : "lock")
        }
        Button(action: onSwap) {
            Label("Swap", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(swapDisabled || isKept)
        Button(action: onPreview) {
            Label("View larger", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }
}

// MARK: - Keep / Swap button (44 × 44)

struct PieceActionButton: View {
    enum Kind { case keep, swap }

    let kind: Kind
    let item: WardrobeItem
    var isOn: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    private var symbol: String {
        switch kind {
        case .keep: return isOn ? "lock.fill" : "lock.open"
        case .swap: return "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(kind == .keep && isOn ? Color.white : DS.Colors.accent)
                .frame(width: 44, height: 44)
                .background {
                    if kind == .keep && isOn { Circle().fill(DS.Colors.accent) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(DSTapBounce())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel("\(kind == .keep ? "Keep" : "Swap") \(StyleVocabulary.describe(item))")
        .accessibilityValue(kind == .keep ? (isOn ? "Kept" : "Not kept") : "")
        .accessibilityAddTraits(kind == .keep && isOn ? .isSelected : [])
        .accessibilityIdentifier("outfit.\(kind == .keep ? "keep" : "swap").\(item.id.uuidString)")
    }
}

// MARK: - Cutout (async, never decoded in body)

/// A garment cutout fitted into its cell with a soft contact shadow. Loads off
/// the main thread through `ClosetImageLoader` (cached images show instantly).
struct BoardCutout: View {
    let item: WardrobeItem
    let path: String?
    var shadowRadius: CGFloat = 6

    @State private var image: UIImage?

    init(item: WardrobeItem, path: String?, shadowRadius: CGFloat = 6) {
        self.item = item
        self.path = path
        self.shadowRadius = shadowRadius
        _image = State(initialValue: ClosetImageLoader.shared.cached(path)
                       ?? ClosetImageLoader.shared.cached(item.gridImagePath))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.10), radius: shadowRadius, x: 0, y: shadowRadius * 0.66)
            } else {
                Image(systemName: item.category.iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            if let loaded = await ClosetImageLoader.shared.load(path) {
                image = loaded
            } else if image == nil, let fallback = await ClosetImageLoader.shared.load(item.gridImagePath) {
                image = fallback
            }
        }
    }
}

// MARK: - Studio surface

/// The board's backdrop: the same warm studio sweep as the closet tiles, so a
/// look reads as one lookbook page in light and dark.
struct StudioSurface: View {
    var body: some View {
        LinearGradient(colors: [DS.Colors.studioTop, DS.Colors.studioBottom],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 2 × 2 cutout collage (logged outfits)

/// Up to four cutouts in a 2 × 2 grid on the studio backdrop, with "+N" when a
/// logged outfit has more. Paths are loaded asynchronously.
struct CutoutCollage: View {
    let paths: [String?]
    var cornerRadius: CGFloat = DS.Radius.card

    var body: some View {
        let shown = Array(paths.prefix(4))
        let extra = paths.count - shown.count
        ZStack(alignment: .bottomTrailing) {
            StudioSurface()
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                if shown.count <= 2 {
                    GridRow {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, p in CollageCell(path: p) }
                    }
                } else {
                    GridRow {
                        CollageCell(path: shown[0])
                        CollageCell(path: shown[1])
                    }
                    GridRow {
                        CollageCell(path: shown[2])
                        if shown.count > 3 { CollageCell(path: shown[3]) } else { Color.clear }
                    }
                }
            }
            .padding(8)
            if extra > 0 {
                Text("+\(extra)")
                    .font(DS.Font.caption1.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct CollageCell: View {
    let path: String?
    @State private var image: UIImage?

    init(path: String?) {
        self.path = path
        _image = State(initialValue: ClosetImageLoader.shared.cached(path))
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(4)
                        .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 2)
                }
            }
            .task(id: path) {
                if let loaded = await ClosetImageLoader.shared.load(path) { image = loaded }
            }
    }
}
