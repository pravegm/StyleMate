import SwiftUI

struct WardrobeSummaryWidget: View {
    let items: [WardrobeItem]
    var productCounts: [String: Int] {
        Dictionary(grouping: items, by: { $0.product })
            .mapValues { $0.count }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wardrobe Summary")
                .font(.headline)
            if productCounts.isEmpty {
                Text("No items in your wardrobe yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(productCounts.sorted(by: { $0.key < $1.key }), id: \.key) { key, count in
                    HStack {
                        Text("\(count) \(key)")
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
} 