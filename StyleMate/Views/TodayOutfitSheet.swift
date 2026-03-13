import SwiftUI

struct TodayOutfitSheet: View {
    let outfit: Outfit
    @Binding var isPresented: Bool
    @EnvironmentObject var homeVM: HomeViewModel
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var outfitsVM: MyOutfitsViewModel
    @EnvironmentObject var authService: AuthService

    @State private var previewImage: PreviewImage? = nil
    @State private var showSaveActionSheet = false
    @State private var showDatePickerSheet = false
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var showSavedOverlay = false
    @State private var showAddProductSheet = false
    @State private var addProductStep: AddProductStep? = nil
    @State private var expandedCategory: Category? = nil
    @State private var isAddingProduct: Bool = false

    // Swipe gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var cardOpacity: Double = 1
    @State private var dismissDirection: DismissDirection? = nil

    private let swipeThreshold: CGFloat = 100

    enum AddProductStep: Identifiable {
        case category
        var id: Int { hashValue }
    }

    enum DismissDirection {
        case left, right
    }

    private var contextLine: String {
        var parts: [String] = []
        if let type = homeVM.selectedOutfitType { parts.append(type.rawValue) }
        if let tempC = homeVM.lastCelsius {
            let temp = homeVM.displayFahrenheit ? Int((tempC * 9.0 / 5.0) + 32) : Int(tempC)
            parts.append("\(temp)°\(homeVM.displayFahrenheit ? "F" : "C")")
        }
        if let weather = homeVM.weather {
            parts.append(WeatherService.weatherDescription(for: weather.weathercode))
        }
        return parts.isEmpty ? "Curated for you" : parts.joined(separator: " · ")
    }

    private var currentOutfit: Outfit? {
        guard homeVM.batchIndex < homeVM.outfitBatch.count else { return nil }
        return homeVM.outfitBatch[homeVM.batchIndex]
    }

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            if homeVM.allOutfitsSeen {
                endOfBatchView
            } else if let outfit = currentOutfit {
                VStack(spacing: 0) {
                    headerView
                    outfitCard(for: outfit)
                }
            }

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
        .alert("Too Many Requests", isPresented: $homeVM.showRateLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're shuffling too fast! Please wait a moment and try again.")
        }
        .actionSheet(isPresented: $showSaveActionSheet) {
            ActionSheet(title: Text("Save Outfit"), message: Text("How would you like to save this outfit?"), buttons: [
                .default(Text("Save for today")) {
                    saveOutfitForDate(Calendar.current.startOfDay(for: Date()))
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
                        saveOutfitForDate(selectedDate)
                        showDatePickerSheet = false
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
        .sheet(item: $addProductStep) { _ in
            addProductSheetContent
        }
        .onChange(of: showAddProductSheet) { newValue in
            if newValue {
                addProductStep = .category
                expandedCategory = nil
            }
        }
        .onChange(of: addProductStep) { newValue in
            if newValue == nil { showAddProductSheet = false }
        }
        .onChange(of: homeVM.isLoading) { loading in
            if !loading { isAddingProduct = false }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Today's Outfit")
                        .font(DS.Font.title1)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(contextLine)
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                if !homeVM.outfitBatch.isEmpty {
                    Text("\(homeVM.batchIndex + 1) of \(homeVM.outfitBatch.count)")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.micro)
                        .background(DS.Colors.backgroundSecondary)
                        .clipShape(Capsule())
                }
            }

            progressDots
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: DS.Spacing.micro) {
            ForEach(0..<homeVM.outfitBatch.count, id: \.self) { idx in
                Circle()
                    .fill(idx == homeVM.batchIndex ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.3))
                    .frame(width: idx == homeVM.batchIndex ? 8 : 6, height: idx == homeVM.batchIndex ? 8 : 6)
                    .animation(.easeInOut(duration: 0.2), value: homeVM.batchIndex)
            }
        }
    }

    // MARK: - Outfit Card

