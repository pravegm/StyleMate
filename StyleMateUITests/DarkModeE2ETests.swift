import XCTest

/// The same end-to-end flows in dark appearance (`XCUIDevice.shared.appearance = .dark`).
/// Screenshots land in the same `e2e-screens` artifact with a `-dark` suffix.

final class StyleMateE2EDarkTests: StyleMateE2ETests {
    override class var usesDarkAppearance: Bool { true }

    /// The import flow's on-device extraction takes minutes; in dark mode only the add
    /// sheet (its first screen) is checked.
    @MainActor
    override func test04_ImportGalleryPhotoExtractsItems() throws {
        launchToHome()
        openTab("Wardrobe")
        let add = app.buttons.matching(NSPredicate(format:
            "identifier == 'closet.add' OR label == 'Add clothes'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "No add (+) button in the closet")
        add.tap()
        let gallery = button(id: "addSource.gallery", label: "Choose from Gallery")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "Add-source sheet didn't open")
        snap("add-source-sheet")
    }
}

final class FirstRunE2EDarkTests: FirstRunE2ETests {
    override class var usesDarkAppearance: Bool { true }
}
