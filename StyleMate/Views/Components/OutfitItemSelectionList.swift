import SwiftUI

struct OutfitItemSelectionList: View {
    @Binding var selectedItems: Set<WardrobeItem>
    @Binding var expandedCategories: Set<Category>
    @Binding var expandedProducts: Set<String>
    @Binding var previewImage: PreviewImage?
    @EnvironmentObject var wardrobeVM: WardrobeViewModel

    private var groupedItems: [(category: Category, products: [(product: String, items: [WardrobeItem])])] {
        let itemsByCategory = Dictionary(grouping: wardrobeVM.items, by: { $0.category })
        return Category.allCases.compactMap { category in
            guard let items = itemsByCategory[category], !items.isEmpty else { return nil }
            let products = Dictionary(grouping: items, by: { $0.product })
                .map { (product: $0.key, items: $0.value) }
                .sorted { $0.product.localizedCaseInsensitiveCompare($1.product) == .orderedAscending }
            return (category: category, products: products)
        }
    }

    var body: some View {
        ForEach(groupedItems, id: \.category) { group in
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                CategoryCardView(
                    category: group.category,
                    isExpanded: expandedCategories.contains(group.category),
                    onToggle: {
                        if expandedCategories.contains(group.category) {
                            expandedCategories.remove(group.category)
                        } else {
                            expandedCategories.insert(group.category)
                        }
                    }
                )

                if expandedCategories.contains(group.category) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ForEach(group.products, id: \.product) { productGroup in
                            ProductGroupView(
                                category: group.category,
                                product: productGroup.product,
                                items: productGroup.items,
                                isExpanded: expandedProducts.contains("\(group.category.rawValue)-\(productGroup.product)"),
                                onToggle: {
                                    let key = "\(group.category.rawValue)-\(productGroup.product)"
                                    if expandedProducts.contains(key) {
                                        expandedProducts.remove(key)
                                    } else {
                                        expandedProducts.insert(key)
                                    }
                                },
                                selectedItems: $selectedItems,
                                previewImage: $previewImage
                            )
                        }
                    }
                    .padding(.leading, DS.Spacing.xs)
                }
            }
        }
    }
}
