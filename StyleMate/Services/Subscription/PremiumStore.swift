import Foundation
import StoreKit

/// StoreKit 2 for StyleMate Premium: loads the two plans, buys, restores and keeps the
/// entitlement current. Everything goes through Apple; there is no StyleMate server, no receipt
/// upload and no analytics.
///
/// - `start()` (app launch) listens to `Transaction.updates` (renewals, Ask to Buy approvals,
///   refunds, purchases made on another device), finishes any unfinished transactions and
///   refreshes the entitlement.
/// - The entitlement comes from `Transaction.currentEntitlements` (signed, cached by StoreKit on
///   the device, so it works offline) plus the group's renewal status (grace period, billing
///   retry, auto-renew), and is cached (`PremiumStatus.cached`) for the first frame and for
///   background scans that start with no UI.
@MainActor
final class PremiumStore: ObservableObject {
    static let shared = PremiumStore()

    enum LoadState: Equatable { case idle, loading, loaded, failed }

    enum PurchaseOutcome: Equatable {
        case purchased
        /// Ask to Buy (a parent approves) or extra bank authentication: Premium arrives later.
        case pending
        case cancelled
        case failed(String)
    }

    @Published private(set) var status: PremiumStatus
    /// Annual first (`PremiumProducts.all` order).
    @Published private(set) var products: [Product] = []
    @Published private(set) var loadState: LoadState = .idle
    /// The user can still take the annual plan's introductory offer (free trial).
    @Published private(set) var isTrialEligible = false
    /// A purchase is waiting for approval (Ask to Buy).
    @Published var isPendingApproval = false

    var isPremium: Bool { status.isPremium() }

    private var updatesTask: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshAgain = false

    private init() {
        status = PremiumStatus.cached()
    }

    // MARK: Launch

    /// Call once at launch (idempotent).
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached(priority: .utility) {
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await PremiumStore.shared.refresh()
            }
        }
        Task {
            await finishUnfinished()
            await refresh()
            await loadProducts()
        }
    }

    private func finishUnfinished() async {
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result, PremiumProducts.isPremiumProduct(transaction.productID) {
                await transaction.finish()
            }
        }
    }

    // MARK: Products

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// Loads the plans (retries when called again after a failure, e.g. offline).
    func loadProducts() async {
        guard loadState != .loading else { return }
        if loadState == .loaded, products.count == PremiumProducts.all.count { return }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: PremiumProducts.all)
            products = PremiumProducts.all.compactMap { id in loaded.first { $0.id == id } }
            loadState = products.isEmpty ? .failed : .loaded
            if let annual = product(PremiumProducts.annual) {
                isTrialEligible = await annual.subscription?.isEligibleForIntroOffer ?? false
            }
            dlog("[Premium] Loaded \(products.count) plans, trial eligible: \(isTrialEligible)")
        } catch {
            loadState = .failed
            dlog("[Premium] Couldn't load plans: \(error)")
        }
    }

    // MARK: Entitlement

    /// Re-reads the entitlement from StoreKit. Concurrent calls collapse into one more pass.
    func refresh() async {
        if isRefreshing { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() async {
        var entitlements: [PremiumStatus.Entitlement] = []
        var groupID: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, PremiumProducts.isPremiumProduct(t.productID) else { continue }
            entitlements.append(PremiumStatus.Entitlement(
                productID: t.productID, expirationDate: t.expirationDate, revocationDate: t.revocationDate,
                isUpgraded: t.isUpgraded, isTrial: t.offer?.type == .introductory))
            groupID = groupID ?? t.subscriptionGroupID
        }
        groupID = groupID ?? products.first?.subscription?.subscriptionGroupID
        var renewal: PremiumStatus.Renewal?
        if let groupID, let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
            renewal = Self.bestRenewal(statuses)
        }
        let resolved = PremiumStatus.resolve(entitlements: entitlements, renewal: renewal)
        if resolved.isPremium() { isPendingApproval = false }
        if resolved != status {
            dlog("[Premium] \(status.state.rawValue) -> \(resolved.state.rawValue) (\(resolved.productID ?? "-"))")
            status = resolved
        }
        resolved.save()
    }

    /// The most useful status of the group (a family member's or an older one may be listed too).
    private static func bestRenewal(_ statuses: [Product.SubscriptionInfo.Status]) -> PremiumStatus.Renewal? {
        func rank(_ s: PremiumStatus.Renewal.State) -> Int {
            switch s {
            case .subscribed: return 4
            case .inGracePeriod: return 3
            case .inBillingRetry: return 2
            case .expired: return 1
            case .revoked: return 0
            }
        }
        var best: PremiumStatus.Renewal?
        for status in statuses {
            guard case .verified(let t) = status.transaction else { continue }
            let info: Product.SubscriptionInfo.RenewalInfo?
            if case .verified(let r) = status.renewalInfo { info = r } else { info = nil }
            let state: PremiumStatus.Renewal.State
            switch status.state {
            case .subscribed: state = .subscribed
            case .inGracePeriod: state = .inGracePeriod
            case .inBillingRetryPeriod: state = .inBillingRetry
            case .revoked: state = .revoked
            default: state = .expired
            }
            let renewal = PremiumStatus.Renewal(
                state: state, productID: t.productID, expirationDate: t.expirationDate,
                gracePeriodExpirationDate: info?.gracePeriodExpirationDate,
                willAutoRenew: info?.willAutoRenew ?? false,
                isTrial: t.offer?.type == .introductory)
            if best.map({ rank(state) > rank($0.state) }) ?? true { best = renewal }
        }
        return best
    }

    // MARK: Purchase / restore

    /// Applies the result of SwiftUI's `purchase(product)` (`@Environment(\.purchase)`).
    func handle(_ result: Product.PurchaseResult) async -> PurchaseOutcome {
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                return .failed("Apple couldn't verify this purchase. You haven't been charged twice; try Restore Purchases.")
            }
            await transaction.finish()
            await refresh()
            // StoreKit can take a moment to list a brand-new entitlement.
            if !isPremium, transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantFuture) > Date() {
                status = PremiumStatus(state: .active, productID: transaction.productID,
                                       expiresAt: transaction.expirationDate, willAutoRenew: true,
                                       isTrial: transaction.offer?.type == .introductory)
                status.save()
            }
            if let annual = product(PremiumProducts.annual) {
                isTrialEligible = await annual.subscription?.isEligibleForIntroOffer ?? false
            }
            return .purchased
        case .pending:
            isPendingApproval = true
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .failed("Something went wrong. Please try again.")
        }
    }

    /// Plain-language message for a purchase error (nil = the user cancelled: say nothing).
    static func message(for error: Error) -> String? {
        if let e = error as? StoreKitError {
            switch e {
            case .userCancelled: return nil
            case .networkError: return "You're offline. Connect to the internet and try again."
            case .notAvailableInStorefront: return "Premium isn't available in your country's App Store yet."
            case .notEntitled: return "This Apple Account can't buy Premium right now."
            default: return "The App Store couldn't complete the purchase. Please try again."
            }
        }
        if let e = error as? Product.PurchaseError {
            switch e {
            case .purchaseNotAllowed: return "Purchases are turned off on this iPhone (Screen Time › Content & Privacy)."
            case .productUnavailable: return "This plan isn't available right now. Please try again later."
            default: return "The App Store couldn't complete the purchase. Please try again."
            }
        }
        return "The App Store couldn't complete the purchase. Please try again."
    }

    /// "Restore Purchases": asks the App Store for this Apple Account's purchases (may ask the
    /// user to sign in). Returns a message for the user.
    func restore() async -> String {
        do {
            try await AppStore.sync()
        } catch {
            if let e = error as? StoreKitError, case .userCancelled = e { return "" }
            await refresh()
            return isPremium ? "Premium is active." : "Couldn't reach the App Store. Check your connection and try again."
        }
        await refresh()
        return isPremium ? "Premium restored. Every piece is unlocked."
                         : "No StyleMate Premium subscription was found for this Apple Account."
    }
}

