import SwiftUI
import CoreLocation

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService
    @State private var showProfile = false
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
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        // MARK: - Greeting + Weather
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text(greeting)
                                .font(DS.Font.largeTitle)
                                .foregroundColor(DS.Colors.textPrimary)

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

                        // MARK: - Get Outfit Button
                        Button(action: {
                            Haptics.medium()
                            if homeVM.isWeatherLoading || homeVM.weather == nil || homeVM.weatherError != nil {
                                showWeatherWarning = true
                            } else {
                                homeVM.suggestTodayOutfit(from: wardrobeViewModel.items)
                            }
                        }) {
                            HStack(spacing: DS.Spacing.xs) {
                                Image(systemName: "wand.and.stars")
                                Text("Get Today's Outfit")
                            }
                        }
                        .buttonStyle(DSPrimaryButton(
                            isDisabled: homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid)
                        ))
                        .disabled(homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid))

                        // MARK: - Wardrobe Summary
                        Button(action: {}) {
                            WardrobeSummaryWidget(items: wardrobeViewModel.items, onSummaryTap: { category, product in
                                selectedCategory = category
                                selectedProduct = product
                            })
                        }
                        .buttonStyle(.plain)
                        .padding(.top, DS.Spacing.xs)
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.xxxl)
                }

                if homeVM.isLoading {
                    OutfitLoadingOverlay(
                        progress: loadingProgress,
                        message: "Finding your perfect outfit…"
                    )
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showProfile = true } label: {
                        Image(systemName: "person.circle")
                            .font(DS.Font.title3)
                            .foregroundColor(DS.Colors.accent)
                    }
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .sheet(isPresented: $homeVM.showOutfitSheet) {
                if let outfit = homeVM.todayOutfit {
                    TodayOutfitSheet(outfit: outfit, isPresented: $homeVM.showOutfitSheet)
                        .environmentObject(homeVM)
                        .environmentObject(wardrobeViewModel)
                        .environmentObject(MyOutfitsViewModel())
                }
            }
            .alert("No valid outfit found", isPresented: $homeVM.showNoOutfitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try adding more items or adjusting colors/patterns.")
            }
            .alert("Weather unavailable", isPresented: $showWeatherWarning) {
                Button("Yes", role: .destructive) {
                    homeVM.suggestTodayOutfit(from: wardrobeViewModel.items)
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
                    loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                        if loadingProgress < 0.9 {
                            loadingProgress += 0.005
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.Font.subheadline)
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
