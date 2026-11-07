import XCTest

/// The account's life on one phone, from a fresh install with the DEBUG test Apple ID
/// (`-uiTestFakeAppleSignIn`; the CI simulator can't do real Sign in with Apple): sign out and back
/// in keeps everything and skips onboarding; Delete Account wipes it, and the same Apple ID starts
/// over from the selfie.
final class AccountFlowsE2ETests: E2ETestCase {

    @MainActor
    private func launchFresh() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-uiTestFakeAppleSignIn",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + darkModeArguments
        self.app = app
        app.launch()
    }

    // MARK: - Sign out, sign back in

    @MainActor
    func test01_SignOutAndBackInKeepsTheAccountAndSkipsOnboarding() throws {
        launchFresh()
        getStartedAndSignIn()
        let onboarding = finishOnboarding()
        XCTAssertFalse(onboarding.isEmpty, "A new account went Home without onboarding")

        openTab("Profile")
        let name = field("Name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Alex Demo", "The account isn't named after the Apple ID")
        replaceText(in: name, with: "Riley Test")
        openTab("Home")
        XCTAssertTrue(text("Riley").waitForExistence(timeout: 10), "Home doesn't greet the new name")

        signOut()
        getStartedAndSignIn()
        // The returning account goes straight Home, without a tap: onboarding would wait for its steps.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30) || tabButton("Home").exists,
                      "Signing back in sent a returning account through onboarding again")
        snap("signed-back-in")
        XCTAssertTrue(text("Riley").waitForExistence(timeout: 10), "Signing back in lost the account's name")
        openTab("Profile")
        XCTAssertEqual(field("Name").value as? String, "Riley Test")
    }

    // MARK: - Delete Account

    @MainActor
    func test02_DeleteAccountWipesItAndTheSameAppleIDStartsOver() throws {
        launchFresh()
        getStartedAndSignIn()
        _ = finishOnboarding()
        openTab("Profile")
        let name = field("Name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        replaceText(in: name, with: "Riley Test")
        openTab("Home")
        XCTAssertTrue(text("Riley").waitForExistence(timeout: 10))

        openTab("Profile")
        let delete = app.buttons.matching(NSPredicate(format: "identifier == 'profile.account.delete' OR label == 'Delete Account'")).firstMatch
        XCTAssertTrue(scrollUntilHittable(delete, maxSwipes: 14) || delete.isHittable, "No Delete Account in Profile")
        delete.tap()
        let confirm = app.buttons["deleteAccount.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete Account has no confirm button")
        for _ in 0..<4 where !confirm.isHittable { app.swipeUp() }
        snap("delete-account")
        confirm.tap()
        XCTAssertTrue(button(id: "onboarding.getStarted", label: "Get Started").waitForExistence(timeout: 20),
                      "Deleting the account didn't return to the welcome screen")
        snap("account-deleted")

        // The same Apple ID is a new account now: onboarding from the selfie, and nothing of the old one.
        getStartedAndSignIn()
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 8),
                       "After Delete Account the same Apple ID went straight Home, as if the account still existed")
        let onboarding = finishOnboarding()
        XCTAssertFalse(onboarding.isEmpty, "Onboarding didn't run again after Delete Account")
        XCTAssertFalse(text("Riley").exists, "The deleted account's name came back")
        openTab("Profile")
        XCTAssertEqual(field("Name").value as? String, "Alex Demo", "The deleted account's profile came back")
    }

    // MARK: - Steps

    @MainActor
    private func getStartedAndSignIn(file: StaticString = #filePath, line: UInt = #line) {
        let getStarted = button(id: "onboarding.getStarted", label: "Get Started")
        XCTAssertTrue(getStarted.waitForExistence(timeout: 30), "No Get Started on the welcome screen", file: file, line: line)
        pause(1.5)   // entrance animation
        getStarted.tap()
        let fake = app.buttons["signIn.debugFake"]
        XCTAssertTrue(fake.waitForExistence(timeout: 15), "The sign-in screen didn't appear", file: file, line: line)
        fake.tap()
    }

    /// Selfie (skipped: no camera) → photos (pre-granted by CI) → Home. Returns the steps seen.
    @MainActor
    private func finishOnboarding(file: StaticString = #filePath, line: UInt = #line) -> Set<String> {
        let tabs = app.tabBars.firstMatch
        var seen = Set<String>()
        let steps: [(key: String, element: XCUIElement)] = [
            ("selfie", app.buttons.matching(NSPredicate(format: "label == 'Skip' OR label == 'Skip for now'")).firstMatch),
            ("photos", button(id: "onboarding.allowPhotos", label: "Allow photo access")),
            ("find-yourself", app.buttons.matching(NSPredicate(format: "label == 'Continue' OR label CONTAINS 'Build my wardrobe'")).firstMatch),
            ("scan", button(id: "onboarding.skipScanWait", label: "keep scanning in the background")),
        ]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !tabs.exists {
            dismissSpringboardAlertIfPresent()
            if selfieScreen().exists { seen.insert("selfie") }
            for step in steps where step.element.exists {
                // The step can move on by itself between the check and the tap: tap the snapshot's frame.
                guard let frame = try? step.element.snapshot().frame else { break }
                guard !frame.isEmpty, app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                seen.insert(step.key)
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                break
            }
            pause(1)
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "Onboarding never reached Home (steps: \(seen.sorted()))", file: file, line: line)
        return seen
    }

    /// The selfie step, whichever state it's in (no camera in the simulator).
    @MainActor
    private func selfieScreen() -> XCUIElement {
        anyElement(NSPredicate(format: "label == 'Take a quick selfie' OR label == 'Camera access needed for selfie'"))
    }

    @MainActor
    private func signOut() {
        openTab("Profile")
        let signOut = app.buttons.matching(NSPredicate(format: "identifier == 'profile.account.signOut' OR label == 'Sign Out'")).firstMatch
        _ = scrollUntilHittable(signOut, maxSwipes: 14)
        XCTAssertTrue(signOut.exists && signOut.isHittable, "No Sign Out in Profile")
        signOut.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign Out' AND identifier != 'profile.account.signOut'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "No sign-out confirmation")
        confirm.tap()
        XCTAssertTrue(button(id: "onboarding.getStarted", label: "Get Started").waitForExistence(timeout: 15),
                      "Signing out didn't return to the welcome screen")
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + value)
    }
}
