import XCTest

/// "On you | Pieces" in the outfit deck, with a seeded try-on body (`-uiTestSeedTryOn`, DEBUG only:
/// a bundled CC0 sample photo as the body; looks are composited on it without the diffusion pass).
/// Screenshots: On you, full screen, Pieces — light here, `-dark` in the subclass.
class TryOnE2ETests: E2ETestCase {
    @MainActor
    func launchWithTryOn() {
        app = makeApp()
        app.launchArguments.append("-uiTestSeedTryOn")
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists, "No main tab UI")
        dismissSpringboardAlertIfPresent()
    }

    @MainActor
    func openDeck() throws {
        let generate = button(id: "home.styleMe", label: "Generate")
        XCTAssertTrue(generate.waitForExistence(timeout: 30), "No Style Me button")
        tapScrollingIfNeeded(generate)
        let counter = anyElement(NSPredicate(format: "identifier == 'outfit.counter' OR label MATCHES %@", "(Option )?1 of [0-9]+"))
        let weatherAlert = app.alerts["Weather unavailable"]
        var outcome: Int?
        let deadline = Date().addingTimeInterval(240)
        repeat {
            outcome = waitForAny([counter, weatherAlert], timeout: max(1, deadline.timeIntervalSinceNow))
            if outcome == 1 { proceedWithoutWeather(weatherAlert); outcome = nil }
        } while outcome == nil && Date() < deadline
        XCTAssertEqual(outcome, 0, "The outfit deck never appeared")
    }

    @MainActor
    func test01_OnYouAndPieces() throws {
        launchWithTryOn()
        try openDeck()

        let toggle = app.descendants(matching: .any)["tryon.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "The deck has no On you | Pieces toggle")
        let onYou = app.buttons["tryon.toggle.onYou"], pieces = app.buttons["tryon.toggle.pieces"]
        XCTAssertTrue(onYou.exists && pieces.exists)
        onYou.tap()
        snap("deck-on-you-rendering")

        // The seeded body + composite (Debug build on the simulator's CPU: allow a few minutes).
        let image = app.buttons["tryon.image"]
        let rejected = app.descendants(matching: .any)["tryon.rejected"]
        let setup = app.buttons["tryon.findPhoto"]
        let which = waitForAny([image, rejected, setup], timeout: 360)
        note("tryon-state", "state=\(which.map(String.init) ?? "timeout")\n" + visibleButtonLabels())
        XCTAssertEqual(which, 0, "The try-on image never appeared (0 = image, 1 = rejected, 2 = no body)")
        snap("deck-on-you")

        image.tap()
        let full = app.descendants(matching: .any)["tryon.fullscreen"]
        XCTAssertTrue(full.waitForExistence(timeout: 10), "Full-screen try-on didn't open")
        full.pinch(withScale: 2.0, velocity: 2.0)
        snap("tryon-fullscreen-zoomed")
        app.buttons["Done"].firstMatch.tap()

        XCTAssertTrue(pieces.waitForExistence(timeout: 10))
        pieces.tap()
        let piece = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'outfit.piece.'")).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 10), "Pieces board didn't come back")
        snap("deck-pieces")

        // Swap a piece in Pieces, then back to On you: that look renders again.
        piece.tap()
        let swap = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'outfit.swap.'")).firstMatch
        if swap.waitForExistence(timeout: 5) {
            swap.tap()
            onYou.tap()
            snap("deck-on-you-after-swap")
        }
    }
}

final class TryOnE2EDarkTests: TryOnE2ETests {
    override class var usesDarkAppearance: Bool { true }
}
