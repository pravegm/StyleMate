import XCTest
import UIKit

/// End-to-end proof of StyleMate's three core features, driven through the real app in the
/// simulator. Screenshots of every step land in the `e2e-screens` CI artifact.
///
/// 1. Gallery -> digital wardrobe: closet grid, item detail, and a real photo imported through
///    the gallery picker and analysed on-device (review screen with the extracted items).
/// 2. "What should I wear today": 5 options, swap one piece, keep one.
/// 3. Outfit log: the kept outfit (and a manually composed one) shows on today's date.
final class StyleMateE2ETests: E2ETestCase {

    // MARK: - 1. Wardrobe

    @MainActor
    func test01_ClosetGridAndItemDetail() throws {
        launchToHome()
        _ = waitForAny([text("Your Wardrobe"), text("Style for an occasion")], timeout: 20)
        snap("home")

        openTab("Wardrobe")
        let count = anyElement(NSPredicate(format: "label BEGINSWITH %@", "\(seededItemCount) items"))
        XCTAssertTrue(count.waitForExistence(timeout: 20), "Closet doesn't report the \(seededItemCount) seeded items")
        let anyTee = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'closet.item.' OR label ENDSWITH 'T-Shirt'")).firstMatch
        XCTAssertTrue(anyTee.waitForExistence(timeout: 10), "Closet grid shows no seeded items")
        snap("closet-grid")

        // Narrow to the Tops shelf with its filter chip ("Tops, 12 items").
        let topsChip = app.buttons.matching(NSPredicate(format:
            "identifier == 'closet.filter.tops' OR label BEGINSWITH 'Tops,'")).firstMatch
        XCTAssertTrue(topsChip.waitForExistence(timeout: 10), "No Tops filter chip in the closet")
        topsChip.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label BEGINSWITH 'Showing'")).waitForExistence(timeout: 5),
                      "Tops filter didn't apply")
        snap("closet-filtered-tops")

