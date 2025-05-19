import SwiftUI

struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    @State private var previewImage: PreviewImage? = nil
    @EnvironmentObject var homeVM: HomeViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
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
        let horizontalPadding: CGFloat = 20
        ZStack {
            LinearGradient(
                colors: [Color.pink.opacity(0.18), Color.blue.opacity(0.18), Color.yellow.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 0) {
                // Drag indicator
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 44, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 10) {
                    // Energetic heading
                    Text("Your Look for Today!")
                        .font(.largeTitle.bold())
                        .foregroundColor(.accentColor)
                        .padding(.top, 24)
                        .transition(.scale)
                    Text(selectedSubheading)
                        .font(.body)
                        .foregroundColor(.secondary.opacity(0.85))
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, horizontalPadding)
                // Outfit items as tiles in a grid
                ScrollView {
                    let minTileWidth: CGFloat = 180
                    let spacing: CGFloat = 16
                    let totalWidth = UIScreen.main.bounds.width - 2 * horizontalPadding
                    let columnsCount = max(1, Int((totalWidth + spacing) / (minTileWidth + spacing)))
                    let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnsCount)
                    let items = outfitItems
                    LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                        ForEach(items, id: \ .id) { item in
                            VStack(spacing: 0) {
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
                                                .cornerRadius(18)
                                                .shadow(color: Color.accentColor.opacity(0.18), radius: 8, x: 0, y: 6)
                                        } else {
                                            Rectangle()
                                                .fill(Color.gray)
                                                .frame(height: 90)
                                                .cornerRadius(18)
                                                .overlay(Text("No Image").font(.caption2))
                                        }
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
                                .padding(.bottom, 4)
                                // Per-item shuffle button
                                Button(action: {
                                    if let category = Category.allCases.first(where: { $0 == item.category }) {
                                        homeVM.shuffleItemInOutfit(category: category, wardrobe: wardrobeViewModel.items)
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.subheadline)
                                        Text("Shuffle")
                                            .font(.caption)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 10)
                                    .background(Color.accentColor.opacity(0.13))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                                }
                                .padding(.top, 2)
                                .disabled(homeVM.isLoading)
                            }
                            .padding()
                            .frame(width: minTileWidth)
                            .background(RoundedRectangle(cornerRadius: 22).fill(Color(.systemBackground).opacity(0.97)))
                            .shadow(color: Color.accentColor.opacity(0.10), radius: 10, x: 0, y: 6)
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 4)
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
                ForEach(0..<burstCount, id: \ .self) { i in
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
            // Loading overlay
            if homeVM.isLoading {
                Color.black.opacity(0.18).ignoresSafeArea()
                ProgressView("Shuffling...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
            }
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
        .alert("Too Many Requests", isPresented: $homeVM.showRateLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're shuffling too fast! Please wait a moment and try again.")
        }
    }
    var outfitItems: [WardrobeItem] {
        [outfit.top, outfit.bottom, outfit.footwear, outfit.accessory, outfit.outerwear].compactMap { $0 }
    }
} 