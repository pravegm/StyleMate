import SwiftUI

struct AddItemReviewView: View {
    let images: [UIImage]
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService

    @State private var isAnalyzing = true
    @State private var progress: Double = 0.0
    @State private var progressTimer: Timer? = nil
    @State private var reviewItems: [ReviewItem] = []

    struct ReviewItem: Identifiable {
        let id = UUID()
        let sourceImageIndex: Int
        var category: Category
        var product: String
        var colors: [String]
        var pattern: Pattern
        var brand: String
        var isSelected: Bool = true
        var duplicateMatch: DuplicateMatch?
        var garmentImage: UIImage?

        var material: String
        var fit: Fit?
        var neckline: Neckline?
        var sleeveLength: SleeveLength?
        var garmentLength: GarmentLength?
        var details: String

        var isDuplicate: Bool { duplicateMatch != nil }
    }

    var selectedCount: Int { reviewItems.filter(\.isSelected).count }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                if isAnalyzing {
                    OutfitLoadingOverlay(progress: progress, message: "Analyzing your items…")
                        .onAppear {
                            progress = 0.0
                            progressTimer?.invalidate()
                            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { timer in
                                if progress < 0.98 { progress += 0.006 } else { timer.invalidate() }
                            }
                        }
                        .onDisappear { progressTimer?.invalidate() }
                } else if reviewItems.isEmpty {
                    VStack(spacing: DS.Spacing.md) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 40))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("No items detected")
                            .font(DS.Font.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Try again with clearer photos of your clothing.")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: DS.Spacing.sm) {
                                if authService.user?.gender == nil || (authService.user?.gender ?? "").isEmpty {
                                    HStack(spacing: DS.Spacing.sm) {
                                        Image(systemName: "sparkles")
                                            .foregroundColor(DS.Colors.accent)
                                        VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                                            Text("Improve detection accuracy")
                                                .font(DS.Font.subheadline)
                                                .foregroundColor(DS.Colors.textPrimary)
                                            Text("Add your gender in Profile for better results")
                                                .font(DS.Font.caption1)
                                                .foregroundColor(DS.Colors.textSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(DS.Spacing.sm)
                                    .background(DS.Colors.accent.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                }

                                Text("\(selectedCount) of \(reviewItems.count) items selected")
                                    .font(DS.Font.subheadline)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .padding(.top, DS.Spacing.sm)

                                ForEach($reviewItems) { $item in
                                    ReviewItemRow(item: $item, wardrobeItems: wardrobeViewModel.items)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.screenH)
                            .padding(.bottom, 100)
                        }

                        VStack(spacing: 0) {
                            Divider()
                            Button(action: addSelectedItems) {
                                HStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add \(selectedCount) Items to Wardrobe")
                                }
                            }
                            .buttonStyle(DSPrimaryButton(isDisabled: selectedCount == 0))
                            .disabled(selectedCount == 0)
                            .padding(.horizontal, DS.Spacing.screenH)
                            .padding(.vertical, DS.Spacing.md)
                        }
                        .dsGlassBar()
                    }
                }
            }
            .navigationTitle("Review Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .interactiveDismissDisabled()
            .onAppear { analyzeAllImages() }
        }
    }

    // MARK: - Analysis

    private func analyzeAllImages() {
        isAnalyzing = true
        Task {
            var allItems: [ReviewItem] = []
            let userGender = authService.user?.gender

            await withTaskGroup(of: (Int, [ImageAnalysisService.SegmentedItem]).self) { group in
                for (idx, image) in images.enumerated() {
                    group.addTask {
                        let results = await ImageAnalysisService.shared.analyzeAndSegment(
                            image: image,
                            userGender: userGender
                        )
                        return (idx, results)
                    }
                }
                for await (idx, results) in group {
                    var items = results.compactMap { seg -> ReviewItem? in
                        guard let cat = seg.category, let prod = seg.product,
                              let pattern = seg.pattern, !seg.colors.isEmpty else { return nil }
                        return ReviewItem(
                            sourceImageIndex: idx,
                            category: cat,
                            product: prod,
                            colors: seg.colors,
                            pattern: pattern,
                            brand: "",
                            garmentImage: seg.maskImage,
                            material: seg.material ?? "",
                            fit: seg.fit,
                            neckline: seg.neckline,
                            sleeveLength: seg.sleeveLength,
                            garmentLength: seg.garmentLength,
                            details: seg.details ?? ""
                        )
                    }
                    let footwearIndices = items.indices.filter { items[$0].category == .footwear }
                    if footwearIndices.count > 1 {
                        items = items.enumerated().filter { i, item in
                            item.category != .footwear || i == footwearIndices.first
                        }.map(\.element)
                    }
                    items = deduplicateAccessories(items)
                    allItems.append(contentsOf: items)
                }
            }

            allItems.sort { $0.sourceImageIndex < $1.sourceImageIndex }
            markDuplicates(&allItems)

            await MainActor.run {
                reviewItems = allItems
                isAnalyzing = false
                progress = 1.0
            }
        }
    }

    private func markDuplicates(_ items: inout [ReviewItem]) {
        for i in items.indices {
            items[i].duplicateMatch = DuplicateDetector.shared.findBestMatch(
                category: items[i].category,
                product: items[i].product,
                colors: items[i].colors,
                pattern: items[i].pattern,
                material: items[i].material.isEmpty ? nil : items[i].material,
                fit: items[i].fit,
                neckline: items[i].neckline,
                sleeveLength: items[i].sleeveLength,
                existingItems: wardrobeViewModel.items
            )
        }
    }

    private func deduplicateAccessories(_ items: [ReviewItem]) -> [ReviewItem] {
        var result = items
        let imageGroups = Dictionary(grouping: result.indices.filter { result[$0].category == .accessories },
                                      by: { result[$0].sourceImageIndex })

        var indicesToRemove: Set<Int> = []

        for (_, indices) in imageGroups {
            let accessoryItems = indices.map { (index: $0, item: result[$0]) }

            // Rule 1: If both "Watches" and a wrist jewelry item exist, drop the jewelry if colors overlap
            let watchIndices = accessoryItems.filter { $0.item.product == "Watches" }
            let wristJewelry = accessoryItems.filter { ["Bracelets", "Jewelry", "Chains"].contains($0.item.product) }
            if !watchIndices.isEmpty && !wristJewelry.isEmpty {
                for wj in wristJewelry {
                    let watchColors = Set(watchIndices.first!.item.colors.map { $0.lowercased() })
                    let jewelryColors = Set(wj.item.colors.map { $0.lowercased() })
                    if !watchColors.intersection(jewelryColors).isEmpty {
                        indicesToRemove.insert(wj.index)
                    }
                }
            }

            // Rule 2: Same product type with overlapping colors = duplicate (e.g., two "Earrings" with "Gold")
            let productGroups = Dictionary(grouping: accessoryItems, by: { $0.item.product })
            for (_, productItems) in productGroups where productItems.count > 1 {
                let colorSets = productItems.map { Set($0.item.colors.map { $0.lowercased() }) }
                for i in 1..<productItems.count {
                    let overlap = colorSets[0].intersection(colorSets[i])
                    if !overlap.isEmpty {
                        indicesToRemove.insert(productItems[i].index)
                    }
                }
            }

            // Rule 3: If multiple glasses types exist from same image, keep only the first
            let glassesProducts = ["Sunglasses", "Eyeglasses", "Reading Glasses"]
            let glassesItems = accessoryItems.filter { glassesProducts.contains($0.item.product) }
            if glassesItems.count > 1 {
                for item in glassesItems.dropFirst() {
                    indicesToRemove.insert(item.index)
                }
            }
        }

        for idx in indicesToRemove.sorted(by: >) {
            result.remove(at: idx)
        }

        return result
    }

    // MARK: - Save

    private func addSelectedItems() {
        let selected = reviewItems.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        Haptics.success()

        for item in selected {
            let fullImage = item.garmentImage ?? images[item.sourceImageIndex]
            let imagePath = WardrobeImageFileHelper.saveImageAsPNG(fullImage) ?? WardrobeImageFileHelper.saveImage(fullImage) ?? ""
            let croppedImagePath = imagePath

            let wardrobeItem = WardrobeItem(
                category: item.category,
                product: item.product,
                colors: item.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                brand: item.brand,
                pattern: item.pattern,
                imagePath: imagePath,
                croppedImagePath: croppedImagePath,
                material: item.material.isEmpty ? nil : item.material,
                fit: item.fit,
                neckline: item.neckline,
                sleeveLength: item.sleeveLength,
                garmentLength: item.garmentLength,
                details: item.details.isEmpty ? nil : item.details
            )
            wardrobeViewModel.items.append(wardrobeItem)
            wardrobeViewModel.syncItemToCloud(wardrobeItem)
        }

        isPresented = false
    }
}

