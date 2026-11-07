import SwiftUI

/// Why the paywall opened (it tailors the headline).
enum PaywallReason: Equatable {
    /// Home / closet card: "23 more pieces found".
    case lockedItems
    /// A camera / gallery add with the free wardrobe full.
    case atLimit
    /// A manual batch crossed the limit: what fit was added, these many wait.
    case batchOverflow(Int)
    /// Opened from Profile.
    case profile
}

/// One place that presents the paywall, as a full-screen cover hosted at the app root
/// (`.premiumSupport()` in RootView). Callers that are themselves inside a sheet or cover close
/// it first and pass a short `after` delay.
@MainActor
final class PaywallCenter: ObservableObject {
    static let shared = PaywallCenter()

    struct Request: Identifiable {
        let id = UUID()
        let reason: PaywallReason
    }

    @Published var request: Request?

    private init() {}

    func present(_ reason: PaywallReason, after delay: TimeInterval = 0) {
        guard delay > 0 else { request = Request(reason: reason); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.request = Request(reason: reason)
        }
    }

    func dismiss() { request = nil }

    /// A paywall to open once the full-screen cover asking for it has closed (`presentQueued()` from its
    /// onDismiss). Opened on a timer while that cover was still animating away, it came up without safe-area
    /// insets: its close button sat under the status bar and couldn't be tapped.
    private var queued: PaywallReason?

    func queue(_ reason: PaywallReason) { queued = reason }

    func presentQueued() {
        guard let reason = queued else { return }
        queued = nil
        present(reason, after: 0.1)
    }
}

extension View {
    /// Apply once, at the app root (RootView): hosts the paywall, keeps the entitlement fresh and
    /// unlocks locked pieces when Premium starts (or when the user makes room in the free tier).
    func premiumSupport(userId: String) -> some View {
        modifier(PremiumSupport(userId: userId))
    }
}

private struct PremiumSupport: ViewModifier {
    let userId: String
    @EnvironmentObject private var wardrobe: WardrobeViewModel
    @ObservedObject private var center = PaywallCenter.shared
    @ObservedObject private var store = PremiumStore.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $center.request) { request in
                PaywallView(reason: request.reason)
                    .environmentObject(wardrobe)
            }
            .task(id: userId) {
                guard !userId.isEmpty else { return }
                if wardrobe.currentUserEmail == userId { PremiumGate.reconcile(wardrobe) }
            }
            // Subscribed (here, on another device, Ask to Buy approved): unlock everything now.
            .onChange(of: store.isPremium) { _, premium in
                if premium { PremiumGate.reconcile(wardrobe) }
            }
            // Removing items makes room in the free tier for the oldest locked pieces.
            .onChange(of: wardrobe.items.count) { old, new in
                if new < old { PremiumGate.reconcile(wardrobe) }
            }
            .onChange(of: wardrobe.currentUserEmail) { _, user in
                if !user.isEmpty { PremiumGate.reconcile(wardrobe) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.refresh() } }
            }
    }
}
