import XCTest

/// Taste learning in the deck, Home's "Almost ready" card and Wardrobe insights, driven through
/// the real app (light here, dark in `TasteInsightsE2EDarkTests`). Screenshots land in
/// `e2e-screens`.
///
/// `-uiTestSeedTaste` (DEBUG) stores a learned profile in which the seeded closet's everyday
/// colour pairings were worn often, so the deck explains "Picked because you often wear …".
class TasteInsightsE2ETests: E2ETestCase {

    // MARK: - Deck: "Picked because…" and "Not my style / Not today"

    @MainActor
    func test01_DeckExplainsTasteAndAsksWhyOnSkip() throws {
        app = makeApp()
        app.launchArguments.append("-uiTestSeedTaste")
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists,
                      "The main tab UI never appeared")
        guard openDeck() else { return }

        // The line belongs to looks a learned pairing shaped: page on until one shows.
        let reason = anyElement(NSPredicate(format:
            "identifier == 'outfit.tasteReason' OR label CONTAINS 'Picked because'"))
        var found = reason.waitForExistence(timeout: 5)
        for _ in 0..<4 where !found {
            skip()
            answerNotToday()
            found = reason.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(found, "No 'Picked because…' line on any look in the deck")
        snap("deck-taste-reason")

        // Skip: the optional "Not my style / Not today" appears; answering dismisses it.
        skip()
        let notMyStyle = app.buttons["outfit.skipReason.notMyStyle"]
        XCTAssertTrue(notMyStyle.waitForExistence(timeout: 5), "No 'Not my style' choice after a skip")
        XCTAssertTrue(app.buttons["outfit.skipReason.notToday"].exists, "No 'Not today' choice after a skip")
        snap("skip-reason-prompt")
        // Unanswered, the prompt settles by itself after 6 s, which a slow runner's queries + screenshot can
        // use up (main run 42337618641): tap it from a snapshot, and if it had gone, skip again and answer at once.
        if !tapIfPresent(notMyStyle) {
            skip()
            XCTAssertTrue(notMyStyle.waitForExistence(timeout: 5), "No 'Not my style' choice after another skip")
            XCTAssertTrue(tapIfPresent(notMyStyle), "The skip prompt went before it could be answered")
        }
        XCTAssertTrue(waitToDisappear(notMyStyle, timeout: 5), "The skip prompt didn't go away when answered")
        snap("skip-reason-answered")
    }

    // MARK: - Home: "Almost ready"

    @MainActor
    func test02_HomeSaysWhatsMissing() throws {
        app = makeApp()
        // The seed catalog starts with two tees: no bottom, no shoes.
        app.launchArguments += ["-uiTestSeedWardrobeCount", "2"]
        app.launch()
        dismissSpringboardAlertIfPresent()
        let card = anyElement(NSPredicate(format: "identifier == 'home.almostReady' OR label == 'Almost ready'"))
        XCTAssertTrue(card.waitForExistence(timeout: 60), "No 'Almost ready' card on a two-tee closet")
        let message = anyElement(NSPredicate(format: "label == %@", "Add 1 more bottom and shoes to get outfits"))
        XCTAssertTrue(message.waitForExistence(timeout: 5), "The card doesn't say what's missing")
        XCTAssertFalse(app.buttons["home.todayLook.wear"].exists, "A Today's look card showed without a whole outfit")
        snap("home-almost-ready")
    }

    // MARK: - Wardrobe insights

    @MainActor
    func test03_WardrobeInsights() throws {
        launchToHome()
        // Log today's look first, so "Most worn" has something to show.
        let wear = app.buttons["home.todayLook.wear"]
        if wear.waitForExistence(timeout: 30) { wear.tap() }

        openTab("Profile")
        let row = anyElement(NSPredicate(format: "identifier == 'profile.insights' OR label == 'Wardrobe insights'"))
        XCTAssertTrue(scrollUntilHittable(row, maxSwipes: 10), "No Wardrobe insights row in Profile")
        snap("profile-your-style")
        row.tap()
        let summary = app.descendants(matching: .any)["insights.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Wardrobe insights didn't open")
        // The summary card itself: Home's "26 pieces" header also exists further down the tree.
        XCTAssertTrue(summary.label.hasPrefix("\(seededItemCount) pieces"),
                      "Insights don't count the seeded closet: '\(summary.label)'")
        snap("insights-top")
        app.swipeUp()
        snap("insights-middle")
        app.swipeUp()
        snap("insights-bottom")
    }

    // MARK: - Steps

    /// Home → Style me → the deck's "1 of N" (answering the weather prompt).
    @MainActor
    private func openDeck() -> Bool {
        let generate = button(id: "home.styleMe", label: "Generate")
        guard generate.waitForExistence(timeout: 20) else { XCTFail("No Style me button on Home"); return false }
        tapScrollingIfNeeded(generate)
        let counter = anyElement(NSPredicate(format: "identifier == 'outfit.counter' OR label MATCHES %@", "(Option )?1 of [0-9]+"))
        let weatherAlert = app.alerts["Weather unavailable"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            switch waitForAny([counter, weatherAlert], timeout: max(1, deadline.timeIntervalSinceNow)) {
            case 0?: return true
            case 1?: proceedWithoutWeather(weatherAlert)
            default: break
            }
        }
        XCTFail("The outfit deck never appeared")
        return false
    }

    @MainActor
    private func skip() {
        let skip = app.buttons.matching(NSPredicate(format: "identifier == 'outfit.skip' OR label == 'Skip'")).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 8), "No Skip button")
        skip.tap()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "next card")], timeout: 0.8)
    }

    /// Taps `element` at its snapshot's frame (no failure if it went meanwhile); false when it's gone.
    @MainActor
    private func tapIfPresent(_ element: XCUIElement) -> Bool {
        guard let frame = try? element.snapshot().frame, !frame.isEmpty else { return false }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        return true
    }

    @MainActor
    private func answerNotToday() {
        let notToday = app.buttons["outfit.skipReason.notToday"]
        if notToday.waitForExistence(timeout: 2) { notToday.tap() }
    }
}
