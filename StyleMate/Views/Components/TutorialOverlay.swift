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
    static let todayOutfit = "todayOutfit"
    static let styleMe = "styleMe"
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

struct CoachStep: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let target: CoachTarget
    var cta: String = "Next"
}

extension CoachStep {
    /// The post-onboarding Home tour — payoff → on-demand value → foundation →
    /// planning → control, in natural journey order. Copy is benefit-led and short.
    static let homeTour: [CoachStep] = [
        CoachStep(title: "Today's look, ready",
                  message: "We built a head-to-toe outfit for today's weather. Tap it to shuffle or lock the pieces you love.",
                  target: .anchor(CoachAnchor.todayOutfit)),
        CoachStep(title: "Dressing for something?",
                  message: "Tell StyleMate the occasion — or type your own — and get five full looks in seconds.",
                  target: .anchor(CoachAnchor.styleMe)),
        CoachStep(title: "Your closet, organized",
                  message: "Everything you own, auto-tagged. The more you add, the smarter your outfits get.",
                  target: .tab(1)),
        CoachStep(title: "Plan your week",
                  message: "Save looks you love and map them to a calendar, so mornings are already decided.",
                  target: .tab(2)),
        CoachStep(title: "Make it yours",
                  message: "Tune your style, manage your face match, and replay this tour anytime — right here.",
                  target: .tab(3), cta: "Start styling")
    ]
}

// MARK: Manager

@MainActor
final class TutorialManager: ObservableObject {
    @Published var isActive = false
    @Published var stepIndex = 0

    let steps: [CoachStep] = CoachStep.homeTour
    private var userKey = ""

    func configure(forUser userID: String) { userKey = userID }

    private var seenKey: String { "homeTutorialSeen_\(userKey)" }
    var hasSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }
    private func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }

    /// Auto-run the very first time (after onboarding). No-op once seen.
    func startIfFirstTime() {
        guard !userKey.isEmpty, !hasSeen, !isActive else { return }
        start()
    }

    /// Replay (e.g. from Profile) — always starts, ignoring the seen flag.
    func start() {
        stepIndex = 0
        withAnimation(.easeInOut(duration: 0.25)) { isActive = true }
    }

    var current: CoachStep? { isActive && stepIndex < steps.count ? steps[stepIndex] : nil }

    func next() { stepIndex < steps.count - 1 ? (stepIndex += 1) : finish() }
    func back() { if stepIndex > 0 { stepIndex -= 1 } }
    func skip() { finish() }

    func finish() {
        markSeen()
        withAnimation(.easeInOut(duration: 0.25)) { isActive = false }
    }
}

// MARK: Overlay

struct CoachMarkOverlay: View {
    @ObservedObject var tutorial: TutorialManager
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
        if let step = tutorial.current {
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
