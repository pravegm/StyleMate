import SwiftUI

// iPhone Duo (iOS 27.1) and other large displays: what a view needs to know to adapt, and a two-pane container
// that respects the fold. Builds for the iOS 18.4 deployment target; the Duo APIs are behind
// `if #available(iOS 27.1, *)`, and every other device simply reports "no hinge".
//
// Apple's model (developer.apple.com/iphone-duo, Tech Talks 111461 / 111463 / 111466):
// - Outer (cover) display: compact width, a normal iPhone. Inner display: regular width and height in every
//   orientation; it ignores the supported interface orientations. Folding resizes the scene in place (no
//   relaunch), so @State, scroll positions and text survive as long as view identity does.
// - The fold is a `.division` reserved region (GeometryProxy.reservedRegions). Active only while partly open;
//   flat it is inactive (zero thick). "Keep each view entirely on one side of the division"; scrolling content
//   doesn't have to avoid it. Hinge state comes from `onHingeChange` (`DeviceHinge.status`).
//
// API
// - `.duoLayoutReader()`: once, at the app root (StyleMateApp). Publishes `\.duoLayout` to everything below,
//   sheets and full-screen covers included.
// - `@Environment(\.duoLayout) var duo`:
//     duo.isWideLayout   horizontal size class regular OR window width >= 700 pt
//     duo.posture        .noHinge / .flat / .book / .tabletop / .closed
//     duo.hinge          .unavailable / .closed / .partiallyOpen / .fullyOpen (raw onHingeChange status)
//     duo.hingeAngle     degrees, 180 = flat (nil without a hinge)
//     duo.isHalfOpen     book or tabletop
//     duo.creaseInGlobal the fold (active or not) in global coordinates, nil without one
//     duo.crease(in:)    the ACTIVE fold in a view's coordinate space, given that view's global frame
// - `DuoCreaseReader { crease in ... }`: a GeometryReader that hands you the active fold in its own coordinates
//   (nil when flat, closed, or not a Duo). Use it at the top of a full-screen view, not inside a ScrollView.
// - `FoldAwareSplit(gutter: 24) { leading } trailing: { trailing }`: two panes side by side on a wide layout,
//   stacked (a leading-aligned VStack) otherwise. Half-open in book pose the split is exactly at the crease: the
//   leading pane ends `gutter / 2` before the fold band, the trailing one starts `gutter / 2` after it. Flat, it
//   is a normal two-column split (`leadingFraction`, default 0.5) with a `gutter` gap. In tabletop pose with
//   `axis: .vertical` (and a fixed height), the panes go above and below the fold instead. It is a `Layout`, not
//   an if/else, so switching between one and two panes never rebuilds them (state survives a fold, a rotation
//   or a move between the displays). Works inside a ScrollView (it only reads its own global x/y and width).

// MARK: - State

/// The hinge as last reported by `onHingeChange`.
enum DuoHingeState: String, Equatable {
    case unavailable, closed, partiallyOpen, fullyOpen
}

/// How the device is held, from the hinge status and the fold's direction (Apple publishes no pose value).
enum DuoPosture: String, Equatable {
    /// Not a foldable (any other iPhone, iPad), or iOS older than 27.1.
    case noHinge
    /// Fully open: one big flat inner display.
    case flat
    /// Partly open, fold running top to bottom (inner display held sideways, like a book).
    case book
    /// Partly open, fold running side to side (inner display upright: Apple's "seated" pose).
    case tabletop
    /// The app is on the cover display: the phone is shut (or only just opening, or in tent pose).
    case closed
}

struct DuoLayoutState: Equatable {
    var hinge: DuoHingeState = .unavailable
    var hingeAngle: Double? = nil
    /// The fold in global coordinates, active or inactive (inactive = zero thick, still in place); nil without one.
    var creaseInGlobal: CGRect? = nil
    /// The fold is active (the system only activates it while the phone is partly open or closed).
    var isCreaseActive = false
    /// Horizontal size class regular, or the window is at least 700 pt wide.
    var isWideLayout = false
    /// The window's size in points.
    var windowSize: CGSize = .zero

