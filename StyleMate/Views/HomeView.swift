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

    var body: some View {
        NavigationStack {
            ZStack {
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
                                    // Energetic subheading with fade/slide and gradient
                                    MagicalSubheading(text: selectedSubheading)
                                        .padding(.top, 2)
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
                        // Suggest Outfit Button with gradient and animation
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
                        .padding(.horizontal)
                        .accessibilityLabel("Suggest an outfit")
                        .disabled(homeVM.isLoading)
                    }
                    .padding(.top, 8)
                }
                // Loading overlay
                if homeVM.isLoading {
                    OutfitLoadingOverlay(progress: loadingProgress)
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showProfile = true }) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 26, weight: .regular))
                    }
                    .accessibilityLabel("Profile")
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .sheet(isPresented: $homeVM.showOutfitSheet) {
                if let outfit = homeVM.todayOutfit {
                    TodayOutfitSheet(outfit: outfit, isPresented: $homeVM.showOutfitSheet)
                        .environmentObject(homeVM)
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
            }
            .onChange(of: homeVM.isLoading) { isLoading in
                if isLoading {
                    loadingProgress = 0.0
                    loadingTimer?.invalidate()
                    loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                        // Fill to 90% over about 3.5s
                        if loadingProgress < 0.9 {
                            loadingProgress += 0.005
                        } else {
                            loadingProgress = 0.9
                            timer.invalidate()
                        }
                    }
                } else {
                    loadingTimer?.invalidate()
                    withAnimation(.linear(duration: 0.2)) {
                        loadingProgress = 1.0
                    }
                    // Optionally, reset progress after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        loadingProgress = 0.0
                    }
                }
            }
        }
    }
}

// Custom animated progress overlay for outfit loading
struct OutfitLoadingOverlay: View {
    let progress: Double
    @State private var animate = false
    let loadingMessages = [
        "Getting your outfit from StyleMate AI...",
        "Consulting the AI fashion oracle...",
        "Mixing and matching with AI...",
        "Finding your perfect AI-powered look...",
        "Styling your day with AI magic..."
    ]
    @State private var selectedMessage: String = "Getting your outfit from StyleMate AI..."
    let emoji = "🧥"
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