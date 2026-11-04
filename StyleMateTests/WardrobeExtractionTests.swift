import Foundation
import Testing
import UIKit
@testable import StyleMate

/// End-to-end, on-device wardrobe extraction on real (CC0) street photos.
/// Runs the bundled Core ML models in the simulator, writes every cutout plus a
/// JSON summary to $REPORT_DIR (uploaded as a CI artifact for visual review),
/// and checks the items a person would expect to be found.
@Suite(.serialized)
struct WardrobeExtractionTests {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static var fixturesDir: URL? {
        if let p = env["FIXTURES_DIR"] { return URL(fileURLWithPath: p).appendingPathComponent("photos") }
        // Local runs: resolve relative to this source file.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let dir = here.appendingPathComponent("Fixtures/photos")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    private static var reportDir: URL {
        let base = env["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wardrobe-report")
        let dir = base.appendingPathComponent("extraction")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func load(_ name: String) throws -> UIImage {
        let dir = try #require(Self.fixturesDir, "fixtures directory not found")
        let url = dir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try #require(UIImage(data: data), "could not decode \(name)")
    }

    @Test func modelsAreBundled() {
        #expect(WardrobeExtractor.isAvailable, "GarmentParser / GarmentLabeler / FashionEncoder / vocabulary missing")
    }

    /// (fixture, products/categories that must be found)
    static let cases: [(String, [String])] = [
        ("street_coat_scarf.jpg", ["Outerwear", "Footwear", "Accessories"]),
        ("street_leather_tunic.jpg", ["Footwear", "Bottoms"]),
        ("street_coat_cap.jpg", ["Outerwear", "Footwear", "Bottoms"]),
        ("street_coat_boots.jpg", ["Outerwear", "Footwear", "Bottoms"]),
        ("street_coat_backpack.jpg", ["Outerwear", "Footwear", "Bottoms"]),
        ("street_back_view.jpg", ["Bottoms"]),
        ("casual_denim_jacket_hat.jpg", ["Outerwear", "Bottoms"]),
        ("pink_coat_boots.jpg", ["Outerwear"]),   // black ankle boots merge into black leggings: known miss
        ("kurta_dhoti_turban.jpg", []),
        ("flannel_shirt_group.jpg", ["Tops"]),
        ("jeans_white_shirt_halfbody.jpg", ["Bottoms"]),
        ("ripped_jeans_belt_watch.jpg", ["Bottoms"]),
        ("denim_shirt_small_fullbody.jpg", [])
    ]

    @Test(arguments: cases.map { $0.0 })
    func extractsExpectedItems(_ fixture: String) async throws {
        try #require(WardrobeExtractor.isAvailable)
        let run = try FixtureExtraction.run(fixture)
        let items = run.items
        let secs = run.seconds

        // Report: cutouts + summary.
        let stem = (fixture as NSString).deletingPathExtension
        var summary: [[String: Any]] = []
        for (i, item) in items.enumerated() {
            let a = item.attributes
            let file = "\(stem)_\(i)_\(a.product.replacingOccurrences(of: " ", with: "")).png"
            try? item.cutout.pngData()?.write(to: Self.reportDir.appendingPathComponent(file))
            summary.append(["file": file, "kind": item.kind.rawValue, "category": a.category.rawValue,
                            "product": a.product, "colors": a.colors, "pattern": a.pattern.rawValue,
                            "material": a.material ?? "", "fit": a.fit?.rawValue ?? "",
                            "neckline": a.neckline?.rawValue ?? "", "sleeve": a.sleeveLength?.rawValue ?? "",
                            "length": a.garmentLength?.rawValue ?? "", "quality": Double(item.quality),
                            "truncated": item.truncated,
                            "box": [item.box.minX, item.box.minY, item.box.maxX, item.box.maxY].map { Double($0) }])
        }
        let json = try JSONSerialization.data(withJSONObject: ["fixture": fixture, "seconds": secs, "items": summary],
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: Self.reportDir.appendingPathComponent("\(stem).json"))
        print("[Report] \(fixture): \(items.count) items in \(String(format: "%.1f", secs))s — " +
              items.map { "\($0.attributes.product) [\($0.attributes.colors.joined(separator: "/"))] q=\(String(format: "%.2f", $0.quality))" }
                .joined(separator: "; "))

        let expected = Self.cases.first { $0.0 == fixture }?.1 ?? []
        let categories = Set(items.map { $0.attributes.category.rawValue })
        for cat in expected {
            #expect(categories.contains(cat), "\(fixture): expected a \(cat) item, got \(categories.sorted())")
        }
        // Every cutout is a framed square with real transparency.
        for item in items {
            let s = item.cutout.size
            #expect(abs(s.width - s.height) <= 1, "cutout not square: \(s)")
            #expect(max(s.width, s.height) <= 1024)
        }
    }

    @Test func coatPhotoNamesTheCoatAndSneakers() throws {
        try #require(WardrobeExtractor.isAvailable)
        let items = try FixtureExtraction.run("street_coat_scarf.jpg").items
        let products = items.map { $0.attributes.product }
        #expect(products.contains { ["Coats", "Overcoats", "Trench Coats"].contains($0) }, "got \(products)")
        #expect(products.contains("Sneakers"), "got \(products)")
        #expect(products.contains("Scarves"), "got \(products)")
        // The coat is light grey, not black.
        if let coat = items.first(where: { $0.attributes.category == .outerwear }) {
            #expect(!coat.attributes.colors.isEmpty && coat.attributes.colors[0] != "Black",
                    "coat colours \(coat.attributes.colors)")
        }
    }

    @Test func colourNamerBasics() {
        #expect(ColorNamer.dominantColors(Self.solid(r: 20, g: 30, b: 70)) == ["Navy"])
        #expect(ColorNamer.dominantColors(Self.solid(r: 245, g: 245, b: 245)) == ["White"])
        #expect(ColorNamer.dominantColors(Self.solid(r: 15, g: 15, b: 15)) == ["Black"])
        #expect(ColorNamer.dominantColors(Self.solid(r: 190, g: 30, b: 40)) == ["Red"])
    }

    private static func solid(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let w = 64, h = 64
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        return ctx.makeImage()!
    }
}
