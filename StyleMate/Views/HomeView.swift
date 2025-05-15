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

struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    @State private var previewImage: PreviewImage? = nil
    @EnvironmentObject var homeVM: HomeViewModel
    @State private var animate = false
    let emojis = ["🎉", "✨", "🥳", "🎊", "💫", "👗", "🕺", "💃", "🧥", "👚", "👖", "👠", "👒", "🧢", "🧣", "🧤"]
    let burstCount = 18
    let subheadings = [
        "You'll rock this outfit! ✨",
        "Ready to shine today!",
        "This look is all you!",
        "Step out in style!",
        "Fashion on point!",
        "You look amazing!",
        "Confidence looks good on you!",
        "Today's your runway!",
        "Own your style!",
        "You're going to turn heads!"
    ]
    @State private var selectedEmoji: String = "👗"
    @State private var selectedSubheading: String = "You'll rock this outfit! ✨"
    
    private func randomizeLook() {
        selectedEmoji = emojis.randomElement() ?? "👗"
        selectedSubheading = subheadings.randomElement() ?? "You'll rock this outfit! ✨"
    }
    
    // Helper to split items into rows for grid centering
    private func gridRows(items: [WardrobeItem], columnsCount: Int) -> [[WardrobeItem]] {
        var rows: [[WardrobeItem]] = []
        var currentRow: [WardrobeItem] = []
        for (idx, item) in items.enumerated() {
            currentRow.append(item)
            if currentRow.count == columnsCount || idx == items.count - 1 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        return rows
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.pink.opacity(0.18), Color.blue.opacity(0.18), Color.yellow.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 24) {
                    // Big celebratory emoji/icon
                    Text(selectedEmoji)
                        .font(.system(size: 70))
                        .scaleEffect(1.2)
                        .shadow(radius: 10)
                        .padding(.top, 8)
                    // Energetic heading
                    Text("Your Look for Today!")
                        .font(.largeTitle.bold())
                        .foregroundColor(.accentColor)
                        .multilineTextAlignment(.center)
                        .transition(.scale)
                    Text(selectedSubheading)
                        .font(.title3)
                        .foregroundColor(.secondary)
                    // Outfit items as tiles in a grid
                    ScrollView {
                        let minTileWidth: CGFloat = 180
                        let spacing: CGFloat = 16
                        let totalWidth = UIScreen.main.bounds.width - 16 // account for padding
                        let columnsCount = max(1, Int((totalWidth + spacing) / (minTileWidth + spacing)))
                        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnsCount)
                        let items = outfitItems
                        let rows = gridRows(items: items, columnsCount: columnsCount)
                        LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                            ForEach(0..<(rows.count - (rows.last?.count ?? 0 < columnsCount ? 1 : 0)), id: \.self) { rowIdx in
                                let row = rows[rowIdx]
                                ForEach(row, id: \.id) { item in
                                    Button(action: {
                                        if let img = item.croppedImage ?? item.image {
                                            previewImage = PreviewImage(image: img)
                                        }
                                    }) {
                                        VStack(spacing: 10) {
                                            if let uiImage = item.croppedImage ?? item.image {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(height: 90)
                                                    .cornerRadius(14)
                                                    .shadow(color: Color.accentColor.opacity(0.18), radius: 6, x: 0, y: 4)
                                            } else {
                                                Rectangle()
                                                    .fill(Color.gray)
                                                    .frame(height: 90)
                                                    .cornerRadius(14)
                                                    .overlay(Text("No Image").font(.caption2))
                                            }
                                            VStack(alignment: .center, spacing: 2) {
                                                Text(item.product)
                                                    .font(.headline)
                                                    .foregroundColor(.primary)
                                                Text(item.colors.joined(separator: ", "))
                                                    .font(.subheadline)
                                                    .foregroundColor(.accentColor)
                                                Text(item.pattern.rawValue)
                                                    .font(.footnote)
                                                    .foregroundColor(.secondary)
                                                if !item.brand.isEmpty {
                                                    Text(item.brand)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        .padding()
                                        .frame(width: minTileWidth)
                                        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground).opacity(0.95)))
                                        .shadow(color: Color.accentColor.opacity(0.08), radius: 6, x: 0, y: 4)
                                    }
                                }
                            }
                        }
                        // Render the last row (if incomplete) as a centered HStack
                        if let lastRow = rows.last, lastRow.count < columnsCount {
                            HStack(spacing: spacing) {
                                Spacer(minLength: 0)
                                ForEach(lastRow, id: \.id) { item in
                                    Button(action: {
                                        if let img = item.croppedImage ?? item.image {
                                            previewImage = PreviewImage(image: img)
                                        }
                                    }) {
                                        VStack(spacing: 10) {
                                            if let uiImage = item.croppedImage ?? item.image {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(height: 90)
                                                    .cornerRadius(14)
                                                    .shadow(color: Color.accentColor.opacity(0.18), radius: 6, x: 0, y: 4)
                                            } else {
                                                Rectangle()
                                                    .fill(Color.gray)
                                                    .frame(height: 90)
                                                    .cornerRadius(14)
                                                    .overlay(Text("No Image").font(.caption2))
                                            }
                                            VStack(alignment: .center, spacing: 2) {
                                                Text(item.product)
                                                    .font(.headline)
                                                    .foregroundColor(.primary)
                                                Text(item.colors.joined(separator: ", "))
                                                    .font(.subheadline)
                                                    .foregroundColor(.accentColor)
                                                Text(item.pattern.rawValue)
                                                    .font(.footnote)
                                                    .foregroundColor(.secondary)
                                                if !item.brand.isEmpty {
                                                    Text(item.brand)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        .padding()
                                        .frame(width: minTileWidth)
                                        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground).opacity(0.95)))
                                        .shadow(color: Color.accentColor.opacity(0.08), radius: 6, x: 0, y: 4)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }
                }
                Spacer(minLength: 0)
                // Fixed bottom buttons
                HStack(spacing: 16) {
                    Button(action: {
                        homeVM.shuffleOutfit()
                        randomizeLook()
                    }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.title2)
                            Text("Shuffle")
                        }
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [Color.blue.opacity(0.7), Color.pink.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 4)
                    }
                    Button(action: { isPresented = false }) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").font(.title2)
                            Text("Love it!")
                        }
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .background(Color(.systemBackground).opacity(0.7).ignoresSafeArea(edges: .bottom))
            }
            .padding(.top, 8)
            .onAppear {
                animate = true
                randomizeLook()
            }
            // Emoji burst animation
            ZStack {
                ForEach(0..<burstCount, id: \.self) { i in
                    let angle = Double(i) / Double(burstCount) * 2 * Double.pi
                    let radius: CGFloat = animate ? CGFloat.random(in: 120...220) : 0
                    let x = cos(angle) * radius
                    let y = sin(angle) * radius
                    Text(emojis.randomElement()!)
                        .font(.system(size: 36))
                        .opacity(animate ? 0 : 1)
                        .offset(x: x, y: y)
                        .scaleEffect(animate ? 1.6 : 0.7)
                        .animation(
                            .easeOut(duration: 1.2).delay(Double(i) * 0.03),
                            value: animate
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image)
                    .padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .font(.headline)
                    .padding()
            }
        }
        .alert("No more new suggestions. Would you like to see them again?", isPresented: $homeVM.showNoMoreSuggestions) {
            Button("OK") { homeVM.resetShufflePopup() }
        } message: {
            Text("You have seen all the current outfit suggestions. Tap OK to cycle through them again.")
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