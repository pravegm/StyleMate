import SwiftUI

struct CategoryCardView: View {
    let category: Category
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .fill(isExpanded ? DS.Colors.accent.opacity(0.15) : DS.Colors.backgroundSecondary)
                        .frame(width: 44, height: 44)
                    Image(systemName: category.iconName)
                        .font(DS.Font.title2)
                        .foregroundColor(DS.Colors.accent)
                }
                Text(category.rawValue)
                    .font(DS.Font.title3)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(DS.Colors.accent)
            }
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.xs)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .dsCardShadow()
        }
        .buttonStyle(PlainButtonStyle())
    }
}
