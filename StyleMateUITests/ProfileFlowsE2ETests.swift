import XCTest

/// Profile's settings, each changed like a person would and checked where it shows up (and after a
/// relaunch): About you and style preferences (Home's greeting and occasion chips), Reset style
/// learning, the morning-outfit notification (the real permission prompt), Replay app tour,
/// the privacy policy link, Retake selfie → Find yourself, and Empty my wardrobe.
final class ProfileFlowsE2ETests: E2ETestCase {

    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    // MARK: - About you + style preferences

    @MainActor
    func test01_AboutYouAndStylePreferencesPersist() throws {
        launchToHome()
        openTab("Profile")
        let name = field("Name")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "No Name field in Profile")
        let age = field("Age")
        XCTAssertTrue(age.exists, "No Age field in Profile")
        // Age first (a number pad has no return key); the name's return then puts the keyboard away.
        replaceText(in: age, with: "34", submit: false)
        replaceText(in: name, with: "Sam Rivera")
        snap("profile-about-you")

        // Preferences: swap Sports / Active for Streetwear (exactly six are kept).
        let edit = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Edit preferences'")).firstMatch
        XCTAssertTrue(scrollUntilHittable(edit, maxSwipes: 4), "No 'Edit preferences' in Profile")
        edit.tap()
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save my style preferences'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "The style preferences sheet didn't open")
        XCTAssertFalse(save.isEnabled, "Save is enabled before anything changed")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sports / Active'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Streetwear'")).firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { save.isEnabled }, "Save stays disabled with six styles picked")
        snap("style-preferences")
        save.tap()
        XCTAssertTrue(waitToDisappear(save, timeout: 10), "The style preferences sheet didn't close on Save")

        // Home greets the new name and offers the new occasion.
        openTab("Home")
        XCTAssertTrue(text("Sam").waitForExistence(timeout: 10), "Home doesn't greet the new first name")
        XCTAssertTrue(app.buttons["home.occasion.Streetwear"].waitForExistence(timeout: 5), "Home doesn't offer the newly picked Streetwear")
        XCTAssertFalse(app.buttons["home.occasion.Sports / Active"].exists, "Home still offers the dropped Sports / Active")
        snap("home-new-name-and-styles")

