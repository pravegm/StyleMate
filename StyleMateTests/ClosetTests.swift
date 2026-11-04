import Foundation
import Testing
@testable import StyleMate

/// Pure closet logic: shelf mapping, filters, search, sorting, wear stats, chips.
struct ClosetTests {

    private func item(_ category: Category, _ product: String, colors: [String] = ["Black"],
                      pattern: Pattern = .solid, brand: String = "", material: String? = nil,
                      details: String? = nil, sleeve: SleeveLength? = nil,
                      neckline: Neckline? = nil) -> WardrobeItem {
        WardrobeItem(category: category, product: product, colors: colors, brand: brand,
                     pattern: pattern, imagePath: "x.png", material: material,
                     neckline: neckline, sleeveLength: sleeve, details: details)
    }

    // MARK: Shelves

    @Test func garmentCategoriesMapToShelves() {
        #expect(ClosetSection.of(category: .tops, product: "T-Shirts") == .tops)
        #expect(ClosetSection.of(category: .midLayers, product: "Hoodies") == .tops)
        #expect(ClosetSection.of(category: .outerwear, product: "Trench Coats") == .tops)
        #expect(ClosetSection.of(category: .bottoms, product: "Jeans") == .bottoms)
        #expect(ClosetSection.of(category: .onePieces, product: "Jumpsuits") == .dresses)
        #expect(ClosetSection.of(category: .footwear, product: "Chelsea Boots") == .footwear)
    }

    @Test func accessoriesSplitIntoBagsJewelryAndAccessories() {
        for bag in ["Handbags", "Tote Bags", "Crossbody Bags", "Backpacks", "Wallets", "Clutches",
                    "Fanny Packs", "Briefcases", "Messenger Bags"] {
            #expect(ClosetSection.of(category: .accessories, product: bag) == .bags, "\(bag)")
        }
        for jewel in ["Rings", "Necklaces", "Earrings", "Pendants", "Chains", "Anklets", "Cufflinks",
                      "Brooches", "Bracelets", "Watches"] {
            #expect(ClosetSection.of(category: .accessories, product: jewel) == .jewelry, "\(jewel)")
        }
        for other in ["Sunglasses", "Baseball Caps", "Scarves", "Belts", "Ties", "Gloves", "Beanies"] {
            #expect(ClosetSection.of(category: .accessories, product: other) == .accessories, "\(other)")
        }
    }

    @Test func mixedCategoriesLandOnTheRightShelf() {
        #expect(ClosetSection.of(category: .activewear, product: "Running Shorts") == .bottoms)
        #expect(ClosetSection.of(category: .activewear, product: "Yoga Pants") == .bottoms)
        #expect(ClosetSection.of(category: .activewear, product: "Swim Trunks") == .bottoms)
        #expect(ClosetSection.of(category: .activewear, product: "Sports Bras") == .tops)
        #expect(ClosetSection.of(category: .activewear, product: "Tennis Dresses") == .dresses)
        #expect(ClosetSection.of(category: .ethnicWear, product: "Kurta") == .tops)
        #expect(ClosetSection.of(category: .ethnicWear, product: "Blouse (saree)") == .tops)
        #expect(ClosetSection.of(category: .ethnicWear, product: "Saree") == .dresses)
        #expect(ClosetSection.of(category: .ethnicWear, product: "Dhoti") == .bottoms)
        #expect(ClosetSection.of(category: .ethnicWear, product: "Lehenga") == .bottoms)
        #expect(ClosetSection.of(category: .ethnicWear, product: "Dupatta") == .accessories)
        #expect(ClosetSection.of(category: .innerwear, product: "Socks") == .footwear)
        #expect(ClosetSection.of(category: .innerwear, product: "Boxers") == .bottoms)
        #expect(ClosetSection.of(category: .innerwear, product: "Undershirts") == .tops)
    }

