import Foundation
import Testing
@testable import StyleMate

/// The Nov 2026 hardening pass: wardrobe storage that can't lose pieces, the one product
/// singulariser, and the smaller reliability fixes that a unit test can prove.
struct HardeningTests {

    // MARK: - Wardrobe storage (P1-5)

    private static func entry(id: UUID = UUID(), category: String = "Tops", product: String = "T-Shirts",
                              pattern: String = "Solid", dropping: Set<String> = []) -> [String: Any] {
        var e: [String: Any] = ["id": id.uuidString, "category": category, "product": product,
                                "colors": ["White"], "brand": "", "pattern": pattern,
                                "imagePath": "\(id.uuidString).png", "thumbnailPath": "thumb_\(id.uuidString).png"]
        for k in dropping { e[k] = nil }
        return e
    }

    private static func blob(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }

    private static func product(in raw: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["product"] as? String
    }

    @Test func unknownCategoryKeepsTheRestAndTheEntry() throws {
        let data = try Self.blob([Self.entry(), Self.entry(category: "Swimwear", product: "Bikinis"), Self.entry()])
        let decoded = WardrobeStorage.decode(data)
        #expect(decoded.isArray)
        #expect(decoded.items.count == 2)
        #expect(decoded.unreadable.count == 1)

        // Writing back keeps the unreadable entry exactly, after the readable ones.
        let saved = try #require(WardrobeStorage.encode(decoded.items, keeping: decoded.unreadable))
        let again = WardrobeStorage.decode(saved)
        #expect(again.items.map(\.id) == decoded.items.map(\.id))
        #expect(again.unreadable.count == 1)
        #expect(Self.product(in: again.unreadable[0]) == "Bikinis")
    }

    @Test func unknownPatternOrMissingKeyKeepsTheRest() throws {
        let data = try Self.blob([
            Self.entry(),
            Self.entry(pattern: "Ikat"),
            Self.entry(product: "Jeans", dropping: ["product"]),     // a required key missing
            Self.entry(product: "Shirts", dropping: ["brand", "colors"]),   // optional detail missing: still read
        ])
        let decoded = WardrobeStorage.decode(data)
        #expect(decoded.items.count == 2)
        #expect(decoded.items.last?.product == "Shirts")
        #expect(decoded.items.last?.brand == "")
        #expect(decoded.items.last?.colors == [])
        #expect(decoded.unreadable.count == 2)
    }

    @Test func emptyAndGarbageBlobs() throws {
        #expect(WardrobeStorage.decode(try Self.blob([])).items.isEmpty)
        let garbage = WardrobeStorage.decode(Data("not json".utf8))
        #expect(!garbage.isArray)
        // Non-object entries are kept too (they could be nothing else, but nothing is dropped).
        let odd = WardrobeStorage.decode(try JSONSerialization.data(withJSONObject: [Self.entry(), "x", 3] as [Any]))
        #expect(odd.items.count == 1)
        #expect(odd.unreadable.count == 2)
    }

