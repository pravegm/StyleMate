import CoreGraphics
import CoreML
import Foundation
import Testing
import UIKit
@testable import StyleMate

/// On-device studio render (SD 1.5-class img2img) end to end in the simulator: a real garment cutout
/// from a CC0 fixture photo, composited on white, rendered at 512x512 with a few steps. The input and the
/// render are written to $REPORT_DIR/studio/ (the `ci-report` artifact) for visual review.
///
/// The simulator has no Neural Engine, so Core ML runs the (ANE-oriented, SPLIT_EINSUM_V2) models on the
/// CPU: slow (minutes) but numerically the same graph the phone runs.
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

    @Test func modelsAreBundled() {
        #expect(StudioRenderer.shared.isAvailable, "StudioModels.bundle missing from the app (scripts/build_studio_models.sh)")
    }

    @Test(.timeLimit(.minutes(45)))
    func rendersGarmentFromCutout() async throws {
        try #require(StudioRenderer.shared.isAvailable)
        let (cutout, source) = try Self.fixtureCutout()
        let input = try #require(StudioRenderer.flattenedOnWhite(cutout, size: StudioRenderer.imageSize))
        try Self.writePNG(input, "input.png")

        let prompt = "professional studio product photo of a \(source.product), clean white background, " +
            "soft even lighting, realistic fabric texture, sharp focus, e-commerce catalog"
        let negative = "person, mannequin, body, hands, text, watermark, blurry, lowres, deformed, cartoon"

        // Dedicated instance so this test can pick compute units without touching the app's singleton.
        let renderer = StudioRenderer()
        var units: [(String, MLComputeUnits)] = [("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuOnly", .cpuOnly)]
        var output: CGImage?
        var usedUnits = ""
        while output == nil, !units.isEmpty {
            let (name, cu) = units.removeFirst()
            renderer.computeUnits = cu
            output = await renderer.render(cutoutOnWhite: input, prompt: prompt, negativePrompt: negative,
                                           strength: 0.5, steps: 6, guidance: 6.5, seed: 42)
            usedUnits = name
            if output == nil { print("[Report] studio render with \(name) returned nil") }
        }
        renderer.unload()
        let image = try #require(output, "studio render returned nil with every compute unit")
        try Self.writePNG(image, "render.png")

        let stats = renderer.lastStats
        let inPx = try #require(Self.rgbPixels(input, size: StudioRenderer.imageSize))
        let outPx = try #require(Self.rgbPixels(image, size: StudioRenderer.imageSize))
        let diff = zip(inPx, outPx).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(inPx.count)
        let mean = outPx.reduce(0.0) { $0 + Double($1) } / Double(outPx.count)
        let std = (outPx.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(outPx.count)).squareRoot()

        let summary: [String: Any] = [
            "source": source.fixture, "product": source.product, "computeUnits": usedUnits,
            "width": image.width, "height": image.height, "steps": 6, "strength": 0.5, "guidance": 6.5, "seed": 42,
            "denoisingSteps": stats?.denoisingSteps ?? -1, "setupSeconds": stats?.setupSeconds ?? -1,
            "totalSeconds": stats?.totalSeconds ?? -1, "meanAbsDiffVsInput": diff, "outputMean": mean, "outputStd": std,
            "prompt": prompt, "negativePrompt": negative,
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: Self.reportDir.appendingPathComponent("render.json"))
        print("[Report] studio render (\(usedUnits)): \(stats?.denoisingSteps ?? -1) steps in " +
              "\(String(format: "%.1f", stats?.totalSeconds ?? -1))s (setup \(String(format: "%.1f", stats?.setupSeconds ?? -1))s), " +
              "diff vs input \(String(format: "%.1f", diff)), std \(String(format: "%.1f", std))")

        #expect(image.width == StudioRenderer.imageSize && image.height == StudioRenderer.imageSize)
        #expect(std > 8, "render is blank / flat")
        #expect(diff > 2, "render is (almost) identical to the input")
        #expect(diff < 120, "render is unrelated to the input (noise?)")
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

    private static func render(_ image: UIImage) -> CGImage? {
        UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.cgImage
    }

    private static func writePNG(_ image: CGImage, _ name: String) throws {
        let data = try #require(UIImage(cgImage: image).pngData())
        try data.write(to: reportDir.appendingPathComponent(name))
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
        return rgba.enumerated().filter { $0.offset % 4 != 3 }.map { $0.element }
    }
}