    @Test func everyKnownProductHasAShelf() {
        // Guards the mapping against new product names: none may crash, and
        // accessories must never fall onto a garment shelf.
        for (category, products) in productTypesByCategory {
            for p in products {
                let s = ClosetSection.of(category: category, product: p)
                if category == .accessories {
                    #expect([.bags, .jewelry, .accessories].contains(s), "\(p)")
                }
            }
        }
    }

    @Test func groupedKeepsShelfOrderAndItemOrder() {
        let shoe = item(.footwear, "Sneakers")
        let tee = item(.tops, "T-Shirts")
        let ring = item(.accessories, "Rings")
        let tee2 = item(.tops, "Shirts")
        let groups = ClosetEngine.grouped([shoe, tee, ring, tee2])
        #expect(groups.map(\.section) == [.tops, .footwear, .jewelry])
        #expect(groups[0].items == [tee, tee2])
    }

    // MARK: Colors

    @Test func colorNormalizationAndRank() {
        #expect(ClosetColor.normalize("  light blue ") == "Light Blue")
        #expect(ClosetColor.normalize("grey") == "Gray")
        #expect(ClosetColor.rank("Black") < ClosetColor.rank("White"))
        #expect(ClosetColor.rank("Dark Green") == ClosetColor.rank("Green"))
        #expect(ClosetColor.rank("Chartreuse") == ClosetColor.order.count)
    }

    @Test func swatchesAreDistinctAndInSpectrumOrder() {
        let items = [item(.tops, "T-Shirts", colors: ["Red", "white"]),
                     item(.bottoms, "Jeans", colors: ["Navy", "Red"]),
                     item(.footwear, "Sneakers", colors: ["Black"])]
        #expect(ClosetColor.swatches(for: items) == ["Black", "White", "Navy", "Red"])
    }

    // MARK: Filter + search

    @Test func filterBySectionColorAndPattern() {
        let redTee = item(.tops, "T-Shirts", colors: ["Red"])
        let stripedTee = item(.tops, "T-Shirts", colors: ["White", "Navy"], pattern: .stripes)
        let jeans = item(.bottoms, "Jeans", colors: ["Blue"])
        let all = [redTee, stripedTee, jeans]

        var f = ClosetFilter()
        #expect(!f.isActive)
        #expect(ClosetEngine.apply(all, filter: f, sort: .oldest) == all)

        f.section = .tops
        #expect(ClosetEngine.apply(all, filter: f, sort: .oldest) == [redTee, stripedTee])

        f.colors = ["Navy", "Blue"]
        #expect(ClosetEngine.apply(all, filter: f, sort: .oldest) == [stripedTee])

        f = ClosetFilter(patterns: [.stripes])
        #expect(f.isActive && f.hasFacets)
        #expect(ClosetEngine.apply(all, filter: f, sort: .oldest) == [stripedTee])
    }

    @Test func searchMatchesWordPrefixesAcrossFields() {
        let tee = item(.tops, "T-Shirts", colors: ["Light Blue"], brand: "Uniqlo", material: "Cotton",
                       details: "embroidered logo")
        let jeans = item(.bottoms, "Jeans", colors: ["Blue"], material: "Denim")
        let bag = item(.accessories, "Crossbody Bags", colors: ["Tan"], material: "Leather")

        func search(_ q: String) -> [WardrobeItem] {
            ClosetEngine.apply([tee, jeans, bag], filter: ClosetFilter(query: q), sort: .oldest)
        }
        #expect(search("blue") == [tee, jeans])
        #expect(search("light blue") == [tee])
        #expect(search("uniq") == [tee])
        #expect(search("DENIM") == [jeans])
        #expect(search("jeans") == [jeans])
        #expect(search("bag") == [bag])
        #expect(search("bags") == [bag])
        #expect(search("leather bag") == [bag])
        #expect(search("red").isEmpty)        // must not match "embroidered"
        #expect(search("   ") == [tee, jeans, bag])
    }

    // MARK: Sort

