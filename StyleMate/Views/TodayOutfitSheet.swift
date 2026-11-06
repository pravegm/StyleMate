import SwiftUI

extension Notification.Name {
    /// Asks the tab shell to open the add-clothes sheet (the outfit sheet's gap card).
    static let showAddClothes = Notification.Name("StyleMate.showAddClothes")
}

/// "What should I wear today?" — the five looks, one at a time, each as a
/// composed outfit board.
///
/// Phone / cover display: stylist note, the board (tap a piece for Keep / Swap,
/// drag right to wear it, left to skip), then Skip + "Wear today".
/// Wide (Duo inner display, regular width): the board on the left (~55%), and
/// on the right the note, a Keep / Swap list, the actions and all five options.
struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    @EnvironmentObject var homeVM: HomeViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.duoLayout) private var duo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedPieceID: UUID? = nil
    @State private var lockedItemIDs: Set<UUID> = []
    @State private var previewItem: WardrobeItem? = nil
    @State private var showDatePicker = false
    @State private var logDate = Calendar.current.startOfDay(for: Date())
    @State private var showAddPiece = false
    @State private var toastText: String? = nil
    @State private var noticeDismissWork: DispatchWorkItem? = nil
    @State private var gapDismissed = false
    // Try-on: "On you | Pieces" (remembered), the full-screen viewer.
    // Pieces by default; On you is a Beta opt-in (lead decision, Nov 2026).
    @AppStorage("tryOn.mode") private var tryOnModeRaw = TryOnMode.pieces.rawValue
    @State private var fullScreenTryOn: TryOnFullScreenItem? = nil
    @ObservedObject private var tryOnQueue = TryOnQueue.shared

    // Drag to decide: right = wear today, left = skip. No stamps — the board's
    // edge tints and one haptic marks the threshold.
    @State private var dragX: CGFloat = 0
    @State private var pastThreshold = false
    /// The header's global x span, to keep its title off the fold.
    @State private var headerFrame: CGRect = .zero
    @State private var boardScale: CGFloat = 1
    @State private var boardOpacity: Double = 1
    @State private var isCommitting = false
    private let threshold: CGFloat = 110

    private var currentOutfit: Outfit? {
        guard homeVM.batchIndex < homeVM.outfitBatch.count else { return nil }
        return homeVM.outfitBatch[homeVM.batchIndex]
    }

    private var contextLine: String {
        var parts: [String] = []
        if let type = homeVM.selectedOutfitType { parts.append(type.rawValue) }
        if let mood = homeVM.selectedMood { parts.append(mood.label) }
        if let tempC = homeVM.lastCelsius {
            let temp = DSFormat.degrees(celsius: tempC, fahrenheit: homeVM.displayFahrenheit)
            parts.append("\(temp)°\(homeVM.displayFahrenheit ? "F" : "C")")
        }
        if let weather = homeVM.weather { parts.append(weather.displayDescription) }
        return parts.isEmpty ? "Styled for you" : parts.joined(separator: " · ")
    }

    private var counterText: String {
        let total = homeVM.outfitBatch.count
        guard total > 1 else { return "Today's outfit" }
        return "Option \(min(homeVM.batchIndex + 1, total)) of \(total)"
    }

    private func isWide(_ size: CGSize) -> Bool {
        duo.isWideLayout && size.width >= 560
    }

    private var tryOnMode: Binding<TryOnMode> {
        Binding(get: { TryOnMode(rawValue: tryOnModeRaw) ?? .pieces }, set: { tryOnModeRaw = $0.rawValue })
    }

    /// The look can be shown on a body (try-on on, and it has clothes to wear).
    private func tryOnActive(_ look: Outfit) -> Bool {
        _ = tryOnQueue.revision
        return TryOnAvailability.isAvailable && TryOnQueue.wearsOnBody(look.items)
    }

    /// Renders the next looks in the background (cool, not Low Power; see `TryOnQueue`).
    private func prerenderTryOns() {
        // Only for someone who opted into the Beta (On you selected).
        guard TryOnAvailability.isAvailable, tryOnMode.wrappedValue == .onYou else { return }
        let looks = homeVM.outfitBatch.map(\.items)
        let start = min(homeVM.batchIndex, max(0, looks.count - 1))
        TryOnQueue.shared.prerender(Array(looks.dropFirst(start).prefix(3)))
    }

    // MARK: - Body

    var body: some View {
        // Our own header row instead of a navigation bar: on the Duo's cover
        // display the system moves bar items into its trailing rail, which split
        // the close button from the title.
        // Hosted in a NavigationStack with its bar hidden, so the page sheet keeps
        // its full page size on the Duo's inner display.
        NavigationStack {
            VStack(spacing: 0) {
                header
                GeometryReader { geo in
                    ZStack {
                        if homeVM.allOutfitsSeen {
                            endOfBatchView
                        } else if let look = currentOutfit {
                            if isWide(geo.size) {
                                wideLayout(look, size: geo.size)
                            } else {
                                phoneLayout(look)
                            }
                        }

                        overlays
                    }
                }
            }
            // Inside the safe area: the sheet itself paints the rest (presentationBackground).
            .background(DS.Colors.backgroundPrimary)
            // First-generation coach tour (inside the stack: preferences don't cross it).
            .overlayPreferenceValue(CoachAnchorKey.self) { anchors in
                GeometryReader { geo in
                    if tutorialManager.activeTour == .generation {
                        CoachMarkOverlay(tutorial: tutorialManager, tour: .generation, anchors: anchors, proxy: geo)
                    }
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $previewItem) { item in
            FullItemImageViewer(path: item.fullImagePath, fallbackPath: item.gridImagePath,
                                title: ClosetText.displayName(item))
        }
        .fullScreenCover(item: $fullScreenTryOn) { item in
            TryOnFullScreenView(image: item.image, title: "On you")
        }
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .sheet(isPresented: $showAddPiece) { addPieceSheet }
        .onChange(of: tryOnModeRaw) { _ in prerenderTryOns() }
        .onChange(of: homeVM.batchIndex) { _ in
            // Keeps and the selection belong to one look.
            lockedItemIDs.removeAll()
            selectedPieceID = nil
            prerenderTryOns()
        }
        .onChange(of: homeVM.stylistNotice) { notice in
            guard notice != nil else { return }
            noticeDismissWork?.cancel()
            let work = DispatchWorkItem {
                withAnimation(DS.Motion.smooth) { homeVM.stylistNotice = nil }
            }
            noticeDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
        }
        .animation(DS.Motion.smooth, value: homeVM.stylistNotice)
        .onAppear {
            Haptics.prepare()
            prerenderTryOns()
            guard currentOutfit != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if currentOutfit != nil { tutorialManager.startIfFirstTime(.generation) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        // Open flat on the Duo the page sheet is centred on the fold, so a centred title sat on the seam: there
        // it goes beside the close button instead.
        let onFold = duo.foldRunsThrough(headerFrame)
        return HStack(spacing: DS.Spacing.xs) {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .frame(width: 44, height: 44)
                    .dsGlassCapsule()
            }
            .buttonStyle(DSTapBounce())
            .accessibilityLabel("Close")
            .accessibilityIdentifier("outfit.close")

            if !onFold { Spacer(minLength: 0) }

            Group {
                if homeVM.allOutfitsSeen || homeVM.outfitBatch.isEmpty {
                    Text("Today's outfit")
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    VStack(alignment: onFold ? .leading : .center, spacing: 5) {
                        Text(counterText)
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .monospacedDigit()
                        if homeVM.outfitBatch.count > 1 { progressDots }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(counterText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("outfit.counter")
                }
            }

            Spacer(minLength: 0)

            // Balances the close button so the title stays centred.
            if !onFold { Color.clear.frame(width: 44, height: 44).accessibilityHidden(true) }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.micro)
        .onGeometryChange(for: CGRect.self) { proxy in
            let r = proxy.frame(in: .global)
            return CGRect(x: r.minX, y: 0, width: r.width, height: 1)   // x only: the fold runs top to bottom
        } action: { headerFrame = $0 }
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<homeVM.outfitBatch.count, id: \.self) { idx in
                Capsule()
                    .fill(idx == homeVM.batchIndex ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.45))
                    .frame(width: idx == homeVM.batchIndex ? 14 : 6, height: 6)
            }
        }
        .animation(DSMotionEnv.resolve(DS.Motion.snappy, reduceMotion: reduceMotion), value: homeVM.batchIndex)
    }

    // MARK: - Phone layout

    private func phoneLayout(_ look: Outfit) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            noteCard(look, lineLimit: 4)
            boardCard(look, inlineControls: true)
                .frame(maxHeight: .infinity)
            if let gap = activeGap {
                gapCard(gap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            actionBar
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Wide layout (Duo inner display, regular width)

    /// Board | note, Keep / Swap list, actions, all options. `FoldAwareSplit`
    /// puts the split exactly on the crease when the Duo is half-open, so the
    /// board never straddles the fold.
    private func wideLayout(_ look: Outfit, size: CGSize) -> some View {
        let gutter = DS.Spacing.lg
        let onBody = tryOnActive(look) && tryOnMode.wrappedValue == .onYou
        return FoldAwareSplit(gutter: gutter, leadingFraction: 0.5) {
            // With try-on: the look on you on one pane, the pieces on the other (nothing on the crease).
            Group {
                if onBody { onBodyCard(look) } else { boardCard(look, inlineControls: false, wideToggle: tryOnActive(look)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } trailing: {
            VStack(spacing: DS.Spacing.sm) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        if onBody {
                            // Compact, so the Keep / Swap list starts on screen above the action bar
                            // (duo-crease: at 0.42 the list began hidden behind "Wear today").
                            boardCard(look, inlineControls: false, forcePieces: true)
                                .frame(height: max(180, size.height * 0.28))
                        }
                        noteCard(look, lineLimit: 4)
                        piecesList(look)
                        if let gap = activeGap { gapCard(gap) }
                        if homeVM.outfitBatch.count > 1 { optionsStrip }
                    }
                    .padding(.bottom, DS.Spacing.sm)
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                // The last rows fade out above the pinned bar, so a cut-off row reads as "scroll for more".
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                    }
                }
                // Pinned, so "Wear today" is never scrolled away or clipped.
                stackedActionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(gutter)
    }

    // MARK: - Stylist note

    private func noteCard(_ look: Outfit, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(contextLine.uppercased())
                    .font(DS.Font.caption2.weight(.semibold))
                    .tracking(0.4)
            } icon: {
                Image(systemName: "sparkles")
                    .font(DS.Font.caption2.weight(.semibold))
            }
            .foregroundStyle(DS.Colors.accent)
            .lineLimit(1)

            if !look.explanation.isEmpty {
                Text(look.explanation)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    // The on-device model may rewrite the note a beat later.
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: look.explanation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Board

    /// The look on the user's body (try-on), with the same card chrome and drag-to-decide as the board.
    private func onBodyCard(_ look: Outfit) -> some View {
        OutfitOnBodyView(items: look.items, priority: .user) { img in fullScreenTryOn = TryOnFullScreenItem(image: img) }
            .padding(.top, 52)
            .overlay(alignment: .top) {
                TryOnModeToggle(mode: tryOnMode).padding(.top, DS.Spacing.xs)
            }
            .studioIsland()
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .dsCardShadow(cornerRadius: DS.Radius.hero)
            .offset(x: reduceMotion ? 0 : dragX * (isCommitting ? 1 : 0.6))
            .scaleEffect(boardScale)
            .opacity(boardOpacity)
            .gesture(decideGesture)
    }

    private func boardCard(_ look: Outfit, inlineControls: Bool, forcePieces: Bool = false, wideToggle: Bool = false) -> some View {
        let progress = min(abs(dragX) / threshold, 1)
        let tint = dragX >= 0 ? DS.Colors.accent : DS.Colors.textSecondary
        // Wide layout (Duo inner display) in Pieces: the toggle sits on the board to switch the pane to On you.
        let showToggle = !forcePieces && (inlineControls || wideToggle) && tryOnActive(look)
        // "On you" when ready: the image replaces the board only once it exists; until then the board
        // stays interactive with a status chip ("Dressing you…").
        let wantsOnYou = showToggle && tryOnMode.wrappedValue == .onYou
        let ready: Bool = { if case .ready = tryOnQueue.state(for: look.items) { return true }; return false }()
        let onYou = wantsOnYou && ready
        return ZStack(alignment: .bottom) {
            if onYou {
                OutfitOnBodyView(items: look.items, priority: .user) { img in fullScreenTryOn = TryOnFullScreenItem(image: img) }
                    .padding(.top, 52)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                OutfitBoard(
                    items: look.items,
                    selectedID: inlineControls ? selectedPieceID : nil,
                    lockedIDs: lockedItemIDs,
                    showsControls: inlineControls,
                    swapDisabled: homeVM.isLoading,
                    bottomInset: 40,
                    onTap: { tap($0, inline: inlineControls) },
                    onKeep: { toggleKeep($0) },
                    onSwap: { swap($0) },
                    onPreview: { previewItem = $0 }
                )
                .padding(.top, showToggle ? 44 : 0)
                .coachAnchor(CoachAnchor.genLook)
                .transition(.opacity)

                Group {
                    if wantsOnYou && selectedPieceID == nil && lockedItemIDs.isEmpty {
                        TryOnStatusChip(items: look.items)
                    } else {
                        boardFooter(inlineControls: inlineControls)
                    }
                }
                .padding(.bottom, DS.Spacing.sm)
            }
        }
        .overlay(alignment: .top) {
            if showToggle {
                TryOnModeToggle(mode: tryOnMode)
                    .padding(.top, DS.Spacing.xs)
            }
        }
        .studioIsland()
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous)
                .strokeBorder(tint.opacity(progress * 0.9), lineWidth: 3)
                .allowsHitTesting(false)
        )
        .dsCardShadow(cornerRadius: DS.Radius.hero)
        .offset(x: reduceMotion ? 0 : dragX * (isCommitting ? 1 : 0.6))
        .scaleEffect(boardScale)
        .opacity(boardOpacity)
        .gesture(decideGesture)
        .animation(DS.Motion.smooth, value: look.items.map { $0.id })
        .animation(DS.Motion.snappy, value: selectedPieceID)
    }

    @ViewBuilder
    private func boardFooter(inlineControls: Bool) -> some View {
        if !lockedItemIDs.isEmpty {
            Button {
                shuffleRest()
            } label: {
                Label("\(lockedItemIDs.count) kept · Shuffle the rest", systemImage: "shuffle")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .dsGlassCapsule()
            }
            .buttonStyle(DSTapBounce())
            .disabled(homeVM.isLoading)
            .coachAnchor(CoachAnchor.genShuffle)
            .accessibilityIdentifier("outfit.shuffleRest")
        } else if selectedPieceID == nil {
            Text(inlineControls ? "Tap a piece to keep or swap it" : "Tap a piece to see it larger")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .frame(minHeight: 36)
                .coachAnchor(CoachAnchor.genShuffle)
        }
    }

    private var decideGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !isCommitting, abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
                let past = abs(dragX) > threshold
                if past != pastThreshold {
                    pastThreshold = past
                    if past { Haptics.selection() }
                }
            }
            .onEnded { _ in
                guard !isCommitting else { return }
                pastThreshold = false
                if dragX > threshold {
                    commit(.wear)
                } else if dragX < -threshold {
                    commit(.skip)
                } else {
                    withAnimation(DS.Motion.snappy) { dragX = 0 }
                }
            }
    }

    // MARK: - Keep / Swap list (wide)

    private func piecesList(_ look: Outfit) -> some View {
        let items = look.items.sorted { $0.category.wearingOrder < $1.category.wearingOrder }
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 68) }
                pieceRow(item)
            }
        }
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .animation(DS.Motion.smooth, value: items.map { $0.id })
    }

    private func pieceRow(_ item: WardrobeItem) -> some View {
        let kept = lockedItemIDs.contains(item.id)
        return HStack(spacing: DS.Spacing.sm) {
            Button {
                previewItem = item
            } label: {
                AsyncItemTile(path: item.gridImagePath, height: 40, cornerRadius: DS.Radius.chip, inset: 3)
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(ClosetText.displayName(item)) larger")

            VStack(alignment: .leading, spacing: 1) {
                // The short garment name ("Camel coat"), two lines when narrow.
                Text(StyleVocabulary.capitalizedFirst(StyleVocabulary.describe(item)))
                    .font(DS.Font.subheadline.weight(.medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if kept {
                    Text("Kept")
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            PieceActionButton(kind: .keep, item: item, isOn: kept) { toggleKeep(item) }
            PieceActionButton(kind: .swap, item: item, disabled: homeVM.isLoading || kept) { swap(item) }
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, 2)
    }

    // MARK: - All options strip (wide)

    private var optionsStrip: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("All \(homeVM.outfitBatch.count) options")
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            HStack(spacing: DS.Spacing.xs) {
                ForEach(Array(homeVM.outfitBatch.enumerated()), id: \.offset) { index, look in
                    let current = index == homeVM.batchIndex
                    Button {
                        jump(to: index)
                    } label: {
                        OutfitBoard(items: look.items, isThumbnail: true)
                            .aspectRatio(0.8, contentMode: .fit)
                            .studioIsland()
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .strokeBorder(current ? DS.Colors.accent : DS.Colors.separator,
                                                  lineWidth: current ? 2 : 0.5)
                            )
                            .overlay(alignment: .topLeading) {
                                Text("\(index + 1)")
                                    .font(DS.Font.caption2.weight(.bold))
                                    .foregroundStyle(current ? DS.Colors.accent : DS.Colors.textSecondary)
                                    .padding(5)
                            }
                    }
                    .buttonStyle(DSTapBounce())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Option \(index + 1)")
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Thin wardrobe

    struct WardrobeGap: Equatable {
        let title: String
        let icon: String
    }

    /// With a small closet every look reuses the same few pieces; say what would help most.
    static func gap(for items: [WardrobeItem]) -> WardrobeGap? {
        let shoes = items.filter { $0.category == .footwear }.count
        let bottoms = items.filter { $0.category == .bottoms }.count
        if shoes < 3 {
            let n = 3 - shoes
            return WardrobeGap(title: "Add \(n == 1 ? "a pair" : "\(n) pairs") of shoes → more outfits", icon: "shoe")
        }
        if bottoms < 3 {
            let n = 3 - bottoms
            return WardrobeGap(title: "Add \(n == 1 ? "a bottom" : "\(n) bottoms") → more outfits", icon: "square.stack")
        }
        if items.count < 20 {
            return WardrobeGap(title: "Add \(20 - items.count) more pieces → more outfits", icon: "hanger")
        }
        return nil
    }

    private var activeGap: WardrobeGap? {
        gapDismissed ? nil : Self.gap(for: wardrobeViewModel.items)
    }

    private func gapCard(_ gap: WardrobeGap) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                openAddClothes()
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: gap.icon)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .frame(width: 34, height: 34)
                        .background(DS.Colors.accentSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(gap.title)
                            .font(DS.Font.subheadline.weight(.semibold))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("A small closet repeats looks")
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("outfit.gap")

            Button {
                withAnimation(DS.Motion.smooth) { gapDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.leading, DS.Spacing.sm)
        .padding(.vertical, 2)
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func openAddClothes() {
        Haptics.light()
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: .showAddClothes, object: nil)
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            moreMenu
            skipButton.frame(maxWidth: 120)
            wearButton
        }
        .disabled(isCommitting)
        .coachAnchor(CoachAnchor.genActions)
    }

    /// Wide layout's narrower pane: "Wear today" full width, ⋯ and Skip beneath.
    private var stackedActionBar: some View {
        VStack(spacing: DS.Spacing.xs) {
            wearButton
            HStack(spacing: DS.Spacing.xs) {
                moreMenu
                skipButton
            }
        }
        .disabled(isCommitting)
        .coachAnchor(CoachAnchor.genActions)
    }

    private var skipButton: some View {
        Button {
            Haptics.light()
            commit(.skip)
        } label: {
            Text("Skip")
        }
        .buttonStyle(DSOutlineButton())
        .accessibilityIdentifier("outfit.skip")
    }

    private var wearButton: some View {
        Button {
            commit(.wear)
        } label: {
            Text("Wear today")
        }
        .buttonStyle(DSPrimaryButton())
        .accessibilityHint("Logs this outfit to today")
        .accessibilityIdentifier("outfit.wear")
    }

    private var moreMenu: some View {
            Menu {
                Button {
                    logDate = Calendar.current.startOfDay(for: Date())
                    showDatePicker = true
                } label: {
                    Label("Log another day…", systemImage: "calendar")
                }
                Button {
                    showAddPiece = true
                } label: {
                    Label("Add a piece", systemImage: "plus")
                }
                Button {
                    shuffleRest()
                } label: {
                    Label(lockedItemIDs.isEmpty ? "Restyle this look" : "Restyle around kept pieces",
                          systemImage: "shuffle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Colors.accent)
                    .frame(width: DS.ButtonSize.height, height: DS.ButtonSize.height)
                    .background(DS.Colors.accentSoft,
                                in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            }
            .accessibilityLabel("More options")
            .accessibilityIdentifier("outfit.more")
    }

    private enum Decision { case wear, skip }

    private func commit(_ decision: Decision) {
        guard !isCommitting, currentOutfit != nil else { return }
        isCommitting = true
        selectedPieceID = nil
        let out: CGFloat = decision == .wear ? 900 : -900
        withAnimation(reduceMotion ? DS.Motion.reduced : .easeIn(duration: 0.24)) {
            if !reduceMotion { dragX = out }
            boardOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            switch decision {
            case .wear:
                log(on: Calendar.current.startOfDay(for: Date()))
            case .skip:
                homeVM.skipCurrentOutfit()
                settleNextBoard()
            }
        }
    }

    /// Logs the current look to `date`, confirms, then moves to the next look.
    private func log(on date: Date) {
        guard let look = currentOutfit else { settleNextBoard(); return }
        outfitsVM.addOutfit(date: date, items: look.items, source: MyOutfitsViewModel.Source.stylist)
        homeVM.saveCurrentOutfit()
        Haptics.success()
        let text = Calendar.current.isDateInToday(date)
            ? "Logged for today"
            : "Logged for \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        withAnimation(DS.Motion.snappy) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(DS.Motion.smooth) { toastText = nil }
            homeVM.advanceToNextOutfit()
            settleNextBoard()
        }
    }

    /// "Log another day…": fade the board, log, advance.
    private func logAnotherDay(_ date: Date) {
        guard !isCommitting, currentOutfit != nil else { return }
        isCommitting = true
        selectedPieceID = nil
        withAnimation(DS.Motion.reduced) { boardOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { log(on: date) }
    }

    private func settleNextBoard() {
        dragX = 0
        pastThreshold = false
        boardScale = reduceMotion ? 1 : 0.96
        withAnimation(reduceMotion ? DS.Motion.reduced : .spring(response: 0.35, dampingFraction: 0.8)) {
            boardScale = 1
            boardOpacity = 1
        }
        isCommitting = false
    }

    private func tap(_ item: WardrobeItem, inline: Bool) {
        guard inline else { previewItem = item; return }
        Haptics.selection()
        withAnimation(DSMotionEnv.resolve(DS.Motion.snappy, reduceMotion: reduceMotion)) {
            selectedPieceID = selectedPieceID == item.id ? nil : item.id
        }
    }

    private func toggleKeep(_ item: WardrobeItem) {
        Haptics.selection()
        withAnimation(DS.Motion.snappy) {
            if lockedItemIDs.contains(item.id) { lockedItemIDs.remove(item.id) } else { lockedItemIDs.insert(item.id) }
        }
    }

    /// Swaps one piece; the selection follows the new piece so repeated taps
    /// walk through the alternatives.
    private func swap(_ item: WardrobeItem) {
        guard let before = currentOutfit else { return }
        Haptics.light()
        let followSelection = selectedPieceID == item.id
        homeVM.shuffleItemInOutfit(itemToShuffle: item, wardrobe: wardrobeViewModel.items, user: authService.user)
        guard followSelection, let after = currentOutfit else { return }
        let old = Set(before.items.map { $0.id })
        if let fresh = after.items.first(where: { !old.contains($0.id) }) {
            selectedPieceID = fresh.id
        }
    }

    private func shuffleRest() {
        Haptics.medium()
        selectedPieceID = nil
        homeVM.reshuffleKeepingLocked(lockedIDs: lockedItemIDs, wardrobe: wardrobeViewModel.items,
                                      user: authService.user)
    }

    private func jump(to index: Int) {
        guard !isCommitting, index != homeVM.batchIndex, index < homeVM.outfitBatch.count else { return }
        Haptics.selection()
        withAnimation(DS.Motion.smooth) {
            homeVM.batchIndex = index
            homeVM.todayOutfit = homeVM.outfitBatch[index]
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        if homeVM.isLoading {
            Color.black.opacity(0.18).ignoresSafeArea()
            ProgressView("Styling…")
                .padding(DS.Spacing.xl)
                .background(DS.Colors.backgroundCard,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }

        // Stylist notices ("That's your only pair of shoes that works here").
        if let notice = homeVM.stylistNotice {
            VStack {
                Spacer()
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(DS.Colors.accent)
                    Text(notice)
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .dsGlassBar(cornerRadius: DS.Radius.card)
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.bottom, 96)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
            .zIndex(9)
            .id(notice)
        }

        if let toastText {
            Label(toastText, systemImage: "checkmark.circle.fill")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.onAccent)
                .padding(.vertical, 14)
                .padding(.horizontal, DS.Spacing.lg)
                .background(DS.Colors.success, in: Capsule(style: .continuous))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .zIndex(10)
                .accessibilityIdentifier("outfit.toast")
        }
    }

    // MARK: - End of batch

    private var endOfBatchView: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                ZStack {
                    Circle().fill(DS.Colors.accentSoft).frame(width: 88, height: 88)
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(DS.Colors.accent)
                }
                .padding(.top, DS.Spacing.xl)
                .accessibilityHidden(true)

                Text("All Caught Up!")
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)

                VStack(spacing: DS.Spacing.xs) {
                    if homeVM.savedCount > 0 {
                        Label("\(homeVM.savedCount) outfit\(homeVM.savedCount == 1 ? "" : "s") logged to your calendar",
                              systemImage: "calendar.badge.checkmark")
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.success)
                    }
                    if homeVM.skippedCount > 0 {
                        Text("\(homeVM.skippedCount) skipped")
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }

                if homeVM.savedCount > 0 {
                    Button {
                        Haptics.light()
                        isPresented = false
                        // The calendar already jumps to the logged day; this asks the
                        // tab shell to switch to it.
                        NotificationCenter.default.post(name: .showOutfitsCalendar, object: nil)
                    } label: {
                        Label("View in Calendar", systemImage: "calendar")
                    }
                    .buttonStyle(DSOutlineButton())
                    .accessibilityIdentifier("outfit.viewInCalendar")
                }

                VStack(spacing: DS.Spacing.sm) {
                    Text("Want more ideas? Pick a mood")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                    FlowLayout(spacing: DS.Spacing.xs) {
                        ForEach(OutfitMood.allCases) { mood in
                            DSChip(title: mood.label, systemImage: mood.icon,
                                   isSelected: homeVM.selectedMood == mood) {
                                withAnimation(DS.Motion.snappy) {
                                    homeVM.selectedMood = homeVM.selectedMood == mood ? nil : mood
                                }
                            }
                        }
                    }
                }
                .padding(.top, DS.Spacing.xs)

                Button {
                    Haptics.medium()
                    homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
                } label: {
                    Label("Style me again", systemImage: "sparkles")
                }
                .buttonStyle(DSPrimaryButton())

                Button("Done") { isPresented = false }
                    .buttonStyle(DSTertiaryButton())
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    // MARK: - Sheets

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Day", selection: $logDate, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .tint(DS.Colors.accent)
                .padding(.horizontal, DS.Spacing.md)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Log to a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showDatePicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Log") {
                            showDatePicker = false
                            let day = Calendar.current.startOfDay(for: logDate)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { logAnotherDay(day) }
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.large])
    }

    /// Categories in the wardrobe, each with its distinct products.
    private var addableProducts: [(category: Category, products: [String])] {
        let byCategory = Dictionary(grouping: wardrobeViewModel.items, by: { $0.category })
        return Category.allCases.compactMap { category in
            guard let items = byCategory[category], !items.isEmpty else { return nil }
            let products = Set(items.map { $0.product }).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return (category: category, products: products)
        }
    }

    private var addPieceSheet: some View {
        NavigationStack {
            List {
                ForEach(addableProducts, id: \.category) { group in
                    Section(group.category.rawValue) {
                        ForEach(group.products, id: \.self) { product in
                            Button {
                                showAddPiece = false
                                Haptics.light()
                                homeVM.addProductToOutfit(
                                    category: group.category,
                                    productType: product,
                                    wardrobe: wardrobeViewModel.items,
                                    user: authService.user
                                )
                            } label: {
                                Label(ClosetText.displayProduct(product), systemImage: group.category.iconName)
                                    .foregroundStyle(DS.Colors.textPrimary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add a piece")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddPiece = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A finished try-on shown full screen.
struct TryOnFullScreenItem: Identifiable {
    let id = UUID()
    let image: UIImage
}
