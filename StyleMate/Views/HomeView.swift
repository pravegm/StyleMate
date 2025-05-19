import SwiftUI
import CoreLocation

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService
    @State private var showProfile = false
    // Add for celebratory emoji and subheading
    let emojis = ["✨", "🕺", "💃", "👗", "🎉", "🌟", "🧥", "👚", "🧢", "🧣", "🧤", "👠", "👒"]
    let subheadings = [
        "Ready to style your day?",
        "Step into your best look!",
        "Your wardrobe, reimagined.",
        "Let's make today stylish!",
        "Fashion, powered by you.",
        "Unleash your inner icon.",
        "Every day is a runway!"
    ]
    @State private var selectedEmoji: String = "✨"
    @State private var selectedSubheading: String = "Ready to style your day?"
    @State private var animateButton = false
    @State private var loadingProgress: Double = 0.0
    @State private var loadingTimer: Timer? = nil
    let styleQuotes = [
        "Style is a way to say who you are without having to speak. – Rachel Zoe",
        "Fashion is the armor to survive the reality of everyday life. – Bill Cunningham",
        "Good clothes open all doors.",
        "Dress how you want to be addressed.",
        "Style is a reflection of your attitude and personality.",
        "Clothes mean nothing until someone lives in them. – Marc Jacobs",
        "Fashion is about something that comes from within you. – Ralph Lauren",
        "The joy of dressing is an art. – John Galliano",
        "You can have anything you want in life if you dress for it. – Edith Head",
        "Style is knowing who you are, what you want to say, and not giving a damn. – Orson Welles",
        "People will stare. Make it worth their while. – Harry Winston",
        "Fashion is instant language. – Miuccia Prada",
        "Life isn't perfect but your outfit can be.",
        "Elegance is not standing out, but being remembered. – Giorgio Armani",
        "When in doubt, overdress."
    ]
    @State private var selectedQuote: String = ""
    let emojiList = ["🧥", "👗", "👚", "👖", "👠", "🧢", "🧣", "👒", "👞", "👟", "🥿", "👔", "🩳", "🩱", "👜", "🎩"]
    @State private var emojiIndex: Int = 0
    let emojiTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var emojiCycling: Bool = false
    @State private var selectedCategory: Category? = nil
    @State private var selectedProduct: String? = nil
    @State private var showWeatherWarning = false
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Elegant gradient background
                LinearGradient(
                    colors: [Color.pink.opacity(0.13), Color.blue.opacity(0.13), Color.yellow.opacity(0.13)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        // StyleMate Card
                        HomeCard {
                            VStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.18))
                                        .frame(width: 80, height: 80)
                                        .blur(radius: 12)
                                    Image(systemName: "tshirt.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 56, height: 56)
                                        .foregroundColor(.accentColor)
                                        .padding(.top, 10)
                                    MagicalSparkles()
                                }
                                Text("StyleMate")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text("Your AI Fashion Stylist")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Image(systemName: "quote.opening")
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                    Text(selectedQuote)
                                        .font(.body.italic())
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.center)
                                    Image(systemName: "quote.closing")
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                }
                                .padding(.top, 4)
                                .padding(.horizontal, 8)
                            }
                        }
                        // Outfit Suggestion Card
                        HomeCard {
                            VStack(spacing: 16) {
                                Text("What type of occasion or vibe are you dressing for today?")
                                    .font(.title2.bold())
                                    .foregroundColor(.accentColor)
                                    .multilineTextAlignment(.center)
                                OutfitTypeSelector(
                                    selectedOutfitType: $homeVM.selectedOutfitType,
                                    customOutfitDescription: $homeVM.customOutfitDescription
                                )
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        animateButton = true
                                    }
                                    // Weather logic: if weather is loading, show warning first
                                    if homeVM.isWeatherLoading {
                                        showWeatherWarning = true
                                    } else if homeVM.weather == nil || homeVM.weatherError != nil {
                                        showWeatherWarning = true
                                    } else {
                                        homeVM.suggestTodayOutfit(from: wardrobeViewModel.items)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        animateButton = false
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "wand.and.stars")
                                        Text("Get Today's Outfit")
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(
                                        LinearGradient(colors: [Color.accentColor, Color.pink.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .scaleEffect(animateButton ? 1.06 : 1.0)
                                    .shadow(color: Color.accentColor.opacity(0.13), radius: 8, x: 0, y: 4)
                                }
                                .padding(.top, 8)
                                .accessibilityLabel("Suggest an outfit")
                                .disabled(homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid))
                            }
                        }
                        // Weather Card
                        WeatherCard(
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
                        // Wardrobe Summary Card
                        HomeCard {
                            WardrobeSummaryWidget(items: wardrobeViewModel.items, onSummaryTap: { category, product in
                                selectedCategory = category
                                selectedProduct = product
                            })
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                }
                // Loading overlay
                if homeVM.isLoading {
                    OutfitLoadingOverlay(progress: loadingProgress, emoji: emojiList[emojiIndex])
                }
            }
            .navigationTitle("")
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .sheet(isPresented: $homeVM.showOutfitSheet) {
                if let outfit = homeVM.todayOutfit {
                    TodayOutfitSheet(outfit: outfit, isPresented: $homeVM.showOutfitSheet)
                        .environmentObject(homeVM)
                        .environmentObject(wardrobeViewModel)
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
                // Randomize emoji and subheading on appear
                selectedEmoji = emojis.randomElement() ?? "✨"
                selectedSubheading = subheadings.randomElement() ?? "Ready to style your day?"
                selectedQuote = styleQuotes.shuffled().first ?? "Style is a way to say who you are without having to speak."
                if homeVM.weather == nil && !homeVM.isWeatherLoading {
                    homeVM.requestWeatherForCurrentLocation()
                }
            }
            .onChange(of: homeVM.isLoading) { isLoading in
                if isLoading {
                    emojiCycling = true
                    loadingProgress = 0.0
                    loadingTimer?.invalidate()
                    loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                        if loadingProgress < 0.9 {
                            loadingProgress += 0.005
                        } else {
                            loadingProgress = 0.9
                            timer.invalidate()
                        }
                    }
                } else {
                    emojiCycling = false
                    emojiIndex = 0
                    loadingTimer?.invalidate()
                    withAnimation(.linear(duration: 0.2)) {
                        loadingProgress = 1.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        loadingProgress = 0.0
                    }
                }
            }
            .onReceive(emojiTimer) { _ in
                if emojiCycling {
                    emojiIndex = (emojiIndex + 1) % emojiList.count
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
    
    private struct OutfitTypeSelector: View {
        @Binding var selectedOutfitType: OutfitType?
        @Binding var customOutfitDescription: String?
        @EnvironmentObject var authService: AuthService
        let columns = Array(repeating: GridItem(.flexible()), count: 3)
        var preferredStyles: [OutfitType] {
            authService.user?.preferredStyles ?? Array(OutfitType.allCases.prefix(6))
        }
        var body: some View {
            VStack(spacing: 18) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(preferredStyles, id: \ .self) { type in
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedOutfitType = type
                                customOutfitDescription = nil
                            }
                        }) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(selectedOutfitType == type && customOutfitDescription == nil ? Color.accentColor : Color.gray.opacity(0.13))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: type.icon)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(selectedOutfitType == type && customOutfitDescription == nil ? .white : .primary)
                                }
                                Text(type.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.6)
                                    .frame(maxWidth: 56, minHeight: 28, alignment: .top)
                            }
                            .frame(height: 72)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                // 'Other' option as a wide rectangle button
                HStack(spacing: 14) {
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            if selectedOutfitType == nil && customOutfitDescription != nil {
                                selectedOutfitType = preferredStyles.first
                                customOutfitDescription = nil
                            } else {
                                selectedOutfitType = nil
                                if customOutfitDescription == nil {
                                    customOutfitDescription = ""
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(selectedOutfitType == nil && customOutfitDescription != nil ? Color.accentColor : Color.gray.opacity(0.13))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "ellipsis.bubble")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(selectedOutfitType == nil && customOutfitDescription != nil ? .white : .primary)
                            }
                            Text(selectedOutfitType == nil && customOutfitDescription != nil ? "Describe your event or outfit need" : "Other")
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(alignment: .leading)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(Color.gray.opacity(0.13))
                        .cornerRadius(14)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                // Show the text field below the button when 'Other' is selected
                if selectedOutfitType == nil && customOutfitDescription != nil {
                    VStack(spacing: 6) {
                        TextField("e.g. Outdoor wedding in summer evening", text: Binding(
                            get: { customOutfitDescription ?? "" },
                            set: { customOutfitDescription = $0 }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(maxWidth: 340)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }
    
    // Custom animated progress overlay for outfit loading
    struct OutfitLoadingOverlay: View {
        let progress: Double
        let emoji: String
        @State private var animate = false
        let loadingMessages = [
            "Getting your outfit from StyleMate AI...",
            "Consulting the AI fashion oracle...",
            "Mixing and matching with AI...",
            "Finding your perfect AI-powered look...",
            "Styling your day with AI magic..."
        ]
        @State private var selectedMessage: String = "Getting your outfit from StyleMate AI..."
        var body: some View {
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                VStack(spacing: 24) {
                    Text(emoji)
                        .font(.system(size: 48))
                        .scaleEffect(animate ? 1.1 : 0.95)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: animate)
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .green))
                        .frame(width: 180)
                    Text(selectedMessage)
                        .font(.headline)
                        .foregroundColor(.accentColor)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.systemBackground).opacity(0.96))
                        .shadow(radius: 12)
                )
                .onAppear {
                    animate = true
                    selectedMessage = loadingMessages.randomElement() ?? loadingMessages[0]
                }
            }
            .transition(.opacity)
        }
    }
    
    // Magical subheading with fade/slide and gradient
    struct MagicalSubheading: View {
        let text: String
        @State private var appear = false
        var body: some View {
            Text(text)
                .font(.headline)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.pink.opacity(0.85), Color.blue.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 12)
                .animation(.easeOut(duration: 1.1), value: appear)
                .onAppear { appear = true }
        }
    }
}
