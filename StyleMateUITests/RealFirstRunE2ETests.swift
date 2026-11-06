import XCTest

/// The first run exactly as a new user lives it, end to end, on a fresh install with nothing
/// pre-granted: Get Started → Sign in → selfie → the real photo-access prompt → "Find yourself"
/// (tap your own face) → the library scan → Home with the real location prompt and the weather.
///
/// It exists because TestFlight build 112 stuck on a real iPhone Duo at "8 of 3,935 photos" with no
/// items, an empty Diagnostics › Live stats and "Loading weather…" forever, while every other UI test
/// skipped the selfie, pre-granted photos + location (`simctl privacy grant`) and so never ran that path.
///
/// What makes it real in the simulator (CI's `Real first run` step in ci.yml):
/// - Nothing is pre-granted: the step resets the app's privacy settings and the test resets photos +
///   location again (`resetAuthorizationStatus`), then answers the SpringBoard prompts like a person.
/// - The selfie: the simulator has no camera, so `-uiTestSelfieFixture` (DEBUG, `DebugSelfieFeed`)
///   hands the real frame check a face framed from a bundled CC0 photo; the rest is the app's own path.
/// - The library: `scripts/ui_test_library.swift` builds ~260 photos: 8 variants of that same person
///   (crops, scales, flips, recompression), every other CC0 fixture as strangers and ~240 photos with
///   nobody in them, each with its own date, added with `simctl addmedia`.
/// - iCloud: simulator photos are always local, so `-uiTestStallSomePhotos` (DEBUG, `ScanFaultInjection`)
///   makes the library's `…_stallthumb…` / `…_stallfull…` photos behave like downloads stuck behind the
///   library's sync: their PhotoKit requests never call back. The scan must get past them on its own.
///   (Before 11ac3dc / 8e881a1 the thumbnail request had no time limit: this test sat at the first such
///   photo, the counter froze and the 3-minute rule below failed it, the founder's exact screen.)
class RealFirstRunE2ETests: E2ETestCase {

    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// The scan's counter may not stand still longer than this.
    private let maxStall: TimeInterval = 180
    /// Home must leave "Loading weather…" within this.
    private let weatherLimit: TimeInterval = 30

    // MARK: - 1. Everything allowed

    @MainActor
    func test01_RealFirstRunFindsYouAndFillsTheCloset() throws {
        launchFresh(extra: ["-uiTestSelfieFixture", "-uiTestStallSomePhotos"])
        getStartedAndSignIn()
        takeSelfie()

        // Photo access: the app's own screen, then the system prompt. Full Access.
        let allowPhotos = button(id: "onboarding.allowPhotos", label: "Allow photo access")
        XCTAssertTrue(allowPhotos.waitForExistence(timeout: 30), "No photo-access step after the selfie")
        snap("photos-ask")
        allowPhotos.tap()
        answerPhotosPrompt(allow: true)

        findYourself()
        watchOnboardingScan()
        watchHome()
        checkCloset()
        checkDiagnostics()
    }

    // MARK: - 2. Photos and location denied

