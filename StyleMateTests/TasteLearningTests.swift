import Testing
import Foundation
@testable import StyleMate

// Taste learning (Services/Outfits/TasteProfile + the taste term in OutfitEngine): learning
// moves choices the expected way on synthetic histories, and never makes a deck worse than
// the taste-free stylist's: the top option stays right for the weather and the occasion.

private func item(_ category: StyleMate.Category, _ product: String, _ colors: [String],
                  material: String? = nil, length: GarmentLength? = nil) -> WardrobeItem {
    WardrobeItem(category: category, product: product, colors: colors, brand: "", pattern: .solid,
                 imagePath: "test_\(UUID().uuidString).jpg", material: material, garmentLength: length)
}

private let noon: Date = {
    let base = Date(timeIntervalSince1970: 1_767_000_000)
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
}()

/// Four neutral tops × four neutral bottoms: on colour alone no core stands out.
private struct Basics {
    let navyTee = item(.tops, "T-Shirts", ["Navy"])
    let whiteTee = item(.tops, "T-Shirts", ["White"])
    let blackTee = item(.tops, "T-Shirts", ["Black"])
    let oliveTee = item(.tops, "T-Shirts", ["Olive"])
    let greyTrousers = item(.bottoms, "Trousers", ["Grey"])
    let beigeChinos = item(.bottoms, "Chinos", ["Beige"])
    let blackJeans = item(.bottoms, "Jeans", ["Black"])
    let blueJeans = item(.bottoms, "Jeans", ["Blue"])
    let sneakers = item(.footwear, "Sneakers", ["White"])
    let loafers = item(.footwear, "Loafers", ["Brown"], material: "Leather")

    var all: [WardrobeItem] {
        [navyTee, whiteTee, blackTee, oliveTee, greyTrousers, beigeChinos, blackJeans, blueJeans, sneakers, loafers]
    }
    var tops: [WardrobeItem] { [navyTee, whiteTee, blackTee, oliveTee] }
    var bottoms: [WardrobeItem] { [greyTrousers, beigeChinos, blackJeans, blueJeans] }
}

private func context(_ temperature: Double, occasion: OutfitType = .everyday, taste: TasteProfile? = nil,
                     condition: String = "Partly cloudy") -> StylingContext {
    var c = StylingContext(temperatureC: temperature, condition: condition, isDaytime: true,
                           occasion: occasion, now: noon)
    c.taste = taste
    return c
}

private func looks(_ wardrobe: [WardrobeItem], _ context: StylingContext, seed: UInt64) -> [Outfit] {
    guard case .success(let looks) = OutfitEngine().suggest(from: wardrobe, context: context, seed: seed) else { return [] }
    return looks
}

private func has(_ look: Outfit, _ pieces: WardrobeItem...) -> Bool {
    pieces.allSatisfy { p in look.items.contains { $0.id == p.id } }
}

@Suite("Taste learning")
struct TasteLearningTests {
    private let b = Basics()

    // MARK: The model

    @Test("Wearing a look adds its pieces, pairings and formality; each value stays bounded")
    func learningIsBounded() {
        var t = TasteProfile(updated: noon)
        let look = [b.navyTee, b.greyTrousers, b.sneakers]
        for _ in 0..<200 { t.learn(.wore, look: look, occasion: .everyday, now: noon) }
        #expect(t.pairs[TasteProfile.pairKey("navy", "gray")] == TasteProfile.Rules.maxEvidence)
        #expect(t.items[b.navyTee.id.uuidString] == TasteProfile.Rules.maxEvidence)
        #expect(t.pairs.count == 1)            // shoes don't make colour pairings
        let sample = t.formality[OutfitType.everyday.rawValue]
        #expect((sample?.weight ?? 0) <= TasteProfile.Rules.maxFormalityWeight)
        #expect(t.events == 200)

        for _ in 0..<200 { t.learn(.notMyStyle, look: look, occasion: .everyday, now: noon) }
        #expect(t.pairs.values.allSatisfy { abs($0) <= TasteProfile.Rules.maxEvidence })
        #expect(t.items.values.allSatisfy { abs($0) <= TasteProfile.Rules.maxEvidence })
    }

