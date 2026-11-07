import XCTest
import StoreKitTest

/// StyleMate Premium from the entry points `SubscriptionE2ETests` doesn't take, through StoreKit Test
/// (StyleMate.storekit), each checked for what it changes: Profile's "See Premium plans" → the monthly
/// plan → adding past 50 opens the photo picker, not the paywall; Restore with nothing bought; a
/// subscription bought elsewhere unlocks the waiting pieces at launch and Restore confirms it;
/// removing pieces lets the oldest waiting ones in; Profile's "Unlock N waiting pieces"; the
/// paywall's Terms link; a held "We weren't sure" piece at the limit opens the paywall and stays held.
final class PremiumFlowsE2ETests: E2ETestCase {
    static let annualID = "com.stylemates.StyleMate.premium.annual"
    private var session: SKTestSession?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let session = try SKTestSession(contentsOf: SubscriptionE2ETests.storeKitConfigURL)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.storefront = "GBR"
        self.session = session
    }

    override func tearDownWithError() throws {
        session?.clearTransactions()
        try super.tearDownWithError()
    }

    @MainActor
    private func launch(pieces: Int, locked: Int, extra: [String] = []) {
        launchToHome(extra: ["-uiTestSeedWardrobeCount", "\(pieces)", "-uiTestSeedLocked", "\(locked)"] + extra)
    }

    @MainActor
    private func status() -> XCUIElement { anyElement(NSPredicate(format: "identifier == 'profile.premium.status'")) }

    @MainActor
    private func lockedCard() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'premium.lockedCard' OR label CONTAINS 'more pieces found'")).firstMatch
    }

    @MainActor
    private func subscribeButton() -> XCUIElement { app.buttons["paywall.subscribe"] }

    @MainActor
    private func waitForPlans(file: StaticString = #filePath, line: UInt = #line) {
        let found = waitForAny([app.buttons["paywall.plan.annual"], app.buttons["paywall.retry"]], timeout: 45)
        if found != 0 { note("paywall-buttons", visibleButtonLabels()) }
        XCTAssertEqual(found, 0, "The paywall never showed the StoreKit plans", file: file, line: line)
    }

    @MainActor
    private func closePaywall() {
        app.buttons["paywall.close"].tap()
        XCTAssertTrue(waitToDisappear(subscribeButton(), timeout: 10), "The paywall didn't close")
    }

    // MARK: - Profile → monthly → no limit any more

    @MainActor
    func test01_ProfileMonthlyPlanLiftsTheFreeLimit() throws {
        launch(pieces: 50, locked: 0)
        openTab("Profile")
        XCTAssertTrue(status().waitForExistence(timeout: 10) && status().label.contains("50 of 50 free pieces used"), "Profile: \(status().label)")
        let upgrade = app.buttons["profile.premium.upgrade"]
        XCTAssertTrue(upgrade.exists && upgrade.label.contains("See Premium plans"), "No 'See Premium plans' in Profile")
        upgrade.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Keep every piece you own'")).waitForExistence(timeout: 15), "The paywall didn't open from Profile")
        waitForPlans()

        app.buttons["paywall.plan.monthly"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.subscribeButton().label == "Subscribe" },
                      "The monthly plan (no trial) should say Subscribe: \(subscribeButton().label)")
        XCTAssertTrue(app.staticTexts["paywall.priceLine"].label.contains("per month"), "The price line isn't the monthly price")
        snap("paywall-monthly")
        subscribeButton().tap()
        let welcome = text("Welcome to Premium")
        let failed = app.alerts["Purchase didn't go through"]
        let outcome = waitForAny([welcome, failed], timeout: 60)
        if outcome == 1 { note("purchase-error", failed.debugDescription) }
        XCTAssertEqual(outcome, 0, "The monthly purchase didn't complete")
        XCTAssertTrue(app.staticTexts["paywall.successDetail"].label.contains("unlimited"), "Success doesn't say the wardrobe is unlimited")
        snap("paywall-monthly-success")
        app.buttons["paywall.done"].tap()

        XCTAssertTrue(waitUntil(timeout: 10) { self.status().label.contains("Premium · Monthly") }, "Profile: \(status().label)")
        XCTAssertTrue(app.buttons["profile.premium.manage"].exists, "No Manage subscription once subscribed")
        XCTAssertFalse(app.buttons["profile.premium.upgrade"].exists, "Profile still offers the plans to a subscriber")

        // At 50 pieces the gallery now opens the photo picker, not the paywall.
        openTab("Wardrobe")
        app.buttons["closet.add"].tap()
        let gallery = button(id: "addSource.gallery", label: "Choose from Gallery")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.tap()
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        let paywall = subscribeButton()
        let opened = waitForAny([photos, paywall], timeout: 30)
        snap("gallery-after-premium")
        XCTAssertEqual(opened, 0, "Past 50 with Premium the gallery still opened the paywall (or nothing)")
    }

    // MARK: - Restore with nothing to restore

    @MainActor
    func test02_RestoreWithNothingBoughtSaysSo() throws {
        launch(pieces: 10, locked: 0)
        openTab("Profile")
        let restore = app.buttons["profile.premium.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "No Restore Purchases in Profile")
        restore.tap()
        let alert = app.alerts["Restore Purchases"]
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "Restore Purchases never answered")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        snap("restore-nothing")
        XCTAssertTrue(message.contains("No StyleMate Premium subscription was found"), "Restore's answer: \(message)")
        alert.buttons["OK"].tap()
        XCTAssertTrue(status().label.contains("10 of 50 free pieces used"), "Restore changed the free tier: \(status().label)")
    }

    // MARK: - Bought elsewhere → unlocked at launch → Restore confirms

    @MainActor
    func test03_SubscriptionFromElsewhereUnlocksWaitingPiecesAndRestoreConfirms() async throws {
        let session = try XCTUnwrap(session)
        _ = try await session.buyProduct(identifier: Self.annualID)   // e.g. bought on the account's other iPhone
        launch(pieces: 50, locked: 23)
        openTab("Wardrobe")
        XCTAssertTrue(waitUntil(timeout: 30) { self.closetPieceCount() == 73 },
                      "An active subscription didn't unlock the 23 waiting pieces at launch (closet: \(closetPieceCount() ?? -1))")
        XCTAssertFalse(lockedCard().exists, "Pieces still wait for Premium with Premium active")

        openTab("Profile")
        XCTAssertTrue(waitUntil(timeout: 10) { self.status().label.contains("Premium") }, "Profile: \(status().label)")
        app.buttons["profile.premium.restore"].tap()
        let alert = app.alerts["Restore Purchases"]
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "Restore Purchases never answered")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        snap("restore-premium")
        XCTAssertTrue(message.contains("Premium restored") || message.contains("Premium is active"), "Restore's answer: \(message)")
        alert.buttons["OK"].tap()
    }

    // MARK: - Removing pieces lets waiting ones in

    @MainActor
    func test04_RemovingPiecesLetsTheOldestWaitingOnesIn() throws {
        launch(pieces: 50, locked: 23)
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), 50)
        XCTAssertTrue(lockedCard().waitForExistence(timeout: 10) && lockedCard().label.contains("23 more pieces found"))
        app.buttons["closet.select"].tap()
        let tiles = closetTiles().allElementsBoundByIndex.filter(\.isHittable).prefix(2)
        XCTAssertEqual(tiles.count, 2, "Couldn't pick two pieces")
        tiles.forEach { $0.tap() }
        app.buttons.matching(NSPredicate(format: "label == 'Remove'")).firstMatch.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Remove 2 items'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.lockedCard().exists && self.lockedCard().label.contains("21 more pieces found") },
                      "Removing two pieces didn't let two waiting ones in (card: \(lockedCard().exists ? lockedCard().label : "gone"))")
        XCTAssertEqual(closetPieceCount(), 50, "The closet should be full again with the two waiting pieces")
        snap("closet-two-unlocked")

        relaunchKeepingData()
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), 50, "The closet changed after a relaunch")
        XCTAssertTrue(lockedCard().waitForExistence(timeout: 10) && lockedCard().label.contains("21 more pieces found"),
                      "The waiting count changed after a relaunch")
    }

    // MARK: - Profile's "Unlock N", the Terms link, a held piece at the limit

    @MainActor
    func test05_WaitingPiecesEntryTermsAndHeldPieceAtTheLimit() throws {
        launch(pieces: 50, locked: 3, extra: ["-uiTestSeedHabits"])
        openTab("Profile")
        let unlock = app.buttons["profile.premium.upgrade"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10) && unlock.label.contains("Unlock 3 waiting pieces"), "Profile: \(unlock.label)")
        unlock.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == '3 more pieces are waiting for your closet'")).waitForExistence(timeout: 15),
                      "The paywall from 'Unlock 3' doesn't speak of the 3 waiting pieces")
        waitForPlans()

        // Terms of Use opens Apple's EULA in Safari; coming back finds the paywall as it was.
        let terms = app.descendants(matching: .any).matching(identifier: "paywall.terms").firstMatch
        XCTAssertTrue(terms.exists, "No Terms of Use on the paywall")
        terms.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Terms of Use didn't open in Safari")
        app.activate()
        XCTAssertTrue(subscribeButton().waitForExistence(timeout: 10), "Coming back from Safari lost the paywall")
        closePaywall()

        // A held piece can't join a full free closet: the paywall instead, and the piece stays held.
        openTab("Home")
        let held = app.buttons["home.uncertainItems"]
        XCTAssertTrue(held.waitForExistence(timeout: 15), "No 'We weren't sure' card")
        held.tap()
        let add = app.buttons.matching(NSPredicate(format: "label == 'Add'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label BEGINSWITH 'Your free wardrobe holds 50 pieces'")).waitForExistence(timeout: 15),
                      "Adding a held piece at the limit didn't open the 'full' paywall")
        snap("paywall-held-at-limit")
        closePaywall()
        XCTAssertTrue(held.waitForExistence(timeout: 10) && held.label.contains("2 items"), "The held piece was lost: \(held.exists ? held.label : "no card")")
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), 50, "The closet went past 50 without Premium")
    }

    // MARK: - A gallery batch that crosses 50

    /// At 49 pieces, a photo with several garments: what fits is added, the rest is saved as waiting,
    /// and the paywall says how many wait.
    @MainActor
    func test06_GalleryBatchCrossingTheLimitAddsWhatFitsAndSavesTheRest() throws {
        launch(pieces: 49, locked: 0)
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), 49)
        app.buttons["closet.add"].tap()
        let gallery = button(id: "addSource.gallery", label: "Choose from Gallery")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.tap()
        guard pickNewestPhoto() else { return }

        let reviewTitle = anyElement(NSPredicate(format: "label ==[c] 'Review items'"))
        let whichOne = anyElement(NSPredicate(format: "label == 'Which one is you?'"))
        if waitForAny([reviewTitle, whichOne], timeout: 120) == 1 { button(label: "use the whole photo").tap() }
        XCTAssertTrue(reviewTitle.waitForExistence(timeout: 60), "The review never appeared")
        let found = anyElement(NSPredicate(format: "label MATCHES %@", "(.*, )?[1-9][0-9]* items? (found|detected)"))
        XCTAssertTrue(found.waitForExistence(timeout: 420), "On-device extraction found nothing in the street photo")
        let add = app.buttons["review.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "No 'Add N Items to Wardrobe'")
        let adding = Int(add.label.components(separatedBy: " ").dropFirst().first ?? "") ?? 0
        note("review-add", "\(add.label) | \(found.label)")
        guard adding >= 2 else { throw XCTSkip("The photo gave \(adding) item(s): nothing to carry past the 50th piece") }
        XCTAssertTrue(app.descendants(matching: .any)["review.allowanceNote"].exists, "The review doesn't warn that only one more piece fits")
        snap("review-at-49")
        add.tap()

        let waiting = adding - 1
        let headline = "\(waiting) piece\(waiting == 1 ? " is" : "s are") saved and waiting"
        XCTAssertTrue(anyElement(NSPredicate(format: "label == %@", headline)).waitForExistence(timeout: 20),
                      "After the batch the paywall doesn't say '\(headline)'")
        snap("paywall-batch-overflow")
        closePaywall()
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), 50, "The batch should fill the closet to exactly 50")
        XCTAssertTrue(lockedCard().waitForExistence(timeout: 10) && lockedCard().label.contains("\(waiting) more piece"),
                      "The rest of the batch isn't waiting for Premium (card: \(lockedCard().exists ? lockedCard().label : "none"))")
    }
}
