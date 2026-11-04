import SwiftUI
import CoreLocation

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @ObservedObject var photoScanService = PhotoScanService.shared
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var tutorialManager: TutorialManager
    @State private var loadingProgress: Double = 0.0
    @State private var loadingTimer: Timer? = nil
    @State private var selectedCategory: Category? = nil
    @State private var selectedProduct: String? = nil
    @State private var showWeatherWarning = false
    @State private var showScanReview = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @ScaledMetric(relativeTo: .body) private var heroThumbHeight: CGFloat = 104

    // MARK: - Outfit sheet presentation

    private func outfitSheetBinding(wide: Bool) -> Binding<Bool> {
        Binding(
            get: { homeVM.showOutfitSheet && (hSizeClass == .regular) == wide },
            set: { homeVM.showOutfitSheet = $0 }
        )
    }

    @ViewBuilder
    private var outfitSheet: some View {
        if let outfit = homeVM.todayOutfit {
            TodayOutfitSheet(outfit: outfit, isPresented: $homeVM.showOutfitSheet)
                .environmentObject(homeVM)
                .environmentObject(wardrobeViewModel)
                .environmentObject(outfitsVM)
                .environmentObject(authService)
                .environmentObject(tutorialManager)
        }
    }

    // MARK: - Blocks (stacked on a phone, two columns when wide)

    /// Staged entrance: fade + rise, or a plain fade under Reduce Motion.
    private func entrance<V: View>(_ view: V, delay: Double) -> some View {
        view
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 20)
            .animation(reduceMotion ? DS.Motion.reduced : .easeOut(duration: 0.5).delay(delay), value: appeared)
    }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            entrance(heroGreetingSection, delay: 0)
                .padding(.top, DS.Spacing.lg)

            if photoScanService.scanState != .idle {
                ScanProgressBanner(
                    scanService: photoScanService,
                    showReview: $showScanReview
                )
                .environmentObject(wardrobeViewModel)
                .padding(.top, DS.Spacing.md)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
                .animation(DSMotionEnv.resolve(.spring(response: 0.4, dampingFraction: 0.8), reduceMotion: reduceMotion),
                           value: photoScanService.scanState)
            }

            if photoScanService.scanState == .idle,
               let userId = authService.user?.id,
               !PhotoScanService.shared.loadLastScanItemIDs(forUser: userId).isEmpty {
                Button {
                    Haptics.light()
                    showScanReview = true
                } label: {
                    Label("Review last scan results", systemImage: "slider.horizontal.3")
                        .font(DS.Font.footnote.weight(.medium))
                        .foregroundStyle(DS.Colors.accent)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder
    private var heroBlock: some View {
        if homeVM.heroOutfit != nil || homeVM.isGeneratingHero {
            entrance(todaysOutfitHero.coachAnchor(CoachAnchor.todayOutfit), delay: 0.1)
                .padding(.top, DS.Spacing.xl)
        }
    }

    private var styleMeBlock: some View {
        entrance(styleMeHeroCard.coachAnchor(CoachAnchor.styleMe), delay: 0.15)
            .padding(.top, DS.Spacing.xl)
    }

    private var wardrobeBlock: some View {
        entrance(wardrobeSection, delay: 0.2)
            .padding(.top, DS.Spacing.xl)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default:      return "Good night"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    if hSizeClass == .regular {
                        // Wide (Duo inner display): greeting + Style me | today's
                        // look + wardrobe, each column at a readable width.
                        HStack(alignment: .top, spacing: DS.Spacing.xl) {
                            VStack(alignment: .leading, spacing: 0) {
                                greetingBlock
                                styleMeBlock
                            }
                            .frame(maxWidth: 560, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                heroBlock
                                wardrobeBlock
                            }
                            .frame(maxWidth: 560, alignment: .leading)
                        }
                        .padding(.horizontal, DS.Spacing.xl)
                        .padding(.bottom, DS.Spacing.xxxl)
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            greetingBlock
                            heroBlock
                            styleMeBlock
                            wardrobeBlock
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.bottom, DS.Spacing.xxxl)
                    }
                }

                if homeVM.isLoading {
                    StylingLoadingView(
                        progress: loadingProgress,
                        weather: homeVM.weather
                    )
                }
            }
            // Phone / cover display: full screen. Wide: a page sheet.
            .fullScreenCover(isPresented: outfitSheetBinding(wide: false)) {
                outfitSheet
            }
            .sheet(isPresented: outfitSheetBinding(wide: true)) {
                outfitSheet
                    .presentationSizing(.page)
            }
            .alert("Outfit Suggestion", isPresented: $homeVM.showOutfitErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                switch homeVM.outfitError {
                case .emptyWardrobe:
                    Text("Add more clothes to get outfit ideas. You need at least a top and a bottom.")
                case .networkError:
                    Text("Something went wrong while styling. Please try again.")
                case .parseError:
                    Text("Couldn't put a complete look together from your wardrobe yet. Try adding a few more pieces.")
                case .none:
                    Text("Try adding more items or adjusting colors/patterns.")
                }
            }
            .alert("Weather unavailable", isPresented: $showWeatherWarning) {
                Button("Style anyway") {
                    homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if homeVM.isWeatherLoading {
                    Text("Weather is still loading. Outfit suggestions may not be seasonally appropriate. Continue?")
                } else {
                    Text("Weather information could not be retrieved. Outfit suggestions may not be seasonally appropriate. Would you like to continue?")
                }
            }
            .sheet(isPresented: $showScanReview) {
                ScanReviewView(
                    scanService: photoScanService,
                    isPresented: $showScanReview
                )
                .environmentObject(wardrobeViewModel)
            }
            .onChange(of: photoScanService.scanState) { newState in
                if case .completed = newState, !photoScanService.scanAddedItemIDs.isEmpty {
                    Haptics.success()
                    print("[StyleMate] Scan completed, \(photoScanService.scanAddedItemIDs.count) items added to wardrobe")
                }
            }
            .onAppear {
                // Recency: the stylist reads what you've logged lately.
                homeVM.attachWearLog(outfitsVM)
                if homeVM.weather == nil && !homeVM.isWeatherLoading {
                    homeVM.requestWeatherForCurrentLocation()
                }
                homeVM.ensureHero(wardrobe: wardrobeViewModel.items, user: authService.user)
                withAnimation { appeared = true }
            }
            .onChange(of: homeVM.weather?.temperature2m) { _ in
                homeVM.ensureHero(wardrobe: wardrobeViewModel.items, user: authService.user)
            }
            .onChange(of: homeVM.weatherError) { _ in
                homeVM.ensureHero(wardrobe: wardrobeViewModel.items, user: authService.user)
            }
            .onChange(of: homeVM.isLoading) { isLoading in
                if isLoading {
                    loadingProgress = 0.0
                    loadingTimer?.invalidate()
                    let startTime = Date()
                    loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                        let elapsed = Date().timeIntervalSince(startTime)
                        let target = 1.0 - (1.0 / (1.0 + elapsed / 4.0))
                        loadingProgress = min(target, 0.97)
                    }
                } else {
                    loadingTimer?.invalidate()
                    loadingTimer = nil
                    withAnimation(.easeOut(duration: 0.25)) { loadingProgress = 1.0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { loadingProgress = 0.0 }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedCategory != nil },
                set: { newValue in if !newValue { selectedCategory = nil; selectedProduct = nil } }
            )) {
                if let category = selectedCategory {
                    CategoryDetailView(category: category, initialProduct: selectedProduct)
                        .environmentObject(wardrobeViewModel)
                }
            }
        }
    }

    // MARK: - Hero Greeting + Inline Weather

    @ViewBuilder
    private var heroGreetingSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.micro) {
            Text(greeting)
                .font(DS.Font.title1)
                .foregroundStyle(DS.Colors.textSecondary)

            if let firstName = authService.user?.name.components(separatedBy: " ").first,
               !firstName.isEmpty, firstName.lowercased() != "user" {
                Text(firstName)
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Colors.textPrimary)
            }

            WeatherInlineRow(
                weather: homeVM.weather,
                isLoading: homeVM.isWeatherLoading,
                error: homeVM.weatherError,
                locationStatus: homeVM.locationStatus,
                onRequest: { homeVM.requestWeatherForCurrentLocation() },
                city: homeVM.lastCity,
                temperatureC: homeVM.lastCelsius,
                temperatureF: homeVM.lastFahrenheit,
                displayFahrenheit: homeVM.displayFahrenheit,
                onToggleUnit: { homeVM.toggleTemperatureUnit() }
            )
            .padding(.top, DS.Spacing.micro)
        }
    }

    // MARK: - Today's Outfit Hero

    @ViewBuilder
    private var todaysOutfitHero: some View {
        if let hero = homeVM.heroOutfit {
            Button {
                Haptics.medium()
                homeVM.openHeroInDeck(user: authService.user)
            } label: {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Today's Outfit")
                            .font(DS.Font.title2)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Spacer()
                        HStack(spacing: 2) {
                            Text("Style it")
                                .font(DS.Font.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(DS.Font.footnote.weight(.semibold))
                        }
                        .foregroundStyle(DS.Colors.accent)
                    }

                    heroPreviewRow(hero)

                    if !hero.explanation.isEmpty {
                        HStack(alignment: .top, spacing: DS.Spacing.xs) {
                            Image(systemName: "sparkles")
                                .font(DS.Font.footnote)
                                .foregroundStyle(DS.Colors.accent)
                                .padding(.top, 1)
                            Text(hero.explanation)
                                .font(DS.Font.subheadline)
                                .foregroundStyle(DS.Colors.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(DS.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
                .dsElevatedShadow(cornerRadius: DS.Radius.hero)
            }
            .buttonStyle(DSTapBounce())
        } else if homeVM.isGeneratingHero {
            heroSkeleton
        }
    }

    private func heroPreviewRow(_ outfit: Outfit) -> some View {
        let items = outfit.items.sorted { $0.category.wearingOrder < $1.category.wearingOrder }
        return HStack(spacing: DS.Spacing.sm) {
            ForEach(items.prefix(5)) { item in
                BoardCutout(item: item, path: item.gridImagePath, shadowRadius: 4)
                    .frame(height: heroThumbHeight)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: heroThumbHeight)
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.md)
        .background(StudioSurface())
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.prefix(5).map { ClosetText.displayName($0) }.joined(separator: ", "))
    }

    private var heroSkeleton: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Today's Outfit")
                .font(DS.Font.title2)
                .foregroundStyle(DS.Colors.textPrimary)
            HStack(spacing: DS.Spacing.sm) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Colors.backgroundSecondary)
                        .frame(height: 108)
                        .frame(maxWidth: .infinity)
                        .shimmering()
                }
            }
            SkeletonBlock(width: 220, height: 13)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .dsElevatedShadow(cornerRadius: DS.Radius.hero)
    }

    // MARK: - Style Me Hero Card

    @ViewBuilder
    private var styleMeHeroCard: some View {
        let ctaDisabled = homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid)

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Colors.accent)
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)

                Text("Style for an occasion")
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)
            }

            OutfitTypeChipRow(
                selectedOutfitType: $homeVM.selectedOutfitType,
                customOutfitDescription: $homeVM.customOutfitDescription,
                selectedMood: $homeVM.selectedMood
            )

            Button(action: {
                Haptics.medium()
                if homeVM.isWeatherLoading || homeVM.weather == nil || homeVM.weatherError != nil {
                    showWeatherWarning = true
                } else {
                    homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
                }
            }) {
                Label("Style me", systemImage: "sparkles")
            }
            .buttonStyle(DSPrimaryButton(isDisabled: ctaDisabled))
            .disabled(ctaDisabled)
            .accessibilityHint("Builds five outfits from your wardrobe")
            .accessibilityIdentifier("home.styleMe")
        }
        .padding(DS.Spacing.lg)
        .background(
            ZStack {
                DS.Colors.backgroundCard
                LinearGradient(
                    colors: [DS.Colors.accent.opacity(0.04), DS.Colors.accentSecondary.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .dsElevatedShadow(cornerRadius: DS.Radius.hero)
    }

    // MARK: - Wardrobe Section

    @ViewBuilder
    private var wardrobeSection: some View {
        if !wardrobeViewModel.items.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                sectionHeader("Your Wardrobe", trailing: "\(wardrobeViewModel.items.count) items")

                let categoryCounts = Dictionary(grouping: wardrobeViewModel.items, by: { $0.category })
                    .map { (category: $0.key, items: $0.value, count: $0.value.count) }
                    .sorted { $0.count > $1.count }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        ForEach(categoryCounts.prefix(6), id: \.category) { entry in
                            Button(action: {
                                Haptics.light()
                                selectedCategory = entry.category
                            }) {
                                WardrobeCategoryCard(
                                    category: entry.category,
                                    items: entry.items,
                                    count: entry.count
                                )
                            }
                            .buttonStyle(DSTapBounce())
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .opacity(phase.isIdentity || reduceMotion ? 1 : 0.7)
                                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.94)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.micro)
                    .padding(.vertical, DS.Spacing.micro)
                }
                .scrollClipDisabled()
            }
        } else {
            VStack(spacing: DS.Spacing.md) {
                ZStack {
                    Circle().fill(DS.Colors.accentSoft).frame(width: 84, height: 84)
                    Image(systemName: "hanger")
                        .font(.system(size: 34, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Colors.accent)
                }
                Text("Your wardrobe is empty")
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Add items from the Wardrobe tab to get personalized outfit suggestions.")
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.xl)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .dsCardShadow(cornerRadius: DS.Radius.hero)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DS.Font.title2)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }
}

