import XCTest

/// Shared plumbing for the end-to-end UI tests.
///
/// Every test launches the real app with the DEBUG launch hooks in
/// `StyleMate/Debug/DebugLaunchSupport.swift`: a clean state, a signed-in demo user, onboarding
/// done, and a seeded ~26-item wardrobe. Each step is saved as a screenshot attachment
/// (`keepAlways`), which CI exports from the .xcresult into the `e2e-screens` artifact.
///
/// Selectors prefer accessibility identifiers and fall back to visible labels, so the tests keep
/// working while the closet / outfit sheet / onboarding redesigns land.
class E2ETestCase: XCTestCase {
    var app: XCUIApplication!
    private var step = 0

    /// Number of items DebugLaunchSupport seeds.
    let seededItemCount = 26

    /// Dark-mode subclasses return true: the simulator runs in dark appearance and every
    /// screenshot is named `…-dark`, next to the light ones in the same artifact.
    class var usesDarkAppearance: Bool { false }

    /// "-dark" for the dark-mode pass, "" otherwise.
    var appearanceSuffix: String { Self.usesDarkAppearance ? "-dark" : "" }

    /// Launch arguments that force the app into dark appearance (the DEBUG hook in
    /// StyleMateApp; `XCUIDevice.appearance` alone didn't reach the app on CI).
    var darkModeArguments: [String] { Self.usesDarkAppearance ? ["-uiTestDarkMode"] : [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        step = 0
        let dark = Self.usesDarkAppearance
        MainActor.assumeIsolated {
            XCUIDevice.shared.appearance = dark ? .dark : .light
        }
    }

    override func tearDownWithError() throws {
        let failed = (testRun?.failureCount ?? 0) + (testRun?.unexpectedExceptionCount ?? 0) > 0
        // XCTest runs UI tests on the main thread; XCUIApplication is main-actor isolated.
        MainActor.assumeIsolated {
            if let app = self.app {
                if failed {
                    self.snap("FAILURE-final-state")
                    self.note("FAILURE-accessibility-tree", app.debugDescription)
                }
                app.terminate()
            }
            // Leave the simulator in light mode for whatever runs next.
            XCUIDevice.shared.appearance = .light
        }
    }

    // MARK: - Launch

    @MainActor
    func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestResetState", "-uiTestDemoUser", "-uiTestSkipOnboarding", "-uiTestSeedWardrobe",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ] + darkModeArguments
        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow Full Access", "Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        return app
    }

    @MainActor
    func launchToHome() {
        app = makeApp()
        app.launch()
        dismissSpringboardAlertIfPresent()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 60) || tabButton("Home").exists,
                      "The main tab UI never appeared: the demo-user / skip-onboarding launch hooks didn't take effect.")
        dismissSpringboardAlertIfPresent()
    }

    /// Location / photos permission prompts belong to SpringBoard, not the app. CI pre-grants
    /// them with `simctl privacy`; this is the safety net.
    @MainActor
    func dismissSpringboardAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        for label in ["Allow While Using App", "Allow Once", "Allow Full Access", "Allow", "OK"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
    }

    // MARK: - Screenshots

    /// Saves a full-screen screenshot named `<test>-<NN>-<name>`.
    @MainActor
    func snap(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%@-%02d-%@", shortTestName, step, name) + appearanceSuffix
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Saves a text attachment (e.g. the buttons on screen) for debugging selectors.
    func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(shortTestName)-\(name)\(appearanceSuffix).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    var shortTestName: String {
        // "-[StyleMateE2ETests test01_Closet]" -> "test01_Closet"
        let raw = name.split(separator: " ").last.map(String.init) ?? name
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]-"))
    }

    // MARK: - Queries

    @MainActor
    func tabButton(_ title: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[title]
        return inTabBar.exists ? inTabBar : app.buttons[title].firstMatch
    }

    @MainActor
    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = tabButton(title)
        XCTAssertTrue(button.waitForExistence(timeout: 15), "No '\(title)' tab", file: file, line: line)
        button.tap()
    }

    /// A button whose identifier is `id`, or whose label contains `label`.
    @MainActor
    func button(id: String? = nil, label: String) -> XCUIElement {
        if let id {
            let byID = app.buttons[id]
            if byID.exists { return byID }
        }
        return app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
    }

    /// Static text whose identifier is `id`, or whose label equals / contains `label`.
    @MainActor
    func text(id: String? = nil, _ label: String, exact: Bool = true) -> XCUIElement {
        if let id {
            let byID = app.descendants(matching: .any)[id]
            if byID.exists { return byID }
        }
        let predicate = exact
            ? NSPredicate(format: "label == %@", label)
            : NSPredicate(format: "label CONTAINS[c] %@", label)
        return app.staticTexts.matching(predicate).firstMatch
    }

    /// Any element (button, text, cell, other) matching the predicate.
    @MainActor
    func anyElement(_ predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - Waiting

    /// Polls until one of `candidates` exists; returns its index, or nil on timeout.
    /// (XCTWaiter on an unfulfillable expectation = a run-loop-friendly poll interval.)
    @MainActor
    @discardableResult
    func waitForAny(_ candidates: [XCUIElement], timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for (index, element) in candidates.enumerated() where element.exists { return index }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.5)
        } while Date() < deadline
        return nil
    }

    @MainActor
    @discardableResult
    func waitToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Taps an element, swiping the screen up a few times first if it's off-screen.
    @MainActor
    func tapScrollingIfNeeded(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "Missing element: \(element)", file: file, line: line)
        var attempts = 0
        while !element.isHittable && attempts < 4 {
            app.swipeUp()
            attempts += 1
        }
        element.tap()
    }

    /// Swipes up until `element` exists and is hittable (lazy grids only materialize what's on screen).
    @MainActor
    @discardableResult
    func scrollUntilHittable(_ element: XCUIElement, maxSwipes: Int) -> Bool {
        // "Clear" = hittable and its centre above the floating tab bar.
        func clear() -> Bool {
            element.exists && element.isHittable && element.frame.midY < app.frame.height * 0.78
        }
        _ = element.waitForExistence(timeout: 3)
        if clear() { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp(velocity: .slow)
            if clear() { return true }
        }
        return clear()
    }

    /// Drags a sheet down from `fromY` (normalized screen height) to dismiss it.
    @MainActor
    func dragSheetDown(fromY: CGFloat = 0.52) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// The open item page (its edit action lives in the ⋯ menu, so match the page itself).
    @MainActor
    func itemPage() -> XCUIElement {
        anyElement(NSPredicate(format:
            "identifier == 'itemDetail.root' OR identifier == 'itemDetail.more' OR label == 'More actions'"))
    }

    /// Answers "Weather unavailable" with its go-ahead button ("Style anyway"; older builds: "Yes").
    @MainActor
    func proceedWithoutWeather(_ alert: XCUIElement) {
        let proceed = alert.buttons["Style anyway"]
        (proceed.exists ? proceed : alert.buttons["Yes"]).tap()
    }

    /// Every button on screen, one per line — attached when a selector needs updating.
    @MainActor
    func visibleButtonLabels() -> String {
        app.buttons.allElementsBoundByIndex
            .map { "id='\($0.identifier)' label='\($0.label)' frame=\($0.frame)" }
            .joined(separator: "\n")
    }
}
