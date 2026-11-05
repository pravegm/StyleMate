#if DEBUG
import UIKit
import CoreData

/// DEBUG-only launch hooks for the XCUITest end-to-end suite (StyleMateUITests).
///
/// None of this is compiled into Release builds. It is driven purely by launch arguments:
///
/// - `-uiTestResetState`      wipe UserDefaults, wardrobe image files, scan checkpoints and the
///                            Core Data outfit log, so every test starts from a clean install.
///                            On its own (no demo user) it's a true first launch: a fresh local
///                            profile and the onboarding flow.
/// - `-uiTestDemoUser`        use a fixed local demo profile instead of the device's own.
/// - `-uiTestSkipOnboarding`  mark onboarding, the initial scan, the coach-mark tours and the
///                            swipe hint as done for the demo user.
/// - `-uiTestSeedWardrobe`    fill an empty wardrobe with ~26 realistic items whose images are
///                            transparent PNG cutouts drawn on the fly.
///
/// Called from `AuthService.init()` (the first object the app creates), so it runs before any
/// view model reads state.
@MainActor
enum DebugLaunchSupport {
    enum Argument {
        static let resetState = "-uiTestResetState"
        static let demoUser = "-uiTestDemoUser"
        static let skipOnboarding = "-uiTestSkipOnboarding"
        static let seedWardrobe = "-uiTestSeedWardrobe"
        /// `-uiTestSeedWardrobeCount 50`: seed exactly this many items (the catalog repeats).
        static let seedCount = "-uiTestSeedWardrobeCount"
        /// `-uiTestSeedLocked 23`: also seed this many pieces waiting for Premium (LockedItemsStore).
        static let seedLocked = "-uiTestSeedLocked"
        /// `-uiTestSeedTaste`: a learned taste profile (the seeded closet's colour pairings worn
        /// often), so the deck shows its "Picked because…" line.
        static let seedTaste = "-uiTestSeedTaste"
    }