    /// Both prompts answered "Don't Allow": the app still reaches Home, and the weather row says why
    /// instead of loading forever. The location prompt comes right as the photo prompt goes away
    /// (onboarding ends at once without photo access), the moment a dropped prompt is likeliest.
    @MainActor
    func test02_PhotosAndLocationDeniedStillReachHome() throws {
        launchFresh(extra: ["-uiTestSelfieFixture"])
        getStartedAndSignIn()
        takeSelfie()

        let allowPhotos = button(id: "onboarding.allowPhotos", label: "Allow photo access")
        XCTAssertTrue(allowPhotos.waitForExistence(timeout: 30), "No photo-access step after the selfie")
        allowPhotos.tap()
        answerPhotosPrompt(allow: false)

        let goOn = app.buttons.matching(NSPredicate(format: "label == 'Continue without scanning'")).firstMatch
        XCTAssertTrue(goOn.waitForExistence(timeout: 20), "No way on after denying photo access")
        snap("photos-denied")
        goOn.tap()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30), "Never reached Home with photo access denied")
        let homeAt = Date()
        var answered = false
        var loadingSince: Date?
        var settled = false
        while Date().timeIntervalSince(homeAt) < 60, !settled {
            if !answered, let alert = locationAlert() {
                snap("location-prompt")
                XCTAssertNotNil(answer(alert, with: ["Don’t Allow", "Don't Allow"]), "Couldn't deny location: \(alert.debugDescription)")
                answered = true
            }
            checkWeatherNeverSpins(&loadingSince)
            if answered, weatherSettled() { settled = true }
            pause(1)
        }
        XCTAssertTrue(answered, "Home never asked for the location")
        XCTAssertTrue(settled, "With location denied the weather row shows neither 'Location required' nor Retry (\(weatherRowText()))")
        XCTAssertFalse(weatherLoading().exists, "Still 'Loading weather…' with location denied")
        snap("home-location-denied")
    }

    // MARK: - Launch

    @MainActor
    private func launchFresh(extra: [String]) {
        let app = XCUIApplication()
        // A fresh install: no answer to any prompt yet (CI also resets the app's privacy settings).
        app.resetAuthorizationStatus(for: .photos)
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-uiTestResetState", "-uiTestFakeAppleSignIn",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        self.app = app
        app.launch()
    }

    @MainActor
    private func getStartedAndSignIn() {
        let getStarted = button(id: "onboarding.getStarted", label: "Get Started")
        XCTAssertTrue(getStarted.waitForExistence(timeout: 30), "No Get Started on the welcome screen")
        pause(1.5)
        snap("welcome")
        getStarted.tap()
        let fake = app.buttons["signIn.debugFake"]
        XCTAssertTrue(fake.waitForExistence(timeout: 15), "The sign-in screen didn't appear")
        snap("sign-in")
        fake.tap()
    }

    /// The selfie step takes its three frames from the fixture; confirm them like a person would.
    @MainActor
    private func takeSelfie() {
        let use = app.buttons.matching(NSPredicate(format: "label == 'Use these selfie photos' OR label == 'Use these photos'")).firstMatch
        let snapped = waitForAny([use], timeout: 120) != nil
        if !snapped { note("selfie-screen", visibleTexts()) }
        XCTAssertTrue(snapped, "The selfie step never kept three frames of the fixture face (see selfie-screen.txt)")
        pause(0.8)
        snap("selfie-captured")
        use.tap()
    }

    // MARK: - System prompts

    /// The photo-access prompt (and iOS's follow-up confirmation, when it shows one).
    @MainActor
    private func answerPhotosPrompt(allow: Bool) {
        let buttons = allow ? ["Allow Full Access", "Allow Access to All Photos", "Allow"] : ["Don’t Allow", "Don't Allow"]
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "The system photo-access prompt never appeared")
        snap("photos-prompt")
        XCTAssertNotNil(answer(alert, with: buttons), "The photo prompt has none of \(buttons): \(alert.debugDescription)")
        // iOS can ask a second time to confirm full access.
        if allow, alert.waitForExistence(timeout: 3), alertMentions(alert, "photo") {
            snap("photos-confirm")
            answer(alert, with: buttons)
        }
    }

    /// The location prompt, if SpringBoard is showing it.
    @MainActor
    private func locationAlert() -> XCUIElement? {
        let alert = springboard.alerts.firstMatch
        guard alert.exists, alertMentions(alert, "location") else { return nil }
        return alert
    }

    /// From a snapshot: the alert can go away mid-query, and reading a gone element fails the test.
    @MainActor
    private func alertMentions(_ alert: XCUIElement, _ word: String) -> Bool {
        guard let snapshot = try? alert.snapshot() else { return false }
        return Self.labels(in: snapshot, types: nil).contains { $0.localizedCaseInsensitiveContains(word) }
    }

    /// Taps the first of `labels` on `alert`; returns the one tapped.
    @MainActor
    @discardableResult
    private func answer(_ alert: XCUIElement, with labels: [String]) -> String? {
        for label in labels {
            let b = alert.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
            if b.exists { b.tap(); return label }
        }
        return nil
    }

    // MARK: - Find yourself

    /// Waits for "Is this you?", then picks the user's own face(s) by tapping them and confirms.
    @MainActor
    private func findYourself() {
        let scanning = anyElement(NSPredicate(format: "identifier == 'findYourself.scanning'"))
        if scanning.waitForExistence(timeout: 30) { snap("find-yourself-scanning") }

        let face = app.buttons.matching(identifier: "findYourself.face").firstMatch
        let nothing = anyElement(NSPredicate(format: "label CONTAINS[c] %@", "couldn't spot you"))
        let empty = anyElement(NSPredicate(format: "label == 'No photos yet' OR label == 'No photos shared yet'"))
        let off = anyElement(NSPredicate(format: "label == 'Photo access is off'"))
        let found = waitForAny([face, nothing, empty, off], timeout: 420)
        if found != 0 { note("find-yourself-screen", visibleTexts()); snap("find-yourself-no-offer") }
        XCTAssertEqual(found, 0, "Find yourself offered no faces (0 = offer, 1 = couldn't spot you, 2 = no photos, 3 = no access, nil = still scanning)")
        pause(1)
        snap("find-yourself-is-this-you")

        // The confident faces come pre-ticked: clear them and tap the user's faces back in.
        let cells = app.buttons.matching(identifier: "findYourself.face").allElementsBoundByIndex
        let preselected = cells.indices.filter { cells[$0].label.contains("selected") && !cells[$0].label.contains("not selected") }
        note("find-yourself-faces", cells.map(\.label).joined(separator: "\n"))
        XCTAssertFalse(preselected.isEmpty, "None of the offered faces matched the selfie well enough to be pre-ticked")
        let selectAll = app.buttons["findYourself.selectAll"]
        if selectAll.exists, selectAll.label == "Select all" { selectAll.tap() }   // some unticked: tick all first…
        if selectAll.exists, selectAll.label == "Clear all" { selectAll.tap() }    // …then none
        XCTAssertTrue(app.buttons["findYourself.confirm"].label.contains("Select the photos of you"),
                      "Clear all left faces ticked: '\(app.buttons["findYourself.confirm"].label)'")
        for i in preselected where cells[i].exists && cells[i].isHittable { cells[i].tap() }
        let confirm = app.buttons["findYourself.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.label.contains("Yes, that's me"), "Tapping the faces didn't select them: '\(confirm.label)'")
        snap("find-yourself-picked")
        confirm.tap()

        // "Also you?" (optional), then "Got it, that's you".
        let done = app.buttons["findYourself.done"]
        let skip = app.buttons.matching(NSPredicate(format: "identifier == 'findYourself.reject' AND label == 'Skip'")).firstMatch
        if waitForAny([done, skip], timeout: 60) == 1 {
            snap("find-yourself-also-you")
            skip.tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout: 60), "Find yourself never finished saving the faces")
        snap("find-yourself-done")
        done.tap()
    }

    // MARK: - The scan

    /// The onboarding scan screen until it hands over to Home (8 items, 90 s or the scan's end).
    @MainActor
    private func watchOnboardingScan() {
        let counter = anyElement(NSPredicate(format: "identifier == 'onboarding.scanCounter'"))
        XCTAssertTrue(counter.waitForExistence(timeout: 30), "The scan screen didn't appear after Find yourself")
        snap("scan-started")
        let openCloset = button(id: "onboarding.openCloset", label: "Open my closet")
        let tabs = app.tabBars.firstMatch
        var last = "", lastMove = Date()
        var snappedProgress = false
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !tabs.exists {
            if let label = try? counter.snapshot().label {
                if label != last { last = label; lastMove = Date() }
                if !snappedProgress, label.range(of: "in [1-9]", options: .regularExpression) != nil {
                    snap("scan-progress"); snappedProgress = true
                }
            }
            XCTAssertLessThan(Date().timeIntervalSince(lastMove), maxStall, "The scan screen's counter stuck at '\(last)'")
            if openCloset.exists, let f = try? openCloset.snapshot().frame, !f.isEmpty {
                snap("scan-ready")
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
            }
            pause(1)
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "The scan screen never handed over to Home")
        note("onboarding-scan-counter", last)
    }

    /// Home: answers the location prompt late (after the app's own 20 s limit, like the prompt the founder
    /// never saw), checks the weather never spins for good, and follows the scan banner to the end,
    /// failing if "N of M photos" stands still for 3 minutes.
    @MainActor
    private func watchHome() {
        let homeAt = Date()
        let progress = anyElement(NSPredicate(format: "identifier == 'scanBanner.progress'"))
        let itemsLine = anyElement(NSPredicate(format: "identifier == 'scanBanner.items'"))
        let completed = anyElement(NSPredicate(format: "identifier == 'scanBanner.completed'"))
        let completedEmpty = anyElement(NSPredicate(format: "identifier == 'scanBanner.completedEmpty'"))
        let paused = anyElement(NSPredicate(format: "label BEGINSWITH 'Scan paused. Double tap to retry'"))

        var lastProgress = "", lastMove = Date(), maxScanned = 0, total = 0
        var items = 0
        var scanDone = false, sawBanner = false
        var promptSeenAt: Date?, answeredAt: Date?
        var weatherChecked = false
        var loadingSince: Date?
        var snapped = Set<String>()
        func snapOnce(_ key: String) { if snapped.insert(key).inserted { snap(key) } }

        let deadline = homeAt.addingTimeInterval(16 * 60)
        while Date() < deadline, !(scanDone && weatherChecked) {
            let now = Date()

            // Location: leave the prompt up past the app's 20 s limit, check Home didn't hang, then allow.
            if answeredAt == nil {
                if let alert = locationAlert() {
                    if promptSeenAt == nil { promptSeenAt = now; snapOnce("home-location-prompt") }
                    if now.timeIntervalSince(promptSeenAt!) >= 25 {
                        XCTAssertFalse(weatherLoading().exists, "Still 'Loading weather…' 25 s into an unanswered location prompt")
                        snapOnce("home-weather-while-prompt-unanswered")
                        note("weather-while-prompt-unanswered", weatherRowText())
                        XCTAssertNotNil(answer(alert, with: ["Allow While Using App", "Allow Once", "Allow"]),
                                        "Couldn't allow location: \(alert.debugDescription)")
                        answeredAt = Date()
                    }
                } else if promptSeenAt != nil {
                    note("location-prompt", "The location prompt went away before the test answered it")
                    answeredAt = now
                } else if now.timeIntervalSince(homeAt) > 40 {
                    note("location-prompt", "Home never showed a location prompt")
                    answeredAt = now
                }
            }
            checkWeatherNeverSpins(&loadingSince)
            if !weatherChecked, let a = answeredAt, now.timeIntervalSince(a) >= weatherLimit {
                XCTAssertTrue(weatherSettled(), "\(Int(weatherLimit)) s after the location answer the weather row shows neither a temperature nor Retry (\(weatherRowText()))")
                snapOnce("home-weather")
                note("weather", weatherRowText())
                weatherChecked = true
            }

            // The scan banner: "1,204 of 5,310 photos · About 12 min left".
            if let label = try? progress.snapshot().label {
                sawBanner = true
                if label != lastProgress {
                    lastProgress = label
                    if let p = Self.parseProgress(label) {
                        if p.done > maxScanned { maxScanned = p.done; lastMove = now }
                        total = p.total
                    }
                }
                if maxScanned > 0 { snapOnce("home-scan-progress") }
            }
            if let label = try? itemsLine.snapshot().label, let n = Self.firstNumber(in: label) { items = max(items, n) }
            if let label = try? completed.snapshot().label {
                if let n = Self.firstNumber(in: label.replacingOccurrences(of: "Scan complete.", with: "")) { items = max(items, n) }
                snapOnce("home-scan-complete")
                scanDone = true
            }
            if completedEmpty.exists { snapOnce("home-scan-complete-empty"); scanDone = true }
            if paused.exists { snapOnce("home-scan-error"); XCTFail("The scan stopped with an error banner"); break }
            if app.buttons["scan.takeSelfie"].exists {
                snapOnce("home-scan-no-selfie"); XCTFail("The scan says there's no selfie, after the selfie step"); break
            }
            if !scanDone, sawBanner, !progress.exists, maxScanned > 0, maxScanned >= total, total > 0 {
                scanDone = true   // the completed banner came and went between two polls
            }

            if !scanDone, now.timeIntervalSince(lastMove) > maxStall {
                note("stuck-banner", "\(lastProgress)\n\(itemsLine.exists ? itemsLine.label : "")")
                snap("home-scan-stuck")
                openDiagnostics()
                note("stuck-diagnostics", visibleTexts())
                snap("home-scan-stuck-diagnostics")
                XCTFail("The scan stood still at '\(lastProgress)' for \(Int(maxStall)) s (see stuck-diagnostics.txt)")
                return
            }
            pause(2)
        }
        note("home-scan", "last banner: \(lastProgress)\nmax scanned: \(maxScanned) of \(total)\nitems: \(items)")
        XCTAssertTrue(weatherChecked, "Never got to check the weather row")
        XCTAssertTrue(scanDone, "The scan didn't finish within 16 min of Home (last: '\(lastProgress)', \(items) items)")
        XCTAssertGreaterThan(maxScanned, 0, "The banner never counted a photo")
        XCTAssertGreaterThan(items, 0, "The scan finished without adding anything from the user's photos")
    }

    /// The closet holds what the scan found.
    @MainActor
    private func checkCloset() {
        openTab("Wardrobe")
        pause(2)
        snap("closet")
        openTab("Home")
    }

    /// Diagnostics › Live stats measured real face checks; Photo scan shows each step's timings and that it
    /// gave up waiting on the stuck photos instead of sitting on them.
    @MainActor
    private func checkDiagnostics() {
        openDiagnostics()
        let live = anyElement(NSPredicate(format: "label CONTAINS 'Live stats'"))
        XCTAssertTrue(live.waitForExistence(timeout: 15), "No Live stats card")
        pause(2.5)   // the screen refreshes its numbers every 2 s
        let texts = visibleTexts()
        note("diagnostics", texts)
        XCTAssertFalse(anyElement(NSPredicate(format: "label BEGINSWITH 'Nothing measured yet'")).exists,
                       "Live stats still says 'Nothing measured yet' after a scan")
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Photos checked for your face'")).exists, "Live stats has no face checks")
        for step in ["Loading thumbnails: ", "Checking faces: ", "Finding clothes: "] {
            XCTAssertTrue(anyElement(NSPredicate(format: "label BEGINSWITH %@", step)).exists,
                          "Photo scan has no '\(step)' timings")
        }
        XCTAssertTrue(anyElement(NSPredicate(format: "label BEGINSWITH 'Gave up waiting'")).exists,
                      "Photo scan never gave up on a stuck photo: the stall hook didn't take effect (photo names lost on import?)")
        let scanCard = anyElement(NSPredicate(format: "label CONTAINS 'Photo scan'"))
        _ = scrollUntilHittable(scanCard, maxSwipes: 6)
        snap("diagnostics-photo-scan")
        app.swipeUp()
        snap("diagnostics-live-stats")
    }

    @MainActor
    private func openDiagnostics() {
        openTab("Profile")
        let row = anyElement(NSPredicate(format: "identifier == 'profile.diagnostics' OR label == 'Diagnostics'"))
        XCTAssertTrue(scrollUntilHittable(row, maxSwipes: 12), "No Diagnostics row in Profile")
        row.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'This phone'")).waitForExistence(timeout: 15),
                      "Diagnostics didn't open")
    }

    // MARK: - Weather row

    @MainActor
    private func weatherLoading() -> XCUIElement {
        anyElement(NSPredicate(format: "label BEGINSWITH 'Loading weather'"))
    }

    /// A temperature, Retry (with the reason) or "Location required".
    @MainActor
    private func weatherSettled() -> Bool {
        app.buttons["home.temperatureUnit"].exists
            || app.buttons.matching(NSPredicate(format: "label == 'Retry'")).firstMatch.exists
            || anyElement(NSPredicate(format: "label == 'Location required'")).exists
    }

    /// Fails when "Loading weather…" has been on screen without a break for longer than the limit.
    @MainActor
    private func checkWeatherNeverSpins(_ since: inout Date?) {
        if weatherLoading().exists {
            if since == nil { since = Date() }
            XCTAssertLessThan(Date().timeIntervalSince(since!), weatherLimit + 5, "'Loading weather…' for over \(Int(weatherLimit)) s")
        } else {
            since = nil
        }
    }

    @MainActor
    private func weatherRowText() -> String {
        let interesting = ["Loading weather", "Retry", "Location required", "location", "weather", "°", "degrees"]
        guard let snapshot = try? app.snapshot() else { return "(no snapshot)" }
        return Self.labels(in: snapshot, types: [.staticText, .button])
            .filter { label in interesting.contains { label.localizedCaseInsensitiveContains($0) } }
            .joined(separator: " | ")
    }

    // MARK: - Helpers

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    @MainActor
    private func visibleTexts() -> String {
        guard let snapshot = try? app.snapshot() else { return "(no snapshot)" }
        return Self.labels(in: snapshot, types: [.staticText, .button]).joined(separator: "\n")
    }

    /// Every non-empty label in the snapshot tree (of these element types; nil = any).
    @MainActor
    static func labels(in node: XCUIElementSnapshot, types: Set<XCUIElement.ElementType>?) -> [String] {
        var out: [String] = []
        if types?.contains(node.elementType) ?? true, !node.label.isEmpty { out.append(node.label) }
        for child in node.children { out += labels(in: child, types: types) }
        return out
    }

    /// "1,204 of 5,310 photos · About 12 min left" → (1204, 5310).
    static func parseProgress(_ label: String) -> (done: Int, total: Int)? {
        let parts = label.components(separatedBy: " of ")
        guard parts.count >= 2,
              let done = Int(parts[0].filter(\.isNumber)),
              let all = firstNumber(in: parts[1]) else { return nil }
        return (done: done, total: all)
    }

    /// The first run of digits (thousands separators allowed) in `text`.
    static func firstNumber(in text: String) -> Int? {
        guard let r = text.range(of: "[0-9][0-9,]*", options: .regularExpression) else { return nil }
        return Int(text[r].filter(\.isNumber))
    }
}
