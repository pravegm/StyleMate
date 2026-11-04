import Testing
import Foundation
@testable import StyleMate

// Unit tests for the on-device OutfitEngine, on a synthetic wardrobe (image paths
// are dummies — the engine never touches images).

// MARK: - Fixtures

private func item(_ category: StyleMate.Category, _ product: String, _ colors: [String],
                  pattern: Pattern = .solid, material: String? = nil,
                  sleeve: SleeveLength? = nil, length: GarmentLength? = nil) -> WardrobeItem {
    WardrobeItem(category: category, product: product, colors: colors, brand: "", pattern: pattern,
                 imagePath: "test_\(UUID().uuidString).jpg", material: material,
                 sleeveLength: sleeve, garmentLength: length)
}

/// A small but realistic closet: neutral basics, a few colourful pieces, layers
/// for every temperature and shoes for every formality.
private struct Closet {
    // Tops
    let whiteTee = item(.tops, "T-Shirts", ["White"])
    let blackTee = item(.tops, "T-Shirts", ["Black"])
    let greyGraphic = item(.tops, "Graphic Tees", ["Grey"])
    let navyShirt = item(.tops, "Button-Down Shirts", ["Navy"], sleeve: .longSleeve)
    let blueShirt = item(.tops, "Shirts", ["Light Blue"], sleeve: .longSleeve)
    let creamBlouse = item(.tops, "Blouses", ["Cream"], material: "Silk")
    let redPolo = item(.tops, "Polo T-Shirts", ["Red"])
    let yellowTee = item(.tops, "T-Shirts", ["Yellow"])
    let pinkWrap = item(.tops, "Wrap Tops", ["Hot Pink"], pattern: .floral)
    // Bottoms
    let jeans = item(.bottoms, "Jeans", ["Blue"])
    let blackTrousers = item(.bottoms, "Trousers", ["Black"], material: "Wool")
    let beigeChinos = item(.bottoms, "Chinos", ["Beige"])
    let greyJoggers = item(.bottoms, "Joggers", ["Grey"], material: "Fleece")
    let khakiShorts = item(.bottoms, "Shorts", ["Khaki"])
    // Mid-layers
    let navySweater = item(.midLayers, "Sweaters", ["Navy"], material: "Wool")
    let greyHoodie = item(.midLayers, "Hoodies", ["Grey"])
    let camelCardigan = item(.midLayers, "Cardigans", ["Camel"])
    // Outerwear
    let camelCoat = item(.outerwear, "Coats", ["Camel"], material: "Wool")
    let blackLeather = item(.outerwear, "Leather Jackets", ["Black"], material: "Leather")
    let navyBlazer = item(.outerwear, "Blazers", ["Navy"])
    let beigeTrench = item(.outerwear, "Trench Coats", ["Beige"])
    let blackPuffer = item(.outerwear, "Puffer Jackets", ["Black"])
    // Footwear
    let whiteSneakers = item(.footwear, "Sneakers", ["White"])
    let blackOxfords = item(.footwear, "Oxford Shoes", ["Black"], material: "Leather")
    let brownBoots = item(.footwear, "Chelsea Boots", ["Brown"], material: "Leather")
    let tanSandals = item(.footwear, "Sandals", ["Tan"])
    let blackLoafers = item(.footwear, "Loafers", ["Black"], material: "Leather")
    // Accessories
    let watch = item(.accessories, "Watches", ["Silver"])
    let belt = item(.accessories, "Belts", ["Black"], material: "Leather")
    let sunglasses = item(.accessories, "Sunglasses", ["Black"])

    var all: [WardrobeItem] {
        [whiteTee, blackTee, greyGraphic, navyShirt, blueShirt, creamBlouse, redPolo, yellowTee, pinkWrap,
         jeans, blackTrousers, beigeChinos, greyJoggers, khakiShorts,
         navySweater, greyHoodie, camelCardigan,
         camelCoat, blackLeather, navyBlazer, beigeTrench, blackPuffer,
         whiteSneakers, blackOxfords, brownBoots, tanSandals, blackLoafers,
         watch, belt, sunglasses]
    }
}

/// A fixed midday so time-of-day rules (sunglasses) never depend on when CI runs.
private let noon: Date = {
    let base = Date(timeIntervalSince1970: 1_767_000_000)
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
}()

private func context(_ temperature: Double?,
                     condition: String = "Partly cloudy",
                     occasion: OutfitType? = .everyday,
                     mood: OutfitMood? = nil,
                     hints: StyleHints = StyleHints(),
                     lastWorn: [UUID: Date] = [:]) -> StylingContext {
    StylingContext(temperatureC: temperature, condition: condition, isDaytime: true,
                   occasion: occasion, mood: mood, hints: hints, lastWorn: lastWorn, now: noon)
}