// MARK: - Wardrobe Category Card

private struct WardrobeCategoryCard: View {
    let category: Category
    let items: [WardrobeItem]
    let count: Int

    /// Scales with Dynamic Type so the title and count never clip.
    @ScaledMetric(relativeTo: .headline) private var cardWidth: CGFloat = 148
    @ScaledMetric(relativeTo: .headline) private var tileHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            // Two newest cutouts, fitted (never cropped) on the studio backdrop,
            // loaded off the main thread.
            HStack(spacing: DS.Spacing.micro) {
                ForEach(Array(items.suffix(2).reversed())) { item in
                    AsyncItemTile(path: item.gridImagePath, height: tileHeight,
                                  cornerRadius: DS.Radius.control, inset: 6)
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .accessibilityHidden(true)

            Text(category.rawValue)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(width: cardWidth)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.sm)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Outfit Type Chip Row

private struct OutfitTypeChipRow: View {
    @Binding var selectedOutfitType: OutfitType?
    @Binding var customOutfitDescription: String?
    @Binding var selectedMood: OutfitMood?
    @EnvironmentObject var authService: AuthService

    var preferredStyles: [OutfitType] {
        authService.user?.preferredStyles ?? Array(OutfitType.allCases.prefix(6))
    }

    private var hasCustom: Bool {
        !(customOutfitDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customText: Binding<String> {
        Binding(
            get: { customOutfitDescription ?? "" },
            set: { customOutfitDescription = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Occasion chips (a quick starting point).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(preferredStyles, id: \.self) { type in
                        ChipButton(
                            label: type.rawValue,
                            icon: type.icon,
                            isSelected: selectedOutfitType == type,
                            action: {
                                Haptics.light()
                                withAnimation(DS.Motion.snappy) { selectedOutfitType = type }
                            }
                        )
                        .accessibilityIdentifier("home.occasion.\(type.rawValue)")
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, 2)
            }
            // Bleed to the card's edges so chips scroll out under its rounded
            // corner instead of being cut mid-card.
            .padding(.horizontal, -DS.Spacing.lg)

            // Mood — optional; tap again to clear. Shapes palette, textures and fit.
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.micro) {
                    Text("How do you want to feel?")
                        .font(DS.Font.footnote)
                        .foregroundStyle(selectedMood == nil ? DS.Colors.textSecondary : DS.Colors.accent)
                    if let mood = selectedMood {
                        Text("· \(mood.label)")
                            .font(DS.Font.footnote.weight(.semibold))
                            .foregroundStyle(DS.Colors.accent)
                            .transition(.opacity)
                    }
                }
                .animation(DS.Motion.snappy, value: selectedMood)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(OutfitMood.allCases) { mood in
                            ChipButton(
                                label: mood.label,
                                icon: mood.icon,
                                isSelected: selectedMood == mood,
                                action: {
                                    Haptics.selection()
                                    withAnimation(DS.Motion.snappy) {
                                        selectedMood = selectedMood == mood ? nil : mood
                                    }
                                }
                            )
                            .accessibilityLabel("\(mood.label) mood")
                            .accessibilityAddTraits(selectedMood == mood ? .isSelected : [])
                            .accessibilityIdentifier("mood.\(mood.rawValue)")
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -DS.Spacing.lg)
            }

            // Always-visible free text — what the user types here takes priority.
            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text("Describe your own occasion or add details")
                    .font(DS.Font.footnote)
                    .foregroundStyle(hasCustom ? DS.Colors.accent : DS.Colors.textSecondary)

                HStack(alignment: .top, spacing: DS.Spacing.xs) {
                    Image(systemName: "text.bubble")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(hasCustom ? DS.Colors.accent : DS.Colors.textTertiary)
                        .padding(.top, 2)

                    TextField("e.g. outdoor wedding, something in blue, chilly evening", text: customText, axis: .vertical)
                        .font(DS.Font.subheadline)
                        .lineLimit(1...3)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .submitLabel(.done)
                }
                .padding(DS.Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Colors.backgroundSecondary)
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(hasCustom ? DS.Colors.accent.opacity(0.4) : Color.clear, lineWidth: 1)
                }
            }
        }
    }
}

private struct ChipButton: View {
    let label: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.micro) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(DS.Font.caption1)
                }
                Text(label)
                    .font(DS.Font.subheadline)
            }
            .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textPrimary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
        .if(isSelected) { view in
            view
                .background(DS.Colors.accent.opacity(0.15), in: Capsule())
                .overlay(Capsule().stroke(DS.Colors.accent, lineWidth: 1))
        }
        .if(!isSelected) { $0.dsGlassChipUnselected() }
    }
}

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