    @Test("The model stays small: entries are capped however much is learned")
    func entriesAreCapped() {
        var t = TasteProfile(updated: noon)
        let colours = ["Navy", "White", "Black", "Olive", "Grey", "Beige", "Red", "Pink", "Green", "Yellow",
                       "Purple", "Orange", "Teal", "Burgundy", "Cream", "Camel"]
        for i in 0..<400 {
            let look = [item(.tops, "T-Shirts", [colours[i % colours.count]]),
                        item(.bottoms, "Trousers", [colours[(i / colours.count) % colours.count]])]
            t.learn(.wore, look: look, occasion: .everyday, now: noon)
        }
        #expect(t.pairs.count <= TasteProfile.Rules.maxPairs)
        #expect(t.items.count <= TasteProfile.Rules.maxItems)
        let data = (try? JSONEncoder().encode(t)) ?? Data()
        #expect(data.count < 16_000, "\(data.count) bytes")
    }

    @Test("Evidence halves every 45 days and old habits fade away")
    func evidenceDecays() throws {
        var t = TasteProfile(updated: noon)
        t.learn(.wore, look: [b.navyTee, b.greyTrousers], occasion: .everyday, now: noon)
        let key = TasteProfile.pairKey("navy", "gray")
        let later = try #require(Calendar.current.date(byAdding: .day, value: 45, to: noon))
        let half = t.decayed(to: later).pairs[key] ?? 0
        #expect(abs(half - 0.5) < 0.01)
        let muchLater = try #require(Calendar.current.date(byAdding: .day, value: 400, to: noon))
        #expect(t.decayed(to: muchLater).isEmpty)
    }

    @Test("Keep, then un-keep, cancels out; a swap only marks the swapped-out piece")
    func keepAndSwap() {
        var t = TasteProfile(updated: noon)
        let look = [b.navyTee, b.greyTrousers, b.sneakers]
        t.learn(.kept, look: look, piece: b.navyTee, occasion: .everyday, now: noon)
        #expect((t.items[b.navyTee.id.uuidString] ?? 0) > 0)
        t.learn(.unkept, look: look, piece: b.navyTee, occasion: .everyday, now: noon)
        #expect(t.items[b.navyTee.id.uuidString] == nil)

        t.learn(.swappedOut, look: look, piece: b.greyTrousers, occasion: .everyday, now: noon)
        #expect((t.items[b.greyTrousers.id.uuidString] ?? 0) < 0)
        #expect(t.items[b.navyTee.id.uuidString] == nil)
        #expect((t.pairs[TasteProfile.pairKey("navy", "gray")] ?? 0) < 0)
    }

    @Test("A store keeps one profile per user and resets it")
    func storePerUser() throws {
        let name = "taste-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TasteStore(defaults: defaults)
        #expect(store.profile(forUser: "a") == nil)
        store.learn(.wore, look: [b.navyTee, b.greyTrousers], occasion: .everyday, forUser: "a", now: noon)
        #expect(store.profile(forUser: "a", now: noon) != nil)
        #expect(store.profile(forUser: "b", now: noon) == nil)
        #expect(store.events(forUser: "a") == 1)
        store.reset(forUser: "a")
        #expect(store.profile(forUser: "a") == nil)
        #expect(store.events(forUser: "a") == 0)
    }

    // MARK: Learning moves choices

    @Test("Wearing navy with grey makes the stylist pick navy with grey more often")
    func woreShiftsTowardPairing() {
        var t = TasteProfile(updated: noon)
        for _ in 0..<5 {
            t.learn(.wore, look: [b.navyTee, b.greyTrousers, b.sneakers], occasion: .everyday, now: noon)
        }
        var before = 0, after = 0, inDeck = 0
        let seeds = UInt64(1)...40
        for seed in seeds {
            if let first = looks(b.all, context(18), seed: seed).first, has(first, b.navyTee, b.greyTrousers) { before += 1 }
            let learned = looks(b.all, context(18, taste: t), seed: seed)
            if let first = learned.first, has(first, b.navyTee, b.greyTrousers) { after += 1 }
            if learned.contains(where: { has($0, b.navyTee, b.greyTrousers) }) { inDeck += 1 }
        }
        #expect(after >= before + 8, "before \(before), after \(after) of 40")
        #expect(after >= 16, "after \(after) of 40")
        #expect(inDeck >= 34, "in the deck \(inDeck) of 40")
    }