private func looks(_ wardrobe: [WardrobeItem], _ context: StylingContext,
                   locked: [WardrobeItem] = [], seed: UInt64 = 42) -> [Outfit] {
    guard case .success(let looks) = OutfitEngine().suggest(from: wardrobe, context: context,
                                                            locked: locked, seed: seed) else { return [] }
    return looks
}

private func slots(_ outfit: Outfit) -> [OutfitSlot] {
    outfit.items.compactMap { OutfitSlot.of($0) }
}

// MARK: - Tests

@Suite("OutfitEngine")
struct OutfitEngineTests {
    private let closet = Closet()

    @Test("Five distinct, complete looks that pass the validator untouched")
    func returnsFiveDistinctCompleteLooks() {
        let result = looks(closet.all, context(18))
        #expect(result.count == 5)
        #expect(Set(result.map { OutfitValidator.signature(of: $0) }).count == 5)

        var usage: [UUID: Int] = [:]
        for look in result {
            let s = slots(look)
            #expect(s.contains(.footwear))
            #expect(s.contains(.onePiece) || (s.contains(.top) && s.contains(.bottom)))
            for singleton in [OutfitSlot.bottom, .footwear, .onePiece, .midLayer, .outerwear] {
                #expect(s.filter { $0 == singleton }.count <= 1)
            }
            #expect(!look.explanation.isEmpty)
            for piece in look.items where OutfitSlot.of(piece) != .accessory {
                usage[piece.id, default: 0] += 1
            }
        }
        // Meaningfully different: no garment carries more than three of the five.
        #expect(usage.values.allSatisfy { $0 <= 3 })

        let validated = OutfitValidator.validateAndRepair(result, wardrobe: closet.all)
        #expect(validated.map { $0.items.map { $0.id } } == result.map { $0.items.map { $0.id } })
    }

    @Test("Cold weather always adds outerwear and skips shorts / sandals")
    func coldWeatherAddsOuterwear() {
        let result = looks(closet.all, context(3, condition: "Cloudy"))
        #expect(result.count == 5)
        for look in result {
            #expect(slots(look).contains(.outerwear))
            #expect(!look.items.contains { $0.product == "Shorts" || $0.product == "Sandals" })
        }
    }

    @Test("Hot weather drops coats and knits")
    func hotWeatherDropsLayers() {
        let result = looks(closet.all, context(32, condition: "Clear sky"))
        #expect(!result.isEmpty)
        for look in result {
            #expect(!slots(look).contains(.midLayer))
            #expect(!slots(look).contains(.outerwear))
        }
    }

    @Test("Formal plans skip sneakers and joggers when dressier pieces exist")
    func formalOccasionSkipsAthleisure() {
        let result = looks(closet.all, context(18, occasion: .formal))
        #expect(!result.isEmpty)
        let casual: Set<String> = ["Sneakers", "Joggers", "Sweatpants", "Graphic Tees", "Shorts"]
        for look in result {
            #expect(!look.items.contains { casual.contains($0.product) })
        }
    }

    @Test("A one-piece is never paired with a separate bottom or top")
    func onePieceNeverWithBottom() {
        let dresses = [
            item(.onePieces, "Dresses", ["Black"]),
            item(.onePieces, "Wrap Dresses", ["Burgundy"]),
            item(.onePieces, "Jumpsuits", ["Olive"])
        ]
        let wardrobe = closet.all + dresses
        var styledOnePiece = false
        for seed in UInt64(1)...UInt64(12) {
            for look in looks(wardrobe, context(20, occasion: .date), seed: seed) {
                let s = slots(look)
                guard s.contains(.onePiece) else { continue }
                styledOnePiece = true
                #expect(!s.contains(.bottom))
                #expect(!s.contains(.top))
            }
        }
        #expect(styledOnePiece)
    }

    @Test("Shuffling a slot returns a different item of the same slot")
    func shuffleSwapsWithinSlot() throws {
        let ctx = context(18)
        let engine = OutfitEngine()
        let first = try #require(looks(closet.all, ctx).first)
        let top = try #require(first.items.first { OutfitSlot.of($0) == .top })

        let shuffled = try #require(engine.shuffle(top, in: first, wardrobe: closet.all, context: ctx, seed: 7))
        let newTops = shuffled.items.filter { OutfitSlot.of($0) == .top }
        #expect(newTops.count == 1)
        #expect(newTops.first?.id != top.id)

        // The rest of the look stays put.
        let others = Set(first.items.filter { $0.id != top.id }.map { $0.id })
        #expect(others.isSubset(of: Set(shuffled.items.map { $0.id })))

        // With every other top excluded there is nothing to shuffle to.
        let allTops = Set(closet.all.filter { $0.category == .tops }.map { $0.id })
        #expect(engine.shuffle(top, in: first, wardrobe: closet.all, context: ctx, excluding: allTops, seed: 7) == nil)
    }

