import SwiftUI

// The deck's two taste-learning touches (Services/Outfits/TasteProfile): the one-line
// "Picked because…" under a stylist note, and the optional "Not my style / Not today"
// after a skip.

/// "Picked because you often wear navy with grey", under the stylist note.
struct TasteReasonLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "heart.text.square")
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
        }
        .labelStyle(.titleAndIcon)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("outfit.tasteReason")
    }
}

/// After a skip: "Skipped. Not my style · Not today". Optional: it settles as a plain skip
/// (a weak signal) after a few seconds, on the next action, or when the deck closes.
/// "Not today" teaches nothing.
struct SkipReasonPrompt: View {
    @ObservedObject var homeVM: HomeViewModel
    /// Wide layout (Duo inner display): sit in the trailing pane, never on the crease.
    var alignTrailing: Bool

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        if let pending = homeVM.pendingSkip {
            HStack(spacing: DS.Spacing.xs) {
                Text("Skipped")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.leading, DS.Spacing.xs)
                choice("Not my style", id: "outfit.skipReason.notMyStyle", prominent: true) {
                    homeVM.answerSkip(notMyStyle: true)
                }
                choice("Not today", id: "outfit.skipReason.notToday", prominent: false) {
                    homeVM.answerSkip(notMyStyle: false)
                }
            }
            .padding(DS.Spacing.micro)
            .dsGlassCapsule()
            .padding(.horizontal, alignTrailing ? DS.Spacing.lg + DS.Spacing.xs : DS.Spacing.screenH)
            // Just above the action buttons (phone: one row; wide: Wear today over ⋯ / Skip),
            // so it never hides the next look's note or the buttons themselves.
            .padding(.bottom, alignTrailing ? 156 : 78)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignTrailing ? .bottomTrailing : .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Why did you skip it?")
            .accessibilityIdentifier("outfit.skipReason")
            // Unanswered: a plain skip. VoiceOver users get longer to reach the buttons.
            .task(id: pending.id) {
                try? await Task.sleep(nanoseconds: UInt64((voiceOver ? 12 : 6) * 1_000_000_000))
                guard !Task.isCancelled, homeVM.pendingSkip?.id == pending.id else { return }
                withAnimation(DS.Motion.smooth) { homeVM.settlePendingSkip() }
            }
            .onDisappear {
                // The deck closed (or the prompt was answered: then this is a no-op).
                if homeVM.pendingSkip?.id == pending.id { homeVM.settlePendingSkip() }
            }
        }
    }

    private func choice(_ title: String, id: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(DS.Motion.smooth) { action() }
        } label: {
            Text(title)
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(prominent ? DS.Colors.accent : DS.Colors.textPrimary)
                .padding(.horizontal, DS.Spacing.sm)
                .frame(minHeight: 44)
                .background(prominent ? DS.Colors.accentSoft : Color.clear, in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(DSTapBounce())
        .accessibilityIdentifier(id)
    }
}
