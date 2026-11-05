import Foundation
import Testing
import UIKit
@testable import StyleMate

/// Runs each fixture through the extractor once per test process and shares the
/// result between the extraction, benchmark and studio suites (extraction takes
/// ~30–80 s a photo on the simulator's CPU).
enum FixtureExtraction {
    struct Run {
        let items: [WardrobeExtractor.Item]
        let seconds: Double
        /// The extractor's diagnostics (drops, zoom finds) for the report.
        let trace: [String]
    }

    private static let lock = NSLock()
    private static var cache: [String: Run] = [:]

    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var fixturesRoot: URL? {
        if let p = env["FIXTURES_DIR"] { return URL(fileURLWithPath: p) }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    static var reportRoot: URL {
        let dir = env["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wardrobe-report")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func photo(_ name: String) throws -> UIImage {
        guard let root = fixturesRoot else { throw Failure(description: "fixtures directory not found") }
        let data = try Data(contentsOf: root.appendingPathComponent("photos").appendingPathComponent(name))
        guard let image = UIImage(data: data) else { throw Failure(description: "could not decode \(name)") }
        return image
    }

    /// One extraction at a time (they'd only fight over the CPU), each fixture once.
    static func run(_ fixture: String) throws -> Run {
        let image = try photo(fixture)
        lock.lock(); defer { lock.unlock() }
        if let r = cache[fixture] { return r }
        let start = Date()
        var trace: [String] = []
        let items = WardrobeExtractor.extract(from: image) { trace.append($0) }
        let r = Run(items: items, seconds: Date().timeIntervalSince(start), trace: trace)
        cache[fixture] = r
        return r
    }
}

/// Accuracy benchmark against hand labels (`Fixtures/labels/<fixture>.json`).
///
/// Predictions are matched to labelled items greedily by box IoU >= 0.3 within
/// a compatible slot (any upper-body kind matches any upper-body label, head- and
/// neckwear match each other). Reports precision / recall over the core items,
/// category, product and primary-colour accuracy (exact and by colour family),
/// colour-name precision, pattern errors, sleeve accuracy, fragment rate and
/// seconds per photo into $REPORT_DIR/benchmark.json, and fails when a headline
/// metric regresses by more than 3 points against `labels/baseline.json`.
@Suite(.serialized)
struct WardrobeBenchmarkTests {
    struct Label: Decodable {
        let id: String
        let kind: String
        let categories: [String]
        let products: [String]
        let colors_primary: [String]
        let colors_all: [String]
        let pattern: [String]?
        let sleeve: [String]?
        let core: Bool
        let bbox: [Double]

        var rect: CGRect { CGRect(x: bbox[0], y: bbox[1], width: bbox[2] - bbox[0], height: bbox[3] - bbox[1]) }
    }

    struct LabelFile: Decodable {
        let fixture: String
        let items: [Label]
    }

    static func slot(_ kind: String) -> String {
        switch kind {
        case "innerTop", "outerLayer", "onePiece": return "upper"
        case "headwear", "neckwear": return "headneck"
        default: return kind
        }
    }

    /// Colour families for the "roughly right" colour score.
    static func family(_ c: String) -> String {
        switch c {
        case "Black", "Charcoal": return "black"
        case "Gray", "Silver": return "gray"
        case "White", "Cream": return "white"
        case "Beige", "Tan", "Khaki", "Brown": return "brown"
        case "Red", "Burgundy", "Maroon": return "red"
        case "Orange", "Rust", "Coral": return "orange"
        case "Yellow", "Gold": return "yellow"
        case "Olive", "Green", "Mint", "Teal": return "green"
        case "Light Blue", "Blue", "Navy": return "blue"
        case "Lavender", "Purple": return "purple"
        case "Pink": return "pink"
        default: return c.lowercased()
        }
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }

    /// Visible parts of a cutout: alpha components >= 4% of the largest one.
    static func parts(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        let side = 160
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return 1 }
        let p = data.assumingMemoryBound(to: UInt8.self)
        var m = [UInt8](repeating: 0, count: side * side)
        for i in 0..<(side * side) { m[i] = p[i * 4 + 3] > 128 ? 1 : 0 }
        let (_, sizes) = GarmentSegmenter.components(m, w: side, h: side)
        guard let largest = sizes.max(), largest > 0 else { return 1 }
        return sizes.filter { $0 * 25 >= largest }.count
    }

    /// Mirrored pairs (two shoes, an open coat's halves) are not fragments.
    static func allowedParts(_ kind: GarmentKind) -> Int {
        switch kind {
        case .footwear, .outerLayer, .eyewear: return 2
        default: return 1
        }
    }

    @Test(.timeLimit(.minutes(40)))
    func benchmark() throws {
        try #require(WardrobeExtractor.isAvailable)
        let root = try #require(FixtureExtraction.fixturesRoot)
        let labelDir = root.appendingPathComponent("labels")
        let files = try FileManager.default.contentsOfDirectory(atPath: labelDir.path)
            .filter { $0.hasSuffix(".json") && $0 != "baseline.json" }.sorted()
        try #require(!files.isEmpty, "no label files in \(labelDir.path)")

        var predictions = 0, truePositives = 0, falsePositives = 0
        var coreTotal = 0, coreFound = 0
        var catOK = 0, prodOK = 0, colOK = 0, famOK = 0, matched = 0
        var colourNames = 0, colourNamesOK = 0
        var falsePatterns = 0, missedPatterns = 0, patternOK = 0, patternTotal = 0
        var sleeveOK = 0, sleeveTotal = 0
        var fragments = 0
        var seconds = 0.0
        var perFixture: [[String: Any]] = []
        var lines: [String] = []
        var matchedItems: [(fixture: String, id: String, item: WardrobeExtractor.Item)] = []

        for file in files {
            let lf = try JSONDecoder().decode(LabelFile.self, from: Data(contentsOf: labelDir.appendingPathComponent(file)))
            let run = try FixtureExtraction.run(lf.fixture)
            seconds += run.seconds
            let preds = run.items
            predictions += preds.count

            // Greedy IoU matching within compatible slots.
            var pairs: [(p: Int, g: Int, iou: Double)] = []
            for (pi, p) in preds.enumerated() {
                for (gi, g) in lf.items.enumerated() where Self.slot(p.kind.rawValue) == Self.slot(g.kind) {
                    let v = Self.iou(p.box, g.rect)
                    if v >= 0.3 { pairs.append((pi, gi, v)) }
                }
            }
            pairs.sort { $0.iou > $1.iou }
            var pUsed = Set<Int>(), gUsed = Set<Int>()
            var match: [Int: Int] = [:]   // pred -> label
            for pr in pairs where !pUsed.contains(pr.p) && !gUsed.contains(pr.g) {
                pUsed.insert(pr.p); gUsed.insert(pr.g); match[pr.p] = pr.g
            }

            var fixtureItems: [[String: Any]] = []
            for (pi, p) in preds.enumerated() {
                let a = p.attributes
                let nParts = Self.parts(p.cutout)
                let isFragment = nParts > Self.allowedParts(p.kind)
                if isFragment { fragments += 1 }
                var row: [String: Any] = ["product": a.product, "category": a.category.rawValue, "kind": p.kind.rawValue,
                                          "colors": a.colors, "pattern": a.pattern.rawValue,
                                          "sleeve": a.sleeveLength?.rawValue ?? "", "parts": nParts,
                                          "box": [p.box.minX, p.box.minY, p.box.maxX, p.box.maxY].map { Double($0) }]
                guard let gi = match[pi] else {
                    falsePositives += 1
                    row["match"] = "FP"
                    lines.append("  FP  \(lf.fixture): \(a.product) [\(a.colors.joined(separator: "/"))]")
                    fixtureItems.append(row)
                    continue
                }
                let g = lf.items[gi]
                row["match"] = g.id
                guard g.core else { fixtureItems.append(row); continue }   // non-core: neither TP nor FP
                matchedItems.append((lf.fixture, g.id, p))
                truePositives += 1
                matched += 1
                let cat = g.categories.contains(a.category.rawValue)
                let prod = g.products.contains(a.product)
                let primary = a.colors.first ?? ""
                let col = g.colors_primary.contains(primary)
                let fam = g.colors_primary.map(Self.family).contains(Self.family(primary))
                if cat { catOK += 1 }
                if prod { prodOK += 1 }
                if col { colOK += 1 }
                if fam { famOK += 1 }
                for c in a.colors { colourNames += 1; if g.colors_all.contains(c) { colourNamesOK += 1 } }
                if let ps = g.pattern {
                    patternTotal += 1
                    let solidGT = ps == ["Solid"]
                    if ps.contains(a.pattern.rawValue) { patternOK += 1 }
                    else if solidGT { falsePatterns += 1 }
                    else if a.pattern == .solid { missedPatterns += 1 }
                }
                if let ss = g.sleeve, let s = a.sleeveLength?.rawValue {
                    sleeveTotal += 1
                    if ss.contains(s) { sleeveOK += 1 }
                }
                let flags: [String: Any] = ["category_ok": cat, "product_ok": prod, "color_ok": col, "family_ok": fam]
                row.merge(flags, uniquingKeysWith: { $1 })
                fixtureItems.append(row)
                if !(cat && prod && col) || isFragment {
                    lines.append("  \(cat && prod ? "ok " : "BAD") \(lf.fixture) \(g.id): \(a.product) [\(a.colors.joined(separator: "/"))] " +
                                 "want \(g.products.first ?? "") [\(g.colors_primary.joined(separator: "|"))]" +
                                 (isFragment ? " FRAGMENT(\(nParts))" : ""))
                }
            }
            let core = lf.items.filter { $0.core }
            coreTotal += core.count
            for (gi, g) in lf.items.enumerated() where g.core {
                if gUsed.contains(gi) { coreFound += 1 }
                else { lines.append("  MISS \(lf.fixture): \(g.id)") }
            }
            perFixture.append(["fixture": lf.fixture, "seconds": run.seconds, "items": fixtureItems, "trace": run.trace])
        }

        func r(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : (Double(a) / Double(b) * 1000).rounded() / 1000 }
        var metrics: [String: Double] = [
            "precision": r(truePositives, truePositives + falsePositives),
            "recall": r(coreFound, coreTotal),
            "category_acc": r(catOK, matched),
            "product_acc": r(prodOK, matched),
            "color_primary_acc": r(colOK, matched),
            "color_family_acc": r(famOK, matched),
            "color_name_precision": r(colourNamesOK, colourNames),
            "pattern_acc": r(patternOK, patternTotal),
            "false_patterns": Double(falsePatterns),
            "missed_patterns": Double(missedPatterns),
            "sleeve_acc": r(sleeveOK, sleeveTotal),
            "fragment_rate": r(fragments, predictions),
            "seconds_per_photo": (seconds / Double(max(1, files.count)) * 10).rounded() / 10,
            "predictions": Double(predictions),
            "core_items": Double(coreTotal),
            "core_found": Double(coreFound),
            "false_positives": Double(falsePositives)
        ]
        metrics.merge(Self.duplicateReport(matchedItems), uniquingKeysWith: { $1 })
        let report: [String: Any] = ["metrics": metrics, "fixtures": perFixture]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: FixtureExtraction.reportRoot.appendingPathComponent("benchmark.json"))

        let summary = metrics.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[Report] BENCHMARK \(summary)")
        for l in lines { print("[Report] \(l)") }

        // Regression gate against the stored baseline.
        let baselineURL = labelDir.appendingPathComponent("baseline.json")
        guard let data = try? Data(contentsOf: baselineURL),
              let base = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bm = base["metrics"] as? [String: Double] else {
            print("[Report] BENCHMARK no baseline.json; not gating")
            return
        }
        for key in ["precision", "recall", "category_acc", "product_acc", "color_primary_acc", "color_family_acc"] {
            if let b = bm[key], let v = metrics[key] {
                #expect(v >= b - 0.03, "benchmark regression: \(key) \(v) < baseline \(b) - 0.03")
            }
        }
        if let b = bm["false_patterns"], let v = metrics["false_patterns"] {
            #expect(v <= b + 1, "benchmark regression: false_patterns \(v) > baseline \(b) + 1")
        }
    }
    // MARK: - Duplicate thresholds

