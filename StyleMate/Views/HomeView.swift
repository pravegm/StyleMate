import SwiftUI

struct HomeView: View {
    @StateObject private var homeVM = HomeViewModel()
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @State private var showProfile = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Logo and Tagline
                    VStack(spacing: 8) {
                        Image(systemName: "tshirt.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .foregroundColor(.blue)
                            .padding(.top, 12)
                        Text("StyleMate")
                            .font(.largeTitle).fontWeight(.bold)
                        Text("Your AI Fashion Stylist")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    
                    // Wardrobe Summary Widget
                    WardrobeSummaryWidget(items: wardrobeViewModel.items)
                        .padding(.horizontal)
                    
                    // Suggest Outfit Button
                    Button(action: {
                        homeVM.suggestTodayOutfit(from: wardrobeViewModel.items)
                    }) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Get Today's Outfit")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                    .accessibilityLabel("Suggest an outfit")
                    .disabled(homeVM.isLoading)
                }
                .padding(.top, 8)
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
            .overlay {
                if homeVM.isLoading {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView()
                            .accessibilityLabel("Loading outfit suggestion")
                    }
                }
            }
        }
    }
} 