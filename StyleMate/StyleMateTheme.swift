import SwiftUI

struct StyleMateTheme {
    static let accent = Color("AccentColor", bundle: nil) // fallback to .indigo
    static let secondary = Color.orange
    static let cardBackground = Color(UIColor.systemBackground)
    static let cardShadow = Color.black.opacity(0.1)
    static let neutralLight = Color(UIColor.secondarySystemBackground)
    static let neutralDark = Color(UIColor.label)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}

extension View {
    func styleMateCard() -> some View {
        self
            .background(StyleMateTheme.cardBackground)
            .cornerRadius(12)
            .shadow(color: StyleMateTheme.cardShadow, radius: 4, x: 0, y: 2)
    }
    func styleMatePrimaryButton() -> some View {
        self
            .font(.headline)
            .foregroundColor(.white)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(StyleMateTheme.accent)
            .cornerRadius(12)
            .contentShape(Rectangle())
    }
    func styleMateSecondaryButton() -> some View {
        self
            .font(.headline)
            .foregroundColor(StyleMateTheme.accent)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(StyleMateTheme.accent, lineWidth: 2)
            )
            .background(StyleMateTheme.cardBackground)
            .cornerRadius(12)
            .contentShape(Rectangle())
    }
    func styleMateSectionSpacing() -> some View {
        self.padding(.vertical, 24)
    }
    func styleMateElementSpacing() -> some View {
        self.padding(.vertical, 8)
    }
} 