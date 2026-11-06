import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import StyleMate

/// StyleMate Premium: the free tier's 50-item gate, the locked-items store, how StoreKit's facts
/// become an entitlement (trial, grace period, billing retry, lapse, refund, offline), and the
/// StoreKit configuration file itself (real StoreKit Test purchases).
struct SubscriptionTests {

    private static func item(_ n: Int = 0) -> WardrobeItem {
        WardrobeItem(category: .tops, product: "T-Shirts", colors: ["White"], brand: "", pattern: .solid,
                     imagePath: "seed_\(n).png", croppedImagePath: "seed_\(n).png", thumbnailPath: nil)
    }

    private static func items(_ count: Int) -> [WardrobeItem] { (0..<count).map { item($0) } }

    // MARK: Counting

    @Test func sampleItemsDontCount() {
        let all = Self.items(60)
        let samples = Set(all.prefix(14).map(\.id))
        #expect(WardrobeAllowance.countedItems(all, sampleIDs: samples) == 46)
        #expect(WardrobeAllowance.countedItems(all, sampleIDs: []) == 60)
        // Samples alone never fill the free tier.
        #expect(WardrobeAllowance.freeSlots(counted: WardrobeAllowance.countedItems(all, sampleIDs: samples),
                                            isPremium: false) == 4)
    }

    @Test func freeLimitIsFifty() {
        #expect(WardrobeAllowance.freeItemLimit == 50)
        #expect(WardrobeAllowance.freeSlots(counted: 0, isPremium: false) == 50)
        #expect(WardrobeAllowance.freeSlots(counted: 49, isPremium: false) == 1)
        #expect(WardrobeAllowance.freeSlots(counted: 50, isPremium: false) == 0)
        #expect(WardrobeAllowance.freeSlots(counted: 73, isPremium: false) == 0)   // never negative
        #expect(WardrobeAllowance.freeSlots(counted: 500, isPremium: true) == Int.max)
        #expect(!WardrobeAllowance.isAtLimit(counted: 49, isPremium: false))
        #expect(WardrobeAllowance.isAtLimit(counted: 50, isPremium: false))
        #expect(!WardrobeAllowance.isAtLimit(counted: 500, isPremium: true))
    }

    // MARK: Batches

    @Test func batchCrossingFiftyAddsWhatFitsAndLocksTheRest() {
        #expect(WardrobeAllowance.split(adding: 8, counted: 47, isPremium: false) == .init(add: 3, lock: 5))
        #expect(WardrobeAllowance.split(adding: 3, counted: 47, isPremium: false) == .init(add: 3, lock: 0))
        #expect(WardrobeAllowance.split(adding: 4, counted: 50, isPremium: false) == .init(add: 0, lock: 4))
        #expect(WardrobeAllowance.split(adding: 15, counted: 0, isPremium: false) == .init(add: 15, lock: 0))
        #expect(WardrobeAllowance.split(adding: 15, counted: 49, isPremium: true) == .init(add: 15, lock: 0))
        #expect(WardrobeAllowance.split(adding: 0, counted: 60, isPremium: false) == .init(add: 0, lock: 0))
        #expect(WardrobeAllowance.split(adding: -2, counted: 10, isPremium: false) == .init(add: 0, lock: 0))
    }

    // MARK: Locked store

    @MainActor
    private static func store() -> LockedItemsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LockedTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LockedItemsStore(directory: dir)
    }

    @MainActor
    @Test func lockedItemsPersistAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LockedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = LockedItemsStore(directory: dir)
        let made = Self.items(3)
        for i in made { first.lock(i, forUser: "user-a") }
        first.lock(made[0], forUser: "user-a")        // the same piece twice is stored once
        #expect(first.count == 3)
        LockedItemsStore.flushWrites()

        let relaunched = LockedItemsStore(directory: dir)
        relaunched.load(forUser: "user-a")
        #expect(relaunched.items.map(\.id) == made.map(\.id.uuidString))   // oldest first
        #expect(relaunched.wardrobeItems.map(\.product) == ["T-Shirts", "T-Shirts", "T-Shirts"])
        // Per profile.
        relaunched.load(forUser: "user-b")
        #expect(relaunched.count == 0)
    }

    @MainActor
    @Test func subscribingUnlocksEveryLockedItem() {
        let s = Self.store()
        let waiting = Self.items(23)
        for i in waiting { s.lock(i, forUser: "u") }
        let closet = Self.items(50)
        let moved = s.takeUnlockable(wardrobe: closet, isPremium: true, sampleIDs: [])
        #expect(moved.map(\.id) == waiting.map(\.id))
        #expect(s.count == 0)
    }

    @MainActor
    @Test func freeTierStaysLockedUntilThereIsRoom() {
        let s = Self.store()
        for i in Self.items(5) { s.lock(i, forUser: "u") }
        // Full: nothing moves.
        #expect(s.takeUnlockable(wardrobe: Self.items(50), isPremium: false, sampleIDs: []).isEmpty)
        #expect(s.count == 5)
        // The user removed two pieces: the two oldest locked ones take the free slots.
        let oldest = s.items.prefix(2).map(\.id)
        let moved = s.takeUnlockable(wardrobe: Self.items(48), isPremium: false, sampleIDs: [])
        #expect(moved.map(\.id.uuidString) == Array(oldest))
        #expect(s.count == 3)
        // Sample clothes don't take a slot.
        let closet = Self.items(50)
        let moved2 = s.takeUnlockable(wardrobe: closet, isPremium: false, sampleIDs: Set(closet.prefix(1).map(\.id)))
        #expect(moved2.count == 1)
    }

    @MainActor
    @Test func lapseKeepsEverythingAndOnlyLocksNewAdditions() {
        // 120 items added while Premium; then it lapses.
        let counted = 120
        let lapsed = PremiumStatus(state: .expired, productID: PremiumProducts.annual,
                                   expiresAt: Date(timeIntervalSinceNow: -60))
        #expect(!lapsed.isPremium())
        // Nothing the user has is touched (the gate has no removal path; slots never go negative)…
        #expect(WardrobeAllowance.freeSlots(counted: counted, isPremium: false) == 0)
        #expect(WardrobeAllowance.unlockable(locked: 0, counted: counted, isPremium: false) == 0)
        // …and every new piece waits.
        #expect(WardrobeAllowance.split(adding: 6, counted: counted, isPremium: false) == .init(add: 0, lock: 6))
        let s = Self.store()
        for i in Self.items(6) { s.lock(i, forUser: "u") }
        #expect(s.takeUnlockable(wardrobe: Self.items(counted), isPremium: false, sampleIDs: []).isEmpty)
        // Resubscribing brings them in.
        #expect(s.takeUnlockable(wardrobe: Self.items(counted), isPremium: true, sampleIDs: []).count == 6)
    }

    // MARK: Entitlement

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func activeTrialIsPremium() {
        let s = PremiumStatus.resolve(
            entitlements: [.init(productID: PremiumProducts.annual, expirationDate: now.addingTimeInterval(86_400 * 7), isTrial: true)],
            renewal: .init(state: .subscribed, productID: PremiumProducts.annual, expirationDate: now.addingTimeInterval(86_400 * 7),
                           willAutoRenew: true, isTrial: true),
            now: now)
        #expect(s.state == .active)
        #expect(s.isTrial)
        #expect(s.willAutoRenew)
        #expect(s.isPremium(at: now))
    }

    @Test func gracePeriodKeepsPremiumButBillingRetryDoesNot() {
        let lapsedTransaction = PremiumStatus.Entitlement(productID: PremiumProducts.monthly,
                                                          expirationDate: now.addingTimeInterval(-3_600))
        let grace = PremiumStatus.resolve(
            entitlements: [lapsedTransaction],
            renewal: .init(state: .inGracePeriod, productID: PremiumProducts.monthly, expirationDate: now.addingTimeInterval(-3_600),
                           gracePeriodExpirationDate: now.addingTimeInterval(86_400 * 6), willAutoRenew: true),
            now: now)
        #expect(grace.state == .gracePeriod)
        #expect(grace.isPremium(at: now))
        #expect(!grace.isPremium(at: now.addingTimeInterval(86_400 * 7)))   // grace ended

        let retry = PremiumStatus.resolve(
            entitlements: [lapsedTransaction],
            renewal: .init(state: .inBillingRetry, productID: PremiumProducts.monthly, expirationDate: now.addingTimeInterval(-3_600),
                           willAutoRenew: true),
            now: now)
        #expect(retry.state == .billingRetry)
        #expect(!retry.isPremium(at: now))
    }

    @Test func refundRevokesPremium() {
        let refunded = PremiumStatus.resolve(
            entitlements: [.init(productID: PremiumProducts.annual, expirationDate: now.addingTimeInterval(86_400 * 300),
                                 revocationDate: now.addingTimeInterval(-60))],
            renewal: nil, now: now)
        #expect(refunded.state == .revoked)
        #expect(!refunded.isPremium(at: now))
    }

    @Test func offlineSignedEntitlementStillCounts() {
        // Product.SubscriptionInfo.status can fail offline; the cached signed transaction is enough.
        let s = PremiumStatus.resolve(
            entitlements: [.init(productID: PremiumProducts.monthly, expirationDate: now.addingTimeInterval(86_400 * 12))],
            renewal: nil, now: now)
        #expect(s.isPremium(at: now))
        #expect(s.productID == PremiumProducts.monthly)
    }

    @Test func expiredOrForeignTransactionsAreNotPremium() {
        let expired = PremiumStatus.resolve(
            entitlements: [.init(productID: PremiumProducts.monthly, expirationDate: now.addingTimeInterval(-1))],
            renewal: nil, now: now)
        #expect(!expired.isPremium(at: now))
        let foreign = PremiumStatus.resolve(
            entitlements: [.init(productID: "com.example.other", expirationDate: now.addingTimeInterval(86_400))],
            renewal: nil, now: now)
        #expect(!foreign.isPremium(at: now))
        #expect(PremiumStatus.none.isPremium(at: now) == false)
    }

    @Test func cachedStatusExpiresOnItsOwn() throws {
        let name = "SubscriptionTests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(PremiumStatus.cached(in: d) == .none)
        let soon = Date().addingTimeInterval(120)
        PremiumStatus(state: .active, productID: PremiumProducts.annual, expiresAt: soon, willAutoRenew: true).save(to: d)
        let cached = PremiumStatus.cached(in: d)
        #expect(cached.isPremium())
        #expect(!cached.isPremium(at: soon.addingTimeInterval(1)))
    }

    // MARK: Copy

    @Test func annualSavingIsComputedNotHardCoded() {
        #expect(PremiumText.savingPercent(yearly: Decimal(string: "24.99")!, monthly: Decimal(string: "3.99")!) == 47)
        #expect(PremiumText.savingPercent(yearly: Decimal(string: "47.88")!, monthly: Decimal(string: "3.99")!) == nil)
        #expect(WardrobeAllowance.lockedHeadline(1) == "1 more piece found")
        #expect(WardrobeAllowance.lockedHeadline(23) == "23 more pieces found")
    }

    // MARK: StoreKit configuration (StoreKit Test)

    /// The repo's StyleMate.storekit, found from this source file's path (the simulator shares the
    /// Mac's file system).
    private static var configURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StyleMate.storekit")
    }

    /// The configuration file itself: both IDs the app asks for, in one group, with the suggested
    /// prices, periods and the annual plan's 1-week free trial.
    @Test func storeKitConfigurationFileMatchesTheApp() throws {
        let data = try Data(contentsOf: Self.configURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
        #expect(groups.count == 1)
        #expect(groups.first?["name"] as? String == PremiumProducts.groupName)
        let subs = try #require(groups.first?["subscriptions"] as? [[String: Any]])
        var byID: [String: [String: Any]] = [:]
        for s in subs { if let id = s["productID"] as? String { byID[id] = s } }
        #expect(Set(byID.keys) == Set(PremiumProducts.all))
        let annual = try #require(byID[PremiumProducts.annual])
        let monthly = try #require(byID[PremiumProducts.monthly])
        #expect(annual["recurringSubscriptionPeriod"] as? String == "P1Y")
        #expect(monthly["recurringSubscriptionPeriod"] as? String == "P1M")
        #expect(annual["displayPrice"] as? String == "24.99")
        #expect(monthly["displayPrice"] as? String == "3.99")
        let intro = try #require(annual["introductoryOffer"] as? [String: Any])
        #expect(intro["paymentMode"] as? String == "free")
        #expect(intro["subscriptionPeriod"] as? String == "P1W")
        #expect(monthly["introductoryOffer"] is NSNull)
        #expect((annual["groupNumber"] as? Int) == 1 && (monthly["groupNumber"] as? Int) == 2)
    }

    @MainActor
    @Test func storeKitConfigurationAndPurchase() async throws {
        let session = try SKTestSession(contentsOf: Self.configURL)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.storefront = "GBR"

        // storekitd can take a moment to pick up a configuration opened from the command line.
        var products: [Product] = []
        for attempt in 0..<8 {
            products = (try? await Product.products(for: PremiumProducts.all)) ?? []
            if products.count == PremiumProducts.all.count { break }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
        }
        guard !products.isEmpty else {
            // xcodebuild's unit-test host doesn't always get StoreKit Test's configuration (Apple
            // FB22237318); the UI tests (SubscriptionE2ETests) cover loading and buying end to end.
            print("[Premium] StoreKit Test returned no products in the unit-test host; skipping the live part")
            return
        }
        #expect(Set(products.map(\.id)) == Set(PremiumProducts.all))
        let annual = try #require(products.first { $0.id == PremiumProducts.annual })
        let monthly = try #require(products.first { $0.id == PremiumProducts.monthly })
        #expect(annual.type == .autoRenewable && monthly.type == .autoRenewable)
        #expect(annual.subscription?.subscriptionPeriod.unit == .year)
        #expect(monthly.subscription?.subscriptionPeriod.unit == .month)
        #expect(annual.subscription?.subscriptionGroupID == monthly.subscription?.subscriptionGroupID)
        #expect(annual.freeTrialText == "1-week free trial")
        #expect(monthly.freeTrialText == nil)
        #expect(annual.price == Decimal(string: "24.99"))
        #expect(monthly.price == Decimal(string: "3.99"))
        #expect(annual.pricePerPeriodText.hasSuffix("per year"))
        let eligible = await annual.subscription?.isEligibleForIntroOffer ?? false
        #expect(eligible)

        // Buy the annual plan: a verified, unrevoked entitlement with the free trial.
        let result = try await annual.purchase()
        guard case .success(let verification) = result, case .verified(let transaction) = verification else {
            Issue.record("Annual purchase didn't succeed: \(result)")
            return
        }
        await transaction.finish()
        #expect(transaction.productID == PremiumProducts.annual)
        #expect(transaction.offer?.type == .introductory)
        var entitlements: [PremiumStatus.Entitlement] = []
        for await r in Transaction.currentEntitlements {
            if case .verified(let t) = r {
                entitlements.append(.init(productID: t.productID, expirationDate: t.expirationDate,
                                          revocationDate: t.revocationDate, isUpgraded: t.isUpgraded))
            }
        }
        #expect(PremiumStatus.resolve(entitlements: entitlements, renewal: nil).isPremium())
        session.clearTransactions()
    }
}
