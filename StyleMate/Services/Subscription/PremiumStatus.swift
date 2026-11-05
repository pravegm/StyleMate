import Foundation

/// The two auto-renewable subscriptions in the App Store Connect group "StyleMate Premium".
/// Prices, periods and trial terms always come from StoreKit (`Product`); nothing is hard-coded.
/// The founder's App Store Connect setup is in docs/TESTFLIGHT.md ("Subscriptions").
enum PremiumProducts {
    static let monthly = "com.stylemates.StyleMate.premium.monthly"
    static let annual = "com.stylemates.StyleMate.premium.annual"
    /// Display order on the paywall: annual (the recommended plan) first.
    static let all = [annual, monthly]
    static let groupName = "StyleMate Premium"

    /// Apple's standard licence agreement (the app has no EULA of its own).
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static var privacyPolicy: URL { LegalLinks.privacyPolicy }

    static func isPremiumProduct(_ id: String) -> Bool { all.contains(id) }

    static func planName(for productID: String?) -> String {
        switch productID {
        case annual: return "Annual"
        case monthly: return "Monthly"
        default: return "Premium"
        }
    }
}

/// What the app knows about the user's Premium subscription. Derived from StoreKit 2's signed
/// transactions (`Transaction.currentEntitlements`) and the group's renewal status, then cached
/// in UserDefaults so the very first frame (and a background scan launched with no UI, or a
/// launch without a network) already knows. A cache only counts until its expiry date.
struct PremiumStatus: Codable, Equatable {
    enum State: String, Codable {
        /// Never subscribed (or nothing known yet).
        case none
        /// Subscribed (including a free trial).
        case active
        /// A renewal payment failed but Apple's billing grace period still gives access.
        case gracePeriod
        /// A renewal payment failed and the grace period is over (or not enabled): no access while
        /// Apple retries the payment.
        case billingRetry
        /// Ran out or was cancelled.
        case expired
        /// Refunded or revoked by Apple / Family Sharing.
        case revoked
    }

    var state: State = .none
    var productID: String? = nil
    /// When the current period ends (the grace period's end while in grace).
    var expiresAt: Date? = nil
    var willAutoRenew = false
    var isTrial = false
    /// This Apple Account has an active subscription, but it was bought for another StyleMate account
    /// (its `appAccountToken`), so it doesn't unlock this one.
    var heldByOtherAccount = false

    static let none = PremiumStatus()

    /// Whether a transaction counts for `account` (founder decision, documented in README):
    /// - its `appAccountToken` is this account's UUID: yes (every purchase made in the app sets it);
    /// - no token: yes (offer codes, purchases on the App Store page, and builds before accounts
    ///   can't carry one; the person signed in on this Apple Account is the best owner we know);
    /// - Family Sharing: yes (the family organiser's token is not ours, but sharing is the point);
    /// - another account's token: no (one App Store subscription doesn't unlock several StyleMate
    ///   accounts on a shared iPhone).
    /// With no account given (signed out; tests), every transaction counts.
    static func belongs(token: UUID?, familyShared: Bool, to account: UUID?) -> Bool {
        guard let account else { return true }
        if familyShared { return true }
        guard let token else { return true }
        return token == account
    }

    /// Unlimited wardrobe right now.
    func isPremium(at now: Date = Date()) -> Bool {
        switch state {
        case .active, .gracePeriod:
            // A cached status is only trusted until its period ends (StoreKit refreshes it).
            guard let end = expiresAt else { return true }
            return end > now
        case .none, .billingRetry, .expired, .revoked:
            return false
        }
    }

    // MARK: Resolving StoreKit's facts (pure, unit tested)

    /// One verified transaction from `Transaction.currentEntitlements`.
    struct Entitlement: Equatable {
        var productID: String
        var expirationDate: Date?
        var revocationDate: Date?
        var isUpgraded = false
        var isTrial = false
        var appAccountToken: UUID? = nil
        var isFamilyShared = false
    }

    /// The group's renewal status (`Product.SubscriptionInfo.status(for:)`), when StoreKit could
    /// answer (it can't always offline).
    struct Renewal: Equatable {
        enum State: Equatable { case subscribed, inGracePeriod, inBillingRetry, expired, revoked }
        var state: State
        var productID: String
        var expirationDate: Date?
        var gracePeriodExpirationDate: Date?
        var willAutoRenew: Bool
        var isTrial = false
        var appAccountToken: UUID? = nil
        var isFamilyShared = false
    }

    /// Combines the signed entitlements with the renewal status. A valid signed entitlement always
    /// wins (it is what StoreKit has cached on the device, so it works offline); the renewal status
    /// adds grace period / billing retry / auto-renew details.
    static func resolve(entitlements: [Entitlement], renewal: Renewal?, account: UUID? = nil,
                        now: Date = Date()) -> PremiumStatus {
        let current = entitlements
            .filter { PremiumProducts.isPremiumProduct($0.productID) && $0.revocationDate == nil && !$0.isUpgraded }
            .filter { ($0.expirationDate ?? .distantFuture) > now }
        let valid = current
            .filter { belongs(token: $0.appAccountToken, familyShared: $0.isFamilyShared, to: account) }
            .sorted { ($0.expirationDate ?? .distantFuture) > ($1.expirationDate ?? .distantFuture) }
            .first
        let renewal = renewal.flatMap {
            belongs(token: $0.appAccountToken, familyShared: $0.isFamilyShared, to: account) ? $0 : nil
        }

        var status = PremiumStatus()
        if valid == nil, !current.isEmpty { status.heldByOtherAccount = true }
        if let r = renewal, PremiumProducts.isPremiumProduct(r.productID) {
            status.productID = r.productID
            status.willAutoRenew = r.willAutoRenew
            status.isTrial = r.isTrial
            status.expiresAt = r.expirationDate
            switch r.state {
            case .subscribed:
                status.state = .active
            case .inGracePeriod:
                status.state = .gracePeriod
                status.expiresAt = r.gracePeriodExpirationDate ?? r.expirationDate
                // A grace period with no end date known: keep access until StoreKit says otherwise.
                if status.expiresAt.map({ $0 <= now }) ?? false { status.expiresAt = nil }
            case .inBillingRetry:
                status.state = .billingRetry
            case .expired:
                status.state = .expired
            case .revoked:
                status.state = .revoked
            }
        }
        if let v = valid, !status.isPremium(at: now) {
            // A signed, unexpired, unrevoked transaction: the user is entitled.
            status.state = .active
            status.productID = v.productID
            status.expiresAt = v.expirationDate
            status.isTrial = v.isTrial
            if renewal == nil { status.willAutoRenew = true }
        }
        if valid == nil, renewal == nil {
            // Nothing current. A revoked entitlement still says why.
            if entitlements.contains(where: { PremiumProducts.isPremiumProduct($0.productID) && $0.revocationDate != nil }) {
                status.state = .revoked
            }
        }
        return status
    }

    // MARK: Cache

    static let cacheKey = "premium.status.v1"

    /// One cache per account (a shared iPhone never shows one account's Premium to another).
    static func cacheKey(for account: UUID?) -> String {
        account.map { "\(cacheKey).\($0.uuidString)" } ?? cacheKey
    }

    static func cached(in defaults: UserDefaults = .standard, account: UUID? = nil) -> PremiumStatus {
        guard let data = defaults.data(forKey: cacheKey(for: account)),
              let s = try? JSONDecoder().decode(PremiumStatus.self, from: data) else { return .none }
        return s
    }

    func save(to defaults: UserDefaults = .standard, account: UUID? = nil) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.cacheKey(for: account)) }
    }
}
