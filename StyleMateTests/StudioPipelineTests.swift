import Foundation
import Testing
import UIKit
@testable import StyleMate

/// The studio pipeline's planning, product isolation, colour matching and
/// candidate ranking, with a fake generator (the real diffusion model is
/// exercised by StudioRendererTests).
@Suite(.serialized)
struct StudioPipelineTests {
    /// Echoes the starting image (a perfect "refine"), or returns a flat grey
    /// square for text-to-image (an obviously wrong render).
    final class FakeGenerator: StudioImageGenerating {
        var calls = 0
        var isAvailable: Bool { true }
        func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                    strength: Float, steps: Int, guidance: Float, seed: UInt32) -> CGImage? {
            calls += 1
            if let s = startingImage { return s }
            return StudioPipelineTests.square(r: 128, g: 128, b: 128, inner: 0)
        }
        func unload() {}
    }

    /// A white canvas with a coloured block in the middle (a "product").
    static func square(r: UInt8, g: UInt8, b: UInt8, inner: Int = 160) -> CGImage {
        let n = 512
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n where inner == 0 || (abs(x - n / 2) < inner && abs(y - n / 2) < inner) {
                let o = (y * n + x) * 4
                px[o] = r; px[o + 1] = g; px[o + 2] = b
            }
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        return ctx.makeImage()!
    }

    @Test func describesItemsTheWayAnImageModelReadsThem() {
        let d = StudioPlan.describe(product: "Flannel Shirts", colors: ["Red", "Black"], pattern: .plaid,
                                    material: "Cotton", sleeve: .longSleeve, neckline: .collared, details: "chest pocket")
        #expect(d.hasPrefix("red and black plaid cotton flannel shirt"), "\(d)")
        #expect(d.contains("long sleeves"))
        #expect(d.contains("chest pocket"))
        #expect(StudioPlan.describe(product: "Jeans", colors: ["Light Blue"], pattern: .solid, material: "Denim",
                                    sleeve: nil, neckline: nil, details: nil) == "light blue denim jeans")
    }

    @Test func layeredItemsAreGeneratedOthersRefined() {
        func plan(_ kind: GarmentKind, truncated: Bool = false) -> StudioPlan {
            StudioPlan.make(product: "X", category: .tops, colors: ["Red"], pattern: .solid, material: nil,
                            sleeve: nil, neckline: nil, details: nil, kind: kind, truncated: truncated)
        }
        if case .generate = plan(.innerTop).mode {} else { Issue.record("tops should be generated") }
        if case .generate = plan(.outerLayer).mode {} else { Issue.record("jackets should be generated") }
        // Without a cutout to draw a template from, bottoms and shoes are refined.
        if case .refine = plan(.lower).mode {} else { Issue.record("trousers without a template should be refined") }
        if case .refine = plan(.footwear).mode {} else { Issue.record("shoes without a template should be refined") }
        if case .generate = plan(.lower, truncated: true).mode {} else { Issue.record("cut-off items should be generated") }
    }

    @Test func shoesHatsAndTrousersGetProductTemplates() throws {
        let cut = Self.square(r: 40, g: 40, b: 44)
        let cases: [(String, GarmentKind, StyleMate.Category, StudioTemplate.Shape)] = [
            ("Sneakers", .footwear, .footwear, .sneaker), ("Boots", .footwear, .footwear, .boot),
            ("Chelsea Boots", .footwear, .footwear, .chelsea), ("Ankle Boots", .footwear, .footwear, .chelsea),
            ("Loafers", .footwear, .footwear, .loafer), ("Oxford Shoes", .footwear, .footwear, .loafer),
            ("Heels", .footwear, .footwear, .heel), ("Sandals", .footwear, .footwear, .sandal),
            ("Baseball Caps", .headwear, .accessories, .cap), ("Sun Hats", .headwear, .accessories, .wideBrim),
            ("Fedoras", .headwear, .accessories, .wideBrim), ("Beanies", .headwear, .accessories, .beanie),
            ("Bucket Hats", .headwear, .accessories, .bucket),
            ("Chinos", .lower, .bottoms, .trousers), ("Jeans", .lower, .bottoms, .trousers),
            ("Wide-Leg Pants", .lower, .bottoms, .wideTrousers), ("Joggers", .lower, .bottoms, .joggers),
            ("Leggings", .lower, .bottoms, .leggings)]
        for (product, kind, category, shape) in cases {
            #expect(StudioTemplate.shape(product: product, kind: kind, sleeve: nil) == shape, "\(product)")
            let plan = StudioPlan.make(product: product, category: category, colors: ["Black"], pattern: .solid,
                                       material: "Leather", sleeve: nil, neckline: nil, details: nil,
                                       kind: kind, truncated: false, cutout: cut)
            #expect(plan.template != nil, "\(product) should get a template")
            if case .generate = plan.mode {} else { Issue.record("\(product) should be generated from its template") }
            #expect(StudioPlan.estimatedTokens(plan.prompt) <= StudioPlan.maxPromptTokens, "\(plan.prompt)")
            #expect(plan.prompt.contains("isolated product photo"), "\(plan.prompt)")
            #expect(StudioTemplate.parts(shape) != nil)
        }
        #expect(StudioTemplate.shape(product: "Jeans", kind: .lower, sleeve: nil, fit: .slim) == .slimTrousers)
        let shoe = StudioPlan.make(product: "Sneakers", category: .footwear, colors: ["White"], pattern: .solid, material: "Leather",
                                   sleeve: nil, neckline: nil, details: nil, kind: .footwear, truncated: false, cutout: cut)
        #expect(shoe.prompt.hasPrefix("white leather sneaker, single shoe, side view"), "\(shoe.prompt)")
        #expect(shoe.negativePrompt.contains("two shoes") && !shoe.negativePrompt.contains("single shoe"))
        #expect(shoe.templateStrength == 0.70)
        // No product pose for these: refined from the cutout, as before.
        for (product, kind) in [("Turbans", GarmentKind.headwear), ("Shorts", .lower), ("Skirts", .lower), ("Dhoti", .lower)] {
            #expect(StudioTemplate.shape(product: product, kind: kind, sleeve: nil) == nil, "\(product)")
            let plan = StudioPlan.make(product: product, category: .bottoms, colors: ["Blue"], pattern: .solid, material: nil,
                                       sleeve: nil, neckline: nil, details: nil, kind: kind, truncated: false, cutout: cut)
            if case .refine = plan.mode {} else { Issue.record("\(product) should be refined") }
        }
    }

    @Test func productTemplatesDrawTheItemsOwnColours() throws {
        // A black upper with a white sole band at the bottom of the cutout.
        let n = 256
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 60..<200 {
            for x in 30..<226 {
                let o = (y * n + x) * 4
                let sole = y >= 176
                px[o] = sole ? 245 : 20; px[o + 1] = sole ? 245 : 20; px[o + 2] = sole ? 240 : 24; px[o + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let cutout = ctx.makeImage()!
        let sole = StudioTemplate.soleColour(cutout, fabric: (20 / 255, 20 / 255, 24 / 255))
        #expect(sole.0 > 0.85 && sole.1 > 0.85, "white sole expected, got \(sole)")
        let t = try #require(StudioTemplate.render(cutout: cutout, shape: .sneaker, solid: true))
        let tp = try #require(GarmentCutout.rgbaPixels(t))
        func at(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            let o = (Int(y * CGFloat(t.height)) * t.width + Int(x * CGFloat(t.width))) * 4
            return (Int(tp[o]), Int(tp[o + 1]), Int(tp[o + 2]))
        }
        #expect(at(0.02, 0.02).0 > 245, "white background")
        #expect(at(0.40, 0.55).0 < 80, "black upper, got \(at(0.40, 0.55))")
        #expect(at(0.50, 0.655).0 > 170, "light sole, got \(at(0.50, 0.655))")
    }

    @Test func lightGreyIsNotWhite() {
        typealias C = (name: String, lab: (Float, Float, Float), share: Float, first: Bool)
        let sunlitGreyCoat: [C] = [("White", (83, 1, -3), 0.78, true), ("Black", (24, 1, -3), 0.13, false)]
        // The encoder reads it as more light grey than white: Silver.
        let grey = ColorNamer.resolveLightNeutral(sunlitGreyCoat, tone: ["White": 0.081, "Silver": 0.096])
        #expect(grey.map { $0.name } == ["Silver", "Black"])
        // A white shirt stays White; so does anything without the vocabulary group.
        #expect(ColorNamer.resolveLightNeutral(sunlitGreyCoat, tone: ["White": 0.104, "Silver": 0.050]).first?.name == "White")
        #expect(ColorNamer.resolveLightNeutral(sunlitGreyCoat, tone: [:]).first?.name == "White")
        // Only near-neutral light main colours are re-read (not a pale pink, not a dark grey).
        let pink: [C] = [("Pink", (75, 18, 2), 0.9, true)]
        #expect(ColorNamer.resolveLightNeutral(pink, tone: ["White": 0.0, "Silver": 0.1]).first?.name == "Pink")
        let tinted: [C] = [("White", (80, 10, 9), 0.9, true)]
        #expect(ColorNamer.resolveLightNeutral(tinted, tone: ["White": 0.0, "Silver": 0.1]).first?.name == "White")
    }

    @Test func whiteKeyIsolatesTheProduct() throws {
        let img = Self.square(r: 30, g: 60, b: 160)
        let cut = try #require(StudioPipeline.isolateProduct(img))
        #expect(!cut.touchesFrame)
        let px = try #require(GarmentCutout.rgbaPixels(cut.image))
        #expect(px[(256 * 512 + 256) * 4 + 3] > 200, "centre should be opaque")
        #expect(px[(10 * 512 + 10) * 4 + 3] < 20, "corner should be transparent")
    }

    @Test func productShotThatChangedColourIsRejected() throws {
        try #require(WardrobeExtractor.isAvailable, "needs the bundled FashionEncoder")
        let black = try #require(StudioPipeline.isolateProduct(Self.square(r: 20, g: 20, b: 24))).image
        let emb = try #require(FashionClassifier.onWhite(black, side: 224).flatMap { WardrobeML.shared.embed($0) })
        let plan = StudioPlan.make(product: "Sneakers", category: .footwear, colors: ["Black"], pattern: .solid, material: "Knit",
                                   sleeve: nil, neckline: nil, details: nil, kind: .footwear, truncated: false, cutout: black)
        #expect(plan.productShot && plan.template != nil)
        // A light-grey "shoe" for a black one.
        let c = try #require(StudioPipeline.evaluate(Self.square(r: 200, g: 200, b: 200), reference: ColorStats(black),
                                                     embedding: emb, plan: plan, minSimilarity: 0))
        #expect(c.rejection?.hasPrefix("colour drift") == true, "\(c.rejection ?? "accepted") ΔL \(c.colourDriftL)")
        // The same colour passes that check.
        let same = try #require(StudioPipeline.evaluate(Self.square(r: 22, g: 22, b: 26), reference: ColorStats(black),
                                                        embedding: emb, plan: plan, minSimilarity: 0))
        #expect(same.rejection?.hasPrefix("colour drift") != true, "\(same.rejection ?? "")")
    }

    @Test func colourMatchingMovesTowardTheRealGarment() throws {
        let render = Self.square(r: 200, g: 40, b: 40)          // a red "render"
        let real = try #require(StudioPipeline.isolateProduct(Self.square(r: 120, g: 20, b: 40)).map { $0.image })
        let ref = try #require(ColorStats(real))
        let cut = try #require(StudioPipeline.isolateProduct(render)).image
        let before = try #require(ColorStats(cut)), matched = try #require(ColorStats.match(cut, to: ref))
        let after = try #require(ColorStats(matched))
        #expect(abs(after.mean.0 - ref.mean.0) < abs(before.mean.0 - ref.mean.0))
        #expect(abs(after.mean.1 - ref.mean.1) < abs(before.mean.1 - ref.mean.1))
    }

    @Test func picksAFaithfulRenderAndRejectsAWrongOne() throws {
        try #require(WardrobeExtractor.isAvailable, "needs the bundled FashionEncoder")
        let fake = FakeGenerator()
        let previous = StudioPipeline.generator
        StudioPipeline.generator = fake
        defer { StudioPipeline.generator = previous }
        let cut = try #require(StudioPipeline.isolateProduct(Self.square(r: 30, g: 60, b: 160))).image
        let cutout = UIImage(cgImage: cut)
        let emb = try #require(FashionClassifier.onWhite(cut, side: 224).flatMap { WardrobeML.shared.embed($0) })

        let refine = StudioPlan.make(product: "Jeans", category: .bottoms, colors: ["Blue"], pattern: .solid,
                                     material: "Denim", sleeve: nil, neckline: nil, details: nil, kind: .lower, truncated: false)
        let good = StudioPipeline.studioImage(cutout: cutout, embedding: emb, plan: refine, seedBase: 1)
        #expect(good != nil, "an exact refine should be accepted")
        #expect((good?.similarity ?? 0) > 0.9)

        let generate = StudioPlan.make(product: "T-Shirts", category: .tops, colors: ["Blue"], pattern: .solid,
                                       material: nil, sleeve: nil, neckline: nil, details: nil, kind: .innerTop, truncated: false)
        let bad = StudioPipeline.studioImage(cutout: cutout, embedding: emb, plan: generate, seedBase: 1)
        #expect(bad == nil, "a blank render must be rejected, keeping the cutout")
        #expect(fake.calls == refine.candidates + generate.candidates)
    }

    /// The whole thing for real: extract garments from a CC0 street photo, then
    /// make studio images with the bundled diffusion model (simulator CPU, so
    /// one candidate and fewer steps). Images go to $REPORT_DIR/studio_pipeline.
    @Test(.timeLimit(.minutes(60)))
    func realStudioRendersFromAPhoto() throws {
        try #require(WardrobeExtractor.isAvailable)
        guard StudioRenderer.shared.isAvailable else {
            Issue.record("studio models not bundled"); return
        }
        let env = ProcessInfo.processInfo.environment
        let dir = env["FIXTURES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("photos") }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/photos")
        let out = (env["REPORT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("studio_pipeline")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        _ = dir
        let items = try FixtureExtraction.run("casual_denim_jacket_hat.jpg").items
        var rendered = 0
        var report: [[String: Any]] = []
        for item in items where [.outerLayer, .lower].contains(item.kind) {
            let a = item.attributes
            let full = StudioPlan.make(product: a.product, category: a.category, colors: a.colors, pattern: a.pattern,
                                       material: a.material, sleeve: a.sleeveLength, neckline: a.neckline, details: nil,
                                       kind: item.kind, truncated: item.truncated, cutout: item.cutout.cgImage,
                                       embedding: a.embedding)
            // Simulator CPU: 2 candidates each (the app renders 3 / 2).
            let plan = StudioPlan(mode: full.mode, prompt: full.prompt, negativePrompt: full.negativePrompt,
                                  candidates: 2, productLabel: full.productLabel, isSolid: full.isSolid,
                                  template: full.template, templateStrength: full.templateStrength)
            let stem = a.product.replacingOccurrences(of: " ", with: "")
            try? item.cutout.pngData()?.write(to: out.appendingPathComponent("\(stem)_cutout.png"))
            if let t = plan.template { try? UIImage(cgImage: t).pngData()?.write(to: out.appendingPathComponent("\(stem)_template.png")) }
            let start = Date()
            var candidates: [[String: Any]] = []
            let seed = StudioQueue.seed(for: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
            let outcome = StudioPipeline.studioOutcome(cutout: item.cutout, embedding: a.embedding, plan: plan,
                                                       seedBase: seed) { k, raw, c in
                try? UIImage(cgImage: raw).pngData()?.write(to: out.appendingPathComponent("\(stem)_raw\(k).png"))
                var row: [String: Any] = ["candidate": k]
                if let c {
                    try? c.image.pngData()?.write(to: out.appendingPathComponent("\(stem)_cand\(k).png"))
                    row.merge(c.summary, uniquingKeysWith: { $1 })
                } else {
                    row["rejection"] = "nothing separable"
                }
                candidates.append(row)
            }
            var entry: [String: Any] = ["product": a.product, "kind": item.kind.rawValue, "prompt": plan.prompt,
                                        "negative": plan.negativePrompt, "seconds": Int(Date().timeIntervalSince(start)),
                                        "candidates": candidates]
            var verdict = ""
            switch outcome {
            case .rendered(let r):
                try? r.image.pngData()?.write(to: out.appendingPathComponent("\(stem)_studio.png"))
                rendered += 1
                entry["accepted"] = ["similarity": r.similarity, "score": r.score]
                verdict = "ACCEPTED sim=\(r.similarity)"
            case .rejected(let best):
                verdict = "rejected (best sim \(best.map { "\($0)" } ?? "-"))"
                entry["accepted"] = verdict
            case .failed:
                verdict = "render failed"
                entry["accepted"] = verdict
            }
            let lines = candidates.map { c -> String in
                "c\(c["candidate"] ?? ""): sim=\(c["similarity"] ?? "-") \(c["rejection"] ?? "")"
            }
            print("[Report] studio \(a.product): \(verdict) — " + lines.joined(separator: "; "))
            // What this costs on a phone: the simulator runs the UNet on its CPU. Estimate for an
            // A17 Pro / A18 Pro-class Neural Engine, ~1 s per denoising step of the 6-bit SD 1.5
            // UNet at 512 px (Apple ml-stable-diffusion benchmarks) plus ~10 s of model loads.
            // NOT measured on a device.
            var stepsPerImage = StudioPlan.steps
            if case .refine(let s) = plan.mode { stepsPerImage = Int(Float(StudioPlan.steps) * s) }
            else if plan.template != nil { stepsPerImage = Int(Float(StudioPlan.steps) * plan.templateStrength) }
            let ane = 10 + stepsPerImage * plan.candidates
            print("[Report] studio \(a.product): simulator \(entry["seconds"] ?? 0)s for \(plan.candidates) x \(stepsPerImage) steps; " +
                  "estimated ~\(ane)s on an iPhone Neural Engine (not measured)")
            entry["ane_estimate_seconds"] = ane
            report.append(entry)
        }
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: out.appendingPathComponent("candidates.json"))
        }
        #expect(rendered >= 1, "no convincing studio render for the denim jacket / jeans photo")
    }

    /// Core ML vs. diffusers: the same text-to-image request (prompt, negative,
    /// seed 1, 20 DPM-Solver++ Karras steps, guidance 7, torch RNG) rendered
    /// here by the bundled 6-bit Core ML pipeline and locally by diffusers fp32
    /// (`Fixtures/labels/studio_parity_reference.png`). The two should be the
    /// same picture up to quantisation noise; if the Core ML one is mush, the
    /// conversion (palettisation, scheduler, VAE) is broken, not the prompts.
    static let parityPrompt = "blue denim jacket, long sleeves, isolated product photo, centered, plain white background, studio lighting"
    static let parityNegative = "person, model, mannequin, body, skin, hands, face, hanger, multiple items, stack, folded, props, " +
        "accessories, shirt underneath, inner layer, lining, white patch, label, logo, text, cropped, cut off, frame, blurry, deformed"

    @Test(.timeLimit(.minutes(30)))
    func coreMLRenderMatchesDiffusers() throws {
        try #require(WardrobeExtractor.isAvailable)
        guard StudioRenderer.shared.isAvailable else { Issue.record("studio models not bundled"); return }
        let env = ProcessInfo.processInfo.environment
        let out = (env["REPORT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("studio_pipeline")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let start = Date()
        let rendered = StudioRenderer.shared.render(startingImage: nil, prompt: Self.parityPrompt,
                                                    negativePrompt: Self.parityNegative, strength: 1,
                                                    steps: 20, guidance: 7, seed: 1)
        let image = try #require(rendered, "no render")
        try UIImage(cgImage: image).pngData()?.write(to: out.appendingPathComponent("parity_coreml_seed1.png"))
        let secs = Int(Date().timeIntervalSince(start))
        // 6-bit palettisation changes the trajectory (a simulated 6-bit render
        // of the same request is a different, equally good picture), so the
        // check is "a convincing denim jacket", not pixel identity.
        let e1 = try #require(FashionClassifier.onWhite(image, side: 224).flatMap { WardrobeML.shared.embed($0) })
        var sims: [String: Float] = [:]
        for name in ["studio_parity_reference.png", "studio_parity_reference_6bit.png"] {
            guard let url = FixtureExtraction.fixturesRoot?.appendingPathComponent("labels/\(name)"),
                  let data = try? Data(contentsOf: url), let ref = UIImage(data: data)?.cgImage,
                  let e2 = FashionClassifier.onWhite(ref, side: 224).flatMap({ WardrobeML.shared.embed($0) }) else { continue }
            sims[name] = WardrobeExtractor.cosine(e1, e2)
        }
        let vocab = try #require(WardrobeML.shared.vocabulary)
        let label = vocab.best(in: "upper_outer", for: e1)?.label ?? "-"
        let denim = vocab.scores(in: "upper_outer", for: e1)["Outerwear|Denim Jackets"] ?? 0
        let line = "parity: Core ML render in \(secs)s: zero-shot \(label) (denim jacket \(String(format: "%.3f", denim))), " +
            sims.sorted { $0.key < $1.key }.map { "SigLIP vs \($0.key) \(String(format: "%.3f", $0.value))" }.joined(separator: ", ")
        print("[Report] \(line)")
        try? line.data(using: .utf8)?.write(to: out.appendingPathComponent("parity.txt"))
        #expect(label == "Outerwear|Denim Jackets" || (sims.values.max() ?? 0) > 0.7,
                "the Core ML render is not recognisably the requested denim jacket: \(line)")
    }

    @Test func storeTracksRendersAndUpgrades() {
        let id = UUID()
        let item = WardrobeItem(id: id, category: .tops, product: "T-Shirts", colors: ["Blue"], brand: "",
                                pattern: .solid, imagePath: "cutout.png")
        let store = StudioStore.shared
        #expect(store.needsRender(item))
        store.set(.init(studioPath: "studio.png", cutoutPath: "cutout.png", version: StudioStore.version), for: id)
        let rendered = item.withImages(imagePath: "studio.png", croppedImagePath: "studio.png", thumbnailPath: nil)
        #expect(!store.needsRender(rendered))
        #expect(store.originalCutout(for: rendered) == "cutout.png")
        // A better photo replaced the image → render again.
        let upgraded = item.withImages(imagePath: "better.png", croppedImagePath: "better.png", thumbnailPath: nil)
        #expect(store.needsRender(upgraded))
    }

    @Test func seedsAreStablePerItem() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(StudioQueue.seed(for: id) == StudioQueue.seed(for: UUID(uuidString: id.uuidString)!))
        #expect(StudioQueue.seed(for: id) != StudioQueue.seed(for: UUID()))
    }

    @Test func promptsStayShortAndAvoidKnollingWords() {
        let plan = StudioPlan.make(product: "Denim Jackets", category: .outerwear, colors: ["Blue", "White"], pattern: .solid,
                                   material: "Denim", sleeve: .longSleeve, neckline: .collared,
                                   details: "button front, chest pockets, contrast stitching, silver buttons, cuffed sleeves",
                                   kind: .outerLayer, truncated: false,
                                   cutout: StudioPipelineTests.square(r: 40, g: 70, b: 140))
        #expect(plan.template != nil, "a jacket should get a fabric template")
        if case .generate = plan.mode {} else { Issue.record("jackets should be generated") }
        #expect(StudioPlan.estimatedTokens(plan.prompt) <= StudioPlan.maxPromptTokens, "\(plan.prompt)")
        #expect(plan.prompt.hasPrefix("blue denim jacket"), "plain garments name only their main colour: \(plan.prompt)")
        #expect(plan.prompt.contains("isolated product photo"))
        for w in ["flat lay", "top-down", "neatly arranged"] { #expect(!plan.prompt.contains(w), "\(plan.prompt)") }
        #expect(plan.negativePrompt.contains("sherpa lining"))
        #expect(StudioPlan.estimatedTokens(plan.negativePrompt) <= 75, "\(plan.negativePrompt)")
    }

    @Test func gateRejectsAPanelAndASecondObject() throws {
        // A navy "tee" with a big white rectangle in the middle...
        let n = 512
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 120..<400 {
            for x in 140..<372 {
                let o = (y * n + x) * 4
                let panel = (200..<300).contains(y) && (210..<300).contains(x)
                if !panel { px[o] = 25; px[o + 1] = 35; px[o + 2] = 80 }
            }
        }
        // ...and a second object (a "prop") in the corner.
        for y in 430..<500 {
            for x in 20..<120 { let o = (y * n + x) * 4; px[o] = 150; px[o + 1] = 40; px[o + 2] = 40 }
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let img = ctx.makeImage()!
        let cut = try #require(StudioPipeline.isolateProduct(img, keepPairs: false))
        #expect(cut.secondObject > 0.1, "second object \(cut.secondObject)")
        #expect(StudioPipeline.interiorWhiteBlob(cut.image) > 0.03)
    }

    @Test func embeddingStoreRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emb-\(UUID().uuidString)")
        let a = ItemEmbeddingStore(directory: dir)
        let id = UUID(), gone = UUID()
        a.set([0.25, -0.5, 1], quality: 0.7, truncated: true, for: id)
        a.set([1, 2, 3], quality: 0.1, for: gone)
        a.remove([gone])
        a.flush()
        let b = ItemEmbeddingStore(directory: dir)
        #expect(b.embedding(for: id) == [0.25, -0.5, 1])
        #expect(b.quality(for: id) == 0.7)
        #expect(b.truncated(for: id) == true)
        #expect(b.embedding(for: gone) == nil)
    }
}