    static let wideMinWidth: CGFloat = 700

    var posture: DuoPosture {
        switch hinge {
        case .unavailable: return .noHinge
        case .closed: return .closed
        case .fullyOpen: return .flat
        case .partiallyOpen:
            // Measured on the Duo simulator (duo.yml): the inner display always reports its fold (book: a
            // 40 pt band at x 456-496 of 951 x 669, active or not); the cover display reports none. So no fold =
            // the app is still on the cover (opening from shut, the cover stays lit to ~20°, or tent pose).
            guard let c = creaseInGlobal, c.width != c.height, isWideLayout else { return .closed }
            return c.height > c.width ? .book : .tabletop
        }
    }

    var isHalfOpen: Bool { posture == .book || posture == .tabletop }

    /// The active fold in the coordinate space of a view whose global frame is `frame`; nil unless half-open
    /// and the fold crosses that view.
    func crease(in frame: CGRect) -> CGRect? {
        guard isHalfOpen, let c = creaseInGlobal, c.intersects(frame.insetBy(dx: -1, dy: -1)) else { return nil }
        return c.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}

private struct DuoLayoutKey: EnvironmentKey {
    static let defaultValue = DuoLayoutState()
}

extension EnvironmentValues {
    var duoLayout: DuoLayoutState {
        get { self[DuoLayoutKey.self] }
        set { self[DuoLayoutKey.self] = newValue }
    }
}

extension View {
    /// Apply once at the app root: follows the hinge, the fold and the window size, and publishes `\.duoLayout`.
    func duoLayoutReader() -> some View { modifier(DuoLayoutReader()) }
}

// MARK: - Reader

private struct DuoLayoutReader: ViewModifier {
    @State private var state = DuoLayoutState()
    @State private var hingeEnabled = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.duoLayout, state)
            .background {
                GeometryReader { proxy in
                    // `state.hinge` is read here so a hinge change also re-reads the reserved regions.
                    let snap = Snapshot(crease: Self.crease(in: proxy), active: Self.isActive(in: proxy),
                                        size: proxy.size, regular: horizontalSizeClass == .regular,
                                        hinge: state.hinge)
                    Color.clear.onChange(of: snap, initial: true) { _, s in apply(s) }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .modifier(HingeStateReader(isEnabled: hingeEnabled) { status, rawAngle in
                // Angles arrive many times a second while folding; 5° steps (about the sensor's accuracy) keep
                // the views that read \.duoLayout from re-rendering on every sample.
                let angle = rawAngle.map { ($0 / 5).rounded() * 5 }
                guard status != state.hinge || angle != state.hingeAngle else { return }
                let postureBefore = state.posture
                state.hinge = status
                state.hingeAngle = angle
                if state.posture != postureBefore { log() }
            })
            // Back from the background with the phone open and still, iOS may send no hinge change; re-enabling
            // the subscription delivers the current state.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                hingeEnabled = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { hingeEnabled = true }
            }
    }

    private struct Snapshot: Equatable {
        var crease: CGRect?
        var active: Bool
        var size: CGSize
        var regular: Bool
        var hinge: DuoHingeState
    }

    private func apply(_ s: Snapshot) {
        let wide = s.regular || s.size.width >= DuoLayoutState.wideMinWidth
        guard s.crease != state.creaseInGlobal || s.active != state.isCreaseActive
                || s.size != state.windowSize || wide != state.isWideLayout else { return }
        state.creaseInGlobal = s.crease
        state.isCreaseActive = s.active
        state.windowSize = s.size
        state.isWideLayout = wide
        log()
    }

    private func log() {
        #if DEBUG
        let c = state.creaseInGlobal.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none"
        duoDebugLog(String(format: "posture=%@ hinge=%@ angle=%@ crease=%@ active=%d window=%.0fx%.0f wide=%d",
                           state.posture.rawValue, state.hinge.rawValue,
                           state.hingeAngle.map { String(format: "%.0f", $0) } ?? "-", c, state.isCreaseActive ? 1 : 0,
                           state.windowSize.width, state.windowSize.height, state.isWideLayout ? 1 : 0))
        #endif
    }