    @Test("Adding a piece swaps a filled singleton slot instead of doubling it")
    func addSwapsSingleton() throws {
        let ctx = context(18)
        let first = try #require(looks(closet.all, ctx).first)
        let engine = OutfitEngine()
        let wearsLoafers = first.items.contains(where: { $0.product == "Loafers" })
        let product = wearsLoafers ? "Chelsea Boots" : "Loafers"
        let updated = try #require(engine.add(category: .footwear, productType: product, to: first,
                                              wardrobe: closet.all, context: ctx, seed: 3))
        let shoes = updated.items.filter { OutfitSlot.of($0) == .footwear }
        #expect(shoes.count == 1)
        #expect(shoes.first?.product == product)
    }

    @Test("Minimal mood prefers neutrals")
    func minimalMoodPrefersNeutrals() {
        func neutralShare(_ looks: [Outfit]) -> Double {
            let clothes = looks.flatMap { $0.items }.filter { OutfitSlot.of($0) != .accessory }
            let neutral = clothes.filter { piece in piece.colors.allSatisfy { StylePalette.isNeutral($0) } }
            return Double(neutral.count) / Double(max(1, clothes.count))
        }
        let minimal = looks(closet.all, context(18, mood: .minimal))
        let bold = looks(closet.all, context(18, mood: .bold))
        #expect(!minimal.isEmpty && !bold.isEmpty)
        #expect(neutralShare(minimal) > neutralShare(bold))
        #expect(neutralShare(minimal) >= 0.7)
    }

    @Test("Recently worn pieces are de-prioritised")
    func recentlyWornIsDeprioritised() throws {
        let fresh = looks(closet.all, context(18))
        let firstLook = try #require(fresh.first)
        let worn = firstLook.items.filter { piece in
            let slot = OutfitSlot.of(piece)
            return slot == .top || slot == .bottom
        }
        #expect(worn.count == 2)
        let wornIDs = Set(worn.map { $0.id })

        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: noon))
        let log = Dictionary(uniqueKeysWithValues: worn.map { ($0.id, yesterday) })
        let afterWearing = looks(closet.all, context(18, lastWorn: log))

        let top = try #require(afterWearing.first)
        #expect(top.items.allSatisfy { !wornIDs.contains($0.id) })

        func uses(_ batch: [Outfit]) -> Int {
            batch.reduce(0) { total, look in total + look.items.filter { wornIDs.contains($0.id) }.count }
        }
        #expect(uses(afterWearing) < uses(fresh))
    }

    @Test("A fixed seed is deterministic; new seeds give new options")
    func seededDeterminism() {
        let ctx = context(14, mood: .cozy)
        let a = looks(closet.all, ctx, seed: 2024)
        let b = looks(closet.all, ctx, seed: 2024)
        #expect(!a.isEmpty)
        #expect(a.map { $0.items.map { $0.id } } == b.map { $0.items.map { $0.id } })
        #expect(a.map { $0.explanation } == b.map { $0.explanation })

        var firstLooks = Set<String>()
        for seed in UInt64(1)...UInt64(10) {
            if let first = looks(closet.all, ctx, seed: seed).first {
                firstLooks.insert(OutfitValidator.signature(of: first))
            }
        }
        #expect(firstLooks.count > 1)
    }

    @Test("Locked pieces stay in every look")
    func lockedPiecesStay() {
        let result = looks(closet.all, context(8), locked: [closet.camelCoat, closet.jeans])
        #expect(!result.isEmpty)
        for look in result {
            #expect(look.items.contains(closet.camelCoat))
            #expect(look.items.contains(closet.jeans))
        }
    }

    @Test("Free text becomes structured hints on-device")
    func parsesFreeText() {
        let office = StyleIntentParser.parse("Something in blue for a client meeting, no sneakers please")
        #expect(office.occasion == .business)
        #expect(office.preferredColors.contains("blue"))
        #expect(office.avoidedProducts.contains("sneakers"))

        let home = StyleIntentParser.parse("cozy work from home day, it's freezing")
        #expect(home.occasion == .loungewear)
        #expect(home.moods.contains(.cozy))
        #expect(home.temperatureC == 0)

        let gym = StyleIntentParser.parse("gym then errands")
        #expect(gym.wantsActive)
    }

    @Test("A requested colour leads the looks")
    func requestedColourLeads() throws {
        let hints = StyleIntentParser.parse("something in red")
        let result = looks(closet.all, context(18, hints: hints))
        let first = try #require(result.first)
        #expect(first.items.contains { $0.colors.contains("Red") })
    }
}
