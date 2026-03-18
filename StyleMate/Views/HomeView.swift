import SwiftUI
import CoreLocation

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @ObservedObject var photoScanService = PhotoScanService.shared
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService
    @State private var loadingProgress: Double = 0.0
    @State private var loadingTimer: Timer? = nil
    @State private var selectedCategory: Category? = nil
    @State private var selectedProduct: String? = nil
    @State private var showWeatherWarning = false
    @State private var showScanReview = false
    @State private var appeared = false
    @State private var sparkleScale: CGFloat = 1.0

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
                    VStack(alignment: .leading, spacing: 0) {
                        // MARK: - Hero Greeting + Weather
                        heroGreetingSection
                            .padding(.top, DS.Spacing.md)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 20)
                            .animation(.easeOut(duration: 0.5), value: appeared)

                        // MARK: - Scan Progress Banner
                        if photoScanService.scanState != .idle {
                            ScanProgressBanner(
                                scanService: photoScanService,
                                showReview: $showScanReview
                            )
                            .padding(.top, DS.Spacing.md)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: photoScanService.scanState)
                        }

                        // MARK: - Style Me Hero Card
                        styleMeHeroCard
                            .padding(.top, DS.Spacing.lg)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 20)
                            .animation(.easeOut(duration: 0.5).delay(0.1), value: appeared)

                        // MARK: - Your Wardrobe
                        wardrobeSection
                            .padding(.top, DS.Spacing.xl)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 20)
                            .animation(.easeOut(duration: 0.5).delay(0.2), value: appeared)
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.xxxl)
                }

                if homeVM.isLoading {
                    StylingLoadingView(
                        progress: loadingProgress,
                        weather: homeVM.weather
                    )
                }
            }
            .fullScreenCover(isPresented: $homeVM.showOutfitSheet) {
                if let outfit = homeVM.todayOutfit {
                    TodayOutfitSheet(outfit: outfit, isPresented: $homeVM.showOutfitSheet)
                        .environmentObject(homeVM)
                        .environmentObject(wardrobeViewModel)
                        .environmentObject(outfitsVM)
                        .environmentObject(authService)
                }
            }
            .alert("Outfit Suggestion", isPresented: $homeVM.showOutfitErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                switch homeVM.outfitError {
                case .emptyWardrobe:
                    Text("Add more items to your wardrobe to get outfit suggestions. You need at least a top, bottom, and shoes.")
                case .networkError:
                    Text("Couldn't connect to the styling engine. Please check your connection and try again.")
                case .parseError:
                    Text("Something went wrong matching the suggestions. Please try again.")
                case .none:
                    Text("Try adding more items or adjusting colors/patterns.")
                }
            }
            .alert("Weather unavailable", isPresented: $showWeatherWarning) {
                Button("Yes", role: .destructive) {
                    homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
                }
                Button("No", role: .cancel) {}
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
                if homeVM.weather == nil && !homeVM.isWeatherLoading {
                    homeVM.requestWeatherForCurrentLocation()
                }
                withAnimation { appeared = true }
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
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(greeting + ",")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textSecondary)

            if let firstName = authService.user?.name.components(separatedBy: " ").first, !firstName.isEmpty {
                Text(firstName)
                    .font(DS.Font.display)
                    .foregroundColor(DS.Colors.textPrimary)
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

    // MARK: - Style Me Hero Card

    @ViewBuilder
    private var styleMeHeroCard: some View {
        let ctaDisabled = homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid)

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(DS.Font.title3)
                    .foregroundColor(DS.Colors.accent)
                    .scaleEffect(sparkleScale)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            sparkleScale = 1.1
                        }
                    }

                Text("Style me for today")
                    .font(DS.Font.title2)
                    .foregroundColor(DS.Colors.textPrimary)
            }

            OutfitTypeChipRow(
                selectedOutfitType: $homeVM.selectedOutfitType,
                customOutfitDescription: $homeVM.customOutfitDescription
            )

            Button(action: {
                Haptics.medium()
                if homeVM.isWeatherLoading || homeVM.weather == nil || homeVM.weatherError != nil {
                    showWeatherWarning = true
                } else {
                    homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
                }
            }) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(DS.Font.headline)
                    Text("Generate 5 Outfits")
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(DS.Font.headline)
                }
            }
            .buttonStyle(DSPrimaryButton(isDisabled: ctaDisabled))
            .disabled(ctaDisabled)
            .opacity(ctaDisabled ? 0.5 : 1.0)
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
                    HStack(spacing: DS.Spacing.sm) {
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
                        }
                    }
                    .padding(.horizontal, DS.Spacing.micro)
                }
            }
        } else {
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "hanger")
                    .font(.system(size: 40))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Your wardrobe is empty")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Add your first items to get personalized outfit suggestions")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.xl)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero))
            .dsCardShadow(cornerRadius: DS.Radius.hero)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(DS.Font.title3)
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }
}

