import SwiftUI

struct ProductCategoryKey: Hashable {
    let product: String
    let category: Category
}

struct ProductSummary: Hashable {
    let product: String
    let count: Int
    let category: Category
}

struct WardrobeSummaryWidget: View {
    let items: [WardrobeItem]
    var productCounts: [ProductSummary] {
        let grouped = Dictionary(grouping: items, by: { ProductCategoryKey(product: $0.product, category: $0.category) })
        return grouped.map { (key, value) in
            ProductSummary(product: key.product, count: value.count, category: key.category)
        }
        .sorted { $0.product < $1.product }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.85))
                .shadow(color: Color.accentColor.opacity(0.08), radius: 8, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Your Wardrobe at a Glance")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("✨")
                        .font(.title2)
                }
                if productCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your wardrobe is looking a little empty...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Add your first item to get started!")
                            .font(.footnote)
                            .foregroundColor(.accentColor)
                    }
                    .padding(.vertical, 8)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(productCounts, id: \.self) { summary in
                                let icon = summary.category.iconName
                                let color = summary.category.iconColor
                                HStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(color.opacity(0.13))
                                            .frame(width: 32, height: 32)
                                        Image(systemName: icon)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(color)
                                    }
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("\(summary.count) \(summary.product)")
                                            .font(.subheadline.bold())
                                            .foregroundColor(color)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 14)
                                .background(
                                    BlurView(style: .systemMaterial)
                                        .clipShape(Capsule())
                                        .opacity(0.85)
                                )
                                .clipShape(Capsule())
                                .shadow(color: color.opacity(0.08), radius: 4, x: 0, y: 2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
        }
    }
} 