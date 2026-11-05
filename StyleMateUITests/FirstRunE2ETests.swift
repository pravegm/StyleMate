import XCTest

/// First launch, no account: the onboarding flow and the "Try with sample photos" path,
/// on a true fresh install (`-uiTestResetState` without the demo user, so AuthService creates
/// the local profile itself). Every screen is snapped for the `e2e-screens` artifact.
final class FirstRunE2ETests: E2ETestCase {

    @MainActor
    private func launchFresh() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow While Using App", "Allow Full Access", "Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        self.app = app
        app.launch()
    }

    /// 1. Welcome → "Try with sample photos" → live sample scan → Home with labelled sample
    ///    clothes → remove them in one tap.
    @MainActor
    func test05_TrySamplePhotosFromWelcome() throws {
        launchFresh()
        let trySamples = button(id: "onboarding.trySamples", label: "Try with sample photos")
        XCTAssertTrue(trySamples.waitForExistence(timeout: 30), "Welcome screen has no 'Try with sample photos'")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sign in'")).firstMatch.exists,
                       "A sign-in button is still shown on first launch")
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "entrance")], timeout: 1.5)
        snap("welcome")
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Privacy Policy'")).exists, "No privacy policy link on welcome")

        trySamples.tap()
        let counter = anyElement(NSPredicate(format: "identifier == 'onboarding.scanCounter' OR label CONTAINS 'found'"))
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "The sample scan screen didn't appear")
        snap("sample-scan-started")

        // Hand-off: 8 items, or 90 s, or the samples are done (then 2.5 s of "ready").
        let openCloset = button(id: "onboarding.openCloset", label: "Open my closet")
        let tabs = app.tabBars.firstMatch
        var snappedProgress = false
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !tabs.exists {
            if !snappedProgress, counter.exists, counter.label.range(of: "^[1-9]", options: .regularExpression) != nil {
                snap("sample-scan-progress"); snappedProgress = true
            }
            if openCloset.exists { snap("sample-closet-ready"); openCloset.tap() }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 1)
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "Never reached Home after the sample scan")
        note("sample-counter", counter.exists ? counter.label : "(gone)")

        // Home labels the samples and removes them in one tap (once any were found).
        let remove = button(id: "home.removeSamples", label: "Remove")
        _ = waitForAny([remove], timeout: 120)   // the import may still be running in the banner
        snap("home-with-samples")
        openTab("Wardrobe")
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "closet")], timeout: 2)
        snap("closet-with-samples")
        openTab("Home")
        if remove.waitForExistence(timeout: 5) {
            remove.tap()
            XCTAssertTrue(waitToDisappear(remove, timeout: 10), "Sample clothes weren't removed")
            snap("home-samples-removed")
        } else {
            note("samples", "No sample items were extracted on this run (models missing?)")
        }
    }

    /// 2. Welcome → Get Started → selfie (skipped: no camera in the simulator) → photos
    ///    (pre-granted by CI) → Find yourself → scanning → Home. Four screens, no sign-in.
    @MainActor
    func test06_OnboardingToHomeWithoutAccount() throws {
        launchFresh()
        let getStarted = button(id: "onboarding.getStarted", label: "Get Started")
        XCTAssertTrue(getStarted.waitForExistence(timeout: 30), "No Get Started on the welcome screen")
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "entrance")], timeout: 1.5)
        getStarted.tap()

        let tabs = app.tabBars.firstMatch
        var seen = Set<String>()
        func snapOnce(_ key: String) { if seen.insert(key).inserted { snap(key) } }
        let steps: [(key: String, element: XCUIElement)] = [
            ("selfie-skip", app.buttons.matching(NSPredicate(format: "label == 'Skip' OR label == 'Skip for now'")).firstMatch),
            ("photos-allow", button(id: "onboarding.allowPhotos", label: "Allow photo access")),
            ("find-yourself-continue", app.buttons.matching(NSPredicate(format: "label == 'Continue' OR label CONTAINS 'Build my wardrobe'")).firstMatch),
            ("scan-open-closet", button(id: "onboarding.openCloset", label: "Open my closet")),
            ("scan-continue-background", button(id: "onboarding.skipScanWait", label: "keep scanning in the background")),
        ]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !tabs.exists {
            dismissSpringboardAlertIfPresent()
            for step in steps where step.element.exists && step.element.isHittable {
                snapOnce(step.key)
                step.element.tap()
                break
            }
            if anyElement(NSPredicate(format: "identifier == 'onboarding.scanCounter'")).exists { snapOnce("scanning") }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 1)
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "Onboarding never reached Home (screens seen: \(seen.sorted()))")
        note("onboarding-screens", seen.sorted().joined(separator: "\n"))
        snap("home-after-onboarding")

        // No coach-mark tour auto-starts any more.
        XCTAssertFalse(anyElement(NSPredicate(format: "label == 'Got it' OR label == 'Next'")).exists,
                       "A coach-mark tour started after onboarding")

        openTab("Profile")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'no account needed'")).waitForExistence(timeout: 10),
                      "Profile doesn't show the local profile")
        XCTAssertFalse(app.buttons["Sign Out"].exists, "Profile still offers Sign Out")
        snap("profile")
        app.swipeUp()
        snap("profile-scrolled")
    }
}
