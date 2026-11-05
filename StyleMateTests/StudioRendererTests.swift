import CoreGraphics
import CoreML
import Foundation
import Testing
import UIKit
@testable import StyleMate

/// On-device studio render (SD 1.5-class) end to end in the simulator, both modes:
/// - img2img: a real garment cutout from a CC0 fixture photo, on white, 2 seeds in one load
///   (6 steps at strength 0.5 -> 3 denoising steps each);
/// - text-to-image: a flat-lay prompt, 4 steps.
/// Inputs, renders and timings go to $REPORT_DIR/studio/ (the `ci-report` artifact) for visual review.
///
/// The simulator has no Neural Engine, so Core ML runs the (ANE-oriented, SPLIT_EINSUM_V2) models on the
/// CPU: slow (minutes) but the same graph the phone runs.
@Suite(.serialized)
struct StudioRendererTests {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static var fixturesDir: URL? {
        if let p = env["FIXTURES_DIR"] { return URL(fileURLWithPath: p).appendingPathComponent("photos") }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/photos")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    private static var reportDir: URL {
        let base = env["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wardrobe-report")
        let dir = base.appendingPathComponent("studio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let negative = "person, mannequin, body, hands, text, watermark, blurry, lowres, deformed, cartoon"

    @Test func modelsAreBundled() {
        #expect(StudioRenderer.shared.isAvailable, "StudioModels.bundle missing from the app (scripts/build_studio_models.sh)")
    }

    @Test(.timeLimit(.minutes(60)))
    func rendersImg2ImgAndText2Img() async throws {
        try #require(StudioRenderer.shared.isAvailable)
        let size = StudioRenderer.imageSize
        let (cutout, source) = try Self.fixtureCutout()
        let input = try #require(StudioRenderer.flattenedOnWhite(cutout, size: size))
        try Self.writePNG(input, "input.png")
        let inPx = try #require(Self.rgbPixels(input, size: size))

        // Dedicated instance so the test can pick compute units without touching the app's singleton.
        let renderer = StudioRenderer()
        var summary: [String: Any] = ["source": source.fixture, "product": source.product]

        // 1. img2img, two seeds in one load. Fall back to CPU-only if the default units can't run here.
        let imgPrompt = "professional studio product photo of a \(source.product), clean white background, " +
            "soft even lighting, realistic fabric texture, sharp focus, e-commerce catalog"
        let seeds: [UInt32] = [42, 7]
        var renders: [CGImage?] = []
        var usedUnits = ""
        for (name, cu) in [("cpuAndNeuralEngine", MLComputeUnits.cpuAndNeuralEngine), ("cpuOnly", .cpuOnly)] {
            renderer.computeUnits = cu
            renders = await renderer.render(startingImage: input, prompt: imgPrompt, negativePrompt: Self.negative,
                                            strength: 0.5, steps: 6, guidance: 6.5, seeds: seeds)
            usedUnits = name
            if renders.allSatisfy({ $0 != nil }) { break }
            print("[Report] studio img2img with \(name) failed: \(renders.map { $0 == nil ? "nil" : "ok" })")
        }
        let img2imgStats = renderer.lastStats
        let images = try renders.map { try #require($0, "img2img render returned nil (\(usedUnits))") }
        var img2img: [[String: Any]] = []
        for (seed, image) in zip(seeds, images) {
            try Self.writePNG(image, "img2img_seed\(seed).png")
            let m = try Self.metrics(image, reference: inPx, size: size)
            img2img.append(["seed": seed, "meanAbsDiffVsInput": m.diff, "std": m.std])
            #expect(image.width == size && image.height == size)
            #expect(m.std > 8, "img2img render (seed \(seed)) is blank / flat")
            #expect(m.diff > 2, "img2img render (seed \(seed)) is (almost) identical to the input")
            #expect(m.diff < 120, "img2img render (seed \(seed)) is unrelated to the input")
        }
        let seedPx = try images.map { try #require(Self.rgbPixels($0, size: size)) }
        let seedDiff = Self.meanAbsDiff(seedPx[0], seedPx[1])
        #expect(seedDiff > 0.5, "different seeds gave the same image")
        summary["img2img"] = ["computeUnits": usedUnits, "steps": 6, "strength": 0.5, "guidance": 6.5,
                              "prompt": imgPrompt, "renders": img2img, "seedToSeedDiff": seedDiff,
                              "stats": Self.json(img2imgStats)] as [String: Any]

        // 2. text-to-image (no starting image; the VAE encoder isn't used).
        let txtPrompt = "flat lay product photo of a navy wool overcoat, neatly laid out on a plain white " +
            "background, top-down view, soft studio lighting, realistic fabric texture, e-commerce catalog"
        let t2i = await renderer.render(startingImage: nil, prompt: txtPrompt, negativePrompt: Self.negative,
                                        strength: 1, steps: 4, guidance: 7, seed: 42)
        let txtStats = renderer.lastStats
        renderer.unload()
        let txtImage = try #require(t2i, "text-to-image render returned nil (\(usedUnits))")
        try Self.writePNG(txtImage, "text2img_seed42.png")
        let tm = try Self.metrics(txtImage, reference: inPx, size: size)
        #expect(txtImage.width == size && txtImage.height == size)
        #expect(tm.std > 8, "text-to-image render is blank / flat")
        summary["text2img"] = ["steps": 4, "guidance": 7, "prompt": txtPrompt, "std": tm.std,
                               "stats": Self.json(txtStats)] as [String: Any]

        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: Self.reportDir.appendingPathComponent("render.json"))
        print("[Report] studio (\(usedUnits)) img2img: 2 seeds x \(img2imgStats?.denoisingSteps ?? -1) steps in " +
              "\(String(format: "%.1f", img2imgStats?.totalSeconds ?? -1))s (setup \(String(format: "%.1f", img2imgStats?.setupSeconds ?? -1))s); " +
              "text2img: \(txtStats?.denoisingSteps ?? -1) steps in \(String(format: "%.1f", txtStats?.totalSeconds ?? -1))s")
    }

    // MARK: - Helpers

    /// A real garment cutout from the extraction pipeline (preferring a top / outerwear), or a centre crop
    /// of the photo if extraction finds nothing.
    private static func fixtureCutout() throws -> (CGImage, (fixture: String, product: String)) {
        let fixture = "street_coat_scarf.jpg"
        let dir = try #require(fixturesDir, "fixtures directory not found")
        let photo = try #require(UIImage(data: try Data(contentsOf: dir.appendingPathComponent(fixture))))
        if WardrobeExtractor.isAvailable {
            let items = WardrobeExtractor.extract(from: photo)
            let preferred = items.filter { ["Outerwear", "Tops"].contains($0.attributes.category.rawValue) }
            if let item = (preferred.isEmpty ? items : preferred).max(by: { $0.quality < $1.quality }),
               let cg = item.cutout.cgImage ?? Self.render(item.cutout) {
                return (cg, (fixture, item.attributes.product.lowercased()))
            }
        }
        let cg = try #require(photo.cgImage ?? Self.render(photo))
        let side = min(cg.width, cg.height) / 2
        let crop = try #require(cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2,
                                                       width: side, height: side)))
        return (crop, (fixture, "coat"))
    }

