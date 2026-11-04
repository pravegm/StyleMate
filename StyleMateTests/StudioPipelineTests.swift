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
        if case .refine = plan(.lower).mode {} else { Issue.record("trousers should be refined") }
        if case .refine = plan(.footwear).mode {} else { Issue.record("shoes should be refined") }
        if case .generate = plan(.lower, truncated: true).mode {} else { Issue.record("cut-off items should be generated") }
    }

    @Test func whiteKeyIsolatesTheProduct() throws {
        let img = Self.square(r: 30, g: 60, b: 160)
        let cut = try #require(StudioPipeline.isolateProduct(img))
        #expect(!cut.touchesFrame)
        let px = try #require(GarmentCutout.rgbaPixels(cut.image))
        #expect(px[(256 * 512 + 256) * 4 + 3] > 200, "centre should be opaque")
        #expect(px[(10 * 512 + 10) * 4 + 3] < 20, "corner should be transparent")
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
        for item in items where [.outerLayer, .lower].contains(item.kind) {
            let a = item.attributes
            let full = StudioPlan.make(product: a.product, category: a.category, colors: a.colors, pattern: a.pattern,
                                       material: a.material, sleeve: a.sleeveLength, neckline: a.neckline, details: nil,
                                       kind: item.kind, truncated: item.truncated)
            let plan = StudioPlan(mode: full.mode, prompt: full.prompt, negativePrompt: full.negativePrompt, candidates: 1,
                                  productLabel: full.productLabel, isSolid: full.isSolid)
            try? item.cutout.pngData()?.write(to: out.appendingPathComponent("\(a.product)_cutout.png"))
            let start = Date()
            if let r = StudioPipeline.studioImage(cutout: item.cutout, embedding: a.embedding, plan: plan, seedBase: 42) {
                try? r.image.pngData()?.write(to: out.appendingPathComponent("\(a.product)_studio.png"))
                rendered += 1
                let line = "\(a.product): sim=\(r.similarity) score=\(r.score) in \(Int(Date().timeIntervalSince(start)))s\n"
                try? line.data(using: .utf8)?.write(to: out.appendingPathComponent("\(a.product).txt"))
            }
        }
        #expect(rendered >= 1, "no convincing studio render for the denim jacket / jeans photo")
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
}
