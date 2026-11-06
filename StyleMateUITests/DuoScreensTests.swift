import XCTest
import StoreKitTest

/// iPhone Duo screenshots, driven by `.github/workflows/duo.yml` on the iPhone Duo simulator (iOS 27.1).
///
/// The test navigates the real app (demo user, seeded wardrobe: the DebugLaunchSupport launch hooks) while the
/// phone is CLOSED, i.e. on the cover display: that is `XCUIScreen.main`, where XCUITest taps land reliably
/// (taps on the inner display are not). At each screen it calls the host-side bridge (`scripts/duo_bridge.py`,
/// plain HTTP on 127.0.0.1), which captures the cover display, opens the hinge flat (180°) and captures the
/// inner display, folds to half-open (~110°) and captures it again, then closes the phone and answers. So each
/// screen also proves the app keeps its state across cover -> inner -> half-open -> cover.
///
/// Skipped unless `DUO_BRIDGE_URL` is set (`TEST_RUNNER_DUO_BRIDGE_URL` for xcodebuild), so ci.yml's
/// iPhone run of StyleMateUITests ignores it.
final class DuoScreensTests: E2ETestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // One missing screen must not cost the rest of the set.
        continueAfterFailure = true
    }

    private var bridgeURL: String? {
        ProcessInfo.processInfo.environment["DUO_BRIDGE_URL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Book pose (the Duo simulator's own orientation) + cover

    @MainActor
    func test01_DuoScreens() throws {
        guard bridgeURL != nil else { throw XCTSkip("DUO_BRIDGE_URL not set: not on the Duo CI") }
        // A seeded try-on body (DEBUG `-uiTestSeedTryOn`), so the deck shows On you | Pieces.
        app = makeApp()
        app.launchArguments.append("-uiTestSeedTryOn")
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists, "No main tab UI")
        _ = waitForAny([text("Your Wardrobe"), text("Style for an occasion")], timeout: 20)
        shoot("01-home")

        // Closet grid.
        openTab("Wardrobe")
        let count = anyElement(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                           "\(seededItemCount) pieces", "\(seededItemCount) items"))
        XCTAssertTrue(count.waitForExistence(timeout: 20), "Closet doesn't show the seeded items")
        shoot("02-closet")

        // Item page (via the Tops chip, so the tile isn't half under the pinned filter bar).
        if openFirstTee() {
            shoot("03-item")
            goBack()
        }

        // Add sheet (a fixed-height sheet: check it on every display).
        let fab = app.buttons.matching(NSPredicate(format:
            "identifier == 'closet.add' OR label == 'Add clothes' OR label == 'Add'")).firstMatch
        if fab.waitForExistence(timeout: 10) {
            fab.tap()
            let gallery = button(id: "addSource.gallery", label: "Choose from Gallery")
            XCTAssertTrue(gallery.waitForExistence(timeout: 10), "Add sheet didn't open")
            shoot("04-add-sheet")
            // Tap above the sheet to dismiss it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            if !waitToDisappear(gallery, timeout: 5) { dragSheetDown(fromY: 0.6) }
        } else {
            XCTFail("No add (+) button in the closet")
        }

        // Today's Outfit deck.
        openTab("Home")
        if openOutfitDeck() {
            // On you (cover: the toggle; inner display: on you | pieces side by side).
            let onYou = app.buttons["tryon.toggle.onYou"]
            if onYou.waitForExistence(timeout: 20) { onYou.tap() }
            _ = waitForAny([app.buttons["tryon.image"], app.descendants(matching: .any)["tryon.rejected"]], timeout: 300)
            shoot("05-outfit-deck")
            let pieces = app.buttons["tryon.toggle.pieces"]
            if pieces.exists {
                pieces.tap()
                shoot("05b-outfit-deck-pieces")
            }
            finishDeck()
        }

        // Calendar (with the look logged from the deck, if it got that far).
        openTab("Outfits")
        _ = anyElement(NSPredicate(format: "label == %@", "Today's Outfits")).waitForExistence(timeout: 15)
        shoot("06-outfits")

        openTab("Profile")
        _ = waitForAny([text("Profile"), app.navigationBars.firstMatch], timeout: 10)
        shoot("07-profile")

        // Profile -> About -> Diagnostics (live hinge readings on every display) and Acknowledgements.
        if openProfileRow("profile.diagnostics", "Diagnostics", expect: "diagnostics.benchmark") {
            shoot("08-diagnostics")
            // The hinge check card (only shown with a hinge): live angle / pose / fold on each display.
            let record = app.buttons["diagnostics.hinge.flat"]
            if scrollUntilHittable(record, maxSwipes: 8) {
                shoot("08b-diagnostics-hinge")
            } else {
                XCTFail("No hinge check on the Duo")
            }
            leaveProfileRow()
        }
        if openProfileRow("profile.acknowledgements", "Acknowledgements", expect: "acknowledgements.privacyPolicy") {
            shoot("09-acknowledgements")
            leaveProfileRow()
        }
    }

    /// Scrolls Profile to a row and opens it; true once `expect` (an identifier on the new screen) shows.
    @MainActor
    private func openProfileRow(_ id: String, _ label: String, expect: String) -> Bool {
        let row = anyElement(NSPredicate(format: "identifier == %@ OR label == %@", id, label))
        guard scrollUntilHittable(row, maxSwipes: 12) else { XCTFail("No '\(label)' row in Profile"); return false }
        row.tap()
        guard app.descendants(matching: .any)[expect].waitForExistence(timeout: 15) else {
            snap("\(label)-missing")
            XCTFail("\(label) didn't open")
            return false
        }
        return true
    }

    /// Back to Profile from a pushed screen (the back button may live in the Duo's trailing rail).
    @MainActor
    private func leaveProfileRow() {
        let back = app.buttons.matching(NSPredicate(format:
            "identifier == 'BackButton' OR label == 'Back' OR label == 'Profile'")).firstMatch
        if back.waitForExistence(timeout: 5), back.isHittable {
            back.tap()
        } else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pop")], timeout: 1.0)
    }

    // MARK: - StyleMate Premium (paywall on every display)

    /// 50 pieces (the free tier's limit) + 23 waiting: Home's locked card, the paywall (cover: one column;
    /// inner: closet | plans split on the crease when half-open).
    @MainActor
    func test02_DuoPaywall() throws {
        guard bridgeURL != nil else { throw XCTSkip("DUO_BRIDGE_URL not set: not on the Duo CI") }
        let session = try SKTestSession(contentsOf: SubscriptionE2ETests.storeKitConfigURL)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.storefront = "GBR"
        defer { session.clearTransactions() }

        app = makeApp()
        app.launchArguments += ["-uiTestSeedWardrobeCount", "50", "-uiTestSeedLocked", "23"]
        app.launch()
        dismissSpringboardAlertIfPresent()
        let card = app.buttons.matching(NSPredicate(format:
            "identifier == 'premium.lockedCard' OR label CONTAINS 'more pieces found'")).firstMatch
        guard card.waitForExistence(timeout: 60) else { XCTFail("No locked-pieces card on Home"); return }
        shoot("20-home-locked")

        card.tap()
        let annual = app.buttons["paywall.plan.annual"]
        XCTAssertNotNil(waitForAny([annual, app.buttons["paywall.retry"]], timeout: 45), "Paywall didn't open")
        // The purchase itself is proven by SubscriptionE2ETests on the iPhone simulator: after a hinge
        // cycle the Duo simulator's accessibility tree still shows the screen under a full-screen
        // cover (run 42007188514), so it can't be driven from here.
        shoot("21-paywall")

        // Buy the annual plan from the test side (StoreKit Test): the app hears it on
        // Transaction.updates, the paywall turns into the success screen and the pieces unlock.
        let bought = expectation(description: "annual bought")
        Task {
            _ = try? await session.buyProduct(identifier: "com.stylemates.StyleMate.premium.annual", options: [])
            bought.fulfill()
        }
        wait(for: [bought], timeout: 60)
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "unlock")], timeout: 4)
        shoot("22-paywall-success")
        // "Done" sits at the bottom centre of the cover display (tapped by position: see above).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.9)).tap()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "dismiss")], timeout: 2)
        openTab("Profile")
        _ = anyElement(NSPredicate(format: "identifier == 'profile.premium.status'")).waitForExistence(timeout: 10)
        shoot("23-profile-premium")
    }

    // MARK: - Taste learning + Wardrobe insights

    /// The deck with its "Picked because…" line (a seeded taste profile, DEBUG `-uiTestSeedTaste`) and
    /// Profile → Wardrobe insights (cover: one column; inner: two columns split on the crease when half-open).
    @MainActor
    func test03_DuoTasteAndInsights() throws {
        guard bridgeURL != nil else { throw XCTSkip("DUO_BRIDGE_URL not set: not on the Duo CI") }
        app = makeApp()
        app.launchArguments.append("-uiTestSeedTaste")
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists, "No main tab UI")

        if openOutfitDeck() {
            let reason = anyElement(NSPredicate(format:
                "identifier == 'outfit.tasteReason' OR label CONTAINS 'Picked because'"))
            if !reason.waitForExistence(timeout: 5) { note("taste-reason-missing", visibleButtonLabels()) }
            shoot("30-deck-taste")
            finishDeck()
        }

        openTab("Profile")
        if openProfileRow("profile.insights", "Wardrobe insights", expect: "insights.summary") {
            shoot("31-insights")
            leaveProfileRow()
        }
    }

    // No seated (tabletop) pass: the Duo simulator shows the inner display sideways and simctl can't rotate it,
    // and without UIRequiresFullScreen (which StyleMate must not set) iOS refuses programmatic rotation:
    // "The current windowing mode does not allow for programmatic changes to interface orientation" (Duo run
    // 41913178351). Seated pose needs the real device.

    // MARK: - Steps

    /// Closet -> Tops chip -> first T-shirt -> its item page. Leaves the filter on "Tops".
    @MainActor
    private func openFirstTee() -> Bool {
        let topsChip = app.buttons.matching(NSPredicate(format:
            "identifier == 'closet.filter.tops' OR label BEGINSWITH 'Tops,'")).firstMatch
        if topsChip.waitForExistence(timeout: 10) { topsChip.tap() }
        let tee = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'T-Shirt'")).firstMatch
        guard scrollUntilHittable(tee, maxSwipes: 4) else { XCTFail("No T-shirt tile to open"); return false }
        tee.tap()
        let editDetails = itemPage()
        if !editDetails.waitForExistence(timeout: 10) {
            // One retry: the first tap can land while the grid is still settling after the scroll.
            if tee.exists, tee.isHittable { tee.tap() }
        }
        guard editDetails.waitForExistence(timeout: 10) else {
            snap("item-page-missing")
            XCTFail("Item page didn't open")
            return false
        }
        return true
    }

    /// Pops the item page (only call when it is open: the first nav-bar button elsewhere is "Select").
    @MainActor
    private func goBack() {
        let editDetails = itemPage()
        // Opening the phone moves a pushed item page into the closet's page pane, so after a
        // shot the cover may already be back on the grid.
        guard editDetails.exists else { return }
        // On the Duo the navigation bar's buttons live in the trailing system rail (not under
        // app.navigationBars), so look for the back button anywhere, then fall back to the edge swipe.
        let back = app.buttons.matching(NSPredicate(format:
            "identifier == 'BackButton' OR label == 'Back' OR label == 'Wardrobe'")).firstMatch
        if back.waitForExistence(timeout: 5), back.isHittable {
            back.tap()
        }
        if !waitToDisappear(editDetails, timeout: 5) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
        if !waitToDisappear(editDetails, timeout: 5) {
            note("back-buttons", visibleButtonLabels())
            XCTFail("Couldn't leave the item page")
        }
    }

    /// Home -> occasion -> Generate -> the deck's "1 of N" (answering the weather prompt).
    @MainActor
    private func openOutfitDeck() -> Bool {
        let occasion = button(id: "home.occasion.Everyday Casual", label: "Everyday Casual")
        if occasion.waitForExistence(timeout: 5), occasion.isHittable { occasion.tap() }
        let generate = button(id: "home.styleMe", label: "Generate")
        guard generate.waitForExistence(timeout: 10) else { XCTFail("No Generate button on Home"); return false }
        tapScrollingIfNeeded(generate)
        let counter = anyElement(NSPredicate(format: "identifier == 'outfit.counter' OR label MATCHES %@", "(Option )?1 of [0-9]+"))
        let weatherAlert = app.alerts["Weather unavailable"]
        let errorAlert = app.alerts["Outfit Suggestion"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            switch waitForAny([counter, weatherAlert, errorAlert], timeout: max(1, deadline.timeIntervalSinceNow)) {
            case 0?: return true
            case 1?: proceedWithoutWeather(weatherAlert)
            case 2?:
                snap("outfit-engine-error")
                errorAlert.buttons.firstMatch.tap()
                XCTFail("The outfit engine returned an error")
                return false
            default: break
            }
        }
        XCTFail("The outfit deck never appeared")
        return false
    }

    /// Keep option 1 (logs it to today), skip the rest, close the deck.
    @MainActor
    private func finishDeck() {
        let save = app.buttons.matching(NSPredicate(format: "identifier == 'outfit.wear' OR identifier == 'outfit.save' OR label BEGINSWITH 'Save'")).firstMatch
        if save.waitForExistence(timeout: 5) { save.tap() }
        let caughtUp = text("All Caught Up!")
        for _ in 0..<8 where !caughtUp.exists {
            let skip = app.buttons.matching(NSPredicate(format: "identifier == 'outfit.skip' OR label CONTAINS 'Skip'")).firstMatch
            guard skip.waitForExistence(timeout: 8) else { break }
            skip.tap()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "card")], timeout: 1.0)
        }
        let done = button(id: "outfit.done", label: "Done")
        if caughtUp.waitForExistence(timeout: 10), done.exists {
            done.tap()
        } else {
            let close = app.buttons.matching(NSPredicate(format:
                "label == 'Close' OR identifier CONTAINS 'xmark' OR label CONTAINS[c] 'close'")).firstMatch
            if close.exists { close.tap() }
        }
    }

    // MARK: - Bridge

    /// Attaches the cover-display state (XCUIScreen.main), then asks the host to shoot cover / flat / half-open.
    @MainActor
    private func shoot(_ name: String) {
        snap("\(name)-xcui")
        guard let base = bridgeURL,
              var components = URLComponents(string: base + "/shoot") else { return }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let done = expectation(description: "bridge \(name)")
        let box = ReplyBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.set("error: \(error.localizedDescription)")
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                box.set("\(status) " + (data.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 320)
        let reply = box.value
        print("[DuoShot] \(name): \(reply)")
        XCTAssertTrue(reply.hasPrefix("200"), "Duo bridge failed for \(name): \(reply)")
        // The phone is closed again: the app is back on the cover display. Give it a beat to settle.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2.0)
    }
}

/// The bridge's reply, written on URLSession's queue and read after the wait.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = "no reply"
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
    func set(_ s: String) { lock.lock(); text = s; lock.unlock() }
}
