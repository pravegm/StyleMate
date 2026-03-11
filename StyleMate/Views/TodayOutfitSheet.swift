import SwiftUI

struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    @State private var previewImage: PreviewImage? = nil
    @EnvironmentObject var homeVM: HomeViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @State private var showSaveActionSheet = false
    @State private var showDatePickerSheet = false
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var showSavedOverlay = false
    @State private var showAddProductSheet = false
    @State private var addProductStep: AddProductStep? = nil
    @State private var selectedCategory: Category? = nil
    @State private var expandedCategory: Category? = nil
    @State private var selectedProductType: String? = nil
    @State private var isAddingProduct: Bool = false

    enum AddProductStep: Identifiable {
        case category, product
        var id: Int { hashValue }
    }

    private var contextLine: String {
        var parts: [String] = []
        if let type = homeVM.selectedOutfitType { parts.append(type.rawValue) }
        if let tempC = homeVM.lastCelsius {
            let temp = homeVM.displayFahrenheit ? Int((tempC * 9.0 / 5.0) + 32) : Int(tempC)
            parts.append("\(temp)°\(homeVM.displayFahrenheit ? "F" : "C")")
        }
        if let weather = homeVM.weather {
            parts.append(weatherDescription(for: weather.weathercode))
        }
        return parts.isEmpty ? "Curated for you" : parts.joined(separator: " · ")
    }

    private let photoColumns = [
        GridItem(.flexible(), spacing: DS.Spacing.sm),
        GridItem(.flexible(), spacing: DS.Spacing.sm)
    ]

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Today's Outfit")
                        .font(DS.Font.title1)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(contextLine)
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.top, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.md)

                // Outfit items grid
                ScrollView {
                    LazyVGrid(columns: photoColumns, spacing: DS.Spacing.sm) {
                        ForEach(outfitItems, id: \.id) { item in
                            OutfitItemTile(
                                item: item,
                                onTap: {
                                    if let img = item.croppedImage ?? item.image {
                                        previewImage = PreviewImage(image: img)
                                    }
                                },
                                onShuffle: {
                                    Haptics.light()
                                    homeVM.shuffleItemInOutfit(itemToShuffle: item, wardrobe: wardrobeViewModel.items)
                                },
                                isLoading: homeVM.isLoading
                            )
                        }
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, 120)
                }

                Spacer(minLength: 0)

                // Bottom action bar
                HStack(spacing: DS.Spacing.sm) {
                    Button(action: {
                        Haptics.light()
                        homeVM.shuffleOutfit()
                    }) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Shuffle All")
                        }
                    }
                    .buttonStyle(DSSecondaryButton())

                    Button(action: {
                        Haptics.medium()
                        showSaveActionSheet = true
                    }) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Save Outfit")
                        }
                    }
                    .buttonStyle(DSPrimaryButton())
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.vertical, DS.Spacing.md)
                .dsGlassBar(cornerRadius: DS.Spacing.md)
            }

            // Loading overlay
            if homeVM.isLoading {
                Color.black.opacity(0.18).ignoresSafeArea()
                ProgressView(isAddingProduct ? "Adding…" : "Shuffling…")
                    .padding(DS.Spacing.xl)
                    .background(DS.Colors.backgroundCard)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            }

            if showSavedOverlay {
                VStack {
                    Spacer()
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.title3)
                        .foregroundColor(.white)
                        .padding(.vertical, DS.Spacing.md)
                        .padding(.horizontal, DS.Spacing.xl)
                        .background(DS.Colors.success)
                        .clipShape(Capsule())
                    Spacer()
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image).padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .buttonStyle(DSSecondaryButton())
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.lg)
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
        .actionSheet(isPresented: $showSaveActionSheet) {
            ActionSheet(title: Text("Save Outfit"), message: Text("How would you like to save this outfit?"), buttons: [
                .default(Text("Save for today")) {
                    let today = Calendar.current.startOfDay(for: Date())
                    outfitsVM.addOutfit(date: today, items: outfit.items, source: "gemini")
                    Haptics.success()
                    showSavedOverlay = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        showSavedOverlay = false
                        isPresented = false
                    }
                },
                .default(Text("Choose a date")) {
                    selectedDate = Calendar.current.startOfDay(for: Date())
                    showDatePickerSheet = true
                },
                .cancel()
            ])
        }
        .sheet(isPresented: $showDatePickerSheet) {
            NavigationView {
                VStack(spacing: DS.Spacing.lg) {
                    DatePicker("Select Date", selection: $selectedDate, displayedComponents: [.date])
                        .datePickerStyle(GraphicalDatePickerStyle())
                        .padding()

                    Button("Save") {
                        outfitsVM.addOutfit(date: selectedDate, items: outfit.items, source: "gemini")
                        Haptics.success()
                        showSavedOverlay = true
                        showDatePickerSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            showSavedOverlay = false
                            isPresented = false
                        }
                    }
                    .buttonStyle(DSPrimaryButton())
                    .padding(.horizontal, DS.Spacing.screenH)

                    Button("Cancel") { showDatePickerSheet = false }
                        .buttonStyle(DSTertiaryButton())
                }
                .padding()
                .navigationTitle("Choose Date")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddProductSheet = true } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(DS.Colors.accent)
                }
            }
        }
        .sheet(item: $addProductStep) { step in
            if step == .category {
                NavigationView {
                    List {
                        ForEach(Category.allCases.filter { category in
                            wardrobeViewModel.items.contains(where: { $0.category == category })
                        }, id: \.self) { category in
                            Section(header:
                                HStack {
                                    Text(category.rawValue)
                                        .font(DS.Font.headline)
                                        .foregroundColor(DS.Colors.accent)
                                    Spacer()
                                    Image(systemName: expandedCategory == category ? "chevron.down" : "chevron.right")
                                        .foregroundColor(DS.Colors.accent)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation { expandedCategory = expandedCategory == category ? nil : category }
                                }
                            ) {
                                if expandedCategory == category {
                                    let userProducts = Set(wardrobeViewModel.items.filter { $0.category == category }.map { $0.product })
                                    let products = (productTypesByCategory[category] ?? []).filter { userProducts.contains($0) }
                                    ForEach(products, id: \.self) { product in
                                        Button(action: {
                                            selectedCategory = category
                                            selectedProductType = product
                                            addProductStep = nil
                                            isAddingProduct = true
                                            homeVM.addProductToOutfit(category: category, productType: product, wardrobe: wardrobeViewModel.items)
                                        }) {
                                            Text(product)
                                                .font(DS.Font.body)
                                                .foregroundColor(DS.Colors.textPrimary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Add Product")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { addProductStep = nil }
                        }
                    }
                }
            }
        }
        .onChange(of: showAddProductSheet) { newValue in
            if newValue {
                addProductStep = .category
                expandedCategory = nil
                selectedProductType = nil
            }
        }
        .onChange(of: addProductStep) { newValue in
            if newValue == nil { showAddProductSheet = false }
        }
        .onChange(of: homeVM.isLoading) { loading in
            if !loading { isAddingProduct = false }
        }
    }

    var outfitItems: [WardrobeItem] { outfit.items }

    private func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return ""
        }
    }
}

// MARK: - Outfit Item Tile

private struct OutfitItemTile: View {
    let item: WardrobeItem
    let onTap: () -> Void
    let onShuffle: () -> Void
    let isLoading: Bool

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            Button(action: onTap) {
                if let uiImage = item.croppedImage ?? item.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .fill(DS.Colors.backgroundSecondary)
                        .frame(height: 110)
                        .overlay(Text("No Image").font(DS.Font.caption2).foregroundColor(DS.Colors.textTertiary))
                }
            }
            .buttonStyle(.plain)

            Text(item.product)
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Text(item.colors.joined(separator: ", "))
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            Button(action: onShuffle) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.accent)
                    .padding(DS.Spacing.xs)
                    .background(DS.Colors.accent.opacity(0.1))
                    .clipShape(Circle())
            }
            .disabled(isLoading)
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
    }
}
