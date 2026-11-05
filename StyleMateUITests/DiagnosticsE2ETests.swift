import XCTest

/// Profile → About → Diagnostics and Acknowledgements, with screenshots for review (`e2e-screens`).
/// The heavy benchmark is never started here: `-uiTestSeedDiagnostics` (DEBUG) fills the screen with sample
/// numbers instead, so the filled-in layout is what gets reviewed.
class DiagnosticsE2ETests: E2ETestCase {

    @MainActor
    private func launchSeeded() {
        app = makeApp()
        app.launchArguments += ["-uiTestSeedDiagnostics"]
        app.launch()
        dismissSpringboardAlertIfPresent()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60) || tabButton("Home").exists,
                      "The main tab UI never appeared")
    }

    @MainActor
    private func openProfileRow(id: String, label: String) {
        openTab("Profile")
        let row = anyElement(NSPredicate(format: "identifier == %@ OR label == %@", id, label))
        XCTAssertTrue(scrollUntilHittable(row, maxSwipes: 12), "No '\(label)' row in Profile")
        row.tap()
    }

    @MainActor
    func test01_Diagnostics() throws {
        launchSeeded()
        openProfileRow(id: "profile.diagnostics", label: "Diagnostics")

        let run = button(id: "diagnostics.benchmark", label: "Run")
        XCTAssertTrue(run.waitForExistence(timeout: 15), "Diagnostics screen didn't open")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'This phone'")).exists, "No phone card")
        _ = text("Last run", exact: false).waitForExistence(timeout: 5)
        snap("diagnostics-top")

        app.swipeUp()
        snap("diagnostics-middle")
        let share = button(id: "diagnostics.share", label: "Share report")
        XCTAssertTrue(scrollUntilHittable(share, maxSwipes: 6), "No Share report button")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Live stats'")).exists, "No live stats card")
        snap("diagnostics-bottom")

        // Copy (not Share: the share sheet is the system's) proves the report builds.
        let copy = button(id: "diagnostics.copy", label: "Copy report")
        if copy.exists, copy.isHittable {
            copy.tap()
            XCTAssertTrue(button(id: "diagnostics.copy", label: "Copied").waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func test02_Acknowledgements() throws {
        launchSeeded()
        openProfileRow(id: "profile.acknowledgements", label: "Acknowledgements")

        let siglip = anyElement(NSPredicate(format: "identifier BEGINSWITH 'acknowledgements.entry.ACK-10' OR label CONTAINS 'Marqo-FashionSigLIP'"))
        XCTAssertTrue(siglip.waitForExistence(timeout: 15), "Acknowledgements list is empty")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Stable Diffusion'")).exists)
        snap("acknowledgements-list")

        siglip.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Apache License'")).waitForExistence(timeout: 10),
                      "Licence text didn't open")
        snap("acknowledgements-siglip")

        app.navigationBars.buttons.firstMatch.tap()
        let sd = anyElement(NSPredicate(format: "label CONTAINS 'Stable Diffusion'"))
        XCTAssertTrue(sd.waitForExistence(timeout: 10))
        sd.tap()
        _ = anyElement(NSPredicate(format: "label CONTAINS 'Attachment A'")).waitForExistence(timeout: 5)
        snap("acknowledgements-stable-diffusion")
    }
}

/// The same screens in dark appearance (`-dark` screenshots).
final class DiagnosticsE2EDarkTests: DiagnosticsE2ETests {
    override class var usesDarkAppearance: Bool { true }
}
