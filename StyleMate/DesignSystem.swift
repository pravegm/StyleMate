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
                ? UIColor(red: 0.102, green: 0.102, blue: 0.118, alpha: 1)   // #1A1A1E
                : UIColor(red: 0.961, green: 0.961, blue: 0.941, alpha: 1)   // #F5F5F0
        })

        static let backgroundSecondary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.165, green: 0.165, blue: 0.180, alpha: 1)   // #2A2A2E
                : UIColor(red: 0.933, green: 0.918, blue: 0.894, alpha: 1)   // #EEEAE4
        })

        static let backgroundCard = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.141, green: 0.141, blue: 0.157, alpha: 1)   // #242428
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
                ? UIColor(red: 0.557, green: 0.627, blue: 0.518, alpha: 1)
                : UIColor(red: 0.490, green: 0.549, blue: 0.447, alpha: 1)   // #7D8C72
        })

        static let accentSecondary = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.698, green: 0.608, blue: 0.494, alpha: 1)
                : UIColor(red: 0.627, green: 0.537, blue: 0.424, alpha: 1)   // #A0896C
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
        static let button: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 20
    }

    // MARK: - Typography (SF Pro — no .rounded)

    enum Font {
        static let largeTitle  = SwiftUI.Font.system(size: 34, weight: .bold)
        static let title1      = SwiftUI.Font.system(size: 28, weight: .bold)
        static let title2      = SwiftUI.Font.system(size: 22, weight: .bold)
        static let title3      = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let headline    = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body        = SwiftUI.Font.system(size: 17, weight: .regular)
        static let callout     = SwiftUI.Font.system(size: 16, weight: .regular)
        static let subheadline = SwiftUI.Font.system(size: 15, weight: .regular)
        static let footnote    = SwiftUI.Font.system(size: 13, weight: .regular)
        static let caption1    = SwiftUI.Font.system(size: 12, weight: .regular)
        static let caption2    = SwiftUI.Font.system(size: 11, weight: .regular)
    }

    enum ButtonSize {
        static let height: CGFloat = 50
    }
}

// MARK: - Shadow Modifier

struct DSCardShadow: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var cornerRadius: CGFloat = DS.Radius.card

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content.shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        } else {
            content.overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
            .background(isDisabled ? DS.Colors.accent.opacity(0.4) : DS.Colors.accent)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
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

// MARK: - Haptic Feedback

enum Haptics {
    static func light()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium()    { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success()   { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
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