    @ViewBuilder
    private func outfitCard(for outfit: Outfit) -> some View {
        let sortedItems = outfit.items.sorted { $0.category.wearingOrder < $1.category.wearingOrder }

        ScrollView {
            VStack(spacing: DS.Spacing.sm) {
                ForEach(sortedItems, id: \.id) { item in
                    OutfitItemRow(
                        item: item,
                        onTap: {
                            if let img = item.croppedImage ?? item.image {
                                previewImage = PreviewImage(image: img)
                            }
                        },
                        onShuffle: {
                            Haptics.light()
                            homeVM.shuffleItemInOutfit(
                                itemToShuffle: item,
                                wardrobe: wardrobeViewModel.items,
                                user: authService.user
                            )
                        },
                        isLoading: homeVM.isLoading
                    )
                }

                if !outfit.explanation.isEmpty {
                    HStack(alignment: .top, spacing: DS.Spacing.xs) {
                        Image(systemName: "sparkles")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.accent)
                            .padding(.top, 2)

                        Text(outfit.explanation)
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DS.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.accent.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                }
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.bottom, DS.Spacing.xxxl + DS.Spacing.xxl)
        }
        .offset(x: dragOffset.width)
        .rotationEffect(.degrees(cardRotation))
        .opacity(cardOpacity)
        .gesture(swipeGesture)
        .overlay(alignment: .bottom) {
            bottomActionBar
        }
    }

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
                cardRotation = Double(value.translation.width / 20)
                let progress = min(abs(value.translation.width) / swipeThreshold, 1.0)
                cardOpacity = 1.0 - (progress * 0.3)
            }
            .onEnded { value in
                if value.translation.width > swipeThreshold {
                    dismissCard(direction: .right)
                } else if value.translation.width < -swipeThreshold {
                    dismissCard(direction: .left)
                } else {
                    resetCardPosition()
                }
            }
    }

    private func dismissCard(direction: DismissDirection) {
        let offscreenX: CGFloat = direction == .right ? 500 : -500
        let rotation: Double = direction == .right ? 15 : -15

        withAnimation(.easeIn(duration: 0.3)) {
            dragOffset = CGSize(width: offscreenX, height: 0)
            cardRotation = rotation
            cardOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if direction == .right {
                showSaveActionSheet = true
                homeVM.saveCurrentOutfit()
            } else {
                homeVM.skipCurrentOutfit()
            }
            resetCardPosition()
        }
    }

    private func resetCardPosition() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            dragOffset = .zero
            cardRotation = 0
            cardOpacity = 1
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: {
                Haptics.light()
                dismissCard(direction: .left)
            }) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "xmark")
                    Text("Skip")
                }
            }
            .buttonStyle(DSSecondaryButton())

            Menu {
                Button(action: {
                    Haptics.light()
                    showAddProductSheet = true
                }) {
                    Label("Add Item", systemImage: "plus.circle")
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "ellipsis.circle")
                    Text("More")
                }
                .font(DS.Font.headline)
                .foregroundColor(DS.Colors.accent)
                .frame(maxWidth: .infinity)
                .frame(height: DS.ButtonSize.height)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card)
                        .stroke(DS.Colors.accent, lineWidth: 1.5)
                )
            }

            Button(action: {
                Haptics.medium()
                dismissCard(direction: .right)
            }) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "checkmark")
                    Text("Save")
                }
            }
            .buttonStyle(DSPrimaryButton())
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.vertical, DS.Spacing.md)
        .dsGlassBar(cornerRadius: DS.Spacing.md)
    }

    // MARK: - End of Batch View

    private var endOfBatchView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 56))
                .foregroundColor(DS.Colors.accent)

            Text("All Caught Up!")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)

            VStack(spacing: DS.Spacing.xs) {
                if homeVM.savedCount > 0 {
                    Label("\(homeVM.savedCount) outfit\(homeVM.savedCount == 1 ? "" : "s") saved", systemImage: "heart.fill")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.success)
                }
                if homeVM.skippedCount > 0 {
                    Label("\(homeVM.skippedCount) skipped", systemImage: "arrow.right")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Text("Want more suggestions?")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)

            Button(action: {
                Haptics.medium()
                homeVM.suggestTodayOutfit(from: wardrobeViewModel.items, user: authService.user)
            }) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "sparkles")
                    Text("Generate More")
                }
            }
            .buttonStyle(DSPrimaryButton())
            .padding(.horizontal, DS.Spacing.xl)

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(DSTertiaryButton())

            Spacer()
        }
        .padding(.horizontal, DS.Spacing.screenH)
    }

    // MARK: - Add Product Sheet

    private var addProductSheetContent: some View {
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
                                    addProductStep = nil
                                    isAddingProduct = true
                                    homeVM.addProductToOutfit(
                                        category: category,
                                        productType: product,
                                        wardrobe: wardrobeViewModel.items,
                                        user: authService.user
                                    )
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

    // MARK: - Save Helper

    private func saveOutfitForDate(_ date: Date) {
        guard let outfit = currentOutfit else { return }
        outfitsVM.addOutfit(date: date, items: outfit.items, source: "gemini")
        Haptics.success()
        showSavedOverlay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showSavedOverlay = false
            homeVM.advanceToNextOutfit()
        }
    }
}

// MARK: - Outfit Item Row

private struct OutfitItemRow: View {
    let item: WardrobeItem
    let onTap: () -> Void
    let onShuffle: () -> Void
    let isLoading: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            Button(action: onTap) {
                if let uiImage = item.thumbnailImage ?? item.croppedImage ?? item.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .fill(DS.Colors.backgroundSecondary)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(DS.Colors.textTertiary)
                        )
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text(item.category.rawValue)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.accent)

                Text(item.product)
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Text(item.colors.joined(separator: ", "))
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                if !item.brand.isEmpty {
                    Text(item.brand)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onShuffle) {
                VStack(spacing: DS.Spacing.micro) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(DS.Font.body)
                        .foregroundColor(DS.Colors.accent)
                    Text("Swap")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(DS.Spacing.sm)
                .background(DS.Colors.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            }
            .disabled(isLoading)
            .opacity(isLoading ? 0.4 : 1.0)
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
    }
}