    /// The integer after `flag` in the launch arguments (`-flag 50`), if any.
    static func intArgument(_ flag: String) -> Int? {
        let args = arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    static let demoUserID = "uitest-demo-user"

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// True when the app was launched by the UI-test suite with a demo user.
    static var isUITestSession: Bool { arguments.contains(Argument.demoUser) }

    /// Applies every requested hook. Returns the demo user to sign in, or nil when
    /// `-uiTestDemoUser` was not passed (normal launch: nothing happens at all).
    static func applyIfNeeded() -> User? {
        // Idempotent: reset + seed run once per process even if several AuthServices are created.
        if didApply { return appliedUser }
        didApply = true
        appliedUser = apply()
        return appliedUser
    }

    private static var didApply = false
    private static var appliedUser: User?

    private static func apply() -> User? {
        let args = arguments
        if args.contains(Argument.resetState) { resetState() }
        guard args.contains(Argument.demoUser) else { return nil }

        let user = User(
            id: demoUserID,
            email: "demo@stylemate.test",
            name: "Alex Demo",
            preferredStyles: [.everyday, .business, .date, .sports, .party, .formal],
            notificationsEnabled: false,
            dateCreated: Date(),
            gender: "Female",
            age: 29
        )
        var profiles = AuthService.loadUserProfiles()
        profiles[user.id] = user
        AuthService.saveUserProfiles(profiles)

        if args.contains(Argument.skipOnboarding) { markOnboardingComplete(userId: user.id) }
        if args.contains(Argument.seedWardrobe) { seedWardrobeIfEmpty(userId: user.id) }
        if args.contains(Argument.seedTaste) { seedTaste(userId: user.id) }
        print("[UITest] Demo user ready (reset=\(args.contains(Argument.resetState)), seed=\(args.contains(Argument.seedWardrobe)))")
        return user
    }

    // MARK: - Reset

    private static func resetState() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: WardrobeImageFileHelper.folderURL)
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Scan checkpoints + held "not sure" items, item embeddings.
            for dir in ["ScanProgress", "WardrobeEmbeddings", "Premium"] {
                try? fm.removeItem(at: support.appendingPathComponent(dir))
            }
        }
        try? fm.removeItem(at: MorningLookStore.folder)

        let context = PersistenceController.shared.container.viewContext
        for entity in ["OutfitItem", "DatedOutfit"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            if let objects = try? context.fetch(request) {
                objects.forEach { context.delete($0) }
            }
        }
        if context.hasChanges { try? context.save() }
        print("[UITest] State reset")
    }

    // MARK: - Onboarding

    private static func markOnboardingComplete(userId: String) {
        let d = UserDefaults.standard
        d.set(true, forKey: "hasCompletedOnboarding_\(userId)")      // OnboardingManager
        d.set(true, forKey: "hasCompletedInitialScan_\(userId)")     // RootView auto-scan gate
        d.set(true, forKey: "tour_home_\(userId)")                   // TutorialManager
        d.set(true, forKey: "tour_generation_\(userId)")
        d.set(true, forKey: "hasSeenSwipeHint")                      // TodayOutfitSheet wiggle
        // The seeded cutouts are already final; keep the legacy image migrations off them.
        d.set(true, forKey: "bgRemovalMigrationComplete_\(userId)")
        d.set(true, forKey: "thumbnailMigrationComplete_\(userId)")
        d.set(true, forKey: "zoneCropMigrationComplete_\(userId)")
    }

    // MARK: - Wardrobe seed

    private static func seedWardrobeIfEmpty(userId: String) {
        let vm = WardrobeViewModel()
        vm.load(forUser: userId)
        guard vm.items.isEmpty else { return }

        let catalog = SeedCatalog.items
        let count = intArgument(Argument.seedCount) ?? catalog.count
        var items: [WardrobeItem] = []
        for i in 0..<max(0, count) {
            if let item = seedItem(catalog[i % catalog.count]) { items.append(item) }
        }
        vm.items = items   // didSet persists under the user's wardrobe key
        print("[UITest] Seeded \(items.count) wardrobe items")

        // Pieces the scan found past the free tier, waiting for Premium.
        if let lockedCount = intArgument(Argument.seedLocked), lockedCount > 0 {
            for i in 0..<lockedCount {
                // Start mid-catalog so the waiting pieces differ from the first closet tiles.
                if let item = seedItem(catalog[(i + 7) % catalog.count]) {
                    LockedItemsStore.shared.lock(item, forUser: userId)
                }
            }
            LockedItemsStore.flushWrites()
            print("[UITest] Seeded \(LockedItemsStore.shared.count) locked items")
        }
    }

    // MARK: - Taste seed

    /// As if the user had worn the seeded closet's everyday pairings a few times each.
    private static func seedTaste(userId: String) {
        var profile = TasteProfile(updated: Date())
        let pairs: [(String, String)] = [
            ("denim", "white"), ("beige", "white"), ("black", "white"), ("denim", "navy"), ("beige", "navy"),
            ("black", "gray"), ("denim", "light blue"), ("black", "cream"), ("beige", "light blue"),
            ("black", "denim"), ("gray", "white"), ("denim", "gray"), ("cream", "denim"), ("black", "black"),
            ("beige", "black"), ("navy", "white"), ("navy", "olive"), ("beige", "olive"), ("denim", "olive"),
        ]
        for (a, b) in pairs { profile.pairs[TasteProfile.pairKey(a, b)] = 4 }
        profile.events = 12
        TasteStore.shared.store(profile, forUser: userId)
        print("[UITest] Seeded a taste profile (\(profile.pairs.count) pairings)")
    }

    private static func seedItem(_ spec: SeedGarment) -> WardrobeItem? {
        let image = GarmentArtist.render(spec)
        guard let path = WardrobeImageFileHelper.saveImageAsPNG(image) else { return nil }
        let thumb = WardrobeImageFileHelper.saveThumbnail(image)
        return WardrobeItem(
            category: spec.category,
            product: spec.product,
            colors: spec.colors,
            brand: spec.brand,
            pattern: spec.pattern,
            imagePath: path,
            croppedImagePath: path,
            thumbnailPath: thumb,
            material: spec.material,
            fit: spec.fit,
            neckline: spec.neckline,
            sleeveLength: spec.sleeve,
            garmentLength: spec.length,
            details: spec.details
        )
    }
}

// MARK: - Seed catalog

struct SeedGarment {
    enum Shape {
        case tee, shirt, blouse, sweater, hoodie, cardigan, denimJacket, leatherJacket, coat
        case jeans, chinos, sweatpants, shorts, skirt, dress
        case sneaker, boot, loafer
        case sunglasses, cap, tote, watch
    }

    let category: Category
    let product: String
    let colors: [String]
    var brand: String = ""
    var pattern: Pattern = .solid
    var material: String? = nil
    var fit: Fit? = nil
    var neckline: Neckline? = nil
    var sleeve: SleeveLength? = nil
    var length: GarmentLength? = nil
    var details: String? = nil
    let shape: Shape
    let fill: UInt32
    var accent: UInt32 = 0xFFFFFF
}