    /// The same physical garment in two fixture photos (one outfit, two shots).
    static let samePairs: [((String, String), (String, String))] = [
        (("street_coat_cap.jpg", "grey_coat"), ("street_coat_backpack.jpg", "grey_jacket")),
        (("street_coat_cap.jpg", "leather_joggers"), ("street_coat_backpack.jpg", "leather_joggers")),
        (("street_coat_cap.jpg", "sneakers"), ("street_coat_backpack.jpg", "sneakers")),
        (("street_coat_cap.jpg", "cap"), ("street_coat_backpack.jpg", "cap"))
    ]

    /// A cutout re-photographed: mirrored, cropped 85%, or ±15% exposure.
    static func variant(_ image: UIImage, _ v: Int) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        switch v {
        case 0: ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1); ctx.draw(cg, in: r)
        case 1:
            guard let c = cg.cropping(to: r.insetBy(dx: CGFloat(w) * 0.075, dy: CGFloat(h) * 0.075)) else { return nil }
            ctx.draw(c, in: r)
        default:
            ctx.draw(cg, in: r)
            guard let data = ctx.data else { return nil }
            let p = data.assumingMemoryBound(to: UInt8.self)
            let k: Float = v == 2 ? 1.15 : 0.85
            for px in 0..<(w * h) {
                let a = Float(p[px * 4 + 3])   // premultiplied: a channel never exceeds alpha
                for c in 0..<3 { p[px * 4 + c] = UInt8(min(a, Float(p[px * 4 + c]) * k)) }
            }
        }
        return ctx.makeImage()
    }

    static func duplicateReport(_ items: [(fixture: String, id: String, item: WardrobeExtractor.Item)]) -> [String: Double] {
        func embed(_ cg: CGImage) -> [Float]? { FashionClassifier.onWhite(cg, side: 224).flatMap { WardrobeML.shared.embed($0) } }
        let same = DuplicateDetector.visualSame, maybe = DuplicateDetector.visualMaybe
        var sameScores: [Float] = [], diffScores: [Float] = [], rows: [[String: Any]] = []
        // Same garment: augmented copies, and the cross-photo pairs.
        for it in items {
            for v in 0..<4 {
                guard let cg = variant(it.item.cutout, v), let e = embed(cg) else { continue }
                let s = WardrobeExtractor.cosine(e, it.item.attributes.embedding)
                sameScores.append(s)
                rows.append(["kind": "variant\(v)", "a": "\(it.fixture)/\(it.id)", "cos": s])
            }
        }
        func find(_ k: (String, String)) -> WardrobeExtractor.Item? { items.first { $0.fixture == k.0 && $0.id == k.1 }?.item }
        var known = Set<String>()
        for (a, b) in samePairs {
            known.insert("\(a.0)/\(a.1)|\(b.0)/\(b.1)")
            guard let x = find(a), let y = find(b) else { continue }
            let s = WardrobeExtractor.cosine(x.attributes.embedding, y.attributes.embedding)
            sameScores.append(s)
            rows.append(["kind": "cross-photo", "a": "\(a.0)/\(a.1)", "b": "\(b.0)/\(b.1)", "cos": s])
        }
        // Different garments of compatible kinds, from different photos.
        for i in 0..<items.count {
            for j in (i + 1)..<items.count where items[i].fixture != items[j].fixture {
                let a = items[i], b = items[j]
                guard slot(a.item.kind.rawValue) == slot(b.item.kind.rawValue),
                      !known.contains("\(a.fixture)/\(a.id)|\(b.fixture)/\(b.id)"),
                      !known.contains("\(b.fixture)/\(b.id)|\(a.fixture)/\(a.id)") else { continue }
                let s = WardrobeExtractor.cosine(a.item.attributes.embedding, b.item.attributes.embedding)
                diffScores.append(s)
                if s >= maybe { rows.append(["kind": "different", "a": "\(a.fixture)/\(a.id)", "b": "\(b.fixture)/\(b.id)", "cos": s]) }
            }
        }
        func share(_ xs: [Float], _ t: Float) -> Double {
            xs.isEmpty ? 0 : (Double(xs.filter { $0 >= t }.count) / Double(xs.count) * 1000).rounded() / 1000
        }
        let m: [String: Double] = [
            "dup_same_pairs": Double(sameScores.count), "dup_diff_pairs": Double(diffScores.count),
            "dup_same_at_visualSame": share(sameScores, same), "dup_same_at_visualMaybe": share(sameScores, maybe),
            "dup_diff_at_visualSame": share(diffScores, same), "dup_diff_at_visualMaybe": share(diffScores, maybe),
            "dup_same_min": Double(sameScores.min() ?? 0), "dup_diff_max": Double(diffScores.max() ?? 0)
        ]
        let report: [String: Any] = ["thresholds": ["visualSame": same, "visualMaybe": maybe], "metrics": m, "pairs": rows]
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: FixtureExtraction.reportRoot.appendingPathComponent("duplicates.json"))
        }
        print("[Report] DUPLICATES " + m.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        return m
    }
}