    @Test("'Not my style' on a piece's looks shows it less")
    func notMyStyleShiftsAway() {
        var t = TasteProfile(updated: noon)
        for bottom in b.bottoms {
            t.learn(.notMyStyle, look: [b.oliveTee, bottom, b.sneakers], occasion: .everyday, now: noon)
        }
        // The option shown first (the deck of five has to reuse its four tops anyway).
        var before = 0, after = 0
        for seed in UInt64(1)...80 {
            if let first = looks(b.all, context(18), seed: seed).first, has(first, b.oliveTee) { before += 1 }
            if let first = looks(b.all, context(18, taste: t), seed: seed).first, has(first, b.oliveTee) { after += 1 }
        }
        #expect(before > 0)
        #expect(after < before, "olive tee first in \(before) decks before, \(after) after")
    }

    @Test("Dressing up a little for everyday makes everyday looks a little dressier, within the occasion")
    func formalityShiftsWithinBand() throws {
        let closet = b.all + [item(.tops, "Button-Down Shirts", ["White"]), item(.bottoms, "Trousers", ["Navy"], material: "Wool"),
                              item(.footwear, "Oxford Shoes", ["Black"], material: "Leather")]
        // Formality only: no piece or pairing evidence.
        var t = TasteProfile(updated: noon)
        t.formality[OutfitType.everyday.rawValue] = .init(mean: 3.6, weight: 8)
        let band = context(18).formalityTarget
        func meanFormality(_ taste: TasteProfile?) -> Double {
            var total = 0.0, n = 0.0
            for seed in UInt64(1)...40 {
                guard let first = looks(closet, context(18, taste: taste), seed: seed).first,
                      let mean = TasteProfile.lookFormality(first.items.compactMap { ItemProfile($0, order: 0) })
                else { continue }
                total += mean; n += 1
            }
            return total / max(1, n)
        }
        let plain = meanFormality(nil), learned = meanFormality(t)
        #expect(learned > plain, "mean formality \(plain) → \(learned)")
        #expect(learned <= band.upperBound + 0.3, "Learning pushed looks past the occasion's band (\(learned))")

        let notes = (UInt64(1)...20).flatMap { looks(closet, context(18, taste: t), seed: $0) }.compactMap(\.tasteNote)
        #expect(!notes.isEmpty)
        #expect(Set(notes) == ["Picked because you usually dress up a little for everyday"])
    }

    // MARK: Never worse

    @Test("A loved pair of shorts and sandals never tops a cool, wet day's deck")
    func tasteNeverBeatsTheWeather() {
        let shorts = item(.bottoms, "Shorts", ["Khaki"], length: .short)
        let sandals = item(.footwear, "Sandals", ["Tan"])
        let closet = b.all + [shorts, sandals, item(.outerwear, "Raincoats", ["Navy"])]
        var t = TasteProfile(updated: noon)
        for top in b.tops {
            for _ in 0..<6 { t.learn(.wore, look: [top, shorts, sandals], occasion: .everyday, now: noon) }
        }
        for temperature in [9.0, 12, 14] {
            for seed in UInt64(1)...25 {
                let deck = looks(closet, context(temperature, taste: t, condition: "Light rain"), seed: seed)
                let first = deck.first
                #expect(first != nil)
                #expect(!(first.map { has($0, shorts) } ?? true), "Shorts on top at \(temperature)°")
                #expect(!(first.map { has($0, sandals) } ?? true), "Sandals on top at \(temperature)°")
            }
        }
    }

