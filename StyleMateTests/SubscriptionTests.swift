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

    // MARK: Account-level reconcile (AccountAllowance)

    private static func entry(_ n: Int, tier: ItemMeta.Tier = .free, locked: Bool = false,
                              sample: Bool = false, at seconds: Double? = nil) -> AccountAllowance.Entry {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        return AccountAllowance.Entry(
            id: id, meta: ItemMeta(createdAt: Date(timeIntervalSince1970: seconds ?? Double(n)), tier: tier, isSample: sample),
            isLocked: locked)
    }

    @Test func subscribingUnlocksEveryLockedItemAndKeepsThemAfterALapse() {
        let closet = (0..<50).map { Self.entry($0) }
        let waiting = (50..<73).map { Self.entry($0, locked: true) }
        let plan = AccountAllowance.reconcile(closet + waiting, isPremium: true)
        #expect(plan.unlock == Set(waiting.map(\.id)))
        #expect(plan.lock.isEmpty)
        #expect(plan.promote.count == 73)   // every free piece becomes Premium's
        let after = AccountAllowance.applying(plan, to: closet + waiting)
        // Premium lapses: nothing is locked again.
        #expect(AccountAllowance.reconcile(after, isPremium: false).isEmpty)
    }

    @Test func freeTierLocksPiecesPastFiftyAndUnlocksWhenThereIsRoom() {
        let closet = (0..<50).map { Self.entry($0) }
        let waiting = (50..<55).map { Self.entry($0, locked: true) }
        #expect(AccountAllowance.reconcile(closet + waiting, isPremium: false).isEmpty)   // full and settled
        // The user removed two pieces: the two oldest waiting ones take the slots.
        let plan = AccountAllowance.reconcile(Array(closet.dropFirst(2)) + waiting, isPremium: false)
        #expect(plan.unlock == Set(waiting.prefix(2).map(\.id)))
        #expect(plan.lock.isEmpty)
    }

    @Test func samplesAndGrandfatheredPiecesFollowTheirOwnRules() {
        // 30 pieces from before the free tier, 25 free ones, 6 samples.
        let old = (0..<30).map { Self.entry($0, tier: .grandfathered) }
        let free = (30..<55).map { Self.entry($0) }
        let samples = (55..<61).map { Self.entry($0, locked: $0 == 60, sample: true) }
        let plan = AccountAllowance.reconcile(old + free + samples, isPremium: false)
        // 50 - 30 kept = 20 free slots: the 5 newest free pieces lock; samples never lock (one unlocks).
        #expect(plan.lock == Set(free.suffix(5).map(\.id)))
        #expect(plan.unlock == [samples.last!.id])
        // A lapse with 120 Premium pieces locks nothing, and every new piece waits.
        let premium = (0..<120).map { Self.entry($0, tier: .premium) }
        #expect(AccountAllowance.reconcile(premium, isPremium: false).isEmpty)
        #expect(WardrobeAllowance.split(adding: 6, counted: 120, isPremium: false) == .init(add: 0, lock: 6))
        let lapsed = PremiumStatus(state: .expired, productID: PremiumProducts.annual, expiresAt: Date(timeIntervalSinceNow: -60))
        #expect(!lapsed.isPremium())
    }

    /// Two iPhones on the free tier each added pieces offline. Whatever order their records arrive
    /// in, both reach the same split: the 50 oldest stay, the rest lock.
    @Test func reconcileIsDeterministicAcrossDevicesAndMergeOrders() {
        let shared = (0..<40).map { Self.entry($0, at: Double($0)) }
        // Device A added 8 (they were unlocked there), device B added 7 (unlocked there too).
        let deviceA = (100..<108).map { Self.entry($0, at: 1_000 + Double($0)) }
        let deviceB = (200..<207).map { Self.entry($0, at: 1_050 + Double($0)) }
        let ab = shared + deviceA + deviceB
        let ba = (deviceB + shared + deviceA).reversed()
        var rng = SystemRandomNumberGenerator()
        let shuffled = ab.shuffled(using: &rng)
        let plans = [ab, Array(ba), shuffled].map { AccountAllowance.reconcile($0, isPremium: false) }
        #expect(plans[0] == plans[1] && plans[1] == plans[2])
        // 55 free pieces, 50 slots: the 5 newest (all from device B) lock.
        let newest = (deviceA + deviceB).sorted(by: AccountAllowance.precedes).suffix(5)
        #expect(plans[0].lock == Set(newest.map(\.id)))
        // Settled: running it again changes nothing, on either device.
        let after = AccountAllowance.applying(plans[0], to: ab)
        #expect(AccountAllowance.reconcile(after, isPremium: false).isEmpty)
        #expect(AccountAllowance.reconcile(Array(after.reversed()), isPremium: false).isEmpty)
        // Equal timestamps: the id breaks the tie the same way everywhere.
        let tied = [Self.entry(7, at: 5), Self.entry(3, at: 5)]
        #expect(AccountAllowance.reconcile(tied, isPremium: false, limit: 1).lock == [tied[0].id])
        #expect(AccountAllowance.movedNotice(3) == "3 pieces moved to Premium because your other iPhone added items.")
    }

    @MainActor
    @Test func lockedPiecesAndTheirBookkeepingPersistPerProfile() throws {
        let user = "test-locked-\(UUID().uuidString)"
        defer {
            for key in [WardrobeViewModel.storageKey(for: user), WardrobeViewModel.lockedKey(for: user),
                        WardrobeViewModel.metaKey(for: user)] { UserDefaults.standard.removeObject(forKey: key) }
        }
        let vm = WardrobeViewModel()
        vm.load(forUser: user)
        vm.items = Self.items(3)
        let waiting = Self.items(2)
        for item in waiting { vm.addLocked(item) }
        vm.addLocked(waiting[0])   // the same piece twice is stored once
        #expect(vm.lockedItems.count == 2)
        #expect(vm.metaFor(waiting[0].id).tier == .free)

        let relaunched = WardrobeViewModel()
        relaunched.load(forUser: user)
        #expect(relaunched.items.count == 3)
        #expect(relaunched.lockedItems.map(\.id) == waiting.map(\.id))
        #expect(relaunched.metaFor(vm.items[0].id) == vm.metaFor(vm.items[0].id))
        // Room in the free tier: they unlock on their own.
        #expect(relaunched.reconcileAllowance(isPremium: false) == 0)
        #expect(relaunched.lockedItems.isEmpty && relaunched.items.count == 5)
    }

    @MainActor
    @Test func itemsFromBeforeTheFreeTierAreGrandfathered() {
        let user = "test-legacy-\(UUID().uuidString)"
        defer {
            for key in [WardrobeViewModel.storageKey(for: user), WardrobeViewModel.lockedKey(for: user),
                        WardrobeViewModel.metaKey(for: user)] { UserDefaults.standard.removeObject(forKey: key) }
        }
        // An older build's wardrobe of 70: no bookkeeping saved yet.
        let old = Self.items(70)
        let data = try? JSONEncoder().encode(old.map { WardrobeItemCodable(from: $0) })
        UserDefaults.standard.set(data, forKey: WardrobeViewModel.storageKey(for: user))
        let vm = WardrobeViewModel()
        vm.load(forUser: user)
        #expect(vm.items.count == 70)
        #expect(vm.metaFor(old[0].id).tier == .grandfathered)
        #expect(vm.reconcileAllowance(isPremium: false) == 0)   // nothing the user had is hidden
        #expect(vm.items.count == 70)
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
