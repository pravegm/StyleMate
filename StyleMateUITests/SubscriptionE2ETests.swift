import XCTest
import StoreKitTest

/// StyleMate Premium end to end, through the real app and StoreKit Test (StyleMate.storekit):
/// a closet at the free tier's 50 pieces with 23 more waiting (locked) → the Home / closet card →
/// the paywall (plans, prices and trial from StoreKit) → buy the annual plan → every waiting piece
/// lands in the closet. And a manual add at the limit opens the paywall instead of the picker.
/// Screenshots go to `e2e-screens` (and `-dark` from the subclass below).
class SubscriptionE2ETests: E2ETestCase {
    static let freeLimit = 50
    static let lockedCount = 23

    private var session: SKTestSession?

    /// The repo's StyleMate.storekit, found from this file's path (the simulator runs on the
    /// same Mac, so the path is valid inside the test runner).
    static var storeKitConfigURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StyleMate.storekit")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let session = try SKTestSession(contentsOf: Self.storeKitConfigURL)
        session.resetToDefaultState()
        session.disableDialogs = true      // purchases complete without the StoreKit sheet
        session.clearTransactions()        // every test starts on the free tier
        session.storefront = "GBR"
        self.session = session
    }

    override func tearDownWithError() throws {
        session?.clearTransactions()
        try super.tearDownWithError()
    }

    /// Demo user with exactly 50 seeded pieces (the free tier's limit) and `locked` more waiting.
    @MainActor
    func launchAtFreeLimit(locked: Int) {
        app = makeApp()
        app.launchArguments += ["-uiTestSeedWardrobeCount", "\(Self.freeLimit)", "-uiTestSeedLocked", "\(locked)"]
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists,
                      "The main tab UI never appeared")
    }

    @MainActor
    private func lockedCard() -> XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "identifier == 'premium.lockedCard' OR label CONTAINS 'more pieces found'")).firstMatch
    }

    @MainActor
    private func closetCount(_ n: Int) -> XCUIElement {
        anyElement(NSPredicate(format: "label BEGINSWITH %@", "\(n) items"))
    }

    // MARK: - Locked pieces → paywall → annual → unlocked

    @MainActor
    func test01_LockedPiecesUnlockWithAnnualPlan() throws {
        launchAtFreeLimit(locked: Self.lockedCount)

        let card = lockedCard()
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Home shows no 'more pieces found' card")
        XCTAssertTrue(card.label.contains("\(Self.lockedCount) more pieces found"), "Card label: \(card.label)")
        snap("home-locked-card")

        openTab("Wardrobe")
        XCTAssertTrue(closetCount(Self.freeLimit).waitForExistence(timeout: 20),
                      "Closet doesn't show the \(Self.freeLimit) free pieces (locked ones must not be in it)")
        XCTAssertTrue(lockedCard().waitForExistence(timeout: 10), "Closet shows no locked-pieces card")
        snap("closet-locked-card")

        // Home and the closet both have the card (an off-screen tab can stay in the tree): tap the visible one.
        let cards = app.buttons.matching(NSPredicate(format:
            "identifier == 'premium.lockedCard' OR label CONTAINS 'more pieces found'")).allElementsBoundByIndex
        (cards.first { $0.isHittable } ?? lockedCard()).tap()
        let annual = app.buttons["paywall.plan.annual"]
        let retry = app.buttons["paywall.retry"]
        let found = waitForAny([annual, retry], timeout: 45)
        if found != 0 { note("paywall-buttons", visibleButtonLabels()) }
        XCTAssertEqual(found, 0, "The paywall never showed the StoreKit plans (StoreKit Test configuration not active?)")
        XCTAssertTrue(app.buttons["paywall.plan.monthly"].exists, "No monthly plan")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'per year'")).exists, "Annual price/period missing")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS[c] 'free trial'")).exists, "Trial terms missing")
        snap("paywall")

        // 3.1.2: restore, terms, privacy, auto-renew disclosure.
        let disclosure = anyElement(NSPredicate(format: "identifier == 'paywall.disclosure'"))
        _ = scrollUntilHittable(disclosure, maxSwipes: 4)
        XCTAssertTrue(app.buttons["paywall.restore"].exists, "No Restore Purchases")
        XCTAssertTrue(anyElement(NSPredicate(format: "identifier == 'paywall.terms' OR label == 'Terms of Use'")).exists, "No Terms of Use")
        XCTAssertTrue(anyElement(NSPredicate(format: "identifier == 'paywall.privacy' OR label == 'Privacy Policy'")).exists, "No Privacy Policy")
        XCTAssertTrue(disclosure.label.contains("renews automatically"), "No auto-renew disclosure")
        snap("paywall-legal")

        if annual.isHittable { annual.tap() }
        let subscribe = app.buttons["paywall.subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5), "No subscribe button")
        XCTAssertTrue(subscribe.label.contains("Start free trial"), "Annual CTA should start the free trial: \(subscribe.label)")
        subscribe.tap()

        let success = anyElement(NSPredicate(format: "identifier == 'paywall.success' OR identifier == 'paywall.done'"))
        let errorAlert = app.alerts["Purchase didn't go through"]
        let outcome = waitForAny([success, errorAlert], timeout: 60)
        if outcome == 1 { note("purchase-error", errorAlert.debugDescription) }
        XCTAssertEqual(outcome, 0, "The annual purchase didn't complete in StoreKit Test")
        let detail = anyElement(NSPredicate(format: "identifier == 'paywall.successDetail'"))
        XCTAssertTrue(detail.waitForExistence(timeout: 5) && detail.label.contains("\(Self.lockedCount) pieces"),
                      "Success doesn't say the \(Self.lockedCount) pieces were added: \(detail.label)")
        snap("paywall-success")

        app.buttons["paywall.done"].tap()
        let total = Self.freeLimit + Self.lockedCount
        XCTAssertTrue(closetCount(total).waitForExistence(timeout: 20), "The \(Self.lockedCount) pieces didn't unlock into the closet")
        XCTAssertTrue(waitToDisappear(lockedCard(), timeout: 10), "The locked card is still shown after subscribing")
        snap("closet-unlocked")

        openTab("Profile")
        let status = anyElement(NSPredicate(format: "identifier == 'profile.premium.status'"))
        XCTAssertTrue(status.waitForExistence(timeout: 10), "No Premium row in Profile")
        XCTAssertTrue(status.label.contains("Premium"), "Profile doesn't show Premium: \(status.label)")
        XCTAssertTrue(app.buttons["profile.premium.manage"].exists, "No Manage Subscription")
        snap("profile-premium")
    }

    // MARK: - Manual add at the limit → paywall

    @MainActor
    func test02_AddAtFreeLimitOpensPaywall() throws {
        launchAtFreeLimit(locked: 0)
        openTab("Wardrobe")
        XCTAssertTrue(closetCount(Self.freeLimit).waitForExistence(timeout: 20), "Closet doesn't show 50 pieces")
        XCTAssertFalse(lockedCard().exists, "No pieces are locked, so no card")

        let add = app.buttons.matching(NSPredicate(format: "identifier == 'closet.add' OR label == 'Add clothes'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "No add (+) button")
        add.tap()
        let gallery = button(id: "addSource.gallery", label: "Choose from Gallery")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "Add sheet didn't open")
        gallery.tap()

        let paywall = anyElement(NSPredicate(format: "identifier == 'paywall.root' OR identifier == 'paywall.subscribe'"))
        XCTAssertTrue(paywall.waitForExistence(timeout: 15), "Gallery at the free limit didn't open the paywall")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Keep every piece'")).exists, "Paywall headline missing")
        _ = waitForAny([app.buttons["paywall.plan.annual"], app.buttons["paywall.retry"]], timeout: 30)
        snap("paywall-at-limit")

        app.buttons["paywall.close"].tap()
        XCTAssertTrue(waitToDisappear(app.buttons["paywall.subscribe"], timeout: 10), "Paywall didn't close")
        XCTAssertTrue(closetCount(Self.freeLimit).exists, "Closet changed after closing the paywall")

        openTab("Profile")
        let status = anyElement(NSPredicate(format: "identifier == 'profile.premium.status'"))
        XCTAssertTrue(status.waitForExistence(timeout: 10), "No Premium row in Profile")
        XCTAssertTrue(status.label.contains("50 of 50 free pieces used"), "Profile free-tier line: \(status.label)")
        snap("profile-free")
    }
}

final class SubscriptionE2EDarkTests: SubscriptionE2ETests {
    override class var usesDarkAppearance: Bool { true }
}
