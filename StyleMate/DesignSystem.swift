import SwiftUI

// MARK: - StyleMate Design System
// Premium-minimal design tokens. 8-point grid. SF Pro typography.
// Glass helpers use .ultraThinMaterial as a cross-version stand-in.
// When building with the iOS 26 SDK, replace dsGlass* internals
// with the native .glassEffect() modifier for true Liquid Glass.

enum DS {

    // MARK: - Colors

    enum Colors {
        static let backgroundPrimary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1)   // #111113
                : UIColor(red: 0.980, green: 0.976, blue: 0.965, alpha: 1)   // #FAF9F6
        })

        static let backgroundSecondary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.110, green: 0.110, blue: 0.125, alpha: 1)   // #1C1C20
                : UIColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 1)   // #F0EDE8
        })

        static let backgroundCard = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.133, green: 0.133, blue: 0.149, alpha: 1)   // #222226
                : UIColor.white
        })

        static let textPrimary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 1)   // #F0EDE8
                : UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)   // #1A1A1A
        })

        static let textSecondary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.608, green: 0.596, blue: 0.565, alpha: 1)   // #9B9890
                : UIColor(red: 0.420, green: 0.420, blue: 0.420, alpha: 1)   // #6B6B6B
        })

        static let textTertiary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.502, green: 0.490, blue: 0.463, alpha: 1)
                : UIColor(red: 0.608, green: 0.608, blue: 0.608, alpha: 1)   // #9B9B9B
        })

        static let accent = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.176, green: 0.831, blue: 0.667, alpha: 1)   // #2DD4AA
                : UIColor(red: 0.102, green: 0.478, blue: 0.427, alpha: 1)   // #1A7A6D
        })

        static let accentSecondary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.910, green: 0.659, blue: 0.298, alpha: 1)   // #E8A84C
                : UIColor(red: 0.776, green: 0.537, blue: 0.247, alpha: 1)   // #C6893F
        })

        static let success = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.420, green: 0.612, blue: 0.431, alpha: 1)
                : UIColor(red: 0.361, green: 0.541, blue: 0.369, alpha: 1)   // #5C8A5E
        })

        static let warning = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.839, green: 0.675, blue: 0.310, alpha: 1)
                : UIColor(red: 0.769, green: 0.604, blue: 0.235, alpha: 1)   // #C49A3C
        })

        static let error = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.796, green: 0.400, blue: 0.380, alpha: 1)
                : UIColor(red: 0.722, green: 0.329, blue: 0.314, alpha: 1)   // #B85450
        })
    }

    // MARK: - Spacing (8-point grid)

    enum Spacing {
        static let micro: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
        static let screenH: CGFloat = 20
    }

    // MARK: - Corner Radius

    enum Radius {
        static let button: CGFloat = 10
        static let card: CGFloat = 14
        static let sheet: CGFloat = 24
        static let hero: CGFloat = 20
    }

    // MARK: - Typography (SF Pro)

    enum Font {
        static let display    = SwiftUI.Font.system(size: 40, weight: .bold, design: .rounded)
        static let largeTitle = SwiftUI.Font.system(size: 34, weight: .bold)
        static let title1     = SwiftUI.Font.system(size: 28, weight: .bold)
        static let title2     = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let title3     = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let headline   = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body       = SwiftUI.Font.system(size: 17, weight: .regular)
        static let callout    = SwiftUI.Font.system(size: 16, weight: .regular)
        static let subheadline = SwiftUI.Font.system(size: 15, weight: .regular)
        static let footnote   = SwiftUI.Font.system(size: 13, weight: .regular)
        static let caption1   = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption2   = SwiftUI.Font.system(size: 11, weight: .medium)
    }

    enum ButtonSize {
        static let height: CGFloat = 50
    }
}

// MARK: - Shadow Modifier

struct DSCardShadow: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var cornerRadius: CGFloat = DS.Radius.card
    var elevated: Bool = false

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content
                .shadow(color: Color.black.opacity(elevated ? 0.10 : 0.05), radius: elevated ? 16 : 8, x: 0, y: elevated ? 6 : 2)
        } else {
            content.overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(elevated ? 0.12 : 0.06), lineWidth: elevated ? 1 : 0.5)
            )
        }
    }
}

// MARK: - Card Modifier

private struct DSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DS.Spacing.md)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .modifier(DSCardShadow())
    }
}

extension View {
    func dsCard() -> some View { modifier(DSCardModifier()) }
    func dsCardShadow(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        modifier(DSCardShadow(cornerRadius: cornerRadius))
    }
    func dsElevatedShadow(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        modifier(DSCardShadow(cornerRadius: cornerRadius, elevated: true))
    }
}

// MARK: - Button Styles

struct DSPrimaryButton: ButtonStyle {
    var isDisabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: DS.ButtonSize.height)
            .background(
                isDisabled
                    ? AnyShapeStyle(DS.Colors.accent.opacity(0.3))
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .shadow(color: DS.Colors.accent.opacity(0.25), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct DSSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.headline)
            .foregroundColor(DS.Colors.accent)
            .frame(maxWidth: .infinity)
            .frame(height: DS.ButtonSize.height)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .stroke(DS.Colors.accent, lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DSTertiaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.headline)
            .foregroundColor(DS.Colors.accent)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

// MARK: - Tap Bounce Button Style

struct DSTapBounce: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Haptic Feedback

enum Haptics {
    static func light()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium()    { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success()   { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Color Name Mapping

enum ColorMapping {
    static func color(for name: String) -> Color {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        switch n {
        case "black": return .black
        case "white": return .white
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "pink": return .pink
        case "purple": return .purple
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "navy": return Color(red: 0, green: 0, blue: 0.5)
        case "beige": return Color(red: 0.96, green: 0.96, blue: 0.86)
        case "cream": return Color(red: 1, green: 0.99, blue: 0.82)
        case "maroon": return Color(red: 0.5, green: 0, blue: 0)
        case "teal": return .teal
        case "olive": return Color(red: 0.5, green: 0.5, blue: 0)
        case "tan", "khaki": return Color(red: 0.82, green: 0.71, blue: 0.55)
        case "burgundy": return Color(red: 0.5, green: 0.0, blue: 0.13)
        case "coral": return Color(red: 1.0, green: 0.5, blue: 0.31)
        case "rust": return Color(red: 0.72, green: 0.25, blue: 0.05)
        case "lavender": return Color(red: 0.71, green: 0.49, blue: 0.86)
        case "mint": return Color(red: 0.6, green: 0.88, blue: 0.7)
        case "charcoal": return Color(red: 0.21, green: 0.27, blue: 0.31)
        default: return DS.Colors.backgroundSecondary
        }
    }
}

// MARK: - Glass Effect Helpers
// Stand-ins using system materials. When iOS 26 SDK is available,
// swap with .glassEffect(.regular), .glassEffect(.clear), etc.

extension View {
    func dsGlassCard(cornerRadius: CGFloat = DS.Radius.sheet) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    func dsGlassClear(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    func dsGlassChipSelected() -> some View {
        self
            .background(DS.Colors.accent.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.accent.opacity(0.25), lineWidth: 1))
    }

    func dsGlassChipUnselected() -> some View {
        self.background(DS.Colors.backgroundSecondary, in: Capsule())
    }

    func dsGlassBar(cornerRadius: CGFloat = DS.Spacing.md) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    func dsGlassCircle() -> some View {
        self.background(.ultraThinMaterial, in: Circle())
    }
}