// MARK: - Wardrobe Category Card

private struct WardrobeCategoryCard: View {
    let category: Category
    let items: [WardrobeItem]
    let count: Int

    private var thumbnails: [UIImage] {
        let shuffled = items.shuffled()
        var result: [UIImage] = []
        for item in shuffled {
            if let img = item.thumbnailImage ?? item.croppedImage ?? item.image {
                result.append(img)
                if result.count >= 2 { break }
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            let thumbs = thumbnails
            if thumbs.count >= 2 {
                HStack(spacing: DS.Spacing.micro) {
                    ForEach(0..<2, id: \.self) { i in
                        Image(uiImage: thumbs[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                    }
                }
            } else if thumbs.count == 1 {
                Image(uiImage: thumbs[0])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            } else {
                Image(systemName: category.iconName)
                    .font(.system(size: 32))
                    .foregroundColor(DS.Colors.accent)
                    .frame(width: 80, height: 80)
            }

            Text(category.rawValue)
                .font(DS.Font.headline)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Text("\(count) items")
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(width: 130)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
    }
}

// MARK: - Outfit Type Chip Row

private struct OutfitTypeChipRow: View {
    @Binding var selectedOutfitType: OutfitType?
    @Binding var customOutfitDescription: String?
    @EnvironmentObject var authService: AuthService

    var preferredStyles: [OutfitType] {
        authService.user?.preferredStyles ?? Array(OutfitType.allCases.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(preferredStyles, id: \.self) { type in
                        ChipButton(
                            label: type.rawValue,
                            icon: type.icon,
                            isSelected: selectedOutfitType == type && customOutfitDescription == nil,
                            action: {
                                Haptics.light()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedOutfitType = type
                                    customOutfitDescription = nil
                                }
                            }
                        )
                    }

                    ChipButton(
                        label: "Other",
                        icon: "ellipsis.bubble",
                        isSelected: selectedOutfitType == nil && customOutfitDescription != nil,
                        action: {
                            Haptics.light()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if selectedOutfitType == nil && customOutfitDescription != nil {
                                    selectedOutfitType = preferredStyles.first
                                    customOutfitDescription = nil
                                } else {
                                    selectedOutfitType = nil
                                    customOutfitDescription = customOutfitDescription ?? ""
                                }
                            }
                        }
                    )
                }
                .padding(.horizontal, DS.Spacing.micro)
            }

            if selectedOutfitType == nil && customOutfitDescription != nil {
                TextField("e.g. Outdoor wedding in summer evening", text: Binding(
                    get: { customOutfitDescription ?? "" },
                    set: { customOutfitDescription = $0 }
                ))
                .font(DS.Font.body)
                .padding(DS.Spacing.sm)
                .background(DS.Colors.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                .foregroundColor(DS.Colors.textPrimary)
                .transition(.move(edge: .top).combined(with: .opacity))
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
