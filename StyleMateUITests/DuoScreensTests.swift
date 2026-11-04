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
/// iPhone run of StyleMateUITests ignores it. `DUO_SEATED=1` adds a pass with `-uiTestOrientation portrait`
/// (Apple's seated / tabletop pose on the inner display).
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

        // Item page.
        let tee = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'T-Shirt'")).firstMatch
        if scrollUntilHittable(tee, maxSwipes: 4) {
            tee.tap()
            let editDetails = itemPage()
            XCTAssertTrue(editDetails.waitForExistence(timeout: 15), "Item page didn't open")
            shoot("03-item")
            let backByID = app.navigationBars.buttons["BackButton"]
            let back = backByID.exists ? backByID : app.navigationBars.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 5) { back.tap() }
            _ = waitToDisappear(editDetails, timeout: 10)
        } else {
            XCTFail("No T-shirt tile to open")
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

    // MARK: - Seated (tabletop) pose

    @MainActor
    func test02_DuoSeatedScreens() throws {
        guard bridgeURL != nil else { throw XCTSkip("DUO_BRIDGE_URL not set: not on the Duo CI") }
        guard ProcessInfo.processInfo.environment["DUO_SEATED"] == "1" else { throw XCTSkip("DUO_SEATED != 1") }
        app = makeApp()
        app.launchArguments += ["-uiTestOrientation", "portrait"]
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists,
                      "The main tab UI never appeared")
        _ = waitForAny([text("Your Wardrobe"), text("Style for an occasion")], timeout: 20)
        shoot("seated-01-home")

        openTab("Wardrobe")
        let tee = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'T-Shirt'")).firstMatch
        if scrollUntilHittable(tee, maxSwipes: 4) {
            tee.tap()
            _ = itemPage().waitForExistence(timeout: 15)
            shoot("seated-03-item")
        }

        openTab("Home")
        if openOutfitDeck() {
            shoot("seated-05-outfit-deck")
        }
    }

    // MARK: - Steps

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
        var reply = ""
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                reply = "error: \(error.localizedDescription)"
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                reply = "\(status) " + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 320)
        print("[DuoShot] \(name): \(reply)")
        XCTAssertTrue(reply.hasPrefix("200"), "Duo bridge failed for \(name): \(reply)")
        // The phone is closed again: the app is back on the cover display. Give it a beat to settle.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2.0)
    }
}
