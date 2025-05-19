import SwiftUI

struct HomeCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.accentColor.opacity(0.10), radius: 12, x: 0, y: 6)
            content
                .padding(.vertical, 20)
                .padding(.horizontal, 20)
        }
    }
} 