import XCTest

/// The everyday flows a signed-in user goes through after onboarding, each acted out like a person
/// and checked for its outcome, not just screenshotted: the closet (search, colour filter, sort,
/// "No matches"), an item's edit and removal (still gone after a relaunch), the outfit deck (Keep,
/// Shuffle the rest, Swap, Skip with "Not my style", Add a piece, Log another day, Wear today → the
/// calendar, after a relaunch too), Home's "Wear today" and deleting a logged look, the manual
/// composer's edit, Home's habit cards ("We weren't sure…", "Wore this yesterday?"), "Is this you?"
/// confirmed into real extraction then "Review last scan results", and "Take a Photo" on a phone
/// without a camera. Screenshots go to `e2e-screens`.
final class UserFlowsE2ETests: E2ETestCase {

    private let piecePrefix = "outfit.piece."

    // MARK: - Closet: search, colour, sort

    @MainActor
    func test01_ClosetSearchColourFilterAndSort() throws {
        launchToHome()
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), seededItemCount, "The closet doesn't hold the seeded pieces")

        // Search narrows to the two pairs of jeans, and only them.
        let search = searchField()
        search.tap()
        search.typeText("jeans")
        XCTAssertTrue(anyElement(NSPredicate(format: "label == %@", "Showing 2 of \(seededItemCount)")).waitForExistence(timeout: 10),
                      "Searching 'jeans' doesn't say 'Showing 2 of \(seededItemCount)'")
        let found = closetTiles().allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(found.count, 2, "Search shows \(found)")
        XCTAssertTrue(found.allSatisfy { $0.hasSuffix("Jeans") }, "Search for jeans shows other pieces: \(found)")
        snap("closet-search-jeans")

        // Nothing matches: the empty state says so and clears the search.
        replaceText(in: search, with: "xyzzy", submit: false)
        // The simulator now and then drops keystrokes (CI once left "jea"): type it again if so.
        if (search.value as? String) != "xyzzy" { replaceText(in: search, with: "xyzzy", submit: false) }
        let noMatches = text("No matches")
        XCTAssertTrue(noMatches.waitForExistence(timeout: 10), "No 'No matches' for a search that finds nothing")
        snap("closet-no-matches")
        app.buttons.matching(NSPredicate(format: "label == 'Clear filters'")).firstMatch.tap()
        XCTAssertTrue(waitToDisappear(noMatches, timeout: 10), "'Clear filters' didn't clear the search")
        XCTAssertFalse(anyElement(NSPredicate(format: "label BEGINSWITH 'Showing'")).exists, "A filter is still on after 'Clear filters'")
        if app.keyboards.firstMatch.exists { app.typeText("\n") }   // put the keyboard away (the search stays, empty)

        // A colour swatch: the burgundy sweater is the only burgundy piece. The swatches scroll sideways.
        let sortMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort, currently'")).firstMatch
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "No sort menu")
        let burgundy = app.buttons.matching(NSPredicate(format: "label == 'Burgundy' AND NOT (identifier BEGINSWITH 'closet.item.')")).firstMatch
        XCTAssertTrue(burgundy.waitForExistence(timeout: 10), "No Burgundy swatch in the closet's filter bar")
        let rowY = sortMenu.frame.midY
        // Off-screen swatches have no hit point (isHittable throws): go by the frame.
        func onScreen(_ e: XCUIElement) -> Bool { e.frame.minX >= 0 && e.frame.maxX <= app.frame.maxX - 4 }
        for _ in 0..<6 where !onScreen(burgundy) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.8, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.width * 0.2, dy: rowY)))
        }
        burgundy.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == %@", "Showing 1 of \(seededItemCount)")).waitForExistence(timeout: 10),
                      "The Burgundy swatch doesn't narrow to one piece")
        XCTAssertTrue(closetTile(containing: "Burgundy").exists, "The burgundy sweater isn't shown under Burgundy")
        snap("closet-burgundy")
        let clearAll = app.buttons.matching(NSPredicate(format: "label == 'Clear all'")).firstMatch
        XCTAssertTrue(clearAll.exists, "No 'Clear all' next to 'Showing 1 of …'")
        clearAll.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.anyElement(NSPredicate(format: "label BEGINSWITH 'Showing'")).exists },
                      "The colour filter didn't clear")

        // Sort: Oldest puts a different piece first than Newest.
        for _ in 0..<6 where !onScreen(sortMenu) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.2, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.width * 0.8, dy: rowY)))
        }
        let firstNewest = closetTiles().firstMatch.label
        XCTAssertEqual(sortMenu.label, "Sort, currently Newest")
        sortMenu.tap()
        let oldest = app.buttons.matching(NSPredicate(format: "label == 'Oldest'")).firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "The sort menu has no Oldest")
        oldest.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { sortMenu.label == "Sort, currently Oldest" }, "Sort didn't switch to Oldest: \(sortMenu.label)")
        XCTAssertTrue(waitUntil(timeout: 5) { self.closetTiles().firstMatch.label != firstNewest },
                      "Oldest first shows the same first piece as Newest first (\(firstNewest))")
        snap("closet-sorted-oldest")
    }

    // MARK: - Item page: edit, then remove

    @MainActor
    func test02_EditedDetailsSurviveARelaunch() throws {
        launchToHome()
        openTab("Wardrobe")
        let coat = closetTile(containing: "Coat")
        XCTAssertTrue(scrollUntilHittable(coat, maxSwipes: 6), "No coat in the closet")
        coat.tap()
        XCTAssertTrue(itemPage().waitForExistence(timeout: 15), "The coat's page didn't open")

        app.buttons["itemDetail.more"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier == 'itemDetail.edit' OR label == 'Edit details'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The item menu has no Edit details")
        edit.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Edit piece'")).waitForExistence(timeout: 10), "The editor didn't open")
        let brand = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Brand' OR label BEGINSWITH 'Brand'")).firstMatch
        for _ in 0..<5 where !(brand.exists && brand.isHittable) { app.swipeUp() }
        XCTAssertTrue(brand.exists && brand.isHittable, "No Brand field in the editor")
        brand.tap()
        brand.typeText("Acme")
        snap("edit-brand")
        app.buttons.matching(NSPredicate(format: "label == 'Save'")).firstMatch.tap()
        XCTAssertTrue(waitToDisappear(anyElement(NSPredicate(format: "label == 'Edit piece'")), timeout: 10), "The editor didn't close on Save")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Acme'")).waitForExistence(timeout: 5),
                      "The item page doesn't show the new brand")
        snap("item-page-edited")

        relaunchKeepingData()
        openTab("Wardrobe")
        let edited = closetTile(containing: "Acme")
        XCTAssertTrue(scrollUntilHittable(edited, maxSwipes: 6), "The edited brand was lost on relaunch")
        snap("closet-after-relaunch-edited")
    }

    @MainActor
    func test03_RemovedPiecesStayRemovedAfterARelaunch() throws {
        launchToHome()
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), seededItemCount)

        // One from its page.
        let skirt = closetTile(containing: "Skirt")
        XCTAssertTrue(scrollUntilHittable(skirt, maxSwipes: 8), "No skirt in the closet")
        skirt.tap()
        let page = itemPage()
        XCTAssertTrue(page.waitForExistence(timeout: 15), "The skirt's page didn't open")
        let remove = app.buttons["itemDetail.remove"]
        for _ in 0..<5 where !(remove.exists && remove.isHittable) { app.swipeUp() }
        XCTAssertTrue(remove.exists && remove.isHittable, "No 'Remove from wardrobe' on the item page")
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Remove from Wardrobe' AND identifier != 'itemDetail.remove'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Removing doesn't ask to confirm")
        snap("remove-confirm")
        confirm.tap()
        XCTAssertTrue(waitToDisappear(page, timeout: 10), "The item page stayed open after removing the piece")
        XCTAssertTrue(waitUntil(timeout: 10) { self.closetPieceCount() == self.seededItemCount - 1 },
                      "The closet count didn't drop to \(seededItemCount - 1)")

        // Two at once with Select.
        app.buttons["closet.select"].tap()
        for name in ["Cap", "Tote Bag"] {
            let tile = closetTile(containing: name)
            XCTAssertTrue(scrollUntilHittable(tile, maxSwipes: 10), "No \(name) to select")
            tile.tap()
        }
        XCTAssertTrue(text("2 selected").waitForExistence(timeout: 5), "Selecting two pieces doesn't say '2 selected'")
        app.buttons.matching(NSPredicate(format: "label == 'Remove'")).firstMatch.tap()
        let bulk = app.buttons.matching(NSPredicate(format: "label == 'Remove 2 items'")).firstMatch
        XCTAssertTrue(bulk.waitForExistence(timeout: 5), "Bulk removal doesn't ask to confirm")
        bulk.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.closetPieceCount() == self.seededItemCount - 3 },
                      "The closet count didn't drop to \(seededItemCount - 3)")
        snap("closet-after-removals")

        relaunchKeepingData()
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), seededItemCount - 3, "Removed pieces came back after a relaunch")
        let search = searchField()
        search.tap()
        for gone in ["skirt", "cap", "tote"] {
            search.typeText(gone)
            XCTAssertTrue(text("No matches").waitForExistence(timeout: 10), "'\(gone)' is back in the closet after a relaunch")
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: gone.count))
            XCTAssertTrue(waitToDisappear(text("No matches"), timeout: 10), "Clearing the search didn't bring the closet back")
        }
        snap("closet-after-relaunch-removed")
    }

    // MARK: - The deck

    @MainActor
    func test04_DeckKeepShuffleSwapSkipAddLogAndWear() throws {
        launchToHome()
        guard openStyleDeck() else { return }
        let start = pieceIDs()
        XCTAssertGreaterThanOrEqual(start.count, 3, "Option 1 has fewer than three pieces: \(start)")
        snap("deck-option-1")

        // Keep a piece, then shuffle the rest around it.
        let kept = start[0]
        app.buttons[piecePrefix + kept].tap()
        let keep = app.buttons["outfit.keep.\(kept)"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Tapping a piece shows no Keep")
        keep.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (keep.value as? String) == "Kept" }, "Keep didn't take")
        let shuffle = app.buttons["outfit.shuffleRest"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 5) && shuffle.label.contains("1 kept"), "No '1 kept · Shuffle the rest'")
        shuffle.tap()
        waitForStyling()
        let shuffled = pieceIDs()
        XCTAssertTrue(shuffled.contains(kept), "Shuffle the rest dropped the kept piece")
        XCTAssertTrue(Set(shuffled) != Set(start) || stylistNotice().exists, "Shuffle the rest changed nothing and said nothing")
        snap("deck-after-shuffle")

        // Swap a piece that isn't kept: it goes, the kept one stays.
        guard let swapped = shuffled.first(where: { $0 != kept }) else { XCTFail("Only the kept piece is left"); return }
        app.buttons[piecePrefix + swapped].tap()
        let swap = app.buttons["outfit.swap.\(swapped)"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5) && swap.isEnabled, "No enabled Swap on an unkept piece")
        swap.tap()
        waitForStyling()
        let afterSwap = pieceIDs()
        XCTAssertTrue(!afterSwap.contains(swapped) || stylistNotice().exists, "Swap didn't replace the piece and said nothing")
        XCTAssertTrue(afterSwap.contains(kept), "Swapping another piece dropped the kept one")
        snap("deck-after-swap")

        // Wear today: logged, then the deck moves to option 2.
        let worn = afterSwap.map { app.buttons[piecePrefix + $0].label }
        app.buttons["outfit.wear"].tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Logged for today'")).waitForExistence(timeout: 5), "No 'Logged for today'")
        XCTAssertTrue(counter(2).waitForExistence(timeout: 10), "Wear today didn't move on to option 2")

        // Skip, answering "Not my style".
        app.buttons["outfit.skip"].tap()
        let notMyStyle = app.buttons["outfit.skipReason.notMyStyle"]
        XCTAssertTrue(notMyStyle.waitForExistence(timeout: 5), "No 'Not my style' after a skip")
        notMyStyle.tap()
        XCTAssertTrue(waitToDisappear(notMyStyle, timeout: 5), "The skip question stayed up")
        XCTAssertTrue(counter(3).waitForExistence(timeout: 10), "Skip didn't move on to option 3")

        // Add a piece from the ⋯ menu: a blouse (the list's first product) joins the look, or the stylist says why not.
        app.buttons["outfit.more"].tap()
        tapMenuItem("Add a piece")
        let blouse = app.buttons.matching(NSPredicate(format: "label == 'Blouse'")).firstMatch
        XCTAssertTrue(blouse.waitForExistence(timeout: 10), "'Add a piece' doesn't list the closet's blouse")
        blouse.tap()
        waitForStyling()
        let hasBlouse = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH 'Blouse'", piecePrefix)).firstMatch
        XCTAssertTrue(hasBlouse.waitForExistence(timeout: 10) || anyElement(NSPredicate(format: "label BEGINSWITH \"Couldn't find a\"")).exists,
                      "Adding the blouse did nothing and said nothing")
        snap("deck-added-piece")

        // Log another day: yesterday.
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        app.buttons["outfit.more"].tap()
        tapMenuItem("Log another day…")
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Log to a day'")).waitForExistence(timeout: 10), "No day picker")
        let dayButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.pickerDayLabel(yesterday))).firstMatch
        let pickedYesterday = cal.isDate(yesterday, equalTo: Date(), toGranularity: .month) && dayButton.waitForExistence(timeout: 5)
        if pickedYesterday { dayButton.tap() } else { note("log-another-day", "Yesterday isn't on this month's picker; logging today") }
        snap("log-another-day")
        app.buttons.matching(NSPredicate(format: "label == 'Log'")).firstMatch.tap()
        // Logged, the deck moves on (the toast lasts about a second; the calendar check below is the proof).
        XCTAssertTrue(counter(4).waitForExistence(timeout: 10), "'Log another day' didn't log and move on to option 4")

        app.buttons["outfit.close"].tap()
        XCTAssertTrue(text("Today you're wearing").waitForExistence(timeout: 10), "Home doesn't show today's logged look")
        snap("home-wearing")

        openTab("Outfits")
        assertTodayCard(source: "Styled for you", containsPiecesNamed: worn)
        if pickedYesterday {
            let cell = visibleDayCell(yesterday)
            XCTAssertTrue(cell.exists && cell.label.contains("outfit logged"), "Yesterday has no logged outfit after 'Log another day'")
            showDay(Calendar.current.startOfDay(for: Date()))
        }
        snap("calendar-today")

        relaunchKeepingData()
        XCTAssertTrue(text("Today you're wearing").waitForExistence(timeout: 20), "After a relaunch Home forgot today's look")
        openTab("Outfits")
        assertTodayCard(source: "Styled for you", containsPiecesNamed: worn)
        snap("calendar-today-after-relaunch")
    }

    // MARK: - Home's Wear today, and deleting a logged look

    @MainActor
    func test05_HomeWearTodayThenDeleteTheLog() throws {
        launchToHome()
        let wear = app.buttons["home.todayLook.wear"]
        XCTAssertTrue(wear.waitForExistence(timeout: 30), "Home has no Today's look with Wear today")
        wear.tap()
        XCTAssertTrue(text("Today you're wearing").waitForExistence(timeout: 10), "Wear today didn't log the look")
        XCTAssertFalse(wear.exists, "Wear today is still offered after logging")
        snap("home-logged")

        // The logged board opens the calendar.
        app.buttons["home.todayLook.board"].tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == \"Today's Outfits\"")).waitForExistence(timeout: 10),
                      "Tapping the logged look didn't open today in the calendar")
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'Styled for you'")).exists, "Today's card isn't the stylist's look")

        app.buttons.matching(NSPredicate(format: "label == 'Outfit actions'")).firstMatch.tap()
        tapMenuItem("Delete")
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Outfit'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a logged outfit doesn't ask to confirm")
        confirm.tap()
        XCTAssertTrue(text("No outfits logged").waitForExistence(timeout: 10), "The deleted outfit is still on today")
        snap("calendar-deleted")

        openTab("Home")
        XCTAssertTrue(app.buttons["home.todayLook.wear"].waitForExistence(timeout: 10), "Home still says you're wearing a deleted look")

        relaunchKeepingData()
        XCTAssertTrue(app.buttons["home.todayLook.wear"].waitForExistence(timeout: 30), "The deleted log came back on Home after a relaunch")
        openTab("Outfits")
        XCTAssertTrue(text("No outfits logged").waitForExistence(timeout: 10), "The deleted log came back in the calendar after a relaunch")
    }

    // MARK: - The manual composer: log, edit, month view

    @MainActor
    func test06_ComposerLogEditAndMonthView() throws {
        launchToHome()
        openTab("Outfits")
        app.buttons["outfits.add"].tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Add Outfit'")).waitForExistence(timeout: 10), "The composer didn't open")
        pick(shelf: "tops", title: "Tops", itemSuffix: "T-Shirt")
        pick(shelf: "bottoms", title: "Bottoms", itemSuffix: "Jeans")
        pick(shelf: "footwear", title: "Footwear", itemSuffix: "Sneaker")
        app.buttons["outfits.composer.save"].tap()
        XCTAssertTrue(waitToDisappear(app.buttons["outfits.composer.save"], timeout: 10), "The composer didn't close")
        var summary = todayCardTexts()
        XCTAssertTrue(summary.contains("Manual") && summary.contains("Sneaker"), "Today's card: \(summary)")

        // Edit: take the sneakers out, add a note.
        app.buttons.matching(NSPredicate(format: "label == 'Outfit actions'")).firstMatch.tap()
        tapMenuItem("Edit")
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Edit Outfit'")).waitForExistence(timeout: 10),
                      "Editing an outfit doesn't open the composer as 'Edit Outfit'")
        XCTAssertTrue(text("Selected (3)").waitForExistence(timeout: 5), "The editor didn't start with the outfit's three pieces")
        let sneakerInTray = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Sneaker, selected'")).firstMatch
        XCTAssertTrue(sneakerInTray.waitForExistence(timeout: 5), "The sneaker isn't in the editor's tray")
        sneakerInTray.tap()
        XCTAssertTrue(text("Selected (2)").waitForExistence(timeout: 5), "Tapping a tray piece didn't take it out")
        snap("composer-edit")
        app.buttons["outfits.composer.save"].tap()
        XCTAssertTrue(waitToDisappear(app.buttons["outfits.composer.save"], timeout: 10), "The editor didn't close")
        summary = todayCardTexts()
        XCTAssertFalse(summary.contains("Sneaker"), "The removed sneakers are still on the outfit: \(summary)")
        XCTAssertTrue(summary.contains("T-Shirt") && summary.contains("Jeans"), "The edit lost pieces it kept: \(summary)")
        snap("calendar-edited")

        // Month view marks today.
        app.buttons["outfits.monthToggle"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["outfits.monthToggle"].label == "Show week" }, "The month view didn't open")
        XCTAssertTrue(dayCell(Calendar.current.startOfDay(for: Date())).label.contains("outfit logged"),
                      "The month view doesn't mark today as logged")
        snap("calendar-month")
        app.buttons["outfits.monthToggle"].tap()
    }

    // MARK: - Home's habit cards

    @MainActor
    func test07_HabitCardsAddHeldPieceAndLogYesterday() throws {
        launchToHome(extra: ["-uiTestSeedHabits"])
        let held = app.buttons["home.uncertainItems"]
        XCTAssertTrue(held.waitForExistence(timeout: 20), "No 'We weren't sure' card on Home")
        XCTAssertTrue(held.label.contains("We weren't sure about 2 items"), "Card: \(held.label)")
        let wore = text("Wore this yesterday?")
        XCTAssertTrue(wore.waitForExistence(timeout: 5), "No 'Wore this yesterday?' card on Home")
        snap("home-habit-cards")

        // Add one (the newest held piece is listed first), say "Not mine" to the other.
        held.tap()
        XCTAssertTrue(anyElement(NSPredicate(format: "label == 'Not sure about these'")).waitForExistence(timeout: 10), "The held-items sheet didn't open")
        snap("held-items")
        let addButtons = app.buttons.matching(NSPredicate(format: "label == 'Add'"))
        XCTAssertEqual(addButtons.count, 2, "The sheet doesn't list both held pieces")
        addButtons.firstMatch.tap()
        let notMine = app.buttons.matching(NSPredicate(format: "label == 'Not mine'")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { addButtons.count == 1 }, "'Add' didn't take the piece off the list")
        notMine.tap()
        XCTAssertTrue(waitToDisappear(notMine, timeout: 10), "The sheet stayed open with nothing left in it")
        XCTAssertTrue(waitToDisappear(held, timeout: 10), "The 'We weren't sure' card stayed after both were answered")

        // Log yesterday's look from the photo.
        app.buttons["home.wearLog.log"].tap()
        XCTAssertTrue(waitToDisappear(wore, timeout: 10), "'Wore this yesterday?' stayed after Log it")

        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), seededItemCount + 1, "The added held piece isn't in the closet")
        openTab("Outfits")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        showDay(yesterday)
        XCTAssertTrue(anyElement(NSPredicate(format: "label CONTAINS 'From your photos'")).waitForExistence(timeout: 10),
                      "Yesterday has no outfit 'From your photos'")
        snap("calendar-yesterday-from-photo")

        relaunchKeepingData()
        XCTAssertFalse(app.buttons["home.uncertainItems"].waitForExistence(timeout: 8), "Answered held pieces came back after a relaunch")
        XCTAssertFalse(text("Wore this yesterday?").exists, "An answered 'Wore this?' came back after a relaunch")
        openTab("Wardrobe")
        XCTAssertEqual(closetPieceCount(), seededItemCount + 1, "The added held piece was lost on relaunch")
    }

    // MARK: - "Is this you?" → extraction → Review last scan results

    @MainActor
    func test08_IsThisYouConfirmedAddsThatPhotosClothes() throws {
        launchToHome(extra: ["-uiTestSeedFaceReview"])
        let banner = app.buttons.matching(NSPredicate(format: "label CONTAINS 'might be you'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "Home doesn't offer the waiting 'Is this you?' photo")
        snap("home-is-this-you")
        banner.tap()
        XCTAssertTrue(text("Tap every photo of you").waitForExistence(timeout: 15), "'Is this you?' didn't open")
        let cell = app.buttons.matching(NSPredicate(format: "label == 'Not selected'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "'Is this you?' shows no photo")
        cell.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH \"That's me\"")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Picking the photo doesn't offer \"That's me — add 1 photo\"")
        snap("is-this-you-picked")
        confirm.tap()

        // "Added N items" shows for under 2 s before the sheet closes itself: wait for the close, then count.
        let none = text("All set")
        let reviewing = text("Tap every photo of you")
        let closed = waitUntil(timeout: 480) { !reviewing.exists && !self.app.navigationBars["Is this you?"].exists }
        snap("is-this-you-done")
        XCTAssertTrue(closed, "'Is this you?' was still working 8 minutes after confirming")
        XCTAssertFalse(none.exists, "Confirming the street photo said 'All set' and added nothing")
        XCTAssertFalse(banner.waitForExistence(timeout: 3), "The answered photo is still waiting on Home")

        openTab("Wardrobe")
        let grown = settledClosetPieceCount() ?? 0
        XCTAssertGreaterThan(grown, seededItemCount, "The closet didn't grow after confirming the photo")

        // Home's "Review last scan results": take one of them out again.
        openTab("Home")
        let review = app.buttons.matching(NSPredicate(format: "label == 'Review last scan results'")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10), "No 'Review last scan results' after the confirmed photo")
        review.tap()
        XCTAssertTrue(text("Review scanned pieces").waitForExistence(timeout: 10), "The scan review didn't open")
        let removeOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch
        XCTAssertTrue(removeOne.waitForExistence(timeout: 5), "The scan review has no remove buttons")
        removeOne.tap()
        snap("scan-review-removed-one")
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done reviewing scanned items'")).firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }   // (the last one closes the review by itself)
        openTab("Wardrobe")
        XCTAssertTrue(waitUntil(timeout: 10) { self.closetPieceCount() == grown - 1 },
                      "Removing a scanned piece didn't take it out of the closet: \(grown) before, \(closetPieceCount() ?? -1) after")
    }

    // MARK: - "Take a Photo" without a camera

    /// The simulator has no camera (nor does a phone with the camera restricted): the add sheet's
    /// "Take a Photo" used to crash there (UIImagePickerController's `.camera` source throws). It now
    /// falls back to the photo library and the picked photo goes through the same review.
    @MainActor
    func test09_TakeAPhotoWithoutACameraStillAddsFromPhotos() throws {
        launchToHome()
        openTab("Wardrobe")
        app.buttons["closet.add"].tap()
        let camera = button(id: "addSource.camera", label: "Take a Photo")
        XCTAssertTrue(camera.waitForExistence(timeout: 10), "The add sheet has no 'Take a Photo'")
        camera.tap()
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 30), "Without a camera, 'Take a Photo' showed nothing to pick from")
        XCTAssertEqual(app.state, .runningForeground, "The app isn't running after 'Take a Photo'")
        snap("camera-fallback-library")
        photos.firstMatch.tap()
        let review = anyElement(NSPredicate(format: "label ==[c] 'Review items' OR label == 'Which one is you?'"))
        XCTAssertTrue(review.waitForExistence(timeout: 60), "The picked photo didn't go on to the review")
        snap("camera-fallback-review")
        app.buttons.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch.tap()
    }

    // MARK: - Replace an item's photo

    /// Edit → Replace photo → the street photo from the gallery: the coat is cut out of it on the
    /// phone, and after Save the item page shows the new picture, also after a relaunch.
    @MainActor
    func test10_ReplacePhotoCutsTheItemOutOfTheNewPhoto() throws {
        launchToHome()
        openTab("Wardrobe")
        let coat = closetTile(containing: "Coat")
        XCTAssertTrue(scrollUntilHittable(coat, maxSwipes: 6), "No coat in the closet")
        coat.tap()
        XCTAssertTrue(itemPage().waitForExistence(timeout: 15), "The coat's page didn't open")
        let hero = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo of'")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "The item page has no picture")
        pause(1.5)
        let before = hero.screenshot().pngRepresentation

        app.buttons["itemDetail.more"].tap()
        app.buttons.matching(NSPredicate(format: "identifier == 'itemDetail.edit' OR label == 'Edit details'")).firstMatch.tap()
        let replace = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Replace photo'")).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 10), "The editor has no Replace photo")
        replace.tap()
        tapMenuItem("Choose from gallery")
        guard pickNewestPhoto() else { return }

        let different = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Choose a different photo'")).firstMatch
        let failed = app.alerts["Couldn't use that photo"]
        let outcome = waitForAny([different, failed], timeout: 420)
        snap("replace-photo-cut-out")
        XCTAssertEqual(outcome, 0, "The new photo wasn't cut out (0 = done, 1 = 'Couldn't use that photo', nil = still working)")
        app.buttons.matching(NSPredicate(format: "label == 'Save'")).firstMatch.tap()
        XCTAssertTrue(waitToDisappear(anyElement(NSPredicate(format: "label == 'Edit piece'")), timeout: 10), "The editor didn't close on Save")
        XCTAssertTrue(waitUntil(timeout: 15) { hero.exists && hero.screenshot().pngRepresentation != before },
                      "The item page still shows the old picture")
        snap("item-page-new-photo")

        relaunchKeepingData()
        openTab("Wardrobe")
        let again = closetTile(containing: "Coat")
        XCTAssertTrue(scrollUntilHittable(again, maxSwipes: 6), "The coat is gone after a relaunch")
        again.tap()
        let heroAgain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo of'")).firstMatch
        XCTAssertTrue(heroAgain.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 15) { heroAgain.screenshot().pngRepresentation != before },
                      "After a relaunch the coat shows its old picture again")
    }

    // MARK: - Auto-scan from the add sheet, without a selfie

    /// Wardrobe + → Auto-Scan Photos → All photos with no selfie on file: the banner asks for one
    /// (instead of spinning), the selfie is taken, and the scan runs to the end on its own.
    @MainActor
    func test11_AutoScanWithoutASelfieAsksForOneThenFinishes() throws {
        launchToHome(extra: ["-uiTestSelfieFixture"])
        openTab("Wardrobe")
        app.buttons["closet.add"].tap()
        let autoScan = button(id: "addSource.autoScan", label: "Auto-Scan Photos")
        XCTAssertTrue(autoScan.waitForExistence(timeout: 10), "The add sheet has no Auto-Scan (photo access is granted on CI)")
        autoScan.tap()
        XCTAssertTrue(text("Scan photos for clothing").waitForExistence(timeout: 10), "The scan range sheet didn't open")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All photos'")).firstMatch.tap()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start scanning'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5) && start.isEnabled, "No enabled Start scanning")
        snap("scan-range")
        start.tap()

        openTab("Home")
        let takeSelfie = app.buttons["scan.takeSelfie"]
        XCTAssertTrue(takeSelfie.waitForExistence(timeout: 20), "A scan without a selfie doesn't ask for one")
        snap("scan-needs-selfie")
        takeSelfie.tap()
        let use = app.buttons.matching(NSPredicate(format: "label == 'Use these selfie photos' OR label == 'Use these photos'")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 120), "The selfie never kept three frames of the fixture face")
        use.tap()
        XCTAssertTrue(waitToDisappear(takeSelfie, timeout: 30), "The scan still asks for a selfie after taking one")

        let completed = anyElement(NSPredicate(format: "identifier == 'scanBanner.completed' OR identifier == 'scanBanner.completedEmpty'"))
        let progress = anyElement(NSPredicate(format: "identifier == 'scanBanner.progress'"))
        let errorBanner = anyElement(NSPredicate(format: "label BEGINSWITH 'Scan paused. Double tap to retry'"))
        var sawProgress = false
        let outcome = waitUntil(timeout: 360) {
            if progress.exists { sawProgress = true }
            return completed.exists || errorBanner.exists || takeSelfie.exists || (sawProgress && !progress.exists)
        }
        snap("scan-after-selfie")
        XCTAssertTrue(outcome, "The scan was still running 6 minutes after the selfie")
        XCTAssertFalse(errorBanner.exists, "The scan stopped with an error")
        XCTAssertFalse(takeSelfie.exists, "The scan still says there's no selfie after taking one")
    }

    // MARK: - Steps

    @MainActor
    private func searchField() -> XCUIElement {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The closet has no search field")
        return field
    }

    /// Home → Style me → the deck's "1 of 5" (answering the weather prompt).
    @MainActor
    private func openStyleDeck() -> Bool {
        let generate = button(id: "home.styleMe", label: "Style me")
        guard generate.waitForExistence(timeout: 20) else { XCTFail("No Style me button on Home"); return false }
        tapScrollingIfNeeded(generate)
        let weatherAlert = app.alerts["Weather unavailable"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            switch waitForAny([counter(1), weatherAlert], timeout: max(1, deadline.timeIntervalSinceNow)) {
            case 0?: return true
            case 1?: proceedWithoutWeather(weatherAlert)
            default: break
            }
        }
        XCTFail("The outfit deck never appeared")
        return false
    }

    @MainActor
    private func counter(_ n: Int) -> XCUIElement {
        anyElement(NSPredicate(format: "label MATCHES %@", "(Option )?\(n) of [0-9]+"))
    }

    /// The current look's piece ids (from one snapshot: the board re-renders as it animates).
    @MainActor
    private func pieceIDs() -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        var ids: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix(piecePrefix) { ids.append(String(node.identifier.dropFirst(piecePrefix.count))) }
            node.children.forEach(walk)
        }
        walk(snapshot)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    @MainActor
    private func waitForStyling() {
        let busy = anyElement(NSPredicate(format: "label BEGINSWITH 'Styling'"))
        if busy.waitForExistence(timeout: 2) { XCTAssertTrue(waitToDisappear(busy, timeout: 120), "Styling never finished") }
        pause(1)   // the board animates the new piece in
    }

    /// The stylist's "why not" notice ("That's your only…", "Those pieces only work one way…").
    @MainActor
    private func stylistNotice() -> XCUIElement {
        anyElement(NSPredicate(format: "label BEGINSWITH \"That's your only\" OR label BEGINSWITH 'Those pieces only' OR label BEGINSWITH \"That's every look\" OR label BEGINSWITH 'Add a few more pieces'"))
    }

    @MainActor
    private func tapMenuItem(_ title: String) {
        let item = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No '\(title)' in the menu")
        item.tap()
    }

    /// "Thursday, November 5": how the graphical date picker labels a day.
    static func pickerDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    static func dayCellID(_ day: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "outfits.day.\(f.string(from: day))"
    }

    @MainActor
    private func dayCell(_ day: Date) -> XCUIElement {
        app.buttons[Self.dayCellID(day)]
    }

    /// `day`'s cell in the Outfits week strip, stepping a week back or forward when it's in another week.
    @MainActor
    private func visibleDayCell(_ day: Date) -> XCUIElement {
        let cell = dayCell(day)
        if !cell.waitForExistence(timeout: 5) {
            // Step from the week on screen, not from today: on a Sunday, yesterday is last week,
            // and today is then one week forward. (yyyy-MM-dd ids sort by date.)
            let shown = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'outfits.day.'")).firstMatch.identifier
            let step = Self.dayCellID(day) < shown ? "Previous week" : "Next week"
            app.buttons.matching(NSPredicate(format: "label == %@", step)).firstMatch.tap()
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "The calendar can't show \(day)")
        return cell
    }

    @MainActor
    private func showDay(_ day: Date) {
        let cell = visibleDayCell(day)
        if cell.exists { cell.tap() }
    }

    /// Every text on today's logged outfit cards, joined.
    @MainActor
    private func todayCardTexts() -> String {
        let header = anyElement(NSPredicate(format: "label == \"Today's Outfits\""))
        if !header.waitForExistence(timeout: 5) {
            // The calendar opens on the day logged last (which can be another day): go to today.
            let todayButton = app.buttons.matching(NSPredicate(format: "label == 'Today'")).firstMatch
            if todayButton.exists { todayButton.tap() } else { showDay(Calendar.current.startOfDay(for: Date())) }
        }
        XCTAssertTrue(header.waitForExistence(timeout: 10), "The calendar isn't on today")
        let cards = app.descendants(matching: .any).matching(identifier: "outfits.card")
        _ = cards.firstMatch.waitForExistence(timeout: 10)
        return cards.allElementsBoundByIndex
            .flatMap { $0.staticTexts.allElementsBoundByIndex.map(\.label) }
            .joined(separator: " | ")
    }

    /// Today's card is marked `source` and names every worn piece (by its product, the name's last word).
    @MainActor
    private func assertTodayCard(source: String, containsPiecesNamed names: [String],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let texts = todayCardTexts()
        XCTAssertTrue(texts.contains(source), "Today's card isn't '\(source)': \(texts)", file: file, line: line)
        for name in names {
            let product = name.split(separator: " ").last.map(String.init) ?? name
            XCTAssertTrue(texts.contains(product), "Today's card lacks the worn \(name): \(texts)", file: file, line: line)
        }
    }

    /// In the composer: open a shelf, tick the first item whose name ends with `itemSuffix`.
    @MainActor
    private func pick(shelf: String, title: String, itemSuffix: String) {
        let tab = app.buttons.matching(NSPredicate(format:
            "identifier == %@ OR label BEGINSWITH %@", "composer.shelf.\(shelf)", "\(title),")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "No \(title) shelf in the composer")
        tab.tap()
        let item = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'composer.item.' AND label ENDSWITH %@", itemSuffix)).firstMatch
        XCTAssertTrue(scrollUntilHittable(item, maxSwipes: 4), "No \(itemSuffix) on the \(title) shelf")
        item.tap()
    }
}
