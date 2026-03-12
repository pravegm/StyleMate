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
        var isDuplicate: Bool = false
        var garmentImage: UIImage?

        var material: String
        var fit: Fit?
        var neckline: Neckline?
        var sleeveLength: SleeveLength?
        var garmentLength: GarmentLength?
        var details: String
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
            items[i].isDuplicate = wardrobeViewModel.items.contains { existing in
                existing.category == items[i].category &&
                existing.product.caseInsensitiveCompare(items[i].product) == .orderedSame &&
                existing.pattern == items[i].pattern &&
                Set(existing.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }) ==
                    Set(items[i].colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
            }
        }
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

                if item.isDuplicate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.warning)
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
                    Picker("Product", selection: $item.product) {
                        ForEach(productTypesByCategory[item.category] ?? [], id: \.self) { prod in
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

            if item.isDuplicate {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DS.Colors.warning)
                    Text("This item may already be in your wardrobe")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.warning)
                }
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
