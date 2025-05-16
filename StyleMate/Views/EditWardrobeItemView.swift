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
                Picker("Product", selection: $product) {
                    ForEach(productOptions, id: \.self) { prod in
                        Text(prod).tag(prod)
                    }
                }
                Section(header: Text("Colors")) {
                    ForEach(colors.indices, id: \.self) { idx in
                        HStack {
                            TextField("Color", text: Binding(
                                get: { colors[idx] },
                                set: { colors[idx] = $0 }
                            ))
                            if colors.count > 1 {
                                Button(action: { colors.remove(at: idx) }) {
                                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                                }
                            }
                        }
                    }
                    Button(action: { colors.append("") }) {
                        Label("Add Color", systemImage: "plus.circle.fill")
                    }
                }
                Picker("Pattern", selection: $pattern) {
                    ForEach(Pattern.allCases) { pat in
                        Text(pat.rawValue).tag(pat)
                    }
                }
                TextField("Brand (e.g. Nike)", text: $brand)
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
} 