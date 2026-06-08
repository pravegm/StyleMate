import SwiftUI

// MARK: - Coach-mark feature tour
//
// A short (5-step), skippable spotlight tour that runs ONCE the first time the user
// lands on Home after onboarding, and can be replayed from Profile. Research-backed:
// few steps, benefit-led copy, a dimmed scrim with a cutout spotlight, progress
// dots, Back/Skip/Next, and a cross-fade fallback under Reduce Motion.

// MARK: Anchor plumbing

/// Stable IDs for the on-screen elements the tour can spotlight.
enum CoachAnchor {
    // Home
    static let todayOutfit = "todayOutfit"
    static let styleMe = "styleMe"
    // Other tabs (the tour navigates to these)
    static let addFAB = "addFAB"
    static let outfitsCalendar = "outfitsCalendar"
    static let profileHeader = "profileHeader"
    // Generation result sheet
    static let genLook = "genLook"
    static let genShuffle = "genShuffle"
    static let genActions = "genActions"
}

/// The tours the app can run, each with its own "seen" flag.
enum TourID: String {
    case home
    case generation

    var steps: [CoachStep] {
        switch self {
        case .home:       return CoachStep.homeTour
        case .generation: return CoachStep.generationTour
        }
    }
}

struct CoachAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Registers this view's frame so the tour can spotlight it.
    func coachAnchor(_ id: String) -> some View {
        anchorPreference(key: CoachAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: Step model

/// An illustrated method shown inside a coach card (e.g. the 3 ways to add clothes).
struct CoachMethod: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

struct CoachStep: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var tab: Int = 0           // Home tour: which tab to navigate to for this step
    var anchor: String? = nil  // element to spotlight (nil = a centered card)
    var cta: String = "Next"
    var methods: [CoachMethod] = []
}

extension CoachStep {
    /// Post-onboarding tour. It NAVIGATES to each tab and spotlights a real element
    /// there — generator → add clothes → plan → profile — in natural-journey order.
    static let homeTour: [CoachStep] = [
        CoachStep(title: "Style on demand",
                  message: "Tap an occasion, or type your own — 'gym', 'date night', 'outdoor wedding'. What you type takes priority. Then Generate for five looks.",
                  tab: 0, anchor: CoachAnchor.styleMe),
        CoachStep(title: "Build your closet",
                  message: "Tap + to add clothes three ways:",
                  tab: 1, anchor: CoachAnchor.addFAB,
                  methods: [
                    CoachMethod(icon: "wand.and.stars", title: "Auto-scan",
                                detail: "Find your clothes in your camera roll automatically"),
                    CoachMethod(icon: "photo.on.rectangle", title: "Upload from gallery",
                                detail: "Pick existing photos of your clothes"),
                    CoachMethod(icon: "camera.fill", title: "Take a photo",
                                detail: "Snap an item right now")
                  ]),
        CoachStep(title: "Plan your week",
                  message: "Save looks you love and map them to a calendar, so mornings are already decided.",
                  tab: 2, anchor: CoachAnchor.outfitsCalendar),
        CoachStep(title: "Make it yours",
                  message: "Tune your style, manage your face match, and replay this tour anytime — here.",
                  tab: 3, anchor: CoachAnchor.profileHeader, cta: "Start styling")
    ]

    /// First-generation tour — runs once when the outfit result sheet first opens.
    static let generationTour: [CoachStep] = [
        CoachStep(title: "Your look, head to toe",
                  message: "A complete outfit from your closet. Tap a piece to zoom — each one has a lock to keep it and a swap icon to change just that piece.",
                  anchor: CoachAnchor.genLook),
        CoachStep(title: "Keep what you like",
                  message: "Lock the pieces you love, then tap Shuffle for a fresh take on everything else.",
                  anchor: CoachAnchor.genShuffle),
        CoachStep(title: "Save, skip, or tweak",
                  message: "Save logs the look for today, Skip shows the next one, + adds a missing piece, and the calendar saves it to a date. You can also swipe right to save, left to skip.",
                  anchor: CoachAnchor.genActions, cta: "Got it")
    ]
}

// MARK: Manager

@MainActor
final class TutorialManager: ObservableObject {
    @Published var activeTour: TourID? = nil
    @Published var stepIndex = 0

    private var userKey = ""

    func configure(forUser userID: String) { userKey = userID }

    private func seenKey(_ tour: TourID) -> String { "tour_\(tour.rawValue)_\(userKey)" }
    func hasSeen(_ tour: TourID) -> Bool { UserDefaults.standard.bool(forKey: seenKey(tour)) }
    private func markSeen(_ tour: TourID) { UserDefaults.standard.set(true, forKey: seenKey(tour)) }
    func resetSeen(_ tour: TourID) { UserDefaults.standard.set(false, forKey: seenKey(tour)) }

    var steps: [CoachStep] { activeTour?.steps ?? [] }
    var current: CoachStep? {
        guard activeTour != nil, stepIndex < steps.count else { return nil }
        return steps[stepIndex]
    }

    /// Auto-run a tour the very first time. No-op once seen, or if a tour is running.
    func startIfFirstTime(_ tour: TourID) {
        guard !userKey.isEmpty, !hasSeen(tour), activeTour == nil else { return }
        start(tour)
    }

    /// Force-start a tour (e.g. replay from Profile), ignoring the seen flag.
    func start(_ tour: TourID) {
        stepIndex = 0
        withAnimation(.easeInOut(duration: 0.25)) { activeTour = tour }
    }

    func next() { stepIndex < steps.count - 1 ? (stepIndex += 1) : finish() }
    func back() { if stepIndex > 0 { stepIndex -= 1 } }
    func skip() { finish() }

    func finish() {
        if let tour = activeTour { markSeen(tour) }
        withAnimation(.easeInOut(duration: 0.25)) { activeTour = nil }
    }
}

// MARK: Overlay

struct CoachMarkOverlay: View {
    @ObservedObject var tutorial: TutorialManager
    let tour: TourID
    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bubbleSize: CGSize = .zero
    @State private var pulse = false

    private var size: CGSize { proxy.size }

    private func spotlightRect() -> CGRect? {
        guard let step = tutorial.current, let id = step.anchor, let a = anchors[id] else { return nil }
        return proxy[a].insetBy(dx: -10, dy: -10)
    }

    private func corner(for rect: CGRect) -> CGFloat {
        // Round small squarish targets (FAB, avatar) into circles; cards get a card radius.
        let squarish = abs(rect.width - rect.height) < 28
        if squarish && min(rect.width, rect.height) < 130 { return min(rect.width, rect.height) / 2 }
        return rect.height > 130 ? DS.Radius.hero : 16
    }

    var body: some View {
        if tutorial.activeTour == tour, let step = tutorial.current {
            let spot = spotlightRect()
            let place = bubblePlacement(spot: spot)
            ZStack(alignment: .topLeading) {
                scrim(spot: spot)
                if let spot { halo(spot) }
                bubble(step: step, place: place)
            }
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
            .animation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.85),
                       value: tutorial.stepIndex)
        }
    }

    // MARK: Scrim with a soft, shape-matched cutout

    private func scrim(spot: CGRect?) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            if let spot {
                RoundedRectangle(cornerRadius: corner(for: spot), style: .continuous)
                    .frame(width: spot.width, height: spot.height)
                    .position(x: spot.midX, y: spot.midY)
                    .blendMode(.destinationOut)
                    .blur(radius: 2)               // soft cutout edge
            }
        }
        .compositingGroup()                        // required for destinationOut
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { Haptics.light(); tutorial.next() }   // tap anywhere to advance
    }

    // MARK: Glowing, breathing spotlight ring

    private func halo(_ spot: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner(for: spot), style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 6)
                .blur(radius: 9)
            RoundedRectangle(cornerRadius: corner(for: spot), style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.9), lineWidth: 2)
        }
        .frame(width: spot.width, height: spot.height)
        .scaleEffect(pulse ? 1.05 : 1.0)
        .opacity(pulse ? 0.55 : 1.0)
        .position(x: spot.midX, y: spot.midY)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // MARK: Tooltip bubble with an integrated tail, anchored adjacent to the target

    private func bubble(step: CoachStep, place: BubblePlacement) -> some View {
        bubbleContent(step: step)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .padding(place.tailEdge == .top ? .top : .bottom, place.hasTail ? 9 : 0)
            .frame(maxWidth: 290)
            .background {
                if place.hasTail {
                    TooltipShape(edge: place.tailEdge, arrowOffset: place.arrowOffset)
                        .fill(DS.Colors.backgroundCard)
                        .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 10)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(DS.Colors.backgroundCard)
                        .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 10)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: BubbleSizeKey.self, value: g.size)
            })
            .onPreferenceChange(BubbleSizeKey.self) { newSize in
                withAnimation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.85)) {
                    bubbleSize = newSize
                }
            }
            .position(x: place.center.x, y: place.center.y)
            .opacity(bubbleSize == .zero ? 0 : 1)   // hide until measured (avoids a position jump)
            .id(step.id)                             // fresh fade per step
            .transition(.opacity)
    }

    private func bubbleContent(step: CoachStep) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(step.title)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(step.message)
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !step.methods.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(step.methods) { method in
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: method.icon)
                                .font(DS.Font.callout)
                                .foregroundStyle(DS.Colors.accent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(method.title)
                                    .font(DS.Font.subheadline.weight(.semibold))
                                    .foregroundStyle(DS.Colors.textPrimary)
                                Text(method.detail)
                                    .font(DS.Font.footnote)
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Controls row: progress dots · Back · Skip · Next
            HStack(spacing: DS.Spacing.sm) {
                HStack(spacing: 6) {
                    ForEach(0..<tutorial.steps.count, id: \.self) { i in
                        Capsule()
                            .fill(i == tutorial.stepIndex ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.3))
                            .frame(width: i == tutorial.stepIndex ? 16 : 6, height: 6)
                    }
                }
                Spacer(minLength: DS.Spacing.xs)
                if tutorial.stepIndex > 0 {
                    Button("Back") { Haptics.light(); tutorial.back() }
                        .font(DS.Font.footnote.weight(.medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Button("Skip") { Haptics.light(); tutorial.skip() }
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textTertiary)
                Button { Haptics.medium(); tutorial.next() } label: {
                    Text(step.cta)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, 8)
                        .background(DS.Colors.accent, in: Capsule(style: .continuous))
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
    }

    // MARK: Placement (adjacent to the target, tail tracking it after clamping)

    private func bubblePlacement(spot: CGRect?) -> BubblePlacement {
        let margin: CGFloat = 16
        let gap: CGFloat = 12
        guard let spot, bubbleSize != .zero else {
            return BubblePlacement(center: CGPoint(x: size.width / 2, y: size.height / 2),
                                   tailEdge: .top, arrowOffset: 0, hasTail: false)
        }
        let w = bubbleSize.width, h = bubbleSize.height
        let safeTop = proxy.safeAreaInsets.top + margin
        let safeBottom = size.height - proxy.safeAreaInsets.bottom - margin
        let placeBelow = (safeBottom - spot.maxY) >= h + gap
        let tailEdge: Edge = placeBelow ? .top : .bottom
        let centerX = min(max(spot.midX, margin + w / 2), size.width - margin - w / 2)
        var centerY = placeBelow ? spot.maxY + gap + h / 2 : spot.minY - gap - h / 2
        centerY = min(max(centerY, safeTop + h / 2), safeBottom - h / 2)
        let maxOff = max(0, w / 2 - 22)
        let arrowOffset = min(max(spot.midX - centerX, -maxOff), maxOff)
        return BubblePlacement(center: CGPoint(x: centerX, y: centerY),
                               tailEdge: tailEdge, arrowOffset: arrowOffset, hasTail: true)
    }
}

// MARK: - Tooltip bubble shape (rounded rect + integrated tail)

struct BubblePlacement {
    var center: CGPoint
    var tailEdge: Edge
    var arrowOffset: CGFloat
    var hasTail: Bool
}

private struct BubbleSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// A rounded-rectangle bubble with a tail on `edge`, whose tip sits at
/// `arrowOffset` from the bubble's horizontal center (so it keeps pointing at the
/// target even after the bubble is clamped to the screen).
struct TooltipShape: Shape {
    var edge: Edge
    var arrowOffset: CGFloat
    var cornerRadius: CGFloat = 18
    var tailWidth: CGFloat = 18
    var tailHeight: CGFloat = 9

    var animatableData: CGFloat {
        get { arrowOffset }
        set { arrowOffset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let body: CGRect
        switch edge {
        case .top:
            body = CGRect(x: rect.minX, y: rect.minY + tailHeight, width: rect.width, height: rect.height - tailHeight)
        default:
            body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)
        }
        var p = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)

        let tipX = min(max(rect.midX + arrowOffset, body.minX + cornerRadius + tailWidth / 2),
                       body.maxX - cornerRadius - tailWidth / 2)
        var tail = Path()
        if edge == .top {
            tail.move(to: CGPoint(x: tipX - tailWidth / 2, y: body.minY))
            tail.addQuadCurve(to: CGPoint(x: tipX + tailWidth / 2, y: body.minY),
                              control: CGPoint(x: tipX, y: rect.minY))   // rounded tip
        } else {
            tail.move(to: CGPoint(x: tipX - tailWidth / 2, y: body.maxY))
            tail.addQuadCurve(to: CGPoint(x: tipX + tailWidth / 2, y: body.maxY),
                              control: CGPoint(x: tipX, y: rect.maxY))
        }
        tail.closeSubpath()
        p.addPath(tail)
        return p
    }
}

// MARK: Cutout helper

extension View {
    /// Punches a hole in `self` wherever `mask` is drawn (for spotlight cutouts).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
        }
    }
}