    @Test("Taste never makes the top look invalid for the occasion")
    func tasteNeverBeatsTheOccasion() {
        let joggers = item(.bottoms, "Joggers", ["Grey"], material: "Fleece")
        let hoodie = item(.midLayers, "Hoodies", ["Grey"])
        let formal = [item(.tops, "Button-Down Shirts", ["White"]), item(.bottoms, "Trousers", ["Black"], material: "Wool"),
                      item(.footwear, "Oxford Shoes", ["Black"], material: "Leather"), item(.outerwear, "Blazers", ["Black"])]
        let closet = b.all + [joggers, hoodie] + formal
        var t = TasteProfile(updated: noon)
        for _ in 0..<6 { t.learn(.wore, look: [b.blackTee, joggers, hoodie, b.sneakers], occasion: .formal, now: noon) }
        for seed in UInt64(1)...25 {
            let first = looks(closet, context(15, occasion: .formal, taste: t), seed: seed).first
            #expect(first != nil)
            #expect(!(first.map { has($0, joggers) || has($0, hoodie) || has($0, b.sneakers) } ?? true),
                    "Lounge pieces on top of a formal deck")
        }
    }

    @Test("Taste only lifts looks inside the window: with a zero window the top look is the stylist's own")
    func windowBoundsThePromotion() {
        var t = TasteProfile(updated: noon)
        for _ in 0..<6 { t.learn(.wore, look: [b.oliveTee, b.blueJeans, b.loafers], occasion: .everyday, now: noon) }
        var closed = OutfitEngine.Weights()
        closed.tasteWindow = 0
        for temperature in [4.0, 18, 30] {
            for seed in UInt64(1)...15 {
                let plain = looks(b.all, context(temperature), seed: seed)
                let learned = looks(b.all, context(temperature, taste: t), seed: seed)
                #expect(plain.count == learned.count, "Learning changed how many looks the closet makes")
                guard case .success(let windowless) = OutfitEngine(weights: closed)
                    .suggest(from: b.all, context: context(temperature, taste: t), seed: seed) else {
                    Issue.record("No looks"); continue
                }
                #expect(windowless.first.map(OutfitValidator.signature) == plain.first.map(OutfitValidator.signature))
            }
        }
    }

    // MARK: Explanation

    @Test("A look shaped by a learned pairing says so in one line")
    func tasteNoteExplainsPairing() throws {
        var t = TasteProfile(updated: noon)
        for _ in 0..<4 { t.learn(.wore, look: [b.navyTee, b.greyTrousers], occasion: .everyday, now: noon) }
        var notes: [String] = []
        for seed in UInt64(1)...20 {
            for look in looks(b.all, context(18, taste: t), seed: seed) where has(look, b.navyTee, b.greyTrousers) {
                notes.append(try #require(look.tasteNote))
            }
        }
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0 == "Picked because you often wear navy with grey" }, "\(Set(notes))")

        // Nothing learned: no line at all.
        #expect(looks(b.all, context(18), seed: 3).allSatisfy { $0.tasteNote == nil })
    }

    @Test("The validator keeps the taste line")
    func validatorKeepsTasteNote() {
        let look = Outfit(items: [b.navyTee, b.greyTrousers, b.sneakers], explanation: "x", tasteNote: "Picked because y")
        let validated = OutfitValidator.validateAndRepair([look], wardrobe: b.all)
        #expect(validated.first?.tasteNote == "Picked because y")
    }

    // MARK: The deck (HomeViewModel)

    @MainActor
    @Test("Skip: 'Not today' teaches nothing, 'Not my style' teaches, no answer teaches a little")
    func skipChoices() throws {
        let userId = "taste-test-\(UUID().uuidString)"
        defer { TasteStore.shared.reset(forUser: userId) }
        let user = User(id: userId, email: nil, name: "Test", preferredStyles: [.everyday], notificationsEnabled: false,
                        dateCreated: noon, gender: nil, age: nil)
        let vm = HomeViewModel()
        let look = Outfit(items: [b.navyTee, b.greyTrousers, b.sneakers], explanation: "")

        func skipOnce() {
            vm.heroOutfit = look
            vm.openHeroInDeck(user: user)
            vm.skipCurrentOutfit()
        }

        skipOnce()
        #expect(vm.pendingSkip != nil)
        vm.answerSkip(notMyStyle: false)
        #expect(vm.pendingSkip == nil)
        #expect(TasteStore.shared.profile(forUser: userId) == nil, "Not today must not teach")

        skipOnce()
        vm.settlePendingSkip()
        let weak = try #require(TasteStore.shared.profile(forUser: userId))
        let weakPair = weak.pairs[TasteProfile.pairKey("navy", "gray")] ?? 0
        #expect(weakPair < 0)

        skipOnce()
        vm.answerSkip(notMyStyle: true)
        let strong = try #require(TasteStore.shared.profile(forUser: userId))
        #expect((strong.pairs[TasteProfile.pairKey("navy", "gray")] ?? 0) < weakPair * 3)
    }
}
