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
                }
            }
            .alert("No valid outfit found", isPresented: $homeVM.showNoOutfitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if !homeVM.debugReasons.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(homeVM.debugReasons.prefix(10), id: \.self) { reason in
                                Text(reason).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Try adding more items or adjusting colors/patterns.")
                }
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

struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Today's Outfit")
                    .font(.headline)
                    .padding(.top, 8)
                ForEach(outfitItems, id: \.id) { item in
                    HStack(spacing: 16) {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .cornerRadius(10)
                        Text("\(item.colors.joined(separator: ", ")) \(item.brand) \(item.product)")
                            .font(.body)
                            .foregroundColor(.primary)
                            .accessibilityLabel("\(item.colors.joined(separator: ", ")) \(item.brand) \(item.product)")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .accessibilityLabel("Close outfit sheet")
            }
            .padding(16)
        }
    }
    var outfitItems: [WardrobeItem] {
        [outfit.top, outfit.bottom, outfit.footwear] + [outfit.accessory, outfit.outerwear].compactMap { $0 }
    }
}

struct WardrobeSummaryWidget: View {
    let items: [WardrobeItem]
    var productCounts: [String: Int] {
        Dictionary(grouping: items, by: { $0.product })
            .mapValues { $0.count }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wardrobe Summary")
                .font(.headline)
            if productCounts.isEmpty {
                Text("No items in your wardrobe yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(productCounts.sorted(by: { $0.key < $1.key }), id: \.key) { key, count in
                    HStack {
                        Text("\(count) \(key)")
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
}

#Preview {
    HomeView().environmentObject(WardrobeViewModel())
} 