import SwiftUI
import PhotosUI
import Foundation

struct DetectedItemCard: View {
    @Binding var item: AddNewItemView.DetectedItem
    @Binding var brand: String
    let onRemove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Category", selection: $item.category) {
                ForEach(Category.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .accessibilityLabel("Category Picker")
            .pickerStyle(.menu)
            Picker("Product", selection: $item.product) {
                ForEach(productOptionsByCategory(item.category), id: \ .self) { prod in
                    Text(prod).tag(prod)
                }
            }
            .accessibilityLabel("Product Picker")
            .pickerStyle(.menu)
            Text("Colors:")
                .font(.subheadline)
            ForEach(Array(item.colors.enumerated()), id: \ .offset) { colorIdx, _ in
                let colorBinding = Binding<String>(
                    get: { item.colors[colorIdx] },
                    set: { item.colors[colorIdx] = $0 }
                )
                HStack {
                    TextField("Color", text: colorBinding)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .accessibilityLabel("Color")
                    Spacer(minLength: 8)
                    if item.colors.count > 1 {
                        Button(action: {
                            var colors = item.colors
                            colors.remove(at: colorIdx)
                            item.colors = colors
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                                .imageScale(.large)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
            }
            Button(action: {
                var colors = item.colors
                colors.append("")
                item.colors = colors
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundColor(.green)
                    Text("Add Color")
                }
            }
            .buttonStyle(BorderlessButtonStyle())
            Picker("Pattern", selection: $item.pattern) {
                ForEach(Pattern.allCases) { pattern in
                    Text(pattern.rawValue).tag(pattern)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Pattern picker")
            TextField("Type brand name (e.g., Nike)", text: $brand)
                .textContentType(.none)
                .autocapitalization(.none)
                .accessibilityLabel("Brand")
            Button(action: onRemove) {
                HStack {
                    Image(systemName: "trash").foregroundColor(.red)
                    Text("Remove Item")
                }
            }
            .foregroundColor(.red)
            .padding(.top, 2)
            .contentShape(Rectangle())
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
    private func productOptionsByCategory(_ category: Category) -> [String] {
        productTypesByCategory[category] ?? []
    }
} 