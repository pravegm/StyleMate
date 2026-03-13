import SwiftUI
import CoreLocation

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService
    @State private var loadingProgress: Double = 0.0
    @State private var loadingTimer: Timer? = nil
    @State private var selectedCategory: Category? = nil
    @State private var selectedProduct: String? = nil
    @State private var showWeatherWarning = false

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
                        // MARK: - Greeting
                        VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                            Text(greeting + ",")
                                .font(DS.Font.title2)
                                .foregroundColor(DS.Colors.textSecondary)

                            if let firstName = authService.user?.name.components(separatedBy: " ").first, !firstName.isEmpty {
                                Text(firstName)
                                    .font(DS.Font.largeTitle)
                                    .foregroundColor(DS.Colors.textPrimary)
                            }
                        }
                        .padding(.top, DS.Spacing.md)

                        // MARK: - Weather Card
                        Group {
                            if homeVM.isWeatherLoading {
                                HStack(spacing: DS.Spacing.xs) {
                                    ProgressView()
                                    Text("Loading weather...")
                                        .font(DS.Font.subheadline)
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DS.Colors.backgroundCard)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                .dsCardShadow()
                            } else if let error = homeVM.weatherError {
                                HStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(DS.Colors.warning)
                                    Text(error)
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Retry") { homeVM.requestWeatherForCurrentLocation() }
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.accent)
                                }
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DS.Colors.backgroundCard)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                .dsCardShadow()
                            } else if homeVM.locationStatus == .denied || homeVM.locationStatus == .restricted {
                                HStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: "location.slash")
                                        .foregroundColor(DS.Colors.textTertiary)
                                    Text("Location access needed for weather")
                                        .font(DS.Font.subheadline)
                                        .foregroundColor(DS.Colors.textSecondary)
                                    Spacer()
                                    Button("Settings") {
                                        if let url = URL(string: UIApplication.openSettingsURLString) {
                                            UIApplication.shared.open(url)
                                        }
                                    }
                                    .font(DS.Font.caption1)
                                    .foregroundColor(DS.Colors.accent)
                                }
                                .padding(DS.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DS.Colors.backgroundCard)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                .dsCardShadow()
                            } else if let weather = homeVM.weather, let tempC = homeVM.lastCelsius {
                                let tempF = homeVM.lastFahrenheit ?? (tempC * 9.0 / 5.0 + 32)
                                let displayTemp = homeVM.displayFahrenheit ? Int(tempF) : Int(tempC)
                                let unit = homeVM.displayFahrenheit ? "F" : "C"

                                HStack(spacing: DS.Spacing.md) {
                                    Image(systemName: WeatherService.weatherIconName(for: weather.weathercode, isDay: weather.isDay == 1))
                                        .font(.system(size: 36))
                                        .foregroundColor(DS.Colors.accent)

                                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                                        Text("\(displayTemp)°\(unit)")
                                            .font(DS.Font.title1)
                                            .foregroundColor(DS.Colors.textPrimary)
                                        Text(WeatherService.weatherDescription(for: weather.weathercode))
                                            .font(DS.Font.subheadline)
                                            .foregroundColor(DS.Colors.textSecondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: DS.Spacing.micro) {
                                        if let city = homeVM.lastCity {
                                            Text(city)
                                                .font(DS.Font.caption1)
                                                .foregroundColor(DS.Colors.textTertiary)
                                        }
                                        Button(action: { Haptics.light(); homeVM.toggleTemperatureUnit() }) {
                                            Text(homeVM.displayFahrenheit ? "°F" : "°C")
                                                .font(DS.Font.caption1)
                                                .foregroundColor(DS.Colors.accent)
                                                .padding(.horizontal, DS.Spacing.xs)
                                                .padding(.vertical, DS.Spacing.micro)
                                                .dsGlassChipUnselected()
                                        }
                                    }
                                }
                                .padding(DS.Spacing.md)
                                .background(DS.Colors.backgroundCard)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                .dsCardShadow()
                            }
                        }
                        .padding(.top, DS.Spacing.md)

                        // MARK: - Outfit Type Selector
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text("What's the vibe today?")
                                .font(DS.Font.headline)
                                .foregroundColor(DS.Colors.textPrimary)

                            OutfitTypeChipRow(
                                selectedOutfitType: $homeVM.selectedOutfitType,
                                customOutfitDescription: $homeVM.customOutfitDescription
                            )
                        }
                        .padding(.top, DS.Spacing.lg)

                        // MARK: - Get Outfit CTA
                        ctaButton
                            .padding(.top, DS.Spacing.md)

                        // MARK: - Wardrobe at a Glance
                        wardrobeAtAGlance
                            .padding(.top, DS.Spacing.xl)
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
            .sheet(isPresented: $homeVM.showOutfitSheet) {
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
            .onAppear {
                if homeVM.weather == nil && !homeVM.isWeatherLoading {
                    homeVM.requestWeatherForCurrentLocation()
                }
            }
            .onChange(of: homeVM.isLoading) { isLoading in
                if isLoading {
                    loadingProgress = 0.0
                    loadingTimer?.invalidate()
                    loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
                        if loadingProgress < 0.20 {
                            loadingProgress += 0.008
                        } else if loadingProgress < 0.40 {
                            loadingProgress += 0.006
                        } else if loadingProgress < 0.70 {
                            loadingProgress += 0.003
                        } else if loadingProgress < 0.90 {
                            loadingProgress += 0.004
                        } else {
                            timer.invalidate()
                        }
                    }
                } else {
                    loadingTimer?.invalidate()
                    withAnimation(.linear(duration: 0.2)) { loadingProgress = 1.0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadingProgress = 0.0 }
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

    // MARK: - CTA Button

    @ViewBuilder
    private var ctaButton: some View {
        let ctaDisabled = homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid)

        Button(action: {
            Haptics.medium()
            if homeVM.isWeatherLoading || homeVM.weather == nil || homeVM.weatherError != nil {
                showWeatherWarning = true
            } else {
                homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
            }
        }) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "wand.and.stars")
                    .font(DS.Font.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get Today's Outfit")
                        .font(DS.Font.headline)
                    if let type = homeVM.selectedOutfitType {
                        Text(type.rawValue)
                            .font(DS.Font.caption1)
                            .opacity(0.8)
                    }
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(DS.Font.title2)
            }
            .foregroundColor(.white)
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .dsCardShadow()
        }
        .disabled(ctaDisabled)
        .opacity(ctaDisabled ? 0.5 : 1.0)
    }

    // MARK: - Wardrobe at a Glance

    @ViewBuilder
    private var wardrobeAtAGlance: some View {
        if !wardrobeViewModel.items.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack {
                    Text("Your Wardrobe")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text("\(wardrobeViewModel.items.count) items")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                }

                let categoryCounts = Dictionary(grouping: wardrobeViewModel.items, by: { $0.category })
                    .map { (category: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: DS.Spacing.xs)], spacing: DS.Spacing.xs) {
                    ForEach(categoryCounts.prefix(6), id: \.category) { item in
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: item.category.iconName)
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.accent)
                            Text("\(item.count)")
                                .font(DS.Font.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(item.category.rawValue)
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Colors.backgroundCard)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                        .dsCardShadow()
                    }
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
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .dsCardShadow()
        }
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
                .textFieldStyle(.roundedBorder)
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
        }
        .buttonStyle(.plain)
        .if(isSelected) { $0.dsGlassChipSelected() }
        .if(!isSelected) { $0.dsGlassChipUnselected() }
    }
}

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
