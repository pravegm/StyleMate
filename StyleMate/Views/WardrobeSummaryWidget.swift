import SwiftUI

struct WardrobeSummaryWidget: View {
    let items: [WardrobeItem]
    var onSummaryTap: ((Category, String) -> Void)? = nil

    var body: some View {
        if items.isEmpty {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "hanger")
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Your wardrobe is empty — add your first item!")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        } else {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "tshirt")
                    .foregroundColor(DS.Colors.accent)
                Text("\(items.count) item\(items.count == 1 ? "" : "s") in your wardrobe")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
    }
}
