import Testing
import Foundation
@testable import StyleMate

// The stylist's notes (OutfitEngine explanations): varied closers, no phrase repeated within a
// deck of five, and no "pops against" between garments of one colour family (review D2).

private func item(_ category: StyleMate.Category, _ product: String, _ colors: [String],
                  pattern: Pattern = .solid, material: String? = nil,
                  sleeve: SleeveLength? = nil) -> WardrobeItem {
    WardrobeItem(category: category, product: product, colors: colors, brand: "", pattern: pattern,
                 imagePath: "test_\(UUID().uuidString).jpg", material: material, sleeveLength: sleeve)
}

private let noon: Date = {
    let base = Date(timeIntervalSince1970: 1_767_000_000)
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
}()

/// Neutral basics, a few colours, layers for every temperature, shoes for every formality.
private let closet: [WardrobeItem] = [
    item(.tops, "T-Shirts", ["White"]), item(.tops, "T-Shirts", ["Black"]), item(.tops, "Graphic Tees", ["Grey"]),
    item(.tops, "Button-Down Shirts", ["Navy"], sleeve: .longSleeve), item(.tops, "Shirts", ["Light Blue"], sleeve: .longSleeve),
    item(.tops, "Blouses", ["Cream"], material: "Silk"), item(.tops, "Polo T-Shirts", ["Red"]),
    item(.tops, "T-Shirts", ["Yellow"]), item(.tops, "Wrap Tops", ["Hot Pink"], pattern: .floral),
    item(.bottoms, "Jeans", ["Blue"]), item(.bottoms, "Trousers", ["Black"], material: "Wool"),
    item(.bottoms, "Chinos", ["Beige"]), item(.bottoms, "Joggers", ["Grey"], material: "Fleece"),
    item(.bottoms, "Shorts", ["Khaki"]), item(.bottoms, "Skirts", ["Black"]),
    item(.midLayers, "Sweaters", ["Navy"], material: "Wool"), item(.midLayers, "Hoodies", ["Grey"]),
    item(.midLayers, "Cardigans", ["Camel"]),
    item(.outerwear, "Coats", ["Camel"], material: "Wool"), item(.outerwear, "Leather Jackets", ["Black"], material: "Leather"),
    item(.outerwear, "Blazers", ["Navy"]), item(.outerwear, "Trench Coats", ["Beige"]),
    item(.outerwear, "Puffer Jackets", ["Black"]),
    item(.footwear, "Sneakers", ["White"]), item(.footwear, "Oxford Shoes", ["Black"], material: "Leather"),
    item(.footwear, "Chelsea Boots", ["Brown"], material: "Leather"), item(.footwear, "Sandals", ["Tan"]),
    item(.footwear, "Loafers", ["Black"], material: "Leather"),
    item(.accessories, "Watches", ["Silver"]), item(.accessories, "Sunglasses", ["Black"]),
]

private func deck(_ wardrobe: [WardrobeItem], temperature: Double, occasion: OutfitType?, mood: OutfitMood?,
                  hints: StyleHints = StyleHints(), seed: UInt64) -> [Outfit] {
    let context = StylingContext(temperatureC: temperature, condition: "Partly cloudy", isDaytime: true,
                                 occasion: occasion, mood: mood, hints: hints, now: noon)
    guard case .success(let looks) = OutfitEngine().suggest(from: wardrobe, context: context, seed: seed) else { return [] }
    return looks
}

/// "Lead — story. Closer." → the closing sentence, if the note has one.
private func closer(_ note: String) -> String? {
    let sentences = note.components(separatedBy: ". ")
    guard sentences.count >= 2, let last = sentences.last else { return nil }
    return last.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
}

/// The weather lead before the em dash, if any.
private func lead(_ note: String) -> String? {
    let parts = note.components(separatedBy: " — ")
    return parts.count >= 2 ? parts[0] : nil
}

@Suite("Stylist notes")
struct StylistNoteTests {

    @Test("Every mood has three or four closers in each register, the first one the classic")
    func moodsHaveSeveralClosers() {
        for mood in OutfitMood.allCases {
            for occasion in [OutfitType.everyday, .business] {
                let list = mood.closers(for: occasion)
                #expect((3...4).contains(list.count), "\(mood) / \(occasion): \(list.count) closers")
                #expect(Set(list).count == list.count)
                #expect(list.first == mood.closer(for: occasion))
            }
        }
        for occasion in OutfitType.allCases {
            #expect(occasion.stylistPhrases.count >= 3)
            #expect(occasion.stylistPhrases.first == occasion.stylistPhrase)
        }
    }

