import Testing
import Foundation
@testable import StyleMate

// Wardrobe insights (Services/Insights/WardrobeInsights) and Home's "Almost ready" card
// (Services/Outfits/OutfitReadiness): pure logic over a synthetic closet and outfit log.

private func item(_ category: StyleMate.Category, _ product: String, _ colors: [String],
                  pattern: Pattern = .solid) -> WardrobeItem {
    WardrobeItem(category: category, product: product, colors: colors, brand: "", pattern: pattern,
                 imagePath: "test_\(UUID().uuidString).jpg")
}

private let now: Date = {
    let base = Date(timeIntervalSince1970: 1_767_000_000)
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
}()

private func daysAgo(_ n: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
}

@Suite("Wardrobe insights")
struct WardrobeInsightsTests {

    // MARK: Wear

    @Test("Most worn, not worn in 60 days and the worn share come from the outfit log")
    func wearInsights() {
        let tee = item(.tops, "T-Shirts", ["White"])
        let jeans = item(.bottoms, "Jeans", ["Blue"])
        let coat = item(.outerwear, "Coats", ["Camel"])
        let boots = item(.footwear, "Chelsea Boots", ["Brown"])
        let dress = item(.onePieces, "Dresses", ["Red"])
        let logs: [ClosetWear.Log] = [
            (date: daysAgo(2), itemIDs: [tee.id, jeans.id, boots.id]),
            (date: daysAgo(5), itemIDs: [tee.id, jeans.id]),
            (date: daysAgo(9), itemIDs: [tee.id]),
            (date: daysAgo(70), itemIDs: [coat.id, boots.id]),           // too long ago for "worn lately"
            (date: now.addingTimeInterval(3 * 86_400), itemIDs: [dress.id]),  // planned, not worn
        ]
        let i = WardrobeInsights.compute(items: [tee, jeans, coat, boots, dress], logs: logs, now: now)

        #expect(i.total == 5)
        // Ties (jeans and boots, twice each) go to the more recently worn.
        #expect(i.mostWorn.map(\.item.id) == [tee.id, boots.id, jeans.id, coat.id])
        #expect(i.mostWorn.first?.count == 3)
        // Never worn first, then the longest since.
        #expect(i.notWorn.map(\.id) == [dress.id, coat.id])
        #expect(i.wornInWindow == 3)
        #expect(abs(i.wornShare - 0.6) < 0.001)
        #expect(i.logCoversWindow)
        #expect(i.hasWearLog)
    }

    @Test("A log younger than 60 days doesn't claim '60 days'")
    func shortLog() {
        let tee = item(.tops, "T-Shirts", ["White"])
        let jeans = item(.bottoms, "Jeans", ["Blue"])
        let i = WardrobeInsights.compute(items: [tee, jeans], logs: [(date: daysAgo(3), itemIDs: [tee.id])], now: now)
        #expect(!i.logCoversWindow)
        #expect(i.notWorn.map(\.id) == [jeans.id])

        let empty = WardrobeInsights.compute(items: [tee, jeans], logs: [], now: now)
        #expect(!empty.hasWearLog)
        #expect(empty.mostWorn.isEmpty)
        #expect(empty.notWorn.count == 2)
    }

    @Test("Recent additions are the newest pieces, newest first")
    func recent() {
        let items = (0..<12).map { item(.tops, "T-Shirts", ["White"]).withNote($0) }
        let i = WardrobeInsights.compute(items: items, logs: [], now: now)
        #expect(i.recent.count == 8)
        #expect(i.recent.first?.id == items.last?.id)
    }

    // MARK: Balance

    @Test("Colour balance: biggest first, the tail folds into Other, neutrals counted")
    func colourBalance() {
        var items: [WardrobeItem] = []
        let colours = ["Black": 5, "White": 3, "Navy": 2, "Red": 1, "Green": 1, "Pink": 1, "Yellow": 1, "Purple": 1]
        for (c, n) in colours { for _ in 0..<n { items.append(item(.tops, "T-Shirts", [c])) } }
        let i = WardrobeInsights.compute(items: items, logs: [], now: now)
        #expect(i.colours.first?.name == "Black")
        #expect(i.colours.first?.count == 5)
        #expect(i.colours.count == 7)
        #expect(i.colours.last?.name == "Other")
        #expect(i.colours.reduce(0) { $0 + $1.count } == items.count)
        #expect(abs(i.neutralShare - 10.0 / 15.0) < 0.001)   // black, white, navy
    }

