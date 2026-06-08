import SwiftUI

// MARK: - StyleMate Design System
//
// Modern iOS-native premium foundation. Everything is a semantic token so the
// whole app stays consistent and adapts to light/dark automatically.
//
// Principles (Apple HIG):
// • 8-pt spacing grid, fixed side margins.
// • Type built on Dynamic Type text styles, so it scales for accessibility.
// • Semantic, system-aligned surfaces; one brand tint (teal) set once via .tint.
// • Continuous (squircle) corners everywhere.
// • iOS-17 spring presets for coherent, interruptible motion.
//
// All public symbol names are stable — screens reference DS.Colors/Font/Spacing/
// Radius/Motion, the DS* button styles, Haptics, ColorMapping, and the card/glass
// helpers. Internals here were upgraded; call sites keep working unchanged.

enum DS {

    // MARK: - Colors
    //
    // Crisp, near-neutral surfaces (gray canvas + white cards in light; layered
    // near-blacks in dark, never pure #000/#FFF) with a single teal brand tint.

    enum Colors {
        // Canvas → the app background. Deliberately a clear gray in light and a
        // near-black in dark so white/elevated cards visibly FLOAT off it (the
        // classic iOS "grouped" depth). This contrast is the main thing that makes
        // the app read as layered and premium rather than flat.
        static let backgroundPrimary = dyn(
            light: UIColor(red: 0.922, green: 0.922, blue: 0.941, alpha: 1),   // #EBEBF0
            dark:  UIColor(red: 0.027, green: 0.027, blue: 0.031, alpha: 1)    // #070708
        )

        // Recessed fills (chips, segmented tracks, subtle wells).
        static let backgroundSecondary = dyn(
            light: UIColor(red: 0.882, green: 0.882, blue: 0.910, alpha: 1),   // #E1E1E8
            dark:  UIColor(red: 0.141, green: 0.141, blue: 0.149, alpha: 1)    // #242426
        )

        // Elevated surfaces (cards, sheets, rows). Clearly lighter than canvas in
        // dark = elevation; pure white in light = maximum lift off the gray canvas.
        static let backgroundCard = dyn(
            light: UIColor.white,                                              // #FFFFFF
            dark:  UIColor(red: 0.114, green: 0.114, blue: 0.125, alpha: 1)    // #1D1D20
        )

        static let textPrimary = dyn(
            light: UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1),   // #111111
            dark:  UIColor(red: 0.961, green: 0.961, blue: 0.973, alpha: 1)    // #F5F5F8
        )

        static let textSecondary = dyn(
            light: UIColor(red: 0.431, green: 0.431, blue: 0.451, alpha: 1),   // #6E6E73 (iOS secondaryLabel)
            dark:  UIColor(red: 0.596, green: 0.596, blue: 0.624, alpha: 1)    // #98989F
        )

        static let textTertiary = dyn(
            light: UIColor(red: 0.682, green: 0.682, blue: 0.698, alpha: 1),   // #AEAEB2 (iOS tertiaryLabel)
            dark:  UIColor(red: 0.431, green: 0.431, blue: 0.451, alpha: 1)    // #6E6E73
        )

        // Brand tint — vivid in dark, deeper in light; legible (WCAG AA) on both canvases.
        static let accent = dyn(
            light: UIColor(red: 0.071, green: 0.490, blue: 0.435, alpha: 1),   // #127D6F
            dark:  UIColor(red: 0.176, green: 0.831, blue: 0.667, alpha: 1)    // #2DD4AA
        )

        static let accentSecondary = dyn(
            light: UIColor(red: 0.776, green: 0.537, blue: 0.247, alpha: 1),   // #C6893F
            dark:  UIColor(red: 0.910, green: 0.659, blue: 0.298, alpha: 1)    // #E8A84C
        )

        static let success = dyn(
            light: UIColor(red: 0.204, green: 0.541, blue: 0.337, alpha: 1),
            dark:  UIColor(red: 0.392, green: 0.808, blue: 0.553, alpha: 1)
        )

        static let warning = dyn(
            light: UIColor(red: 0.769, green: 0.604, blue: 0.235, alpha: 1),
            dark:  UIColor(red: 0.910, green: 0.722, blue: 0.337, alpha: 1)
        )

