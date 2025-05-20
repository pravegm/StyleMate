import SwiftUI

struct CategoryCardView: View {
    let category: Category
    let isExpanded: Bool
    let onToggle: () -> Void
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isExpanded ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                        .frame(width: 44, height: 44)
                    Image(systemName: category.iconName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                Text(category.rawValue)
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(.accentColor)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
            .shadow(color: Color.accentColor.opacity(0.06), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
    }
} 