    @Test("No closer, weather lead or whole note repeats within a deck (many decks)")
    func noRepeatsWithinADeck() {
        var decks = 0
        for mood in [nil] + OutfitMood.allCases.map(Optional.some) {
            for occasion in [OutfitType.everyday, .business, .date, .party] {
                for temperature in [2.0, 14, 20, 31] {
                    for seed in UInt64(1)...4 {
                        let looks = deck(closet, temperature: temperature, occasion: occasion, mood: mood, seed: seed)
                        guard looks.count == 5 else { continue }
                        decks += 1
                        let notes = looks.map(\.explanation)
                        #expect(Set(notes).count == notes.count, "Repeated note in \(notes)")
                        let closers = notes.compactMap(closer)
                        #expect(Set(closers).count == closers.count, "Repeated closer (\(String(describing: mood)), \(occasion), \(temperature)°): \(closers)")
                        let leads = notes.compactMap(lead)
                        #expect(Set(leads).count == leads.count, "Repeated weather lead: \(leads)")
                    }
                }
            }
        }
        #expect(decks >= 500)
    }

    @Test("A confident everyday deck no longer ends four looks on the same line")
    func confidentEverydayVaries() {
        var seen = Set<String>()
        for seed in UInt64(1)...30 {
            let looks = deck(closet, temperature: 18, occasion: .everyday, mood: .confident, seed: seed)
            let closers = looks.compactMap { closer($0.explanation) }
            #expect(closers.filter { $0 == "Easy, with a little swagger" }.count <= 1)
            seen.formUnion(closers)
        }
        #expect(seen.count >= 4, "Only \(seen) across 30 decks")
    }

    @Test("A requested colour is acknowledged, but not five times over")
    func requestedColourVaries() {
        var hints = StyleHints()
        hints.preferredColors = ["red"]
        for seed in UInt64(1)...10 {
            let looks = deck(closet, temperature: 18, occasion: .everyday, mood: nil, hints: hints, seed: seed)
            let closers = looks.compactMap { closer($0.explanation) }
            #expect(Set(closers).count == closers.count, "\(closers)")
        }
    }

    @Test("Light blue, denim and navy are one colour family; black, white and red aren't")
    func colourFamilies() throws {
        func p(_ category: StyleMate.Category, _ product: String, _ colour: String) throws -> ItemProfile {
            try #require(ItemProfile(item(category, product, [colour]), order: 0))
        }
        let lightBlueShirt = try p(.tops, "Shirts", "Light Blue")
        let jeans = try p(.bottoms, "Jeans", "Blue")
        let navyTrousers = try p(.bottoms, "Trousers", "Navy")
        #expect(StyleVocabulary.sameColourFamily(lightBlueShirt, jeans))
        #expect(StyleVocabulary.sameColourFamily(lightBlueShirt, navyTrousers))
        #expect(!StyleVocabulary.sameColourFamily(try p(.tops, "T-Shirts", "Red"), jeans))
        #expect(!StyleVocabulary.sameColourFamily(lightBlueShirt, try p(.bottoms, "Trousers", "Black")))
        #expect(!StyleVocabulary.sameColourFamily(lightBlueShirt, try p(.bottoms, "Chinos", "White")))
    }

    @Test("Nothing 'pops against' a garment of the same colour family")
    func noPopsBetweenSimilarColours() {
        // Every possible core here pairs a blue top with a blue bottom.
        let blues = [
            item(.tops, "Shirts", ["Light Blue"], sleeve: .longSleeve), item(.tops, "T-Shirts", ["Light Blue"]),
            item(.tops, "Polo T-Shirts", ["Blue"]),
            item(.bottoms, "Jeans", ["Blue"]), item(.bottoms, "Trousers", ["Navy"]),
            item(.footwear, "Sneakers", ["White"]), item(.footwear, "Loafers", ["Brown"], material: "Leather"),
        ]
        var notes: [String] = []
        for mood in [nil] + OutfitMood.allCases.map(Optional.some) {
            for seed in UInt64(1)...12 {
                notes += deck(blues, temperature: 20, occasion: .everyday, mood: mood, seed: seed).map(\.explanation)
            }
        }
        #expect(notes.count > 100)
        for note in notes {
            for contrast in ["pops against", "pop against", "does the talking", "one hit of colour"] {
                #expect(!note.contains(contrast), "Contrast phrase between blues: \(note)")
            }
        }
        #expect(notes.contains { $0.contains("colour family") || $0.contains("tone on tone") || $0.contains("tonal pairing") })
    }

    @Test("A real contrast still gets its 'pops against'")
    func contrastStillPops() {
        let look = [
            item(.tops, "T-Shirts", ["Red"]), item(.bottoms, "Jeans", ["Blue"]), item(.footwear, "Sneakers", ["White"]),
        ]
        let notes = (UInt64(1)...40).flatMap { deck(look, temperature: 20, occasion: .everyday, mood: nil, seed: $0) }
            .map(\.explanation)
        #expect(notes.contains { $0.contains("pops against the blue jeans") || $0.contains("does the talking")
            || $0.contains("one hit of colour") })
    }
}