        static let error = dyn(
            light: UIColor(red: 0.792, green: 0.255, blue: 0.255, alpha: 1),
            dark:  UIColor(red: 0.920, green: 0.420, blue: 0.404, alpha: 1)
        )

        // MARK: New semantic helpers (additive)

        /// Hairline separators (translucent, adapts automatically).
        static let separator = Color(uiColor: .separator)

        /// Soft tinted background for selected chips / accent wells.
        static let accentSoft = dyn(
            light: UIColor(red: 0.071, green: 0.490, blue: 0.435, alpha: 0.10),
            dark:  UIColor(red: 0.176, green: 0.831, blue: 0.667, alpha: 0.16)
        )

        /// Neutral fill for unselected chips / capsules.
        static let fill = Color(uiColor: .secondarySystemFill)

        /// Always-light "styling board" surface for outfit looks. Garment cutouts are
        /// saved on a WHITE background (no alpha), so they only blend seamlessly on a
        /// near-white surface. Keeping this light in BOTH light and dark mode lets the
        /// flat-lay read as a lookbook page instead of white rectangles on a dark card.
        static let styleBoard = Color(red: 0.988, green: 0.984, blue: 0.976)   // #FCFBF9

        // Internal: build a light/dark dynamic Color.
        private static func dyn(light: UIColor, dark: UIColor) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
    }

    // MARK: - Spacing (8-pt grid)

    enum Spacing {
        static let micro: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
        static let screenH: CGFloat = 20   // fixed horizontal screen margin
    }

    // MARK: - Corner Radius (use with .continuous everywhere)

    enum Radius {
        static let chip: CGFloat = 10
        static let button: CGFloat = 14
        static let control: CGFloat = 12
        static let card: CGFloat = 18
        static let hero: CGFloat = 24
        static let sheet: CGFloat = 28
    }

    // MARK: - Typography
    //
    // Built on Dynamic Type text styles so everything scales for accessibility and
    // gets Apple's optical sizing (SF Text vs Display) for free. Same token names.

    enum Font {
        static let display    = SwiftUI.Font.system(size: 40, weight: .bold, design: .rounded)
        static let largeTitle = SwiftUI.Font.system(.largeTitle, design: .default).weight(.bold)
        static let title1     = SwiftUI.Font.system(.title, design: .default).weight(.bold)
        static let title2     = SwiftUI.Font.system(.title2, design: .default).weight(.semibold)
        static let title3     = SwiftUI.Font.system(.title3, design: .default).weight(.semibold)
        static let headline   = SwiftUI.Font.system(.headline)                     // 17 semibold
        static let body       = SwiftUI.Font.system(.body)                          // 17 regular
        static let callout    = SwiftUI.Font.system(.callout)                       // 16 regular
        static let subheadline = SwiftUI.Font.system(.subheadline)                  // 15 regular
        static let footnote   = SwiftUI.Font.system(.footnote)                      // 13 regular
        static let caption1   = SwiftUI.Font.system(.caption).weight(.medium)       // 12 medium
        static let caption2   = SwiftUI.Font.system(.caption2).weight(.medium)      // 11 medium
    }

    // MARK: - Motion (iOS-17 spring presets)
    //
    // Coherent, interruptible, physics-based. Use these instead of ad-hoc curves.

    enum Motion {
        static let press   = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.68)
        static let snappy  = SwiftUI.Animation.snappy(duration: 0.32, extraBounce: 0.04)
        static let smooth  = SwiftUI.Animation.smooth(duration: 0.40)
        static let bouncy  = SwiftUI.Animation.bouncy(duration: 0.48, extraBounce: 0.12)
        static let gentle  = SwiftUI.Animation.spring(response: 0.55, dampingFraction: 0.85)

        /// Cross-fade fallback to use when Reduce Motion is on.
        static let reduced = SwiftUI.Animation.easeInOut(duration: 0.22)
    }

    enum ButtonSize {
        static let height: CGFloat = 52
    }
}

// MARK: - Shadow / Card Modifiers