    private static func crease(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            guard let local = proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame else {
                return nil
            }
            let origin = proxy.frame(in: .global).origin
            return local.offsetBy(dx: origin.x, dy: origin.y)
        }
        return nil
    }

    private static func isActive(in proxy: GeometryProxy) -> Bool {
        if #available(iOS 27.1, *) {
            return !proxy.reservedRegions(kind: .division).isEmpty
        }
        return false
    }
}

#if DEBUG
/// DEBUG-only: prints a `[Duo] …` line and appends it to Documents/duo-log.txt, which the Duo CI copies out of the
/// simulator (XCUITest owns the app's stdout there, and the unified log hides dynamic strings).
func duoDebugLog(_ message: String) {
    let line = "[Duo] \(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    print(line, terminator: "")
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
          let data = line.data(using: .utf8) else { return }
    let url = docs.appendingPathComponent("duo-log.txt")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
#endif

/// `onHingeChange` (iOS 27.1+) as a status and an angle in degrees; reports `.unavailable` on older systems.
private struct HingeStateReader: ViewModifier {
    let isEnabled: Bool
    let onChange: (DuoHingeState, Double?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange(isEnabled: isEnabled) { _, context in
                guard let hinge = context.hinge else { onChange(.unavailable, nil); return }
                let degrees = hinge.angle.degrees
                // DeviceHinge.Status is a struct, so compare rather than switch.
                if hinge.status == .closed { onChange(.closed, degrees) }
                else if hinge.status == .partiallyOpen { onChange(.partiallyOpen, degrees) }
                else { onChange(.fullyOpen, degrees) }
            }
        } else {
            content
        }
    }
}

// MARK: - Crease reader

/// A GeometryReader that passes the ACTIVE fold in its own coordinate space (nil when flat, closed or not a Duo).
struct DuoCreaseReader<Content: View>: View {
    @ViewBuilder var content: (CGRect?) -> Content
    @Environment(\.duoLayout) private var duo

    var body: some View {
        GeometryReader { proxy in
            content(duo.crease(in: proxy.frame(in: .global)))
        }
    }
}

// MARK: - Two panes

/// Two panes split at the fold when half-open, a normal two-column split on any other wide layout, one stacked
/// column on a compact one. See the API notes at the top of this file.
struct FoldAwareSplit<Leading: View, Trailing: View>: View {
    enum Axis { case horizontal, vertical }

    /// `.horizontal`: side by side (book pose, flat, iPad). `.vertical`: above and below the fold in tabletop pose,
    /// for a container with a fixed height (falls back to side by side when not in tabletop pose).
    var axis: Axis = .horizontal
    /// Gap between the panes; half-open it is added around the fold band (gutter / 2 each side).
    var gutter: CGFloat = 24
    /// Spacing between the two panes when stacked on a compact layout.
    var stackedSpacing: CGFloat = DS.Spacing.lg
    /// The leading pane's share when there is no fold to split at.
    var leadingFraction: CGFloat = 0.5
    /// The container must be at least this wide to split (a Split View window on the Duo is ~475 pt).
    var minimumWidth: CGFloat = 560
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @Environment(\.duoLayout) private var duo
    @State private var frame = GlobalFrame()

    var body: some View {
        let crease = duo.crease(in: frame.rect)
        let tabletop = axis == .vertical && duo.posture == .tabletop && crease != nil
        let split = tabletop || (duo.isWideLayout && frame.width >= minimumWidth)
        let band: (CGFloat, CGFloat)?
        if let c = crease, tabletop {
            band = (c.minY, c.maxY)
        } else if let c = crease, duo.posture == .book {
            band = (c.minX, c.maxX)
        } else {
            band = nil
        }
        return FoldPanesLayout(
            isSplit: split,
            vertical: tabletop,
            spacing: stackedSpacing,
            gutter: gutter,
            fold: band,
            leadingFraction: leadingFraction
        ) {
            VStack(alignment: .leading, spacing: stackedSpacing) { leading }
            VStack(alignment: .leading, spacing: stackedSpacing) { trailing }
        }
        .onGeometryChange(for: GlobalFrame.self) { proxy in
            GlobalFrame(rect: proxy.frame(in: .global), trackY: axis == .vertical)
        } action: { frame = $0 }
    }
}