enum SeedCatalog {
    static let items: [SeedGarment] = [
        // Tops
        SeedGarment(category: .tops, product: "T-Shirts", colors: ["White"], material: "Cotton",
                    neckline: .crewNeck, sleeve: .shortSleeve, details: "Heavyweight crew-neck tee",
                    shape: .tee, fill: 0xF7F7F5),
        SeedGarment(category: .tops, product: "T-Shirts", colors: ["Navy", "White"], pattern: .stripes,
                    material: "Cotton", neckline: .crewNeck, sleeve: .shortSleeve,
                    details: "Breton stripe tee", shape: .tee, fill: 0x1E2A4A, accent: 0xF4F1EA),
        SeedGarment(category: .tops, product: "Graphic Tees", colors: ["Black"], material: "Cotton",
                    fit: .relaxed, neckline: .crewNeck, sleeve: .shortSleeve,
                    details: "Washed black tee with a chest print", shape: .tee, fill: 0x232323, accent: 0xE8B04B),
        SeedGarment(category: .tops, product: "Button-Down Shirts", colors: ["Light Blue"], material: "Oxford Cotton",
                    neckline: .collared, sleeve: .longSleeve, details: "Oxford button-down",
                    shape: .shirt, fill: 0x9DBBDD),
        SeedGarment(category: .tops, product: "Blouses", colors: ["Cream"], material: "Silk",
                    neckline: .vNeck, sleeve: .longSleeve, details: "Soft drape silk blouse",
                    shape: .blouse, fill: 0xF3EBD8),
        SeedGarment(category: .tops, product: "Polo T-Shirts", colors: ["Olive"], material: "Pique Cotton",
                    neckline: .collared, sleeve: .shortSleeve, details: "Two-button pique polo",
                    shape: .shirt, fill: 0x6B7041),

        // Bottoms
        SeedGarment(category: .bottoms, product: "Jeans", colors: ["Blue"], material: "Denim", fit: .slim,
                    length: .fullLength, details: "Mid-wash straight jeans",
                    shape: .jeans, fill: 0x4A6FA0, accent: 0xD9963B),
        SeedGarment(category: .bottoms, product: "Jeans", colors: ["Black"], material: "Denim", fit: .regular,
                    length: .fullLength, details: "Washed black jeans",
                    shape: .jeans, fill: 0x2C2D30, accent: 0x8A8A8A),
        SeedGarment(category: .bottoms, product: "Chinos", colors: ["Beige"], material: "Cotton Twill",
                    fit: .regular, length: .fullLength, details: "Pressed stone chinos",
                    shape: .chinos, fill: 0xD8C8A8),
        SeedGarment(category: .bottoms, product: "Sweatpants", colors: ["Grey"], material: "Fleece",
                    fit: .relaxed, length: .fullLength, details: "Cuffed fleece joggers",
                    shape: .sweatpants, fill: 0x9A9DA3),
        SeedGarment(category: .bottoms, product: "Shorts", colors: ["Khaki"], material: "Cotton",
                    length: .short, details: "Chino shorts", shape: .shorts, fill: 0xC7AE7E),
        SeedGarment(category: .bottoms, product: "Skirts", colors: ["Black"], material: "Wool Blend",
                    length: .kneeLength, details: "A-line knee skirt", shape: .skirt, fill: 0x26262A),

        // Mid-layers
        SeedGarment(category: .midLayers, product: "Hoodies", colors: ["Grey"], material: "Cotton Fleece",
                    fit: .relaxed, neckline: .hooded, sleeve: .longSleeve, details: "Heather grey pullover hoodie",
                    shape: .hoodie, fill: 0xA4A7AD, accent: 0xF2F2F2),
        SeedGarment(category: .midLayers, product: "Sweaters", colors: ["Burgundy"], material: "Merino Wool",
                    neckline: .crewNeck, sleeve: .longSleeve, details: "Fine-knit merino crew",
                    shape: .sweater, fill: 0x7A2236),
        SeedGarment(category: .midLayers, product: "Cardigans", colors: ["Navy"], material: "Cotton Knit",
                    neckline: .vNeck, sleeve: .longSleeve, details: "Button cardigan",
                    shape: .cardigan, fill: 0x22305A, accent: 0xE9E4D6),

        // Outerwear
        SeedGarment(category: .outerwear, product: "Denim Jackets", colors: ["Light Blue"], material: "Denim",
                    neckline: .collared, sleeve: .longSleeve, length: .cropped, details: "Classic trucker jacket",
                    shape: .denimJacket, fill: 0x7F9FC6, accent: 0xD9963B),
        SeedGarment(category: .outerwear, product: "Coats", colors: ["Camel"], material: "Wool",
                    fit: .relaxed, neckline: .collared, sleeve: .longSleeve, length: .kneeLength,
                    details: "Double-faced wool overcoat", shape: .coat, fill: 0xC19A6B, accent: 0x5A4632),
        SeedGarment(category: .outerwear, product: "Leather Jackets", colors: ["Black"], material: "Leather",
                    fit: .slim, neckline: .collared, sleeve: .longSleeve, details: "Moto leather jacket",
                    shape: .leatherJacket, fill: 0x1C1C1E, accent: 0xC9C9C9),

        // One-pieces
        SeedGarment(category: .onePieces, product: "Dresses", colors: ["Green", "White"], pattern: .polkaDot,
                    material: "Viscose", neckline: .squareNeck, sleeve: .sleeveless, length: .midi,
                    details: "Polka-dot midi sundress", shape: .dress, fill: 0x2F6B4F, accent: 0xF5F3EE),

        // Footwear
        SeedGarment(category: .footwear, product: "Sneakers", colors: ["White"], material: "Leather",
                    details: "Minimal white leather sneakers", shape: .sneaker, fill: 0xF4F4F2, accent: 0xD0D0D0),
        SeedGarment(category: .footwear, product: "Sneakers", colors: ["Navy", "White"], material: "Canvas",
                    details: "Canvas low-tops", shape: .sneaker, fill: 0x253561, accent: 0xF4F4F2),
        SeedGarment(category: .footwear, product: "Chelsea Boots", colors: ["Brown"], material: "Suede",
                    details: "Suede Chelsea boots", shape: .boot, fill: 0x7A5233, accent: 0x2B2B2B),
        SeedGarment(category: .footwear, product: "Loafers", colors: ["Black"], material: "Leather",
                    details: "Penny loafers", shape: .loafer, fill: 0x1F1F21, accent: 0x6B4A2E),

        // Accessories
        SeedGarment(category: .accessories, product: "Sunglasses", colors: ["Black"], material: "Acetate",
                    details: "Classic square frames", shape: .sunglasses, fill: 0x1A1A1A, accent: 0x3A4A55),
        SeedGarment(category: .accessories, product: "Baseball Caps", colors: ["Navy"], material: "Cotton",
                    details: "Washed six-panel cap", shape: .cap, fill: 0x243358),
        SeedGarment(category: .accessories, product: "Tote Bags", colors: ["Tan"], material: "Leather",
                    details: "Everyday leather tote", shape: .tote, fill: 0xB88A5A, accent: 0x6E4B2A),
    ]
}