    /// The whole path: load must not write, and the first real change keeps what wasn't read.
    @Test func loadingNeverShrinksTheStoredCloset() throws {
        let user = "hardening-\(UUID().uuidString)"
        let key = WardrobeViewModel.storageKey(for: user)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: WardrobeViewModel.unreadableBackupKey(for: user))
            SyncLedger.remove(userKey: key)
        }
        let stored = try Self.blob([Self.entry(), Self.entry(category: "Hats"), Self.entry(pattern: "Ikat")])
        UserDefaults.standard.set(stored, forKey: key)

        let vm = WardrobeViewModel()
        vm.load(forUser: user)
        #expect(vm.items.count == 1)
        #expect(vm.unreadableEntries.count == 2)
        #expect(UserDefaults.standard.data(forKey: key) == stored)   // loading wrote nothing

        vm.items.append(WardrobeItem(category: .bottoms, product: "Jeans", colors: ["Blue"], brand: "",
                                     pattern: .solid, imagePath: "jeans.png"))
        let after = WardrobeStorage.decode(try #require(UserDefaults.standard.data(forKey: key)))
        #expect(after.items.count == 2)
        #expect(after.unreadable.count == 2)

        // A relaunch sees the same.
        let relaunched = WardrobeViewModel()
        relaunched.load(forUser: user)
        #expect(relaunched.items.count == 2)
        #expect(relaunched.unreadableEntries.count == 2)
    }

    @Test func unreadableBlobIsBackedUpBeforeAnySave() throws {
        let user = "hardening-\(UUID().uuidString)"
        let key = WardrobeViewModel.storageKey(for: user)
        let backup = WardrobeViewModel.unreadableBackupKey(for: user)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: backup)
            SyncLedger.remove(userKey: key)
        }
        let corrupt = Data("{\"half\": [".utf8)
        UserDefaults.standard.set(corrupt, forKey: key)

        let vm = WardrobeViewModel()
        vm.load(forUser: user)
        #expect(vm.items.isEmpty)
        #expect(UserDefaults.standard.data(forKey: backup) == corrupt)
        vm.items.append(WardrobeItem(category: .tops, product: "Shirts", colors: [], brand: "",
                                     pattern: .solid, imagePath: "shirt.png"))
        #expect(UserDefaults.standard.data(forKey: backup) == corrupt)   // still there after the save
    }

    // MARK: - Product singulariser (P1-3)

    /// Every catalogue product, as one piece. Shoes are singular in the closet but stay plural
    /// in the studio prompt (see `studioKeepsShoesPlural`).
    static let expectedSingular: [String: String] = [
        // Tops
        "T-Shirts": "T-Shirt", "Polo T-Shirts": "Polo T-Shirt", "Shirts": "Shirt", "Button-Down Shirts": "Button-Down Shirt",
        "Flannel Shirts": "Flannel Shirt", "Blouses": "Blouse", "Henley": "Henley", "Tank Tops": "Tank Top",
        "Camisoles": "Camisole", "Crop Tops": "Crop Top", "Tube Tops": "Tube Top", "Off-Shoulder Tops": "Off-Shoulder Top",
        "Halter Tops": "Halter Top", "Bandeau": "Bandeau", "Peplum Tops": "Peplum Top", "Corset Tops": "Corset Top",
        "Wrap Tops": "Wrap Top", "Bustiers": "Bustier", "Bodysuits": "Bodysuit", "Graphic Tees": "Graphic Tee",
        "Mesh Tops": "Mesh Top", "Turtlenecks": "Turtleneck", "Tunics": "Tunic",
        // Bottoms
        "Jeans": "Jeans", "Trousers": "Trousers", "Chinos": "Chinos", "Cargo Pants": "Cargo Pants",
        "Wide-Leg Pants": "Wide-Leg Pants", "Palazzo Pants": "Palazzo Pants", "Linen Pants": "Linen Pants",
        "Sweatpants": "Sweatpants", "Joggers": "Joggers", "Leggings": "Leggings", "Shorts": "Shorts",
        "Capris": "Capris", "Culottes": "Culottes", "Skirts": "Skirt", "Mini Skirts": "Mini Skirt", "Skorts": "Skort",
        // Mid-layers
        "Hoodies": "Hoodie", "Sweatshirts": "Sweatshirt", "Sweaters": "Sweater", "Cardigans": "Cardigan",
        "Pullovers": "Pullover", "Fleece Jackets": "Fleece Jacket", "Vests": "Vest", "Gilets": "Gilet",
        "Quarter-Zips": "Quarter-Zip", "Shrugs": "Shrug", "Ponchos": "Poncho",
        // Outerwear
        "Jackets": "Jacket", "Leather Jackets": "Leather Jacket", "Denim Jackets": "Denim Jacket",
        "Bomber Jackets": "Bomber Jacket", "Puffer Jackets": "Puffer Jacket", "Coats": "Coat", "Overcoats": "Overcoat",
        "Trench Coats": "Trench Coat", "Blazers": "Blazer", "Parkas": "Parka", "Windbreakers": "Windbreaker",
        "Raincoats": "Raincoat", "Shirt Jackets": "Shirt Jacket", "Capes": "Cape",
        // One-pieces
        "Dresses": "Dress", "Wrap Dresses": "Wrap Dress", "Maxi Dresses": "Maxi Dress", "Shirt Dresses": "Shirt Dress",
        "Gowns": "Gown", "Jumpsuits": "Jumpsuit", "Rompers": "Romper", "Playsuits": "Playsuit",
        "Dungarees": "Dungarees", "Overalls": "Overalls",
        // Footwear
        "Sneakers": "Sneaker", "Boots": "Boot", "Ankle Boots": "Ankle Boot", "Chelsea Boots": "Chelsea Boot",
        "Sandals": "Sandal", "Slides": "Slides", "Espadrilles": "Espadrilles", "Loafers": "Loafer",
        "Oxford Shoes": "Oxford Shoe", "Formal Shoes": "Formal Shoe", "Mules": "Mule", "Flats": "Flats",
        "Heels": "Heels", "Platform Shoes": "Platform Shoe", "Clogs": "Clog", "Slippers": "Slipper",
        // Accessories
        "Sunglasses": "Sunglasses", "Eyeglasses": "Eyeglasses", "Reading Glasses": "Reading Glasses",
        "Baseball Caps": "Baseball Cap", "Beanies": "Beanie", "Fedoras": "Fedora", "Bucket Hats": "Bucket Hat",
        "Sun Hats": "Sun Hat", "Visors": "Visor", "Bandanas": "Bandana", "Turbans": "Turban", "Headbands": "Headband",
        "Berets": "Beret", "Watches": "Watch", "Bracelets": "Bracelet", "Rings": "Ring", "Necklaces": "Necklace",
        "Earrings": "Earring", "Pendants": "Pendant", "Chains": "Chain", "Anklets": "Anklet", "Cufflinks": "Cufflink",
        "Brooches": "Brooch", "Scarves": "Scarf", "Ties": "Tie", "Bowties": "Bowtie", "Gloves": "Glove",
        "Belts": "Belt", "Suspenders": "Suspenders", "Pocket Squares": "Pocket Square",
        "Hair Accessories": "Hair Accessory", "Handbags": "Handbag", "Tote Bags": "Tote Bag",
        "Crossbody Bags": "Crossbody Bag", "Backpacks": "Backpack", "Wallets": "Wallet", "Clutches": "Clutch",
        "Fanny Packs": "Fanny Pack", "Briefcases": "Briefcase", "Messenger Bags": "Messenger Bag",
        // Innerwear
        "Underwear": "Underwear", "Boxers": "Boxers", "Briefs": "Briefs", "Undershirts": "Undershirt",
        "Bras": "Bra", "Bralettes": "Bralette", "Thongs": "Thong", "Socks": "Sock", "Thermal Wear": "Thermal Wear",
        "Shapewear": "Shapewear", "Lingerie": "Lingerie",
        // Activewear
        "Athletic Tops": "Athletic Top", "Athletic Shorts": "Athletic Shorts", "Running Shorts": "Running Shorts",
        "Cycling Shorts": "Cycling Shorts", "Track Pants": "Track Pants", "Active Jackets": "Active Jacket",
        "Compression Wear": "Compression Wear", "Rashguards": "Rashguard", "Sports Bras": "Sports Bra",
        "Active Leggings": "Active Leggings", "Yoga Pants": "Yoga Pants", "Swim Trunks": "Swim Trunks",
        "Swimwear": "Swimwear", "Tennis Dresses": "Tennis Dress",
        // Ethnic wear
        "Kurta": "Kurta", "Sherwani": "Sherwani", "Nehru Jacket": "Nehru Jacket", "Dhoti": "Dhoti", "Lungis": "Lungi",
        "Mundu": "Mundu", "Jodhpuri Suit": "Jodhpuri Suit", "Pathani Suit": "Pathani Suit", "Bandhgala": "Bandhgala",
        "Angrakha": "Angrakha", "Kurti": "Kurti", "Saree": "Saree", "Blouse (saree)": "Blouse (saree)",
        "Lehenga": "Lehenga", "Choli": "Choli", "Dupatta": "Dupatta", "Salwar": "Salwar",
        "Patiala Pants": "Patiala Pants", "Anarkali": "Anarkali", "Churidar": "Churidar", "Palazzo Suit": "Palazzo Suit",
        "Sharara": "Sharara", "Ghagra": "Ghagra",
    ]

    /// Every product the on-device labeler can emit (scripts/fashion_vocabulary.json).
    private static func vocabularyProducts() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fashion_vocabulary.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var out = Set<String>()
        for case let head as [String: Any] in json.values {
            for case let pair as [Any] in (head["labels"] as? [Any]) ?? [] {
                guard let label = pair.first as? String, label.contains("|") else { continue }
                out.insert(String(label.split(separator: "|")[1]))
            }
        }
        return out
    }

    @Test func everyCatalogueProductHasItsSingular() throws {
        let catalogue = Set(productTypesByCategory.values.flatMap { $0 })
        let all = catalogue.union(try Self.vocabularyProducts())
        #expect(all.count > 150)
        for product in all {
            let expected = try #require(Self.expectedSingular[product], "no expected singular for \(product)")
            #expect(ProductNoun.singular(product) == expected, "\(product)")
            #expect(ClosetText.displayProduct(product) == expected, "\(product)")
        }
    }

    @Test func itemNamesUseTheSameSingular() {
        let scarf = WardrobeItem(category: .accessories, product: "Scarves", colors: ["Black"], brand: "",
                                 pattern: .solid, imagePath: "s.png")
        #expect(scarf.displayProduct == "Scarf")
        #expect(scarf.name == "Black Scarf")
        #expect(ClosetText.displayName(scarf) == "Black Scarf")
        let pants = WardrobeItem(category: .activewear, product: "Yoga Pants", colors: ["Gray"], brand: "",
                                 pattern: .solid, imagePath: "p.png")
        #expect(pants.name == "Gray Yoga Pants")
        let bag = WardrobeItem(category: .accessories, product: "Hair Accessories", colors: [], brand: "",
                               pattern: .solid, imagePath: "h.png")
        #expect(bag.displayProduct == "Hair Accessory")
    }

    @Test func studioKeepsShoesPlural() {
        for shoe in productTypesByCategory[.footwear] ?? [] {
            #expect(ProductNoun.singular(shoe, keepingPairs: true) == shoe, "\(shoe)")
        }
        #expect(ProductNoun.singular("Scarves", keepingPairs: true) == "Scarf")
        #expect(ProductNoun.singular("Track Pants", keepingPairs: true) == "Track Pants")
    }

    @Test func searchWordsMatchIrregularPlurals() {
        #expect(ClosetText.words("Scarves") == ["scarf"])
        #expect(ClosetText.words("scarf") == ["scarf"])
        #expect(ClosetText.words("Hair Accessories") == ["hair", "accessory"])
    }
}
