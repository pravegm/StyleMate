import SwiftUI
import StoreKit

/// Profile's "StyleMate Premium" section: the plan and its renewal date with Manage Subscription
/// (Apple's sheet) and Restore Purchases, or, on the free tier, how many of the 50 free pieces
/// are used and a way to the paywall.
struct PremiumProfileSection: View {
    @EnvironmentObject private var wardrobe: WardrobeViewModel
    @ObservedObject private var store = PremiumStore.shared
    @ObservedObject private var locked = LockedItemsStore.shared
    @State private var showManage = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    var body: some View {
        Section {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: store.isPremium ? "crown.fill" : "hanger")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Colors.onAccent)
                    .frame(width: 34, height: 34)
                    .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(detail)
                        .font(DS.Font.caption1)
                        .foregroundStyle(statusIsWarning ? DS.Colors.warning : DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.premium.status")
            // Presenters live on one row (modifiers on a Section apply per row).
            .manageSubscriptionsSheet(isPresented: $showManage)
            .onChange(of: showManage) { _, open in
                if !open { Task { await store.refresh() } }
            }
            .alert("Restore Purchases", isPresented: Binding(
                get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreMessage ?? "")
            }

            if store.isPremium || store.status.state == .billingRetry {
                Button {
                    Haptics.light()
                    showManage = true
                } label: {
                    Label("Manage Subscription", systemImage: "creditcard")
                }
                .foregroundStyle(DS.Colors.accent)
                .accessibilityIdentifier("profile.premium.manage")
            } else {
                Button {
                    Haptics.light()
                    PaywallCenter.shared.present(locked.count > 0 ? .lockedItems : .profile)
                } label: {
                    Label(locked.count > 0 ? "Unlock \(locked.count) waiting piece\(locked.count == 1 ? "" : "s")"
                                           : "See Premium plans",
                          systemImage: "sparkles")
                }
                .foregroundStyle(DS.Colors.accent)
                .accessibilityIdentifier("profile.premium.upgrade")
            }

            Button {
                Task { await restore() }
            } label: {
                HStack {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                    if isRestoring { Spacer(); ProgressView() }
                }
            }
            .foregroundStyle(DS.Colors.accent)
            .disabled(isRestoring)
            .accessibilityIdentifier("profile.premium.restore")
        } header: {
            Text("StyleMate Premium")
        } footer: {
            Text("Every feature is free for your first \(WardrobeAllowance.freeItemLimit) pieces (sample clothes don't count). Premium makes the wardrobe unlimited. Subscriptions are handled by Apple; StyleMate never sees your payment details.")
                .font(DS.Font.caption2)
        }
    }

    private var counted: Int { PremiumGate.countedItems(in: wardrobe) }

    private var title: String {
        guard store.isPremium else { return "Free" }
        return "Premium · \(PremiumProducts.planName(for: store.status.productID))"
    }

    private var statusIsWarning: Bool {
        store.status.state == .gracePeriod || store.status.state == .billingRetry
            || (store.isPremium && !store.status.willAutoRenew)
    }

    private var detail: String {
        let s = store.status
        let date = s.expiresAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
        switch s.state {
        case .active where s.isPremium():
            if s.isTrial, let date { return s.willAutoRenew ? "Free trial · first payment \(date)" : "Free trial ends \(date)" }
            if let date { return s.willAutoRenew ? "Renews \(date)" : "Ends \(date) · won't renew" }
            return "Unlimited wardrobe"
        case .gracePeriod:
            return "Payment problem: update your payment method" + (date.map { " by \($0)" } ?? "") + " to keep Premium."
        case .billingRetry:
            return "Payment didn't go through. Update your payment method to restore Premium."
        default:
            let used = min(counted, WardrobeAllowance.freeItemLimit)
            var line = "\(used) of \(WardrobeAllowance.freeItemLimit) free pieces used"
            if locked.count > 0 { line += " · \(locked.count) waiting" }
            if s.state == .expired { line += " · Premium ended" }
            if s.state == .revoked { line += " · Premium was refunded" }
            return line
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        let message = await store.restore()
        if store.isPremium { PremiumGate.reconcile(wardrobe) }
        if !message.isEmpty { restoreMessage = message }
    }
}