// MARK: - Garment artist

/// Draws simple, flat-lay style product cutouts on a transparent canvas: a filled silhouette with
/// soft shading, an outline, construction details and (optionally) a stripe or dot print.
enum GarmentArtist {
    static func render(_ g: SeedGarment) -> UIImage {
        let size = canvasSize(for: g.shape)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let s = Scale(size: size)
            let fill = UIColor(seedHex: g.fill)
            let accent = UIColor(seedHex: g.accent)
            for path in silhouettes(g.shape, s) {
                paint(path, fill: fill, accent: accent, pattern: g.pattern, in: cg, size: size)
            }
            drawDetails(g.shape, s, fill: fill, accent: accent, graphicPrint: g.product == "Graphic Tees")
        }
    }

    private static func canvasSize(for shape: SeedGarment.Shape) -> CGSize {
        switch shape {
        case .sneaker, .boot, .loafer, .sunglasses, .cap: return CGSize(width: 720, height: 480)
        case .tote, .watch: return CGSize(width: 600, height: 600)
        default: return CGSize(width: 600, height: 720)
        }
    }

    /// Maps normalized (0...1) coordinates onto the canvas.
    struct Scale {
        let size: CGSize
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
        }
    }

    private static func poly(_ s: Scale, _ pts: [(CGFloat, CGFloat)]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: s.p(first.0, first.1))
        for pt in pts.dropFirst() { path.addLine(to: s.p(pt.0, pt.1)) }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    // MARK: Silhouettes

    private static func silhouettes(_ shape: SeedGarment.Shape, _ s: Scale) -> [UIBezierPath] {
        switch shape {
        case .tee:
            let path = UIBezierPath()
            path.move(to: s.p(0.39, 0.10))
            path.addQuadCurve(to: s.p(0.61, 0.10), controlPoint: s.p(0.50, 0.21))
            for pt in [(0.79, 0.15), (0.95, 0.33), (0.83, 0.41), (0.74, 0.33), (0.74, 0.90),
                       (0.26, 0.90), (0.26, 0.33), (0.17, 0.41), (0.05, 0.33), (0.21, 0.15)] as [(CGFloat, CGFloat)] {
                path.addLine(to: s.p(pt.0, pt.1))
            }
            path.close()
            path.lineJoinStyle = .round
            return [path]

        case .shirt, .blouse, .sweater, .hoodie, .cardigan, .denimJacket, .leatherJacket, .coat:
            let hem: CGFloat
            let width: CGFloat
            switch shape {
            case .coat: hem = 0.97; width = 0.25
            case .denimJacket, .leatherJacket: hem = 0.82; width = 0.27
            case .blouse: hem = 0.86; width = 0.29
            default: hem = 0.88; width = 0.27
            }
            let l = width, r = 1 - width
            let path = UIBezierPath()
            path.move(to: s.p(0.40, 0.09))
            path.addQuadCurve(to: s.p(0.60, 0.09), controlPoint: s.p(0.50, 0.17))
            for pt in [(r + 0.05, 0.13), (0.92, 0.80), (0.81, 0.83), (r, 0.34), (r, hem),
                       (l, hem), (l, 0.34), (0.19, 0.83), (0.08, 0.80), (l - 0.05, 0.13)] as [(CGFloat, CGFloat)] {
                path.addLine(to: s.p(pt.0, pt.1))
            }
            path.close()
            path.lineJoinStyle = .round
            if shape == .hoodie {
                let hood = UIBezierPath(ovalIn: s.r(0.35, 0.02, 0.30, 0.15))
                return [hood, path]
            }
            return [path]

        case .jeans, .chinos, .sweatpants:
            return [poly(s, [(0.28, 0.05), (0.72, 0.05), (0.77, 0.96), (0.54, 0.96), (0.50, 0.34),
                             (0.46, 0.96), (0.23, 0.96)])]

        case .shorts:
            return [poly(s, [(0.25, 0.18), (0.75, 0.18), (0.82, 0.68), (0.55, 0.70), (0.50, 0.45),
                             (0.45, 0.70), (0.18, 0.68)])]

        case .skirt:
            let path = UIBezierPath()
            path.move(to: s.p(0.33, 0.12))
            path.addLine(to: s.p(0.67, 0.12))
            path.addLine(to: s.p(0.82, 0.82))
            path.addQuadCurve(to: s.p(0.18, 0.82), controlPoint: s.p(0.50, 0.88))
            path.close()
            return [path]

        case .dress:
            let path = UIBezierPath()
            path.move(to: s.p(0.36, 0.12))
            path.addQuadCurve(to: s.p(0.64, 0.12), controlPoint: s.p(0.50, 0.17))
            path.addLine(to: s.p(0.62, 0.40))
            path.addLine(to: s.p(0.83, 0.93))
            path.addQuadCurve(to: s.p(0.17, 0.93), controlPoint: s.p(0.50, 0.98))
            path.addLine(to: s.p(0.38, 0.40))
            path.close()
            let strapL = UIBezierPath(roundedRect: s.r(0.37, 0.03, 0.035, 0.10), cornerRadius: 6)
            let strapR = UIBezierPath(roundedRect: s.r(0.595, 0.03, 0.035, 0.10), cornerRadius: 6)
            return [strapL, strapR, path]

        case .sneaker, .loafer:
            let top: CGFloat = shape == .loafer ? 0.40 : 0.28
            let upper = UIBezierPath()
            upper.move(to: s.p(0.08, 0.66))
            upper.addLine(to: s.p(0.10, top + 0.06))
            upper.addQuadCurve(to: s.p(0.34, top + 0.02), controlPoint: s.p(0.18, top - 0.04))
            upper.addQuadCurve(to: s.p(0.62, top + 0.20), controlPoint: s.p(0.46, top + 0.18))
            upper.addQuadCurve(to: s.p(0.94, 0.62), controlPoint: s.p(0.92, top + 0.24))
            upper.addLine(to: s.p(0.94, 0.66))
            upper.close()
            let sole = UIBezierPath(roundedRect: s.r(0.06, 0.64, 0.89, 0.12), cornerRadius: 22)
            return [upper, sole]

        case .boot:
            let upper = UIBezierPath()
            upper.move(to: s.p(0.14, 0.72))
            upper.addLine(to: s.p(0.16, 0.06))
            upper.addLine(to: s.p(0.44, 0.06))
            upper.addLine(to: s.p(0.47, 0.40))
            upper.addQuadCurve(to: s.p(0.90, 0.64), controlPoint: s.p(0.86, 0.44))
            upper.addLine(to: s.p(0.90, 0.72))
            upper.close()
            let sole = UIBezierPath(roundedRect: s.r(0.12, 0.70, 0.80, 0.10), cornerRadius: 12)
            return [upper, sole]

        case .sunglasses:
            let left = UIBezierPath(roundedRect: s.r(0.10, 0.32, 0.34, 0.34), cornerRadius: 46)
            let right = UIBezierPath(roundedRect: s.r(0.56, 0.32, 0.34, 0.34), cornerRadius: 46)
            return [left, right]

        case .cap:
            let dome = UIBezierPath()
            dome.move(to: s.p(0.16, 0.66))
            dome.addCurve(to: s.p(0.74, 0.66), controlPoint1: s.p(0.14, 0.10), controlPoint2: s.p(0.76, 0.10))
            dome.close()
            let brim = UIBezierPath()
            brim.move(to: s.p(0.66, 0.60))
            brim.addQuadCurve(to: s.p(0.96, 0.74), controlPoint: s.p(0.92, 0.58))
            brim.addQuadCurve(to: s.p(0.62, 0.72), controlPoint: s.p(0.80, 0.80))
            brim.close()
            return [dome, brim]

        case .tote:
            let body = poly(s, [(0.16, 0.36), (0.84, 0.36), (0.90, 0.92), (0.10, 0.92)])
            return [body]

        case .watch:
            let band = UIBezierPath(roundedRect: s.r(0.40, 0.04, 0.20, 0.92), cornerRadius: 30)
            let face = UIBezierPath(ovalIn: s.r(0.30, 0.32, 0.40, 0.36))
            return [band, face]
        }
    }

    // MARK: Paint

    private static func paint(_ path: UIBezierPath, fill: UIColor, accent: UIColor, pattern: Pattern,
                              in cg: CGContext, size: CGSize) {
        cg.saveGState()
        // Soft drop shadow so the cutout reads as an object on any background.
        cg.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: UIColor.black.withAlphaComponent(0.18).cgColor)
        fill.setFill()
        path.fill()
        cg.restoreGState()

        cg.saveGState()
        path.addClip()
        switch pattern {
        case .stripes:
            accent.setFill()
            var y: CGFloat = 0
            while y < size.height {
                UIRectFill(CGRect(x: 0, y: y, width: size.width, height: 14))
                y += 42
            }
        case .polkaDot:
            accent.setFill()
            var row = 0
            var y: CGFloat = 10
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 10 : 34
                while x < size.width {
                    UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 14, height: 14)).fill()
                    x += 48
                }
                y += 42
                row += 1
            }
        default:
            break
        }
        // Fabric shading: light from the top-left.
        let colors = [UIColor.white.withAlphaComponent(0.22).cgColor,
                      UIColor.white.withAlphaComponent(0.0).cgColor,
                      UIColor.black.withAlphaComponent(0.16).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
            let b = path.bounds
            cg.drawLinearGradient(gradient, start: CGPoint(x: b.minX, y: b.minY), end: CGPoint(x: b.maxX, y: b.maxY), options: [])
        }
        cg.restoreGState()

        fill.seedDarker(0.72).setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    // MARK: Details

    private static func line(_ s: Scale, _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat),
                             color: UIColor, width: CGFloat, dash: Bool = false) {
        let path = UIBezierPath()
        path.move(to: s.p(a.0, a.1))
        path.addLine(to: s.p(b.0, b.1))
        path.lineWidth = width
        path.lineCapStyle = .round
        if dash { path.setLineDash([8, 6], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    private static func dot(_ s: Scale, _ x: CGFloat, _ y: CGFloat, radius: CGFloat, color: UIColor) {
        let c = s.p(x, y)
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
    }

    private static func drawDetails(_ shape: SeedGarment.Shape, _ s: Scale, fill: UIColor, accent: UIColor,
                                    graphicPrint: Bool) {
        let seam = fill.seedDarker(0.78)
        switch shape {
        case .tee:
            let neck = UIBezierPath()
            neck.move(to: s.p(0.39, 0.10))
            neck.addQuadCurve(to: s.p(0.61, 0.10), controlPoint: s.p(0.50, 0.21))
            neck.lineWidth = 9
            seam.setStroke()
            neck.stroke()
            line(s, (0.27, 0.86), (0.73, 0.86), color: seam, width: 2, dash: true)
            if graphicPrint {
                // chest print on the graphic tee
                accent.setFill()
                UIBezierPath(roundedRect: s.r(0.40, 0.34, 0.20, 0.16), cornerRadius: 18).fill()
            }

        case .shirt:
            seam.setFill()
            poly(s, [(0.40, 0.09), (0.50, 0.17), (0.45, 0.22)]).fill()
            poly(s, [(0.60, 0.09), (0.50, 0.17), (0.55, 0.22)]).fill()
            line(s, (0.50, 0.17), (0.50, 0.88), color: seam, width: 2)
            for y in stride(from: CGFloat(0.24), through: 0.80, by: 0.11) {
                dot(s, 0.515, y, radius: 5, color: UIColor.white.withAlphaComponent(0.85))
            }
            line(s, (0.30, 0.36), (0.40, 0.36), color: seam, width: 2)
            line(s, (0.15, 0.78), (0.24, 0.80), color: seam, width: 3)
            line(s, (0.85, 0.78), (0.76, 0.80), color: seam, width: 3)

        case .blouse:
            seam.setStroke()
            let v = UIBezierPath()
            v.move(to: s.p(0.42, 0.10)); v.addLine(to: s.p(0.50, 0.26)); v.addLine(to: s.p(0.58, 0.10))
            v.lineWidth = 4; v.stroke()
            line(s, (0.15, 0.78), (0.24, 0.80), color: seam, width: 3)
            line(s, (0.85, 0.78), (0.76, 0.80), color: seam, width: 3)

        case .sweater, .hoodie:
            line(s, (0.27, 0.84), (0.73, 0.84), color: seam, width: 10)
            line(s, (0.10, 0.77), (0.19, 0.80), color: seam, width: 8)
            line(s, (0.90, 0.77), (0.81, 0.80), color: seam, width: 8)
            if shape == .hoodie {
                seam.setStroke()
                let pocket = UIBezierPath(roundedRect: s.r(0.35, 0.56, 0.30, 0.18), cornerRadius: 14)
                pocket.lineWidth = 3; pocket.stroke()
                line(s, (0.46, 0.12), (0.45, 0.32), color: accent, width: 4)
                line(s, (0.54, 0.12), (0.55, 0.32), color: accent, width: 4)
            } else {
                let neck = UIBezierPath()
                neck.move(to: s.p(0.40, 0.09))
                neck.addQuadCurve(to: s.p(0.60, 0.09), controlPoint: s.p(0.50, 0.17))
                neck.lineWidth = 10; seam.setStroke(); neck.stroke()
            }

        case .cardigan:
            seam.setStroke()
            let v = UIBezierPath()
            v.move(to: s.p(0.40, 0.09)); v.addLine(to: s.p(0.50, 0.38)); v.addLine(to: s.p(0.60, 0.09))
            v.lineWidth = 8; v.stroke()
            line(s, (0.50, 0.38), (0.50, 0.88), color: seam, width: 3)
            for y in stride(from: CGFloat(0.44), through: 0.82, by: 0.095) {
                dot(s, 0.515, y, radius: 7, color: accent)
            }
            line(s, (0.27, 0.84), (0.73, 0.84), color: seam, width: 10)

        case .denimJacket:
            seam.setFill()
            poly(s, [(0.40, 0.09), (0.50, 0.17), (0.43, 0.24), (0.34, 0.14)]).fill()
            poly(s, [(0.60, 0.09), (0.50, 0.17), (0.57, 0.24), (0.66, 0.14)]).fill()
            line(s, (0.50, 0.17), (0.50, 0.82), color: seam, width: 2)
            line(s, (0.27, 0.40), (0.73, 0.40), color: accent, width: 2, dash: true)
            line(s, (0.27, 0.74), (0.73, 0.74), color: accent, width: 2, dash: true)
            seam.setStroke()
            for x in [CGFloat(0.31), 0.56] {
                let flap = UIBezierPath(rect: s.r(x, 0.43, 0.13, 0.07)); flap.lineWidth = 2; flap.stroke()
            }
            for y in stride(from: CGFloat(0.26), through: 0.76, by: 0.12) {
                dot(s, 0.52, y, radius: 6, color: UIColor(seedHex: 0xB87333))
            }

        case .leatherJacket:
            seam.setFill()
            poly(s, [(0.40, 0.09), (0.50, 0.17), (0.38, 0.30), (0.30, 0.16)]).fill()
            poly(s, [(0.60, 0.09), (0.50, 0.17), (0.62, 0.30), (0.70, 0.16)]).fill()
            line(s, (0.56, 0.20), (0.46, 0.82), color: accent, width: 4)
            line(s, (0.31, 0.52), (0.42, 0.50), color: accent, width: 3)
            line(s, (0.60, 0.56), (0.70, 0.54), color: accent, width: 3)
            line(s, (0.27, 0.78), (0.73, 0.78), color: seam, width: 6)

        case .coat:
            seam.setFill()
            poly(s, [(0.40, 0.09), (0.50, 0.40), (0.35, 0.28), (0.32, 0.14)]).fill()
            poly(s, [(0.60, 0.09), (0.50, 0.40), (0.65, 0.28), (0.68, 0.14)]).fill()
            line(s, (0.50, 0.40), (0.50, 0.97), color: seam, width: 2)
            for y in [CGFloat(0.50), 0.64] {
                dot(s, 0.44, y, radius: 9, color: accent)
                dot(s, 0.56, y, radius: 9, color: accent)
            }
            line(s, (0.30, 0.62), (0.40, 0.60), color: seam, width: 3)
            line(s, (0.60, 0.60), (0.70, 0.62), color: seam, width: 3)

        case .jeans, .chinos, .sweatpants:
            line(s, (0.28, 0.11), (0.72, 0.11), color: seam, width: 3)
            if shape == .sweatpants {
                line(s, (0.24, 0.93), (0.46, 0.93), color: seam, width: 10)
                line(s, (0.54, 0.93), (0.76, 0.93), color: seam, width: 10)
                line(s, (0.47, 0.08), (0.46, 0.20), color: UIColor.white.withAlphaComponent(0.9), width: 4)
                line(s, (0.53, 0.08), (0.54, 0.20), color: UIColor.white.withAlphaComponent(0.9), width: 4)
            } else {
                let stitch = shape == .jeans ? accent : seam
                line(s, (0.50, 0.11), (0.50, 0.28), color: stitch, width: 2)
                seam.setStroke()
                for (a, c) in [((0.30, 0.11), (0.38, 0.20)), ((0.70, 0.11), (0.62, 0.20))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
                    let pocket = UIBezierPath()
                    pocket.move(to: s.p(a.0, a.1))
                    pocket.addQuadCurve(to: s.p(a.0, c.1 + 0.02), controlPoint: s.p(c.0, c.1))
                    pocket.lineWidth = 2
                    (shape == .jeans ? accent : seam).setStroke()
                    pocket.stroke()
                }
                if shape == .chinos {
                    line(s, (0.36, 0.30), (0.35, 0.94), color: seam, width: 1.5)
                    line(s, (0.64, 0.30), (0.65, 0.94), color: seam, width: 1.5)
                }
                dot(s, 0.50, 0.08, radius: 6, color: shape == .jeans ? UIColor(seedHex: 0xB87333) : seam)
            }

        case .shorts:
            line(s, (0.25, 0.24), (0.75, 0.24), color: seam, width: 3)
            line(s, (0.50, 0.24), (0.50, 0.40), color: seam, width: 2)
            line(s, (0.19, 0.64), (0.45, 0.66), color: seam, width: 2, dash: true)
            line(s, (0.55, 0.66), (0.81, 0.64), color: seam, width: 2, dash: true)

        case .skirt:
            line(s, (0.33, 0.18), (0.67, 0.18), color: seam, width: 3)
            for x in [CGFloat(0.42), 0.58] {
                line(s, (x, 0.20), (x + (x - 0.5) * 0.6, 0.82), color: seam, width: 1.5)
            }

        case .dress:
            line(s, (0.38, 0.40), (0.62, 0.40), color: fill.seedDarker(0.6), width: 6)

        case .sneaker:
            line(s, (0.08, 0.70), (0.94, 0.70), color: UIColor(seedHex: 0x9A9A9A), width: 2)
            for i in 0..<4 {
                let x = 0.36 + CGFloat(i) * 0.055
                let y = 0.36 + CGFloat(i) * 0.05
                line(s, (x, y), (x + 0.05, y - 0.04), color: accent, width: 5)
            }
            dot(s, 0.20, 0.44, radius: 10, color: accent)

        case .loafer:
            seam.setStroke()
            let strap = UIBezierPath(roundedRect: s.r(0.44, 0.48, 0.20, 0.06), cornerRadius: 6)
            strap.lineWidth = 3; strap.stroke()
            line(s, (0.08, 0.70), (0.94, 0.70), color: accent, width: 2)

        case .boot:
            accent.setFill()
            UIBezierPath(roundedRect: s.r(0.30, 0.10, 0.12, 0.28), cornerRadius: 10).fill()
            line(s, (0.20, 0.06), (0.20, 0.02), color: seam, width: 8)

        case .sunglasses:
            seam.setStroke()
            let bridge = UIBezierPath()
            bridge.move(to: s.p(0.44, 0.42))
            bridge.addQuadCurve(to: s.p(0.56, 0.42), controlPoint: s.p(0.50, 0.34))
            bridge.lineWidth = 12; bridge.stroke()
            line(s, (0.10, 0.38), (0.03, 0.34), color: seam, width: 10)
            line(s, (0.90, 0.38), (0.97, 0.34), color: seam, width: 10)
            accent.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: s.r(0.13, 0.36, 0.28, 0.26), cornerRadius: 36).fill()
            UIBezierPath(roundedRect: s.r(0.59, 0.36, 0.28, 0.26), cornerRadius: 36).fill()
            line(s, (0.17, 0.42), (0.24, 0.40), color: UIColor.white.withAlphaComponent(0.5), width: 6)
            line(s, (0.63, 0.42), (0.70, 0.40), color: UIColor.white.withAlphaComponent(0.5), width: 6)

        case .cap:
            dot(s, 0.45, 0.25, radius: 10, color: seam)
            line(s, (0.45, 0.25), (0.45, 0.64), color: seam, width: 2, dash: true)
            line(s, (0.30, 0.30), (0.25, 0.64), color: seam, width: 2, dash: true)
            line(s, (0.60, 0.30), (0.65, 0.62), color: seam, width: 2, dash: true)

        case .tote:
            accent.setStroke()
            for (x0, x1) in [(CGFloat(0.28), CGFloat(0.42)), (0.58, 0.72)] {
                let handle = UIBezierPath()
                handle.move(to: s.p(x0, 0.37))
                handle.addCurve(to: s.p(x1, 0.37), controlPoint1: s.p(x0, 0.06), controlPoint2: s.p(x1, 0.06))
                handle.lineWidth = 14; handle.lineCapStyle = .round; handle.stroke()
            }
            line(s, (0.18, 0.46), (0.82, 0.46), color: accent, width: 2, dash: true)

        case .watch:
            UIColor(seedHex: 0xF7F5EF).setFill()
            UIBezierPath(ovalIn: s.r(0.34, 0.355, 0.32, 0.29)).fill()
            line(s, (0.50, 0.50), (0.50, 0.40), color: .black, width: 5)
            line(s, (0.50, 0.50), (0.58, 0.53), color: .black, width: 4)
        }
    }
}

private extension UIColor {
    convenience init(seedHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }

    func seedDarker(_ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        // Near-black fabrics get a lighter outline instead, so details stay visible.
        if (r + g + b) / 3 < 0.2 {
            return UIColor(red: min(r + 0.18, 1), green: min(g + 0.18, 1), blue: min(b + 0.18, 1), alpha: a)
        }
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }

    var seedIsDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r * 0.299 + g * 0.587 + b * 0.114) < 0.35
    }
}
#endif