    @Test func newestOldestAndColorSorts() {
        let a = item(.tops, "T-Shirts", colors: ["White"])
        let b = item(.tops, "T-Shirts", colors: ["Black"])
        let c = item(.tops, "T-Shirts", colors: ["Red"])
        let all = [a, b, c]   // wardrobe order: oldest first
        #expect(ClosetEngine.apply(all, filter: ClosetFilter(), sort: .newest) == [c, b, a])
        #expect(ClosetEngine.apply(all, filter: ClosetFilter(), sort: .oldest) == [a, b, c])
        #expect(ClosetEngine.apply(all, filter: ClosetFilter(), sort: .color) == [b, a, c])
    }

    @Test func wearSorts() {
        let a = item(.tops, "T-Shirts")
        let b = item(.tops, "Shirts")
        let c = item(.bottoms, "Jeans")
        let day = { (d: Int) in Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }
        let logs: [ClosetWear.Log] = [
            (date: day(1), itemIDs: [a.id, c.id]),
            (date: day(2), itemIDs: [a.id]),
            (date: day(5), itemIDs: [c.id, c.id]),   // listed twice in one outfit = worn once
        ]
        let wear = ClosetWear.stats(from: logs)
        #expect(wear[a.id] == WearStat(count: 2, lastWorn: day(2)))
        #expect(wear[c.id] == WearStat(count: 2, lastWorn: day(5)))
        #expect(wear[b.id] == nil)

        let all = [a, b, c]
        #expect(ClosetEngine.apply(all, filter: ClosetFilter(), sort: .mostWorn, wear: wear) == [c, a, b])
        #expect(ClosetEngine.apply(all, filter: ClosetFilter(), sort: .leastWorn, wear: wear) == [b, a, c])
        #expect(ClosetEngine.apply(all, filter: ClosetFilter(), sort: .recentlyWorn, wear: wear) == [c, a, b])
    }

    @Test func wearSummaryText() {
        #expect(ClosetAttributes.wearSummary(nil) == "Not logged in an outfit yet")
        #expect(ClosetAttributes.wearSummary(WearStat(count: 1, lastWorn: nil)) == "Worn once")
        let s = ClosetAttributes.wearSummary(WearStat(count: 3, lastWorn: Date()))
        #expect(s.hasPrefix("Worn 3 times · last on "))
    }

    // MARK: Attribute chips

    @Test func chipsAreGatedByCategory() {
        let shirt = item(.tops, "Shirts", brand: "Zara", material: "Linen", sleeve: .shortSleeve, neckline: .collared)
        let labels = ClosetAttributes.chips(for: shirt).map(\.label)
        #expect(labels == ["Category", "Type", "Pattern", "Material", "Sleeve", "Neckline", "Brand"])

        // A watch never shows garment-only attributes, even if it carries them.
        let watch = item(.accessories, "Watches", sleeve: .shortSleeve, neckline: .collared)
        let watchLabels = ClosetAttributes.chips(for: watch).map(\.label)
        #expect(!watchLabels.contains("Sleeve") && !watchLabels.contains("Neckline"))
        #expect(ClosetAttributes.chips(for: watch).first { $0.label == "Type" }?.value == "Watch")
    }

    @Test func productDisplayNames() {
        #expect(ClosetText.displayProduct("Watches") == "Watch")
        #expect(ClosetText.displayProduct("Dresses") == "Dress")
        #expect(ClosetText.displayProduct("T-Shirts") == "T-Shirt")
        #expect(ClosetText.displayProduct("Jeans") == "Jeans")
        #expect(ClosetText.displayProduct("Yoga Pants") == "Yoga Pants")
        #expect(ClosetText.displayProduct("Leggings") == "Leggings")
        #expect(ClosetText.displayProduct("Henley") == "Henley")
        let watch = item(.accessories, "Watches", colors: ["Silver"])
        #expect(ClosetText.displayName(watch) == "Silver Watch")
    }

    @Test func textSingularization() {
        #expect(ClosetText.words("Crossbody Bags") == ["crossbody", "bag"])
        #expect(ClosetText.words("Watches") == ["watch"])
        #expect(ClosetText.words("Dresses") == ["dress"])
        #expect(ClosetText.words("Dress") == ["dress"])
    }
}