        relaunchKeepingData()
        XCTAssertTrue(text("Sam").waitForExistence(timeout: 15), "The new name was lost on relaunch")
        XCTAssertTrue(app.buttons["home.occasion.Streetwear"].exists, "The style preferences were lost on relaunch")
        openTab("Profile")
        XCTAssertEqual(field("Name").value as? String, "Sam Rivera", "Profile's name after a relaunch")
        XCTAssertEqual(field("Age").value as? String, "34", "Profile's age after a relaunch")
    }

    // MARK: - Reset style learning

    @MainActor
    func test02_ResetStyleLearningForgetsAndStaysForgotten() throws {
        launchToHome(extra: ["-uiTestSeedTaste"])
        openTab("Profile")
        let reset = app.buttons["profile.resetTaste"]
        XCTAssertTrue(scrollUntilHittable(reset, maxSwipes: 8), "No 'Reset style learning' in Profile")
        XCTAssertTrue(reset.isEnabled, "Reset is disabled although the stylist has learned from 12 choices")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Learned from 12 choices'")).exists, "The footer doesn't say what was learned")
        reset.tap()
        let alert = app.alerts["Reset style learning?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Reset doesn't ask to confirm")
        snap("reset-taste-confirm")
        alert.buttons["Reset"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !reset.isEnabled }, "Reset stays enabled after resetting")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Nothing learned yet.'")).waitForExistence(timeout: 5),
                      "The footer doesn't say nothing is learned any more")
        snap("reset-taste-done")

        relaunchKeepingData()
        openTab("Profile")
        let again = app.buttons["profile.resetTaste"]
        XCTAssertTrue(scrollUntilHittable(again, maxSwipes: 8))
        XCTAssertFalse(again.isEnabled, "The reset learning came back after a relaunch")
    }

    // MARK: - Morning outfit notification

    @MainActor
    func test03_MorningOutfitAsksForNotificationsAndKeepsTheTime() throws {
        launchToHome()
        openTab("Profile")
        let toggle = app.switches["profile.morningLook"]
        XCTAssertTrue(scrollUntilHittable(toggle, maxSwipes: 8), "No Morning outfit switch in Profile")
        XCTAssertEqual(toggle.value as? String, "0", "Morning outfit is on before it was asked for")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

        // iOS asks once; allow.
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) {
            snap("notification-prompt")
            let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
            XCTAssertTrue(allow.exists, "The notification prompt has no Allow: \(alert.debugDescription)")
            allow.tap()
        } else {
            note("notification-prompt", "No system prompt (notifications were already answered on this simulator)")
        }
        XCTAssertTrue(waitUntil(timeout: 10) { toggle.value as? String == "1" }, "Morning outfit didn't turn on after allowing notifications")
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Time'")).waitForExistence(timeout: 5), "No time to pick once it's on")
        snap("morning-outfit-on")

        relaunchKeepingData()
        openTab("Profile")
        let again = app.switches["profile.morningLook"]
        XCTAssertTrue(scrollUntilHittable(again, maxSwipes: 8))
        XCTAssertEqual(again.value as? String, "1", "Morning outfit turned itself off after a relaunch")
        again.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { again.value as? String == "0" }, "Morning outfit didn't turn off")
        XCTAssertFalse(anyElement(NSPredicate(format: "label == 'Time'")).exists, "The time stays after turning it off")
    }

    // MARK: - Replay app tour

    @MainActor
    func test04_ReplayTourWalksEveryTabAndEnds() throws {
        launchToHome()
        openTab("Profile")
        let replay = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Replay app tour'")).firstMatch
        XCTAssertTrue(scrollUntilHittable(replay, maxSwipes: 10), "No 'Replay app tour' in Profile")
        replay.tap()
        let steps = ["Get an outfit, instantly", "Add your clothes", "Save & plan outfits", "Your profile & settings"]
        for (i, title) in steps.enumerated() {
            XCTAssertTrue(text(title).waitForExistence(timeout: 10), "Tour step \(i + 1) ('\(title)') didn't show")
            snap("tour-step-\(i + 1)")
            let cta = app.buttons.matching(NSPredicate(format: "label == %@", i == steps.count - 1 ? "Start styling" : "Next")).firstMatch
            XCTAssertTrue(cta.waitForExistence(timeout: 5), "Tour step \(i + 1) has no way on")
            cta.tap()
        }
        XCTAssertTrue(waitToDisappear(text(steps.last!), timeout: 5), "The tour didn't end")
        XCTAssertTrue(app.buttons["home.styleMe"].waitForExistence(timeout: 10), "The tour didn't end on Home")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == 'Next'")).firstMatch.exists, "A tour bubble is still up")
    }

    // MARK: - Privacy policy

    @MainActor
    func test05_PrivacyPolicyOpensInSafari() throws {
        launchToHome()
        openTab("Profile")
        let link = app.descendants(matching: .any).matching(identifier: "profile.privacyPolicy").firstMatch
        XCTAssertTrue(scrollUntilHittable(link, maxSwipes: 10), "No Privacy Policy link in Profile")
        link.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "The privacy policy didn't open in Safari")
        pause(2)
        snap("privacy-policy-safari")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Couldn't get back to StyleMate")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Coming back from Safari didn't return to Profile")
    }

    // MARK: - Retake selfie → Find yourself

    /// The new selfie goes straight on to Find yourself, which ends on an answer (faces to pick, or
    /// "couldn't spot you") and closes back to Profile; it never sits scanning for good.
    @MainActor
    func test06_RetakeSelfieGoesOnToFindYourself() throws {
        launchToHome(extra: ["-uiTestSelfieFixture"])
        openTab("Profile")
        let retake = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Retake selfie'")).firstMatch
        XCTAssertTrue(scrollUntilHittable(retake, maxSwipes: 10), "No 'Retake selfie' in Profile")
        retake.tap()
        let use = app.buttons.matching(NSPredicate(format: "label == 'Use these selfie photos' OR label == 'Use these photos'")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 120), "The retake never kept three frames of the fixture face")
        snap("retake-captured")
        use.tap()

        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Find yourself'")).waitForExistence(timeout: 20),
                      "A new selfie didn't go on to Find yourself")
        let face = app.buttons.matching(identifier: "findYourself.face").firstMatch
        let nothing = anyElement(NSPredicate(format: "label CONTAINS[c] %@", "couldn't spot you"))
        let empty = anyElement(NSPredicate(format: "label == 'No photos yet' OR label == 'No photos shared yet'"))
        let outcome = waitForAny([face, nothing, empty], timeout: 300)
        snap("retake-find-yourself")
        XCTAssertNotNil(outcome, "Find yourself was still scanning after 5 minutes")
        app.buttons.matching(NSPredicate(format: "label == 'Close'")).firstMatch.tap()
        XCTAssertTrue(retake.waitForExistence(timeout: 10), "Closing Find yourself didn't return to Profile")
    }

    // MARK: - Empty my wardrobe

    @MainActor
    func test07_EmptyMyWardrobeLeavesAnEmptyClosetThatStaysEmpty() throws {
        launchToHome()
        openTab("Profile")
        let empty = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Empty my wardrobe'")).firstMatch
        XCTAssertTrue(scrollUntilHittable(empty, maxSwipes: 12), "No 'Empty my wardrobe' in Profile")
        empty.tap()
        let alert = app.alerts["Are you sure you want to empty your wardrobe?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Emptying doesn't ask to confirm")
        alert.buttons["Empty"].tap()

        openTab("Wardrobe")
        XCTAssertTrue(text("Your wardrobe is empty").waitForExistence(timeout: 10), "The closet isn't empty")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Add clothes'")).firstMatch.exists, "The empty closet offers no way to add clothes")
        openTab("Home")
        XCTAssertTrue(app.buttons["home.trySamples"].waitForExistence(timeout: 10), "Home's empty closet doesn't offer the sample photos")
        XCTAssertFalse(app.buttons["home.todayLook.wear"].exists, "Home still offers a look from an empty closet")
        snap("home-empty-closet")

        relaunchKeepingData()
        openTab("Wardrobe")
        XCTAssertTrue(text("Your wardrobe is empty").waitForExistence(timeout: 10), "The emptied closet refilled after a relaunch")
    }

    // MARK: - Helpers
}