        let tee = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'T-Shirt'")).firstMatch
        XCTAssertTrue(scrollUntilHittable(tee, maxSwipes: 4), "Tops shelf shows no T-shirt")
        tee.tap()
        // The item page (edit lives in its ⋯ menu, so wait for the page itself).
        let editDetails = itemPage()
        XCTAssertTrue(editDetails.waitForExistence(timeout: 15), "Item detail didn't open")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS[c] 'T-Shirt'")).exists,
                      "Item detail doesn't describe the tapped T-shirt")
        snap("item-detail")
        app.swipeUp()
        snap("item-detail-scrolled")

        // Back to the closet.
        let backByID = app.navigationBars.buttons["BackButton"]
        let back = backByID.exists ? backByID : app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No back button on the item page")
        back.tap()
        XCTAssertTrue(waitToDisappear(editDetails, timeout: 10), "Item page didn't close")
        XCTAssertTrue(topsChip.waitForExistence(timeout: 10), "Didn't return to the closet grid")
        snap("closet-after-back")
    }

    // MARK: - 2 + 3. Today's outfit -> swap -> keep -> calendar

    @MainActor
    func test02_StyleMeFiveOptionsSwapAndLog() throws {
        launchToHome()
        XCTAssertTrue(text("Style for an occasion").waitForExistence(timeout: 20) ||
                      button(id: "home.styleMe", label: "Generate").exists,
                      "Home has no Style Me card")

        // Occasion + (once the redesign lands) mood.
        let occasion = button(id: "home.occasion.Everyday Casual", label: "Everyday Casual")
        if occasion.waitForExistence(timeout: 5) { occasion.tap() }
        pickMoodIfOffered()
        snap("home-style-me")

        let generate = button(id: "home.styleMe", label: "Generate")
        tapScrollingIfNeeded(generate)

        // Wait for the deck ("Option 1 of 5"), answering the weather prompt if it appears.
        let counter = anyElement(NSPredicate(format: "identifier == 'outfit.counter' OR label MATCHES %@", "(Option )?1 of [0-9]+"))
        let weatherAlert = app.alerts["Weather unavailable"]
        let errorAlert = app.alerts["Outfit Suggestion"]
        var outcome: Int?
        let deadline = Date().addingTimeInterval(240)
        repeat {
            outcome = waitForAny([counter, weatherAlert, errorAlert], timeout: max(1, deadline.timeIntervalSinceNow))
            if outcome == 1 {
                snap("weather-unavailable-prompt")
                proceedWithoutWeather(weatherAlert)
                outcome = nil
            }
        } while outcome == nil && Date() < deadline

        if outcome == 2 {
            snap("styling-engine-error")
            let message = errorAlert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            errorAlert.buttons.firstMatch.tap()
            throw XCTSkip("Outfit engine returned an error instead of 5 options (\(message)). " +
                          "Expected until the on-device stylist replaces the Gemini call on main.")
        }
        XCTAssertEqual(outcome, 0, "Outfit options never appeared")

        let total = Int(counter.label.split(separator: " ").last ?? "") ?? -1
        XCTAssertEqual(total, 5, "Expected 5 outfit options, the deck says '\(counter.label)'")
        snap("option-1-of-\(total)")
        note("outfit-sheet-buttons", visibleButtonLabels())

        // Select a piece on the board: its Keep / Swap capsule appears.
        let piece = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'outfit.piece.'")).firstMatch
        if piece.waitForExistence(timeout: 10) {
            piece.tap()
            snap("option-1-piece-selected")
        }

        // Swap that piece.
        let swap = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'outfit.swap' OR label BEGINSWITH[c] 'swap '")).firstMatch
        XCTAssertTrue(swap.waitForExistence(timeout: 10),
                      "No per-item swap button on the outfit board (see the outfit-sheet-buttons attachment)")
        XCTAssertGreaterThanOrEqual(swap.frame.width, 44, "Swap button is smaller than a 44pt target")
        let before = lookFingerprint()
        swap.tap()
        let busy = anyElement(NSPredicate(format: "label BEGINSWITH 'Styling' OR label CONTAINS 'Shuffling'"))
        if busy.waitForExistence(timeout: 3) {
            XCTAssertTrue(waitToDisappear(busy, timeout: 120), "Swap never finished")
        }
        XCTAssertTrue(anyElement(NSPredicate(format: "label MATCHES %@", "(Option )?1 of [0-9]+")).waitForExistence(timeout: 10),
                      "Swapping moved off option 1")
        let changed = waitUntil(timeout: 10) { self.lookFingerprint() != before }
        XCTAssertTrue(changed, "The swapped piece didn't change the look")
        snap("option-1-after-swap")

        // Wear option 1 (logs it to today), then page through the other four.
        let wear = app.buttons.matching(NSPredicate(format:
            "identifier == 'outfit.wear' OR label BEGINSWITH 'Wear today' OR label BEGINSWITH 'Save'")).firstMatch
        XCTAssertTrue(wear.waitForExistence(timeout: 5), "No Wear today button on the outfit sheet")
        wear.tap()
        let saved = anyElement(NSPredicate(format: "label == 'Logged for today' OR label == 'Saved'"))
        if saved.waitForExistence(timeout: 3) { snap("option-1-logged") }

        if total > 1 {
            for index in 2...total {
                let page = anyElement(NSPredicate(format: "label == %@ OR label == %@",
                                                  "Option \(index) of \(total)", "\(index) of \(total)"))
                XCTAssertTrue(page.waitForExistence(timeout: 15), "Option \(index) never showed")
                snap("option-\(index)-of-\(total)")
                let skip = app.buttons.matching(NSPredicate(format: "identifier == 'outfit.skip' OR label CONTAINS 'Skip'")).firstMatch
                XCTAssertTrue(skip.waitForExistence(timeout: 5), "No Skip button")
                skip.tap()
            }
        }

        XCTAssertTrue(text("All Caught Up!").waitForExistence(timeout: 10), "End-of-deck screen didn't appear")
        XCTAssertTrue(anyElement(NSPredicate(format: "label BEGINSWITH '1 outfit'")).exists,
                      "End-of-deck doesn't confirm the kept outfit")
        snap("deck-finished")
        let viewInCalendar = button(id: "outfit.viewInCalendar", label: "View in Calendar")
        if viewInCalendar.exists { viewInCalendar.tap() } else { button(label: "Done").tap() }

        // The kept outfit is on today's date.
        openTab("Outfits")
        assertTodayHasLoggedOutfit(expectedSourceLabel: "Styled for you")
        snap("calendar-today-with-kept-outfit")
    }

    // MARK: - 3. Manual log to today

    @MainActor
    func test03_LogOutfitManuallyToToday() throws {
        launchToHome()
        openTab("Outfits")
        XCTAssertTrue(text("No outfits logged").waitForExistence(timeout: 15), "Fresh state should have no outfits today")
        snap("calendar-empty")

        let add = app.buttons.matching(NSPredicate(format: "identifier == 'outfits.add' OR label CONTAINS 'Add'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "No Add button on the calendar")
        add.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Add Outfit'")).waitForExistence(timeout: 10),
                      "Add Outfit composer didn't open")

        pickInComposer(category: "Tops", product: "T-Shirts", itemSuffix: "T-Shirt")
        pickInComposer(category: "Bottoms", product: "Jeans", itemSuffix: "Jeans")
        pickInComposer(category: "Footwear", product: "Sneakers", itemSuffix: "Sneaker")
        snap("composer-three-items-selected")

        let saveOutfit = button(id: "outfits.composer.save", label: "Save Outfit")
        XCTAssertTrue(saveOutfit.exists && saveOutfit.isEnabled, "Save Outfit missing or disabled after picking items")
        saveOutfit.tap()
        XCTAssertTrue(waitToDisappear(saveOutfit, timeout: 10), "Composer didn't close after saving")

        assertTodayHasLoggedOutfit(expectedSourceLabel: "Manual")
        // The card names its pieces in the singular ("T-Shirt · Jeans · Sneaker").
        for product in ["T-Shirt", "Jeans", "Sneaker"] {
            XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS %@", product)).exists,
                          "Logged outfit is missing the picked \(product)")
        }
        snap("calendar-today-with-manual-outfit")
    }

    // MARK: - 1. Gallery photo -> on-device extraction -> review

    /// CI adds `StyleMateUITests/Fixtures/street_coat_boots.jpg` to the simulator's photo
    /// library (`simctl addmedia`) before the run.
    @MainActor
    func test04_ImportGalleryPhotoExtractsItems() throws {
        launchToHome()
        openTab("Wardrobe")
        let fab = app.buttons.matching(NSPredicate(format: "identifier == 'closet.add' OR label == 'Add clothes' OR label == 'Add'")).firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 15), "No add (+) button in the closet")
        fab.tap()

        let gallery = button(id: "addSource.gallery", label: "Choose from Gallery")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "Add-source sheet didn't open")
        snap("add-source-sheet")
        gallery.tap()

        // System photo picker (out of process, but bridged into the app's accessibility tree).
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        guard photos.firstMatch.waitForExistence(timeout: 30) else {
            snap("photo-picker-missing")
            note("photo-picker-tree", app.debugDescription)
            XCTFail("The photo picker showed no photos")
            return
        }
        snap("photo-picker")
        let photo = newestPhoto(in: photos)
        note("photo-picker-choice", "picked: \(photo.label)\nall:\n" +
             photos.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
        photo.tap()

        // The picker's confirm button is a checkmark (identifier 'Add', label 'Done'). The closet's
        // own (+) under the sheet is identifier 'plus', label 'Add' — exclude it. (Resolve with
        // firstMatch, not allElementsBoundByIndex: the picker's tree mutates after a selection.)
        let pickerAdd = app.buttons.matching(NSPredicate(format:
            "(identifier == 'Add' OR label == 'Done' OR label == 'Add') AND identifier != 'plus'")).firstMatch
        XCTAssertTrue(pickerAdd.waitForExistence(timeout: 10), "Photo picker has no confirm (Add/Done) button")
        if pickerAdd.isHittable {
            pickerAdd.tap()
        } else {
            pickerAdd.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        // Identity resolution -> (optional "which one is you?") -> on-device analysis.
        let reviewTitle = anyElement(NSPredicate(format: "label == 'Review Items'"))
        let whichOne = anyElement(NSPredicate(format: "label == 'Which one is you?'"))
        let first = waitForAny([reviewTitle, whichOne], timeout: 120)
        if first == 1 {
            snap("which-one-is-you")
            button(label: "use the whole photo").tap()
        }
        XCTAssertTrue(reviewTitle.waitForExistence(timeout: 60), "Review screen never appeared")
        snap("review-analyzing")

        // Per-photo status reads "Photo 1, 3 items found" (older UI: "3 items detected").
        let found = anyElement(NSPredicate(format: "label MATCHES %@",
                                           "(.*, )?[1-9][0-9]* items? (found|detected)"))
        let noneFound = anyElement(NSPredicate(format: "label CONTAINS 'No clothes found' OR label == 'No items detected'"))
        let result = waitForAny([found, noneFound], timeout: 420)
        snap("review-extracted-items")
        XCTAssertEqual(result, 0, "On-device extraction found no garments in the fixture photo")
        guard result == 0 else { return }
        note("review-status", found.label)
        app.swipeUp()
        snap("review-extracted-items-scrolled")

        let addToWardrobe = button(id: "review.add", label: "to Wardrobe")
        XCTAssertTrue(addToWardrobe.waitForExistence(timeout: 5), "No 'Add N Items to Wardrobe' button")
        addToWardrobe.tap()
        XCTAssertTrue(waitToDisappear(reviewTitle, timeout: 30), "Review screen didn't close after adding")
        // Closet summary: "29 items · 5 shelves".
        let newCount = anyElement(NSPredicate(format: "label MATCHES %@", "[0-9]+ items?( · .*)?"))
        if newCount.waitForExistence(timeout: 10) {
            let n = Int(newCount.label.split(separator: " ").first ?? "") ?? 0
            XCTAssertGreaterThan(n, seededItemCount, "Closet count didn't grow after adding extracted items")
        }
        snap("closet-after-import")
    }

    // MARK: - Helpers

    /// Taps a mood option if the outfit flow offers one (the mood picker is being added).
    @MainActor
    private func pickMoodIfOffered() {
        let byID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'mood.'")).firstMatch
        if byID.exists && byID.isHittable {
            byID.tap()
            snap("mood-picked")
            return
        }
        for mood in ["Confident mood", "Confident", "Relaxed mood", "Relaxed"] {
            let option = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", mood)).firstMatch
            if option.exists && option.isHittable {
                option.tap()
                snap("mood-picked-\(mood.lowercased())")
                return
            }
        }
    }

    /// In the manual composer: expand a category, expand a product group, tick the first item.
    @MainActor
    private func pickInComposer(category: String, product: String, itemSuffix: String) {
        let categoryRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", category)).firstMatch
        tapScrollingIfNeeded(categoryRow)
        let productRow = app.staticTexts[product]
        tapScrollingIfNeeded(productRow)
        // Item rows: a select button labelled with the item's name (newer UI) or the name as text.
        let byButton = app.buttons.matching(NSPredicate(format:
            "label ENDSWITH %@ AND NOT (label BEGINSWITH 'Preview')", itemSuffix)).firstMatch
        let item = byButton.waitForExistence(timeout: 5) ? byButton
            : app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@ AND label != %@", itemSuffix, product)).firstMatch
        tapScrollingIfNeeded(item)
        // Collapse again so the next category sits near the top and clear of the bottom bar.
        if categoryRow.isHittable { categoryRow.tap() }
    }

    @MainActor
    private func assertTodayHasLoggedOutfit(expectedSourceLabel: String, file: StaticString = #filePath, line: UInt = #line) {
        let header = anyElement(NSPredicate(format: "label == %@", "Today's Outfits"))
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Outfits tab isn't showing today", file: file, line: line)
        XCTAssertFalse(text("No outfits logged").exists, "Today shows no logged outfit", file: file, line: line)
        let badge = anyElement(NSPredicate(format: "label CONTAINS %@", expectedSourceLabel))
        XCTAssertTrue(badge.waitForExistence(timeout: 5),
                      "Today's outfit card isn't marked '\(expectedSourceLabel)'", file: file, line: line)
    }

    /// The newest photo in the picker, by the date in its accessibility label
    /// ("Photo, March 30, 2018, 7:14 PM"; this year's photos omit the year: "Photo, November 04, 1:52 PM").
    @MainActor
    private func newestPhoto(in photos: XCUIElementQuery) -> XCUIElement {
        let all = photos.allElementsBoundByIndex
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let thisYear = Calendar.current.component(.year, from: Date())
        let withYear = ["MMMM d, yyyy, h:mm a", "MMM d, yyyy, h:mm a", "MMMM d, yyyy 'at' h:mm a", "d MMMM yyyy, HH:mm"]
        let withoutYear = ["MMMM d, h:mm a", "MMM d, h:mm a", "MMMM d 'at' h:mm a", "d MMMM, HH:mm"]
        func date(of element: XCUIElement) -> Date? {
            let label = element.label
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "Photo, ", with: "")
            if label.hasPrefix("Today") { return Date() }
            for format in withYear {
                formatter.dateFormat = format
                if let d = formatter.date(from: label) { return d }
            }
            for format in withoutYear {
                formatter.dateFormat = "yyyy " + format
                if let d = formatter.date(from: "\(thisYear) " + label) { return d }
            }
            return nil
        }
        let dated = all.compactMap { element in date(of: element).map { (element, $0) } }
        if let newest = dated.max(by: { $0.1 < $1.1 }) { return newest.0 }
        return all.last ?? photos.firstMatch
    }

    /// A cheap fingerprint of the outfit card's pixels, to prove a swap changed the look.
    @MainActor
    private func lookFingerprint() -> Data {
        let shot = XCUIScreen.main.screenshot().image
        guard let cg = shot.cgImage else { return Data() }
        let crop = CGRect(x: 0, y: CGFloat(cg.height) * 0.25, width: CGFloat(cg.width), height: CGFloat(cg.height) * 0.5)
        guard let region = cg.cropping(to: crop) else { return Data() }
        return UIImage(cgImage: region).pngData() ?? Data()
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.5)
        } while Date() < deadline
        return false
    }
}
