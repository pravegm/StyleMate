import SwiftUI

struct EditWardrobeItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category
    @State private var product: String
    @State private var colors: [String]
    @State private var brand: String
    @State private var pattern: Pattern
    let imagePath: String
    let croppedImagePath: String?
    let id: UUID
    var onSave: (WardrobeItem) -> Void

    init(item: WardrobeItem, onSave: @escaping (WardrobeItem) -> Void) {
        _category = State(initialValue: item.category)
        _product = State(initialValue: item.product)
        _colors = State(initialValue: item.colors)
        _brand = State(initialValue: item.brand)
        _pattern = State(initialValue: item.pattern)
        self.imagePath = item.imagePath
        self.croppedImagePath = item.croppedImagePath
        self.id = item.id
        self.onSave = onSave
    }

    var productOptions: [String] {
        productTypesByCategory[category] ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(Category.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .tint(DS.Colors.accent)

                Picker("Product", selection: $product) {
                    ForEach(productOptions, id: \.self) { prod in
                        Text(prod).tag(prod)
                    }
                }
                .tint(DS.Colors.accent)

                Section(header: Text("Colors")) {
                    ForEach(colors.indices, id: \.self) { idx in
                        HStack(spacing: DS.Spacing.xs) {
                            colorSwatch(for: colors[idx])

                            TextField("Color", text: Binding(
                                get: { colors[idx] },
                                set: { colors[idx] = $0 }
                            ))

                            if colors.count > 1 {
                                Button(action: { colors.remove(at: idx) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(DS.Colors.error)
                                }
                            }
                        }
                    }
                    Button(action: { colors.append("") }) {
                        Label("Add Color", systemImage: "plus.circle.fill")
                            .foregroundColor(DS.Colors.success)
                    }
                }

                Picker("Pattern", selection: $pattern) {
                    ForEach(Pattern.allCases) { pat in
                        Text(pat.rawValue).tag(pat)
                    }
                }
                .tint(DS.Colors.accent)

                TextField("Brand (e.g. Nike)", text: $brand)
            }
            .tint(DS.Colors.accent)
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.medium()
                        let updatedItem = WardrobeItem(
                            id: id,
                            category: category,
                            product: product,
                            colors: colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                            brand: brand,
                            pattern: pattern,
                            imagePath: imagePath,
                            croppedImagePath: croppedImagePath
                        )
                        onSave(updatedItem)
                        dismiss()
                    }
                    .disabled(product.isEmpty || colors.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
    }

    @ViewBuilder
    private func colorSwatch(for colorName: String) -> some View {
        let name = colorName.lowercased().trimmingCharacters(in: .whitespaces)
        let color: Color = {
            switch name {
            case "black": return .black
            case "white": return .white
            case "red": return .red
            case "blue": return .blue
            case "green": return .green
            case "yellow": return .yellow
            case "orange": return .orange
            case "pink": return .pink
            case "purple": return .purple
            case "brown": return .brown
            case "gray", "grey": return .gray
            case "navy": return Color(red: 0, green: 0, blue: 0.5)
            case "beige": return Color(red: 0.96, green: 0.96, blue: 0.86)
            case "cream": return Color(red: 1, green: 0.99, blue: 0.82)
            case "teal": return .teal
            default: return DS.Colors.backgroundSecondary
            }
        }()

        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
    }
}