/// Global frame without the y origin unless asked for, so a FoldAwareSplit in a ScrollView doesn't re-layout on
/// every scroll step.
private struct GlobalFrame: Equatable {
    var rect: CGRect = .zero
    var width: CGFloat { rect.width }

    init() {}
    init(rect: CGRect, trackY: Bool) {
        // Without y tracking, keep the full height span so a book-pose fold (top to bottom) still intersects.
        self.rect = trackY ? rect : CGRect(x: rect.minX, y: -100_000, width: rect.width, height: 200_000)
    }
}

/// The layout behind FoldAwareSplit.
struct FoldPanesLayout: Layout {
    var isSplit: Bool
    /// Above and below (tabletop) instead of side by side. Needs a fixed height proposal.
    var vertical = false
    var spacing: CGFloat
    var gutter: CGFloat
    /// The fold band (start, end) along the split axis, in this container's coordinates.
    var fold: (CGFloat, CGFloat)? = nil
    var leadingFraction: CGFloat = 0.5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard isSplit, subviews.count == 2 else { return stackedSize(proposal: proposal, subviews: subviews) }
        let full = proposal.replacingUnspecifiedDimensions()
        if vertical { return full }
        let (a, b) = paneFrames(in: CGRect(origin: .zero, size: full))
        let ha = subviews[0].sizeThatFits(ProposedViewSize(width: a.width, height: proposal.height)).height
        let hb = subviews[1].sizeThatFits(ProposedViewSize(width: b.width, height: proposal.height)).height
        return CGSize(width: full.width, height: proposal.height ?? max(ha, hb))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard isSplit, subviews.count == 2 else {
            var y = bounds.minY
            for subview in subviews {
                let h = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
            return
        }
        let (a, b) = paneFrames(in: bounds)
        let fixedHeight = vertical || proposal.height != nil
        for (subview, rect) in zip(subviews, [a, b]) {
            subview.place(at: rect.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: rect.width, height: fixedHeight ? rect.height : nil))
        }
    }

    private func stackedSize(proposal: ProposedViewSize, subviews: Subviews) -> CGSize {
        var height: CGFloat = 0, width: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            height += size.height + (i > 0 ? spacing : 0)
            width = max(width, size.width)
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    /// The two panes. With a fold, the first ends gutter/2 before its band and the second starts gutter/2 after
    /// it; otherwise the gutter is centred on `leadingFraction`. A pane is never narrower than a quarter.
    private func paneFrames(in bounds: CGRect) -> (CGRect, CGRect) {
        let length = vertical ? bounds.height : bounds.width
        var firstEnd: CGFloat, secondStart: CGFloat
        if let band = fold {
            firstEnd = band.0 - gutter / 2
            secondStart = band.1 + gutter / 2
        } else {
            firstEnd = length * leadingFraction - gutter / 2
            secondStart = length * leadingFraction + gutter / 2
        }
        let gap = max(0, secondStart - firstEnd)
        firstEnd = min(max(firstEnd, length / 4), length * 3 / 4 - gap)
        secondStart = firstEnd + gap
        if vertical {
            return (CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: firstEnd),
                    CGRect(x: bounds.minX, y: bounds.minY + secondStart, width: bounds.width, height: length - secondStart))
        }
        return (CGRect(x: bounds.minX, y: bounds.minY, width: firstEnd, height: bounds.height),
                CGRect(x: bounds.minX + secondStart, y: bounds.minY, width: length - secondStart, height: bounds.height))
    }
}
