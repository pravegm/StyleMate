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
} 