struct DSCardShadow: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var cornerRadius: CGFloat = DS.Radius.card
    var elevated: Bool = false

    func body(content: Content) -> some View {
        if colorScheme == .light {
            // Stronger, soft shadow so cards clearly lift off the gray canvas.
            content
                .shadow(color: Color.black.opacity(elevated ? 0.14 : 0.09),
                        radius: elevated ? 24 : 14, x: 0, y: elevated ? 12 : 6)
        } else {
            // Dark mode: a hairline rim + soft black drop reads as elevation.
            content
                .shadow(color: Color.black.opacity(elevated ? 0.5 : 0.35),
                        radius: elevated ? 18 : 10, x: 0, y: elevated ? 8 : 4)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(elevated ? 0.12 : 0.08),
                                      lineWidth: elevated ? 1 : 0.6)
                )
        }
    }
}

private struct DSCardModifier: ViewModifier {
    var padding: CGFloat = DS.Spacing.md
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .modifier(DSCardShadow())
    }
}

extension View {
    func dsCard(padding: CGFloat = DS.Spacing.md) -> some View {
        modifier(DSCardModifier(padding: padding))
    }
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: DS.ButtonSize.height)
            .background(
                isDisabled ? AnyShapeStyle(DS.Colors.accent.opacity(0.35))
                           : AnyShapeStyle(DS.Colors.accent),
                in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
            )
            .shadow(color: DS.Colors.accent.opacity(isDisabled ? 0 : 0.28),
                    radius: configuration.isPressed ? 4 : 10, x: 0, y: configuration.isPressed ? 2 : 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

struct DSSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.headline)
            .foregroundStyle(DS.Colors.accent)
            .frame(maxWidth: .infinity)
            .frame(height: DS.ButtonSize.height)
            .background(DS.Colors.accentSoft,
                        in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

struct DSTertiaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.headline)
            .foregroundStyle(DS.Colors.accent)
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

/// Subtle tactile press for tappable cards/chips/icons.
struct DSTapBounce: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Haptic Feedback

/// Haptics with long-lived, pre-warmed generators.
///
/// Allocating a fresh generator per call and firing without `prepare()` makes the
/// Taptic Engine cold-start synchronously on the main thread after any idle — which
/// stalls the very tap that triggered it. Reusing prepared generators and
/// re-preparing after each fire keeps the engine warm so taps stay instant.
/// `@MainActor` because feedback generators must be used from the main thread.
@MainActor
enum Haptics {
    private static let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let impactSoft   = UIImpactFeedbackGenerator(style: .soft)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selectionGen = UISelectionFeedbackGenerator()

    static func light()     { impactLight.impactOccurred();  impactLight.prepare() }
    static func medium()    { impactMedium.impactOccurred(); impactMedium.prepare() }
    static func soft()      { impactSoft.impactOccurred();   impactSoft.prepare() }
    static func success()   { notification.notificationOccurred(.success); notification.prepare() }
    static func warning()   { notification.notificationOccurred(.warning); notification.prepare() }
    static func selection() { selectionGen.selectionChanged(); selectionGen.prepare() }

    /// Warm the Taptic Engine ahead of an expected tap (call from `.onAppear`).
    static func prepare() {
        impactLight.prepare()
        impactMedium.prepare()
        impactSoft.prepare()
        notification.prepare()
        selectionGen.prepare()
    }
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
        case "silver": return Color(red: 0.75, green: 0.75, blue: 0.76)
        case "gold": return Color(red: 0.83, green: 0.69, blue: 0.22)
        case "navy": return Color(red: 0.10, green: 0.16, blue: 0.36)
        case "beige": return Color(red: 0.90, green: 0.86, blue: 0.76)
        case "cream": return Color(red: 0.98, green: 0.96, blue: 0.88)
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

// MARK: - Glass Effect Helpers (system materials)

extension View {
    func dsGlassCard(cornerRadius: CGFloat = DS.Radius.sheet) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func dsGlassClear(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func dsGlassChipSelected() -> some View {
        self
            .background(DS.Colors.accentSoft, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.accent.opacity(0.30), lineWidth: 1))
    }

    func dsGlassChipUnselected() -> some View {
        self.background(.ultraThinMaterial, in: Capsule(style: .continuous))
    }

    func dsGlassBar(cornerRadius: CGFloat = DS.Spacing.md) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func dsGlassCircle() -> some View {
        self.background(.ultraThinMaterial, in: Circle())
    }
}