    private static func json(_ s: StudioRenderer.RenderStats?) -> [String: Any] {
        guard let s else { return [:] }
        return ["setupSeconds": s.setupSeconds, "totalSeconds": s.totalSeconds, "denoisingSteps": s.denoisingSteps,
                "imageCount": s.imageCount, "textToImage": s.textToImage]
    }

    private static func render(_ image: UIImage) -> CGImage? {
        UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.cgImage
    }

    private static func writePNG(_ image: CGImage, _ name: String) throws {
        let data = try #require(UIImage(cgImage: image).pngData())
        try data.write(to: reportDir.appendingPathComponent(name))
    }

    private static func metrics(_ image: CGImage, reference: [UInt8], size: Int) throws -> (diff: Double, std: Double) {
        let px = try #require(rgbPixels(image, size: size))
        let mean = px.reduce(0.0) { $0 + Double($1) } / Double(px.count)
        let variance = px.reduce(0.0) { acc, v in acc + (Double(v) - mean) * (Double(v) - mean) } / Double(px.count)
        return (meanAbsDiff(reference, px), variance.squareRoot())
    }

    private static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) { sum += abs(Double(a[i]) - Double(b[i])) }
        return sum / Double(max(1, min(a.count, b.count)))
    }

    /// RGB bytes (no alpha) of `image` drawn at size x size.
    private static func rgbPixels(_ image: CGImage, size: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8]()
        rgb.reserveCapacity(size * size * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgb.append(contentsOf: rgba[i..<i + 3]) }
        return rgb
    }
}