// MARK: - Display helpers (all from StoreKit; no hard-coded prices)

extension Product {
    /// "year" / "month" / "week" / "3 months".
    var periodText: String {
        guard let p = subscription?.subscriptionPeriod else { return "" }
        return PremiumText.period(p)
    }

    /// "£24.99 per year".
    var pricePerPeriodText: String {
        periodText.isEmpty ? displayPrice : "\(displayPrice) per \(periodText)"
    }

    /// The price spread over months ("£2.08"), for plans longer than a month.
    var monthlyEquivalentText: String? {
        guard let p = subscription?.subscriptionPeriod else { return nil }
        let months: Decimal
        switch p.unit {
        case .year: months = Decimal(12 * p.value)
        case .month: months = Decimal(p.value)
        default: return nil
        }
        guard months > 1 else { return nil }
        return (price / months).formatted(priceFormatStyle)
    }

    /// A free trial offer, if the plan has one: "1-week free trial".
    var freeTrialText: String? {
        guard let offer = subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return "\(PremiumText.duration(offer.period, count: offer.periodCount)) free trial"
    }
}

enum PremiumText {
    static func period(_ p: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch p.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return p.value == 1 ? unit : "\(p.value) \(unit)s"
    }

    /// "1-week", "3-day", "1-month" (hyphenated, for "… free trial").
    static func duration(_ p: Product.SubscriptionPeriod, count: Int) -> String {
        var value = p.value * max(1, count)
        var unit: String
        switch p.unit {
        case .day: unit = "day"
            if value % 7 == 0 { value /= 7; unit = "week" }
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return "\(value)-\(unit)"
    }

    /// Whole-percent saving of `yearly` against twelve months of `monthly` (rounded down, so the
    /// claim is never overstated). nil when there's no real saving.
    static func savingPercent(yearly: Decimal, monthly: Decimal) -> Int? {
        let fullYear = monthly * 12
        guard fullYear > 0, yearly > 0, yearly < fullYear else { return nil }
        let fraction = NSDecimalNumber(decimal: (fullYear - yearly) / fullYear).doubleValue
        let percent = Int((fraction * 100).rounded(.down))
        return percent >= 5 ? percent : nil
    }
}