    @Test("Shelves in closet order, with a note when tops outnumber bottoms 3 to 1")
    func shelfBalance() {
        let items = (0..<9).map { _ in item(.tops, "T-Shirts", ["White"]) }
            + [item(.bottoms, "Jeans", ["Blue"]), item(.bottoms, "Chinos", ["Beige"]), item(.bottoms, "Shorts", ["Khaki"]),
               item(.footwear, "Sneakers", ["White"])]
        let i = WardrobeInsights.compute(items: items, logs: [], now: now)
        #expect(i.shelves.map(\.section) == [.tops, .bottoms, .footwear])
        #expect(i.shelves.first?.count == 9)
        #expect(i.balanceNote == "About 3 tops for every bottom: another bottom adds the most new outfits.")

        let even = WardrobeInsights.compute(items: Array(items.prefix(2)) + Array(items.suffix(4)), logs: [], now: now)
        #expect(even.balanceNote == nil)
    }

    // MARK: Duplicates

    @Test("'You have 9 black tees', in natural English")
    func duplicates() {
        let tees = (0..<9).map { _ in item(.tops, "T-Shirts", ["Black"]) }
        let jeans = (0..<4).map { _ in item(.bottoms, "Jeans", ["Blue"]) }
        let dresses = (0..<3).map { _ in item(.onePieces, "Dresses", ["Grey"]) }
        let watches = (0..<3).map { _ in item(.accessories, "Watches", ["Silver"]) }
        let pair = (0..<2).map { _ in item(.tops, "Shirts", ["White"]) }      // two isn't a pattern
        let i = WardrobeInsights.compute(items: tees + jeans + dresses + watches + pair, logs: [], now: now)
        #expect(i.duplicates.map(\.title) == [
            "You have 9 black tees",
            "You have 4 pairs of blue jeans",
            "You have 3 grey dresses",
            "You have 3 silver watches",
        ])
        #expect(i.duplicates.first?.items.count == 9)
    }

    @Test("Insights are on for everyone (one switch away from Premium)")
    func availability() {
        #expect(InsightsAvailability.isAvailable)
    }

    // MARK: Almost ready

    @Test("Only tops: 'Add 1 more bottom and shoes to get outfits'")
    func onlyTops() {
        let s = OutfitReadiness.status(of: [item(.tops, "T-Shirts", ["White"]), item(.tops, "Shirts", ["Blue"])])
        #expect(!s.isReady)
        #expect(s.missing == [.bottom, .shoes])
        #expect(OutfitReadiness.message(for: s) == "Add 1 more bottom and shoes to get outfits")
        #expect(s.has[.top] == true)
    }

    @Test("Only accessories: a top, a bottom and shoes (a dress would do for the first two)")
    func nothingToWear() {
        let s = OutfitReadiness.status(of: [item(.accessories, "Watches", ["Silver"])])
        #expect(s.missing == [.top, .bottom, .shoes])
        #expect(s.dressWouldHelp)
        #expect(OutfitReadiness.message(for: s) == "Add a top, a bottom and shoes to get outfits")
    }

    @Test("A dress and shoes are ready; dungarees still need a top")
    func onePieces() {
        let shoes = item(.footwear, "Sneakers", ["White"])
        #expect(OutfitReadiness.isReady([item(.onePieces, "Dresses", ["Red"]), shoes]))
        let dungarees = OutfitReadiness.status(of: [item(.onePieces, "Dungarees", ["Blue"]), shoes])
        #expect(dungarees.missing == [.top])
        #expect(OutfitReadiness.message(for: dungarees) == "Add 1 more top to get outfits")
    }

    @Test("Top, bottom and shoes: ready, no message")
    func ready() {
        let s = OutfitReadiness.status(of: [item(.tops, "T-Shirts", ["White"]), item(.bottoms, "Jeans", ["Blue"]),
                                            item(.footwear, "Sneakers", ["White"])])
        #expect(s.isReady)
        #expect(OutfitReadiness.message(for: s) == nil)
    }
}

private extension WardrobeItem {
    /// A distinct copy (fresh id) so wardrobe order is easy to read in tests.
    func withNote(_ n: Int) -> WardrobeItem {
        WardrobeItem(category: category, product: product, colors: colors, brand: "\(n)", pattern: pattern, imagePath: imagePath)
    }
}
