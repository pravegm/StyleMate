import XCTest

/// iPhone landscape (D7). The app keeps landscape on: Info.plist can't tell the iPhone Duo (whose inner
/// display is used sideways) from other iPhones. In landscape a 17 Pro is 874 pt wide, so the Duo's wide
/// layouts (`FoldAwareSplit`) run at 402 pt high. This walks the four tabs sideways and checks the tab bar
/// stays reachable; the screenshots (`e2e-screens`) are for review.
final class LandscapeE2ETests: E2ETestCase {

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
        try super.tearDownWithError()
    }

    @MainActor
    func test01_TabsInLandscape() throws {
        launchToHome()
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "rotate")], timeout: 1.5)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app didn't rotate to landscape")

        for tab in ["Home", "Wardrobe", "Outfits", "Profile"] {
            openTab(tab)
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)
            snap("landscape-\(tab.lowercased())")
            XCTAssertTrue(tabButton("Home").isHittable, "Tab bar not reachable in landscape on \(tab)")
        }
    }
}
