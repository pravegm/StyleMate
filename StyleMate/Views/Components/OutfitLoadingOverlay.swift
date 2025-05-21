import SwiftUI

struct OutfitLoadingOverlay: View {
    let progress: Double
    let emoji: String
    let loadingMessages: [String]
    let animateEmoji: Bool
    @State private var animate = false
    @State private var selectedMessage: String = ""

    init(progress: Double, emoji: String, loadingMessages: [String]? = nil, animateEmoji: Bool = true) {
        self.progress = progress
        self.emoji = emoji
        let defaultMessages = [
            "Getting your outfit from StyleMate AI...",
            "Consulting the AI fashion oracle...",
            "Mixing and matching with AI...",
            "Finding your perfect AI-powered look...",
            "Styling your day with AI magic..."
        ]
        self.loadingMessages = loadingMessages ?? defaultMessages
        self.animateEmoji = animateEmoji
        _selectedMessage = State(initialValue: self.loadingMessages.randomElement() ?? defaultMessages[0])
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
            VStack(spacing: 24) {
                Text(emoji)
                    .font(.system(size: 48))
                    .scaleEffect(animateEmoji ? (animate ? 1.1 : 0.95) : 1.0)
                    .animation(animateEmoji ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: animate)
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .green))
                    .frame(width: 180)
                Text(selectedMessage)
                    .font(.headline)
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.96))
                    .shadow(radius: 12)
            )
            .onAppear {
                animate = true
                selectedMessage = loadingMessages.randomElement() ?? loadingMessages[0]
            }
        }
        .transition(.opacity)
    }
} 