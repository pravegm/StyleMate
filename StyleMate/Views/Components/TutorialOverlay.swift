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

enum CoachTarget: Equatable {
    case anchor(String)   // spotlight a registered Home element
    case tab(Int)         // spotlight a bottom tab-bar item (0-based)
    case center           // no spotlight, centered card
}

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
    let target: CoachTarget
    var cta: String = "Next"
    var methods: [CoachMethod] = []
}

extension CoachStep {
    /// The post-onboarding Home tour — payoff → on-demand value → foundation →
    /// planning → control, in natural journey order. Copy is benefit-led and short.
    static let homeTour: [CoachStep] = [
        CoachStep(title: "Today's look, ready",
                  message: "We built a head-to-toe outfit for today's weather. Tap it to shuffle or lock the pieces you love.",
                  target: .anchor(CoachAnchor.todayOutfit)),
        CoachStep(title: "Dressing for something?",
                  message: "Tap an occasion, or type your own in the box — 'gym', 'date night', 'outdoor wedding'. What you type takes priority. Then Generate for five looks.",
                  target: .anchor(CoachAnchor.styleMe)),
        CoachStep(title: "Build your closet",
                  message: "Tap + in your Wardrobe to add clothes three ways:",
                  target: .tab(1),
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
                  target: .tab(2)),
        CoachStep(title: "Make it yours",
                  message: "Tune your style, manage your face match, and replay this tour anytime — right here.",
                  target: .tab(3), cta: "Start styling")
    ]

    /// First-generation tour — runs once when the outfit result sheet first opens,
    /// explaining the controls that only exist there.
    static let generationTour: [CoachStep] = [
        CoachStep(title: "Your look, head to toe",
                  message: "A complete outfit from your closet. Tap a piece to zoom — each one has a lock to keep it and a swap icon to change just that piece.",
                  target: .anchor(CoachAnchor.genLook)),
        CoachStep(title: "Keep what you like",
                  message: "Lock the pieces you love, then tap Shuffle for a fresh take on everything else.",
                  target: .anchor(CoachAnchor.genShuffle)),
        CoachStep(title: "Save, skip, or tweak",
                  message: "Save logs the look for today, Skip shows the next one, + adds a missing piece, and the calendar saves it to a date. You can also swipe right to save, left to skip.",
                  target: .anchor(CoachAnchor.genActions), cta: "Got it")
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

    private var size: CGSize { proxy.size }

    private func spotlightRect() -> CGRect? {
        guard let step = tutorial.current else { return nil }
        switch step.target {
        case .center:
            return nil
        case .anchor(let id):
            guard let a = anchors[id] else { return nil }
            return proxy[a].insetBy(dx: -12, dy: -12)
        case .tab(let index):
            let count: CGFloat = 4
            let w = size.width / count
            let cx = w * (CGFloat(index) + 0.5)
            let cy = size.height - max(proxy.safeAreaInsets.bottom, 0) - 25
            let halfW: CGFloat = 34, halfH: CGFloat = 30
            return CGRect(x: cx - halfW, y: cy - halfH, width: halfW * 2, height: halfH * 2)
        }
    }

    private func corner(for rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) > 100 ? DS.Radius.hero : 16
    }

    var body: some View {
        if tutorial.activeTour == tour, let step = tutorial.current {
            let spot = spotlightRect()
            ZStack(alignment: .topLeading) {
                // Dimmed scrim with a cutout over the target.
                Color.black.opacity(0.62)
                    .reverseMask {
                        if let spot {
                            RoundedRectangle(cornerRadius: corner(for: spot), style: .continuous)
                                .frame(width: spot.width, height: spot.height)
                                .position(x: spot.midX, y: spot.midY)
                        }
                    }
                    .contentShape(Rectangle())   // block taps to the UI underneath

                // Spotlight ring.
                if let spot {
                    RoundedRectangle(cornerRadius: corner(for: spot), style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: spot.width, height: spot.height)
                        .position(x: spot.midX, y: spot.midY)
                        .allowsHitTesting(false)
                }

                calloutContainer(step: step, spot: spot)
            }
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : DS.Motion.smooth, value: tutorial.stepIndex)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func calloutContainer(step: CoachStep, spot: CGRect?) -> some View {
        // Dock the card to the edge away from the spotlight so they never overlap.
        let dockTop = (spot?.midY ?? size.height / 2) > size.height * 0.55
        let centered = (spot == nil)

        VStack(spacing: 0) {
            if centered {
                Spacer(minLength: 0); calloutCard(step: step); Spacer(minLength: 0)
            } else if dockTop {
                calloutCard(step: step); Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0); calloutCard(step: step)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.top, dockTop ? proxy.safeAreaInsets.top + DS.Spacing.lg : 0)
        .padding(.bottom, !dockTop && !centered ? proxy.safeAreaInsets.bottom + DS.Spacing.xxl + 60 : 0)
    }

    private func calloutCard(step: CoachStep) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                ForEach(0..<tutorial.steps.count, id: \.self) { i in
                    Capsule()
                        .fill(i == tutorial.stepIndex ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.35))
                        .frame(width: i == tutorial.stepIndex ? 18 : 6, height: 6)
                }
                Spacer()
                Button("Skip") { Haptics.light(); tutorial.skip() }
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            Text(step.title)
                .font(DS.Font.title3)
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
                                .frame(width: 28)
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
                .padding(.top, DS.Spacing.micro)
            }

            HStack {
                if tutorial.stepIndex > 0 {
                    Button {
                        Haptics.light(); tutorial.back()
                    } label: {
                        Text("Back").font(DS.Font.subheadline.weight(.medium))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                Spacer()
                Button {
                    Haptics.medium(); tutorial.next()
                } label: {
                    Text(step.cta)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(DS.Colors.accent, in: Capsule(style: .continuous))
                }
            }
            .padding(.top, DS.Spacing.micro)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: 380)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .dsElevatedShadow(cornerRadius: DS.Radius.hero)
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