// MARK: - Review Item Row

private struct ReviewItemRow: View {
    @Binding var item: AddItemReviewView.ReviewItem
    let wardrobeItems: [WardrobeItem]

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                Button(action: {
                    Haptics.light()
                    item.isSelected.toggle()
                }) {
                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(DS.Font.title3)
                        .foregroundColor(item.isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let img = item.garmentImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                }

                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text(item.category.rawValue)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.accent)
                    Text(item.product)
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: DS.Spacing.micro) {
                        Text(item.colors.joined(separator: ", "))
                        if !item.material.isEmpty {
                            Text("·")
                            Text(item.material)
                        }
                    }
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                }

                Spacer()

                if let match = item.duplicateMatch {
                    HStack(spacing: DS.Spacing.xs) {
                        if let existingImage = match.existingItem.croppedImage ?? match.existingItem.image {
                            Image(uiImage: existingImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(DS.Colors.warning.opacity(0.4), lineWidth: 1)
                                )
                        }

                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.warning)
                    }
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if isExpanded {
                expandedFields
                    .padding(.top, DS.Spacing.sm)
                    .padding(.leading, 44 + DS.Spacing.sm)
            }
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
        .opacity(item.isSelected ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    @ViewBuilder
    private var expandedFields: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {

            if let match = item.duplicateMatch {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DS.Colors.warning)
                        Text("Similar item already in your wardrobe")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.warning)
                    }

                    HStack(spacing: DS.Spacing.sm) {
                        if let existingImage = match.existingItem.croppedImage ?? match.existingItem.image {
                            Image(uiImage: existingImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                        }

                        VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                            Text(match.existingItem.name)
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(2)
                            if let details = match.existingItem.detailsSubtitle {
                                Text(details)
                                    .font(DS.Font.caption2)
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                    .padding(DS.Spacing.sm)
                    .background(DS.Colors.warning.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Category")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                    Picker("Category", selection: $item.category) {
                        ForEach(Category.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.Colors.accent)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Product")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                    let standardProducts = productTypesByCategory[item.category] ?? []
                    Picker("Product", selection: $item.product) {
                        if !standardProducts.contains(item.product) && !item.product.isEmpty {
                            Text(item.product).tag(item.product)
                        }
                        ForEach(standardProducts, id: \.self) { prod in
                            Text(prod).tag(prod)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.Colors.accent)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Colors")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)

                ForEach(item.colors.indices, id: \.self) { colorIdx in
                    HStack(spacing: DS.Spacing.xs) {
                        colorSwatch(for: item.colors[colorIdx])

                        TextField("Color", text: Binding(
                            get: { item.colors[colorIdx] },
                            set: { item.colors[colorIdx] = $0 }
                        ))
                        .font(DS.Font.body)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .submitLabel(.done)

                        if item.colors.count > 1 {
                            Button(action: { item.colors.remove(at: colorIdx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(DS.Colors.error)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button(action: { item.colors.append("") }) {
                    HStack(spacing: DS.Spacing.micro) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(DS.Colors.success)
                        Text("Add Color")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.accent)
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Pattern")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                    Picker("Pattern", selection: $item.pattern) {
                        ForEach(Pattern.allCases) { pat in
                            Text(pat.rawValue).tag(pat)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.Colors.accent)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Brand")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                    TextField("e.g. Nike", text: $item.brand)
                        .font(DS.Font.body)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .submitLabel(.done)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text("Material")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)
                TextField("e.g. Cotton, Denim, Wool", text: $item.material)
                    .font(DS.Font.body)
                    .textContentType(.none)
                    .autocapitalization(.none)
                    .submitLabel(.done)
            }

            HStack(spacing: DS.Spacing.sm) {
                if ![.footwear, .accessories].contains(item.category) {
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Fit")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                        Picker("Fit", selection: Binding(
                            get: { item.fit ?? .regular },
                            set: { item.fit = $0 }
                        )) {
                            ForEach(Fit.allCases) { f in Text(f.rawValue).tag(f) }
                        }
                        .pickerStyle(.menu)
                        .tint(DS.Colors.accent)
                    }
                }

                if [.tops, .midLayers, .onePieces, .outerwear].contains(item.category) {
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Neckline")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                        Picker("Neckline", selection: Binding(
                            get: { item.neckline ?? .crewNeck },
                            set: { item.neckline = $0 }
                        )) {
                            ForEach(Neckline.allCases) { n in Text(n.rawValue).tag(n) }
                        }
                        .pickerStyle(.menu)
                        .tint(DS.Colors.accent)
                    }
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                if [.tops, .midLayers, .outerwear, .onePieces, .activewear].contains(item.category) {
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Sleeve Length")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                        Picker("Sleeve Length", selection: Binding(
                            get: { item.sleeveLength ?? .longSleeve },
                            set: { item.sleeveLength = $0 }
                        )) {
                            ForEach(SleeveLength.allCases) { s in Text(s.rawValue).tag(s) }
                        }
                        .pickerStyle(.menu)
                        .tint(DS.Colors.accent)
                    }
                }

                if [.bottoms, .onePieces, .outerwear].contains(item.category) {
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Length")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                        Picker("Length", selection: Binding(
                            get: { item.garmentLength ?? .fullLength },
                            set: { item.garmentLength = $0 }
                        )) {
                            ForEach(GarmentLength.allCases) { l in Text(l.rawValue).tag(l) }
                        }
                        .pickerStyle(.menu)
                        .tint(DS.Colors.accent)
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text("Details")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)
                TextField("e.g. ribbed cuffs, front zip, logo on chest", text: $item.details)
                    .font(DS.Font.body)
                    .textContentType(.none)
                    .autocapitalization(.none)
                    .submitLabel(.done)
            }

        }
    }

    @ViewBuilder
    private func colorSwatch(for colorName: String) -> some View {
        let name = colorName.lowercased().trimmingCharacters(in: .whitespaces)
        let color: Color = {
            switch name {
            case "black":  return .black
            case "white":  return .white
            case "red":    return .red
            case "blue":   return .blue
            case "green":  return .green
            case "yellow": return .yellow
            case "orange": return .orange
            case "pink":   return .pink
            case "purple": return .purple
            case "brown":  return .brown
            case "gray", "grey": return .gray
            case "navy":   return Color(red: 0, green: 0, blue: 0.5)
            case "beige":  return Color(red: 0.96, green: 0.96, blue: 0.86)
            case "cream":  return Color(red: 1, green: 0.99, blue: 0.82)
            case "maroon": return Color(red: 0.5, green: 0, blue: 0)
            case "teal":   return .teal
            case "olive":  return Color(red: 0.5, green: 0.5, blue: 0)
            default:       return DS.Colors.backgroundSecondary
            }
        }()

        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
    }
}
