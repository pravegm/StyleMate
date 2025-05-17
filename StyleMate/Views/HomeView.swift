import SwiftUI

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
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
                    VStack(spacing: 28) {
                        // Logo/tagline area (emoji removed)
                        VStack(spacing: 0) {
                            ZStack {
                                // Animated magical gradient border
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            gradient: Gradient(colors: [Color.pink.opacity(0.7), Color.blue.opacity(0.7), Color.yellow.opacity(0.7), Color.pink.opacity(0.7)]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 3.5
                                    )
                                    .blur(radius: 1.5)
                                    .opacity(0.85)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                                            .fill(Color(.systemBackground).opacity(0.85))
                                            .shadow(color: Color.accentColor.opacity(0.08), radius: 8, x: 0, y: 4)
                                    )
                                // Sparkles (animated)
                                MagicalSparkles()
                                VStack(spacing: 8) {
                                    ZStack {
                                        // Soft glow behind icon
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
                                    }
                                    Text("StyleMate")
                                        .font(.system(size: 36, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                    Text("Your AI Fashion Stylist")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                    // Add the quote here
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
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 20) // add a bit more top padding since emoji is gone
                        }
                        // Wardrobe Summary Widget with improved background and subtle shadow
                        WardrobeSummaryWidget(items: wardrobeViewModel.items)
                            .padding(.horizontal, 24)
                        // Outfit Suggestion Card
                        VStack(spacing: 0) {
                            // Card Header
                            VStack(spacing: 6) {
                                Text("Let's decide what you should wear today!")
                                    .font(.title2.bold())
                                    .foregroundColor(.accentColor)
                                    .multilineTextAlignment(.center)
                                Text("What type of occasion or vibe are you dressing for?")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 20)
                            .padding(.horizontal, 20)
                            // Chips in 3+3+1 grid
                            VStack(spacing: 14) {
                                HStack(spacing: 12) {
                                    ForEach(OutfitType.allCases.prefix(3)) { type in
                                        Button(action: {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                                homeVM.selectedOutfitType = type
                                                homeVM.customOutfitDescription = nil
                                            }
                                        }) {
                                            HStack(spacing: 5) {
                                                Image(systemName: type.icon)
                                                    .font(.footnote)
                                                Text(type.rawValue)
                                                    .font(.footnote)
                                                    .lineLimit(1)
                                            }
                                            .frame(minWidth: 0, maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(homeVM.selectedOutfitType == type && homeVM.customOutfitDescription == nil ? Color.accentColor : Color.gray.opacity(0.13))
                                            .foregroundColor(homeVM.selectedOutfitType == type && homeVM.customOutfitDescription == nil ? .white : .primary)
                                            .cornerRadius(14)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(homeVM.selectedOutfitType == type && homeVM.customOutfitDescription == nil ? Color.accentColor : Color.clear, lineWidth: 1.2)
                                            )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                HStack(spacing: 12) {
                                    ForEach(OutfitType.allCases.dropFirst(3).prefix(3)) { type in
                                        Button(action: {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                                homeVM.selectedOutfitType = type
                                                homeVM.customOutfitDescription = nil
                                            }
                                        }) {
                                            HStack(spacing: 5) {
                                                Image(systemName: type.icon)
                                                    .font(.footnote)
                                                Text(type.rawValue)
                                                    .font(.footnote)
                                                    .lineLimit(1)
                                            }
                                            .frame(minWidth: 0, maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(homeVM.selectedOutfitType == type && homeVM.customOutfitDescription == nil ? Color.accentColor : Color.gray.opacity(0.13))
                                            .foregroundColor(homeVM.selectedOutfitType == type && homeVM.customOutfitDescription == nil ? .white : .primary)
                                            .cornerRadius(14)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(homeVM.selectedOutfitType == type && homeVM.customOutfitDescription == nil ? Color.accentColor : Color.clear, lineWidth: 1.2)
                                            )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                HStack(spacing: 12) {
                                    Spacer(minLength: 0)
                                    Button(action: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            if homeVM.selectedOutfitType == nil && homeVM.customOutfitDescription != nil {
                                                homeVM.selectedOutfitType = .everyday
                                                homeVM.customOutfitDescription = nil
                                            } else {
                                                homeVM.selectedOutfitType = nil
                                                if homeVM.customOutfitDescription == nil {
                                                    homeVM.customOutfitDescription = ""
                                                }
                                            }
                                        }
                                    }) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "ellipsis.bubble")
                                                .font(.footnote)
                                            Text(homeVM.selectedOutfitType == nil && homeVM.customOutfitDescription != nil ? "Describe your event or outfit need" : "Other")
                                                .font(.footnote)
                                                .lineLimit(1)
                                        }
                                        .frame(minWidth: 0, maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(homeVM.selectedOutfitType == nil && homeVM.customOutfitDescription != nil ? Color.accentColor : Color.gray.opacity(0.13))
                                        .foregroundColor(homeVM.selectedOutfitType == nil && homeVM.customOutfitDescription != nil ? .white : .primary)
                                        .cornerRadius(14)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(homeVM.selectedOutfitType == nil && homeVM.customOutfitDescription != nil ? Color.accentColor : Color.clear, lineWidth: 1.2)
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    Spacer(minLength: 0)
                                }
                                // Show the text field below the button when 'Other' is selected, with no extra label
                                if homeVM.selectedOutfitType == nil && homeVM.customOutfitDescription != nil {
                                    VStack(spacing: 6) {
                                        TextField("e.g. Outdoor wedding in summer evening", text: Binding(
                                            get: { homeVM.customOutfitDescription ?? "" },
                                            set: { homeVM.customOutfitDescription = $0 }
                                        ))
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .frame(maxWidth: 340)
                                        .padding(.top, 8)
                                        .padding(.bottom, 2)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                        if !homeVM.isCustomDescriptionValid {
                                            Text("Please describe your event or outfit need.")
                                                .font(.caption)
                                                .foregroundColor(.red)
                                                .multilineTextAlignment(.center)
                                                .padding(.top, 2)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 18)
                            // Suggest Outfit Button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                animateButton = true
                            }
                            homeVM.suggestTodayOutfit(from: wardrobeViewModel.items)
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
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 20)
                        .accessibilityLabel("Suggest an outfit")
                        .disabled(homeVM.isLoading || (homeVM.selectedOutfitType == nil && !homeVM.isCustomDescriptionValid))
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(.systemBackground))
                                .shadow(color: Color.accentColor.opacity(0.10), radius: 12, x: 0, y: 6)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 60) // Add space for quote at bottom
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
            .onAppear {
                // Randomize emoji and subheading on appear
                selectedEmoji = emojis.randomElement() ?? "✨"
                selectedSubheading = subheadings.randomElement() ?? "Ready to style your day?"
                selectedQuote = styleQuotes.shuffled().first ?? "Style is a way to say who you are without having to speak."
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