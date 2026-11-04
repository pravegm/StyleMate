import XCTest

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
        launchToHome()
        _ = waitForAny([text("Your Wardrobe"), text("Style for an occasion")], timeout: 20)
        shoot("01-home")

        // Closet grid.
        openTab("Wardrobe")
        let count = anyElement(NSPredicate(format: "label BEGINSWITH %@", "\(seededItemCount) items"))
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
            shoot("05-outfit-deck")
            finishDeck()
        }

        // Calendar (with the look logged from the deck, if it got that far).
        openTab("Outfits")
        _ = anyElement(NSPredicate(format: "label == %@", "Today's Outfits")).waitForExistence(timeout: 15)
        shoot("06-outfits")

        openTab("Profile")
        _ = waitForAny([text("Profile"), app.navigationBars.firstMatch], timeout: 10)
        shoot("07-profile")
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
