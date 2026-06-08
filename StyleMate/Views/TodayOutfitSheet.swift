import SwiftUI

struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    @EnvironmentObject var homeVM: HomeViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @EnvironmentObject var authService: AuthService

    @State private var previewImage: PreviewImage? = nil
    @State private var lockedItemIDs: Set<UUID> = []
    @State private var showDatePickerSheet = false
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var showSavedOverlay = false
    @State private var showAddProductSheet = false
    @State private var addProductStep: AddProductStep? = nil
    @State private var expandedCategory: Category? = nil
    @State private var isAddingProduct: Bool = false

    // Swipe gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var cardOpacity: Double = 1
    @State private var dismissDirection: DismissDirection? = nil
    @State private var hasTriggeredSwipeHaptic = false

    // Card entry animation state
    @State private var cardScale: CGFloat = 1.0
    @State private var cardYOffset: CGFloat = 0

    // First-time hint state
    @State private var showSwipeTooltip = false
    @State private var isPlayingHint = false

    private let swipeThreshold: CGFloat = 100
    private let cardCornerRadius: CGFloat = 20

    enum AddProductStep: Identifiable {
        case category
        var id: Int { hashValue }
    }

    enum DismissDirection {
        case left, right
    }

    private var contextLine: String {
        var parts: [String] = []
        if let type = homeVM.selectedOutfitType { parts.append(type.rawValue) }
        if let tempC = homeVM.lastCelsius {
            let temp = homeVM.displayFahrenheit ? Int((tempC * 9.0 / 5.0) + 32) : Int(tempC)
            parts.append("\(temp)°\(homeVM.displayFahrenheit ? "F" : "C")")
        }
        if let weather = homeVM.weather {
            parts.append(weather.displayDescription)
        }
        return parts.isEmpty ? "Curated for you" : parts.joined(separator: " · ")
    }

    private var currentOutfit: Outfit? {
        guard homeVM.batchIndex < homeVM.outfitBatch.count else { return nil }
        return homeVM.outfitBatch[homeVM.batchIndex]
    }

    private var saveProgress: Double {
        dragOffset.width > 20 ? min((dragOffset.width - 20) / (swipeThreshold - 20), 1.0) : 0
    }

    private var skipProgress: Double {
        dragOffset.width < -20 ? min((abs(dragOffset.width) - 20) / (swipeThreshold - 20), 1.0) : 0
    }

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            if homeVM.allOutfitsSeen {
                endOfBatchView
            } else if let outfit = currentOutfit {
                VStack(spacing: 0) {
                    headerView

                    ZStack {
                        ghostCards
                        outfitCard(for: outfit)
                            .scaleEffect(cardScale)
                            .offset(y: cardYOffset)
                    }
                    .padding(.horizontal, DS.Spacing.screenH)

                    if showSwipeTooltip {
                        Text("Swipe right to save, left to skip")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(DS.Colors.backgroundSecondary)
                            .clipShape(Capsule())
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .padding(.top, DS.Spacing.xs)
                    }
                }
                .offset(x: dragOffset.width)
                .rotationEffect(.degrees(cardRotation))
                .opacity(cardOpacity)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 30)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            guard !isPlayingHint else { return }
                            dragOffset = value.translation
                            cardRotation = Double(value.translation.width / 20)
                            let progress = min(abs(value.translation.width) / swipeThreshold, 1.0)
                            cardOpacity = 1.0 - (progress * 0.3)

                            if abs(value.translation.width) > swipeThreshold && !hasTriggeredSwipeHaptic {
                                Haptics.light()
                                hasTriggeredSwipeHaptic = true
                            }
                            if abs(value.translation.width) <= swipeThreshold {
                                hasTriggeredSwipeHaptic = false
                            }
                        }
                        .onEnded { value in
                            hasTriggeredSwipeHaptic = false
                            guard !isPlayingHint else { return }
                            guard abs(value.translation.width) > abs(value.translation.height) else {
                                resetCardPosition()
                                return
                            }
                            if value.translation.width > swipeThreshold {
                                dismissCard(direction: .right)
                            } else if value.translation.width < -swipeThreshold {
                                dismissCard(direction: .left)
                            } else {
                                resetCardPosition()
                            }
                        }
                )
            }

            if homeVM.isLoading {
                Color.black.opacity(0.18).ignoresSafeArea()
                ProgressView(isAddingProduct ? "Adding…" : "Shuffling…")
                    .padding(DS.Spacing.xl)
                    .background(DS.Colors.backgroundCard)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            }

            if showSavedOverlay {
                VStack {
                    Spacer()
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.title3)
                        .foregroundColor(.white)
                        .padding(.vertical, DS.Spacing.md)
                        .padding(.horizontal, DS.Spacing.xl)
                        .background(DS.Colors.success)
                        .clipShape(Capsule())
                    Spacer()
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .onAppear { playSwipeHintIfNeeded() }
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image).padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .buttonStyle(DSSecondaryButton())
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.lg)
            }
        }
        .alert("Too Many Requests", isPresented: $homeVM.showRateLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're shuffling too fast! Please wait a moment and try again.")
        }
        .sheet(isPresented: $showDatePickerSheet) {
            NavigationView {
                VStack(spacing: DS.Spacing.lg) {
                    DatePicker("Select Date", selection: $selectedDate, displayedComponents: [.date])
                        .datePickerStyle(GraphicalDatePickerStyle())
                        .padding()

                    Button("Save") {
                        saveOutfitForDate(selectedDate)
                        showDatePickerSheet = false
                    }
                    .buttonStyle(DSPrimaryButton())
                    .padding(.horizontal, DS.Spacing.screenH)

                    Button("Cancel") { showDatePickerSheet = false }
                        .buttonStyle(DSTertiaryButton())
                }
                .padding()
                .navigationTitle("Choose Date")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $addProductStep) { _ in
            addProductSheetContent
        }
        .onChange(of: showAddProductSheet) { newValue in
            if newValue {
                addProductStep = .category
                expandedCategory = nil
            }
        }
        .onChange(of: addProductStep) { newValue in
            if newValue == nil { showAddProductSheet = false }
        }
        .onChange(of: homeVM.batchIndex) { _ in
            lockedItemIDs.removeAll()   // locks are per-look; clear when swiping to the next
        }
        .onChange(of: homeVM.isLoading) { loading in
            if !loading { isAddingProduct = false }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Today's Outfit")
                        .font(DS.Font.title1)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(contextLine)
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                if !homeVM.outfitBatch.isEmpty {
                    Text("\(homeVM.batchIndex + 1) of \(homeVM.outfitBatch.count)")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.micro)
                        .background(DS.Colors.backgroundSecondary)
                        .clipShape(Capsule())
                }

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            progressDots
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: DS.Spacing.micro) {
            ForEach(0..<homeVM.outfitBatch.count, id: \.self) { idx in
                Circle()
                    .fill(idx == homeVM.batchIndex ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.3))
                    .frame(width: idx == homeVM.batchIndex ? 8 : 6, height: idx == homeVM.batchIndex ? 8 : 6)
                    .animation(.easeInOut(duration: 0.2), value: homeVM.batchIndex)
            }
        }
    }

    // MARK: - Ghost (Stacked) Cards

    @ViewBuilder
    private var ghostCards: some View {
        if homeVM.batchIndex + 2 < homeVM.outfitBatch.count {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(DS.Colors.backgroundCard.opacity(0.5))
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                .padding(.horizontal, 16)
                .offset(y: 14)
                .scaleEffect(0.92)
        }
        if homeVM.batchIndex + 1 < homeVM.outfitBatch.count {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(DS.Colors.backgroundCard)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                .padding(.horizontal, 8)
                .offset(y: 8)
                .scaleEffect(0.96)
        }
    }

    // MARK: - Outfit Card

    @ViewBuilder
    private func outfitCard(for outfit: Outfit) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(DS.Colors.backgroundCard)
                .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 4)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: DS.Spacing.lg) {
                        if !outfit.explanation.isEmpty {
                            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                                Image(systemName: "sparkles")
                                    .font(DS.Font.footnote)
                                    .foregroundStyle(DS.Colors.accent)
                                    .padding(.top, 2)

                                Text(outfit.explanation)
                                    .font(DS.Font.subheadline)
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Colors.accentSoft)
                        }

                        lookToolbar
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.top, DS.Spacing.xs)

                        flatLay(for: outfit)
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.top, DS.Spacing.xs)
                            .padding(.bottom, 96)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))

            // SAVE stamp (upper-left, visible when dragging right)
            if saveProgress > 0 {
                VStack {
                    HStack {
                        Text("SAVE")
                            .font(.system(size: 48, weight: .black))
                            .foregroundColor(DS.Colors.success)
                            .opacity(saveProgress)
                            .rotationEffect(.degrees(-15))
                            .padding(.top, DS.Spacing.xl)
                            .padding(.leading, DS.Spacing.lg)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // SKIP stamp (upper-right, visible when dragging left)
            if skipProgress > 0 {
                VStack {
                    HStack {
                        Spacer()
                        Text("SKIP")
                            .font(.system(size: 48, weight: .black))
                            .foregroundColor(DS.Colors.error)
                            .opacity(skipProgress)
                            .rotationEffect(.degrees(15))
                            .padding(.top, DS.Spacing.xl)
                            .padding(.trailing, DS.Spacing.lg)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(
                    saveProgress > 0
                        ? DS.Colors.success.opacity(saveProgress * 0.8)
                        : (skipProgress > 0
                            ? DS.Colors.error.opacity(skipProgress * 0.8)
                            : Color.clear),
                    lineWidth: 3
                )
        )
        .overlay(alignment: .bottom) {
            bottomActionBar
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.sm)
        }
    }

    // MARK: - Flat-lay canvas
    //
    // Presents the outfit as a styled "look": background-removed cutouts arranged
    // top → bottom → shoes, with accessories beneath — instead of a row list. Each
    // piece can be tapped to zoom or shuffled via its badge.

    private static let upperZone: Set<Category> =
        [.outerwear, .midLayers, .tops, .onePieces, .activewear, .ethnicWear, .innerwear]

    @ViewBuilder
    private func flatLay(for outfit: Outfit) -> some View {
        let items = outfit.items
        let upper = items.filter { Self.upperZone.contains($0.category) }
            .sorted { $0.category.wearingOrder < $1.category.wearingOrder }
        let lower = items.filter { $0.category == .bottoms }
        let feet = items.filter { $0.category == .footwear }
        let accessories = items.filter { $0.category == .accessories }

        VStack(spacing: DS.Spacing.xl) {
            if !upper.isEmpty { flatLayRow(upper, maxHeight: 188) }
            if !lower.isEmpty { flatLayRow(lower, maxHeight: 156) }
            if !feet.isEmpty { flatLayRow(feet, maxHeight: 92) }
            if !accessories.isEmpty {
                HStack(spacing: DS.Spacing.xl) {
                    ForEach(accessories) { flatLayPiece($0, maxHeight: 56) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .padding(.horizontal, DS.Spacing.lg)
        .background(DS.Colors.styleBoard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func flatLayRow(_ items: [WardrobeItem], maxHeight: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.lg) {
            ForEach(items) { flatLayPiece($0, maxHeight: maxHeight) }
        }
        .frame(maxWidth: .infinity)
    }

    private func flatLayPiece(_ item: WardrobeItem, maxHeight: CGFloat) -> some View {
        let image = item.croppedImage ?? item.image
        let isLocked = lockedItemIDs.contains(item.id)
        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Colors.backgroundSecondary)
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay(
                        Image(systemName: item.category.iconName)
                            .font(.system(size: 24))
                            .foregroundStyle(DS.Colors.textTertiary)
                    )
            }
        }
        .frame(maxHeight: maxHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if let image { previewImage = PreviewImage(image: image) }
        }
        // Lock toggle (top-left): "keep this piece" when you hit Shuffle.
        .overlay(alignment: .topLeading) {
            Button {
                Haptics.selection()
                if isLocked { lockedItemIDs.remove(item.id) } else { lockedItemIDs.insert(item.id) }
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isLocked ? DS.Colors.accent : DS.Colors.textTertiary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(DSTapBounce())
        }
        // Per-slot shuffle (top-right): re-roll just this piece. Hidden when locked.
        .overlay(alignment: .topTrailing) {
            if !isLocked {
                Button {
                    Haptics.light()
                    homeVM.shuffleItemInOutfit(
                        itemToShuffle: item,
                        wardrobe: wardrobeViewModel.items,
                        user: authService.user
                    )
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Colors.accent)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(DSTapBounce())
                .disabled(homeVM.isLoading)
            }
        }
    }

    // MARK: - Look toolbar (lock + shuffle)

    private var lookToolbar: some View {
        HStack(spacing: DS.Spacing.micro) {
            Image(systemName: lockedItemIDs.isEmpty ? "lock.open" : "lock.fill")
                .font(DS.Font.caption1)
            Text(lockedItemIDs.isEmpty ? "Tap a piece to keep it" : "\(lockedItemIDs.count) kept")
                .font(DS.Font.footnote)
            Spacer()
            Button {
                Haptics.medium()
                homeVM.reshuffleKeepingLocked(
                    lockedIDs: lockedItemIDs,
                    wardrobe: wardrobeViewModel.items,
                    user: authService.user
                )
            } label: {
                HStack(spacing: DS.Spacing.micro) {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(DS.Font.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(DS.Colors.accentSoft, in: Capsule(style: .continuous))
            }
            .buttonStyle(DSTapBounce())
            .disabled(homeVM.isLoading)
        }
        .foregroundStyle(lockedItemIDs.isEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
    }

    // MARK: - Dismiss & Reset

    private func dismissCard(direction: DismissDirection) {
        let screenWidth = UIScreen.main.bounds.width
        let offscreenX: CGFloat = direction == .right ? screenWidth + 100 : -(screenWidth + 100)
        let rotation: Double = direction == .right ? 15 : -15

        withAnimation(.easeIn(duration: 0.3)) {
            dragOffset = CGSize(width: offscreenX, height: -30)
            cardRotation = rotation
            cardOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if direction == .right {
                saveOutfitForToday()
            } else {
                Haptics.medium()
                homeVM.skipCurrentOutfit()
            }
            resetCardPosition()
        }
    }

    private func resetCardPosition() {
        dragOffset = .zero
        cardRotation = 0
        cardOpacity = 1
        cardScale = 0.96
        cardYOffset = 8
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            cardScale = 1.0
            cardYOffset = 0
        }
    }

    // MARK: - First-Time Swipe Hint

    private func playSwipeHintIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasSeenSwipeHint") else { return }
        guard !isPlayingHint else { return }

        isPlayingHint = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.4)) {
                dragOffset = CGSize(width: 60, height: 0)
                cardRotation = 3
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                dragOffset = .zero
                cardRotation = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.4)) {
                dragOffset = CGSize(width: -60, height: 0)
                cardRotation = -3
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.3)) {
                dragOffset = .zero
                cardRotation = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSwipeTooltip = true
            }
            isPlayingHint = false
            UserDefaults.standard.set(true, forKey: "hasSeenSwipeHint")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            withAnimation(.easeOut(duration: 0.4)) {
                showSwipeTooltip = false
            }
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button(action: {
                Haptics.light()
                dismissCard(direction: .left)
            }) {
                HStack(spacing: DS.Spacing.micro) {
                    Image(systemName: "arrow.left")
                    Text("Skip")
                }
            }
            .buttonStyle(DSSecondaryButton())
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .stroke(DS.Colors.error.opacity(skipProgress * 0.6), lineWidth: 2)
            )

            Button(action: {
                Haptics.light()
                showAddProductSheet = true
            }) {
                HStack(spacing: DS.Spacing.micro) {
                    Image(systemName: "plus")
                    Text("Add")
                }
            }
            .buttonStyle(DSSecondaryButton())

            Button(action: {
                Haptics.light()
                selectedDate = Calendar.current.startOfDay(for: Date())
                showDatePickerSheet = true
            }) {
                Image(systemName: "calendar")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.accent)
                    .frame(width: DS.ButtonSize.height, height: DS.ButtonSize.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card)
                            .stroke(DS.Colors.accent, lineWidth: 1.5)
                    )
            }

            Button(action: {
                Haptics.light()
                dismissCard(direction: .right)
            }) {
                HStack(spacing: DS.Spacing.micro) {
                    Text("Save")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(DSPrimaryButton())
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .stroke(DS.Colors.success.opacity(saveProgress * 0.6), lineWidth: 2)
            )
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.sm)
        .dsGlassBar(cornerRadius: DS.Spacing.md)
    }

    // MARK: - End of Batch View

    private var endOfBatchView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 56))
                .foregroundColor(DS.Colors.accent)

            Text("All Caught Up!")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)

            VStack(spacing: DS.Spacing.xs) {
                if homeVM.savedCount > 0 {
                    Label(
                        "\(homeVM.savedCount) outfit\(homeVM.savedCount == 1 ? "" : "s") saved for today",
                        systemImage: "heart.fill"
                    )
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.success)
                }
                if homeVM.skippedCount > 0 {
                    Label("\(homeVM.skippedCount) skipped", systemImage: "arrow.right")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            if homeVM.savedCount > 0 {
                Button(action: {
                    Haptics.light()
                    isPresented = false
                }) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "calendar")
                        Text("View in Calendar")
                    }
                }
                .buttonStyle(DSSecondaryButton())
                .padding(.horizontal, DS.Spacing.xl)
            }

            Text("Want more suggestions?")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)

            Button(action: {
                Haptics.medium()
                homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
            }) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "sparkles")
                    Text("Generate More")
                }
            }
            .buttonStyle(DSPrimaryButton())
            .padding(.horizontal, DS.Spacing.xl)

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(DSTertiaryButton())

            Spacer()
        }
        .padding(.horizontal, DS.Spacing.screenH)
    }

    // MARK: - Add Product Sheet

    private var addProductSheetContent: some View {
        NavigationView {
            List {
                ForEach(Category.allCases.filter { category in
                    wardrobeViewModel.items.contains(where: { $0.category == category })
                }, id: \.self) { category in
                    Section(header:
                        HStack {
                            Text(category.rawValue)
                                .font(DS.Font.headline)
                                .foregroundColor(DS.Colors.accent)
                            Spacer()
                            Image(systemName: expandedCategory == category ? "chevron.down" : "chevron.right")
                                .foregroundColor(DS.Colors.accent)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation { expandedCategory = expandedCategory == category ? nil : category }
                        }
                    ) {
                        if expandedCategory == category {
                            let userProducts = Set(wardrobeViewModel.items.filter { $0.category == category }.map { $0.product })
                            let products = (productTypesByCategory[category] ?? []).filter { userProducts.contains($0) }
                            ForEach(products, id: \.self) { product in
                                Button(action: {
                                    addProductStep = nil
                                    isAddingProduct = true
                                    homeVM.addProductToOutfit(
                                        category: category,
                                        productType: product,
                                        wardrobe: wardrobeViewModel.items,
                                        user: authService.user
                                    )
                                }) {
                                    Text(product)
                                        .font(DS.Font.body)
                                        .foregroundColor(DS.Colors.textPrimary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { addProductStep = nil }
                }
            }
        }
    }

    // MARK: - Save Helpers

    private func saveOutfitForToday() {
        saveOutfitForDate(Calendar.current.startOfDay(for: Date()))
    }

    private func saveOutfitForDate(_ date: Date) {
        guard let outfit = currentOutfit else { return }
        outfitsVM.addOutfit(date: date, items: outfit.items, source: "gemini")
        homeVM.saveCurrentOutfit()
        Haptics.success()
        showSavedOverlay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showSavedOverlay = false
            homeVM.advanceToNextOutfit()
        }
    }
}

// MARK: - Outfit Item Row

private struct OutfitItemRow: View {
    let item: WardrobeItem
    let onTap: () -> Void
    let onShuffle: () -> Void
    let isLoading: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: onTap) {
                if let uiImage = item.thumbnailImage ?? item.croppedImage ?? item.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .fill(DS.Colors.backgroundSecondary)
                        .frame(width: 70, height: 70)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(DS.Colors.textTertiary)
                        )
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text(item.category.rawValue)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.accent)

                Text(item.product)
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Text(item.colors.joined(separator: ", "))
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                HStack(spacing: DS.Spacing.micro) {
                    if let material = item.material, !material.isEmpty {
                        Text(material)
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    if !item.brand.isEmpty {
                        if item.material != nil && !(item.material?.isEmpty ?? true) {
                            Text("·")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Text(item.brand)
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button(action: onShuffle) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.accent)
                    .padding(DS.Spacing.xs)
                    .background(DS.Colors.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            }
            .disabled(isLoading)
            .opacity(isLoading ? 0.4 : 1.0)
            .accessibilityLabel("Swap item")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }
}
