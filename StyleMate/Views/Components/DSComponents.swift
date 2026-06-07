import SwiftUI

// MARK: - Shared premium components built on the design system.
// These give every screen a consistent, iOS-native look: section headers,
// designed empty states, shimmer/skeleton loaders, chips, and motion helpers.

// MARK: - Section Header

/// A large-title-style section header ("Recommended Today") with an optional
/// trailing action. Title = Title2 semibold; optional eyebrow + action link.
struct DSSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            Spacer(minLength: DS.Spacing.sm)
            if let actionTitle, let action {
                Button {
                    Haptics.light()
                    action()
                } label: {
                    Text(actionTitle)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                }
                .buttonStyle(DSTapBounce())
            }
        }
    }
}

// MARK: - Empty State

/// Designed empty state: symbol in a soft tinted disc + headline + one line +
/// optional primary CTA. Never a blank screen.
struct DSEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var appear = false

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DS.Colors.accentSoft)
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(DS.Colors.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .scaleEffect(appear ? 1 : 0.8)
            .opacity(appear ? 1 : 0)

            VStack(spacing: DS.Spacing.xs) {
                Text(title)
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button {
                    Haptics.medium()
                    action()
                } label: {
                    Text(actionTitle)
                }
                .buttonStyle(DSPrimaryButton())
                .padding(.top, DS.Spacing.xs)
                .frame(maxWidth: 280)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(DS.Motion.gentle) { appear = true }
        }
    }
}

// MARK: - Chip

/// Selectable capsule chip (filters, tags). Soft accent fill when selected,
/// material when not. Use for tappable filters.
struct DSChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: DS.Spacing.micro) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(DS.Font.footnote.weight(.semibold))
                }
                Text(title)
                    .font(DS.Font.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background {
                if isSelected {
                    Capsule(style: .continuous).fill(DS.Colors.accentSoft)
                    Capsule(style: .continuous).strokeBorder(DS.Colors.accent.opacity(0.30), lineWidth: 1)
                } else {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                }
            }
        }
        .buttonStyle(DSTapBounce())
    }
}

// MARK: - Shimmer / Skeleton loading

/// A moving sheen used for skeleton placeholders. Pair with `.redacted`.
struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.45), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 0.6)
                        .offset(x: phase * w * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Adds an animated sheen (use on redacted skeleton placeholders).
    func shimmering() -> some View { modifier(ShimmerModifier()) }

    /// Renders the view as a shimmering skeleton when `active` is true.
    @ViewBuilder
    func skeleton(_ active: Bool) -> some View {
        if active {
            self.redacted(reason: .placeholder).shimmering()
        } else {
            self
        }
    }
}

/// A neutral rounded skeleton block for building custom placeholders.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DS.Colors.backgroundSecondary)
            .frame(width: width, height: height)
            .shimmering()
    }
}

// MARK: - Entrance / motion helpers

extension View {
    /// Standard staged entrance: fade + slight rise. Drive `shown` from `.onAppear`.
    func dsAppear(_ shown: Bool, rise: CGFloat = 12) -> some View {
        self.opacity(shown ? 1 : 0).offset(y: shown ? 0 : rise)
    }

    /// Fixed horizontal screen margin.
    func dsScreenPadding() -> some View {
        self.padding(.horizontal, DS.Spacing.screenH)
    }
}

// MARK: - Reduce-Motion-aware animation

enum DSMotionEnv {
    /// Returns the given animation, or a quick cross-fade when Reduce Motion is on.
    @MainActor static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? DS.Motion.reduced : animation
    }
}
