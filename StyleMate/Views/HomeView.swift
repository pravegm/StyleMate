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
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(Color(.systemBackground).opacity(0.85))
                                    .shadow(color: Color.accentColor.opacity(0.08), radius: 8, x: 0, y: 4)
                                VStack(spacing: 8) {
                                    Image(systemName: "tshirt.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 56, height: 56)
                                        .foregroundColor(.accentColor)
                                        .padding(.top, 10)
                                    Text("StyleMate")
                                        .font(.system(size: 36, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                    Text("Your AI Fashion Stylist")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                    // Energetic subheading
                                    Text(selectedSubheading)
                                        .font(.headline)
                                        .foregroundColor(.accentColor)
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
                            .padding(.horizontal)
                            .background(
                                Color(
                                    UIColor { trait in
                                        trait.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(0.85)
                                    }
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 2)
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
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView()
                            .accessibilityLabel("Loading outfit suggestion")
                    }
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
        }
    }
} 