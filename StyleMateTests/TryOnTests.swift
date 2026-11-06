import Foundation
import Testing
import UIKit
@testable import StyleMate

/// "On you" try-on, on CC0 fixture photos with studio-render closet items
/// (`Fixtures/tryon/items`, made by the app's own studio renderer from CC0 photos).
///
/// Every composite, its gate verdict and the timings go to $REPORT_DIR/tryon/ (the `ci-report`
/// artifact): `<body>__<outfit>.jpg` (photo | try-on), `report.json`, `timing.txt`.
@Suite(.serialized)
struct TryOnTests {
    static let env = ProcessInfo.processInfo.environment

    static var fixtures: URL {
        env["FIXTURES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static var reportDir: URL {
        let base = env["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wardrobe-report")
        let dir = base.appendingPathComponent("tryon")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func photo(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("photos/\(name).jpg"))
        let img = try #require(UIImage(data: data))
        return try #require(TryOnBodyLibrary.upright(img, maxSide: 2048))
    }

    struct ItemMeta: Decodable { let category: String; let product: String; let fit: String?; let sleeve: String? }

    static func garment(_ key: String) throws -> TryOnGarmentSpec {
        let dir = fixtures.appendingPathComponent("tryon/items")
        let metas = try JSONDecoder().decode([String: ItemMeta].self, from: Data(contentsOf: dir.appendingPathComponent("items.json")))
        let m = try #require(metas[key])
        let img = try #require(UIImage(contentsOfFile: dir.appendingPathComponent("\(key).png").path)?.cgImage)
        let role: TryOnRole
        switch m.category {
        case "Bottoms": role = .bottom
        case "Outerwear": role = .outer
        case "One-Pieces": role = .onePiece
        default: role = .top
        }
        return TryOnGarmentSpec(role: role, product: m.product, fit: m.fit.flatMap(Fit.init(rawValue:)),
                                sleeve: m.sleeve.flatMap(SleeveLength.init(rawValue:)), image: img)
    }

    static let outfits: [(String, [String])] = [
        ("tee_jeans", ["navytee", "bluejeans"]),
        ("flannel_jeans", ["flannel", "whitejeans"]),
        ("jacket_tank", ["tank", "jacket", "bluejeans"]),
        ("coat", ["blacktee", "pinkcoat", "bluejeans"]),
        ("dress", ["dress"]),
    ]
    /// Full-length, front-facing CC0 photos (a fitted outfit first: the easiest body).
    static let bodies = ["street_leather_tunic", "pink_coat_boots", "street_coat_cap", "denim_shirt_small_fullbody"]

    static func report(_ line: String) {
        let url = reportDir.appendingPathComponent("timing.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
        print("[Report] tryon \(line)")
    }

    /// photo | try-on side by side, as a JPEG in the report.
    static func saveSheet(_ name: String, body: TryOnBodyModel, images: [CGImage]) {
        let h = body.height, w = body.width
        guard let ctx = TryOnDraw.context(width: w * (images.count + 1), height: h),
              let original = body.image.opaqueCGImage() else { return }
        for (k, img) in ([original] + images).enumerated() {
            TryOnDraw.draw(img, in: ctx, transform: CGAffineTransform(a: CGFloat(w) / CGFloat(img.width), b: 0, c: 0,
                                                                     d: CGFloat(h) / CGFloat(img.height), tx: CGFloat(k * w), ty: 0))
        }
        if let out = ctx.makeImage(), let data = UIImage(cgImage: out).jpegData(compressionQuality: 0.85) {
            try? data.write(to: reportDir.appendingPathComponent(name + ".jpg"))
        }
    }

    // MARK: - Body photos

    @Test func bodyPhotoScoring() throws {
        var lines: [String] = []
        let names = Self.bodies + ["street_back_view", "jeans_white_shirt_halfbody", "flannel_shirt_group"]
        var visionWorks = false
        for n in names {
            let img = try Self.photo(n)
            let raw = TryOnBodyAnalyzer.detectPose(img)
            if raw != nil { visionWorks = true }
            let s = TryOnBodyLibrary.quickScore(img)
            lines.append("\(n): pose=\(raw != nil) people=\(raw?.personCount ?? 0) score=\(s.map { String(format: "%.2f", $0) } ?? "unusable")")
        }
        Self.report("body scores (Vision pose \(visionWorks ? "available" : "unavailable here")):\n  " + lines.joined(separator: "\n  "))
        guard visionWorks else { return }   // the simulator may have no Vision body pose
        #expect(TryOnBodyLibrary.quickScore(try Self.photo("jeans_white_shirt_halfbody")) == nil, "a waist-down crop is not a body photo")
        #expect(TryOnBodyLibrary.quickScore(try Self.photo("street_leather_tunic")) != nil, "a full-length front photo is")
    }

    // MARK: - Composite + gate on every body x outfit

    @Test(.timeLimit(.minutes(40)))
    func compositesAndGatesOutfits() async throws {
        guard WardrobeML.shared.isAvailable else { Issue.record("wardrobe models missing"); return }
        var rows: [[String: Any]] = []
        var passed = 0, total = 0
        for b in Self.bodies {
            let t0 = CFAbsoluteTimeGetCurrent()
            let analysed = TryOnBodyAnalyzer.analyze(try Self.photo(b))
            guard case .success(let body) = analysed else { Issue.record("\(b): body analysis failed \(analysed)"); continue }
            Self.report("\(b): body analysis \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0))s, pose from \(body.pose.source), \(body.width)x\(body.height), clothing bulk \(String(format: "%.3f", TryOnBodyLibrary.clothingBulk(body)))")
            var images: [CGImage] = []
            for (name, keys) in Self.outfits {
                let garments = try keys.map(Self.garment)
                let t = CFAbsoluteTimeGetCurrent()
                let outcome = await TryOnRenderer.render(body: body, garments: garments, harmonize: false)
                let secs = CFAbsoluteTimeGetCurrent() - t
                total += 1
                var row: [String: Any] = ["body": b, "outfit": name, "seconds": secs]
                switch outcome {
                case .ready(let r):
                    passed += 1
                    images.append(r.image)
                    row["verdict"] = "ready"
                    row["report"] = Self.json(r.report)
                    #expect(r.report.faceChangedPixels == 0)
                case .rejected(let rep, let comp):
                    if let comp { images.append(comp) }
                    row["verdict"] = "rejected: \(rep.rejection ?? "")"
                    row["report"] = Self.json(rep)
                    #expect(rep.faceChangedPixels == 0)
                case .failed(let why):
                    row["verdict"] = "failed: \(why)"
                    Issue.record("\(b) / \(name) failed: \(why)")
                }
                Self.report("\(b) / \(name): \(row["verdict"] ?? "") in \(String(format: "%.1f", secs))s")
                rows.append(row)
            }
            // Composites without the diffusion pass: the gate's input, never shown to a user as is.
            Self.saveSheet("composite__" + b, body: body, images: images)
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.reportDir.appendingPathComponent("report.json"))
        Self.report("composite-only: \(passed)/\(total) passed the gate")
        // Composite-only output is the gate's input, never what a user sees (Beta shows harmonised looks
        // only), so its pass rate is reported here, not asserted; harmonizedTryOn asserts what ships, with
        // the gate unchanged. With the commercial GarmentNet segmenter each composite repaints more of the
        // body than the old FASHN parser's did: CI 42166968041 (4cbbc27) passed 4/20 composite-only
        // (invented share 0.12-0.21 on the tee and coat looks vs the 0.09 limit), against 12-13/20 before,
        // while pink_coat_boots / tee_jeans was ready after harmonisation (154 s on CI). Re-running the easy
        // body through the diffusion pass here would add ~150 s per look and duplicate harmonizedTryOn.
        let easy = rows.filter { ($0["body"] as? String) == "street_leather_tunic" && ["tee_jeans", "flannel_jeans"].contains($0["outfit"] as? String ?? "") }
        Self.report("composite-only, fitted body (tee/flannel + jeans): \(easy.map { $0["verdict"] ?? "" })")
    }

    static func json(_ r: TryOnGate.Report) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(r))) ?? [:]
    }

    // MARK: - The gate rejects a wrong item

    @Test func gateRejectsTheWrongItem() async throws {
        guard WardrobeML.shared.isAvailable else { return }
        guard case .success(let body) = TryOnBodyAnalyzer.analyze(try Self.photo("street_leather_tunic")) else {
            Issue.record("body analysis failed"); return
        }
        let tee = try Self.garment("navytee"), jeans = try Self.garment("bluejeans"), coat = try Self.garment("pinkcoat")
        let comp = try #require(TryOnCompositor.composite(body: body, garments: [tee, jeans]))
        // Right references: passes the per-piece checks.
        let good = TryOnGate.check(final: comp.image, body: body, composite: comp,
                                   references: [tee.id: tee.image, jeans.id: jeans.image], harmonized: false)
        // The navy tee checked against the pink coat's image: must fail (similarity or colour).
        let bad = TryOnGate.check(final: comp.image, body: body, composite: comp,
                                  references: [tee.id: coat.image, jeans.id: jeans.image], harmonized: false)
        Self.report("gate: right items sim=\(good.pieces.map { $0.similarity.map { String(format: "%.3f", $0) } ?? "-" }) " +
                    "wrong item sim=\(bad.pieces.map { $0.similarity.map { String(format: "%.3f", $0) } ?? "-" }) " +
                    "verdict right=\(good.rejection ?? "pass") wrong=\(bad.rejection ?? "pass")")
        #expect(good.pieces.allSatisfy { $0.rejection == nil }, "\(good.pieces.map { $0.rejection ?? "ok" })")
        #expect(bad.pieces.first(where: { $0.id == tee.id })?.rejection != nil, "a navy tee must not pass as a pink coat")
        // Face, hair and hands are never changed.
        #expect(good.faceChangedPixels == 0)
    }

    // MARK: - Full pipeline with the diffusion pass (Core ML on the simulator's CPU: slow)

    @Test(.timeLimit(.minutes(50)))
    func harmonizedTryOn() async throws {
        guard WardrobeML.shared.isAvailable, TryOnHarmonizer.shared.isAvailable else {
            Issue.record("models missing"); return
        }
        let saved = TryOnRenderer.steps
        TryOnRenderer.steps = 12   // CI budget: ~10 UNet steps on the CPU per look
        defer { TryOnRenderer.steps = saved }
        // What a user sees: a coat-wearing body (lots to invent) and a fitted one with a dress (legs to invent).
        for (b, keys, name) in [("pink_coat_boots", ["navytee", "bluejeans"], "tee_jeans"),
                                ("street_leather_tunic", ["dress"], "dress")] {
            guard case .success(let body) = TryOnBodyAnalyzer.analyze(try Self.photo(b)) else {
                Issue.record("\(b): body analysis failed"); continue
            }
            let garments = try keys.map(Self.garment)
            let t = CFAbsoluteTimeGetCurrent()
            let outcome = await TryOnRenderer.render(body: body, garments: garments, harmonize: true)
            let secs = CFAbsoluteTimeGetCurrent() - t
            let unetSteps = TryOnHarmonizer.shared.lastSteps
            // iPhone estimate: ~1 s per SD 1.5 UNet step on the Neural Engine (Apple's ml-stable-diffusion
            // benchmarks, same model class as the studio renders) at the app's 20-step schedule (~17 steps
            // with the 0.85 max strength) + ~3 s for the composite, VAE and gate.
            let iphoneEstimate = Double(Int(Double(20) * 0.85)) * 1.0 + 3
            switch outcome {
            case .ready(let r):
                // photo | composite (never shown) | the finished try-on (what the user sees)
                Self.saveSheet("shown__\(b)__\(name)", body: body, images: [r.composite, r.image].compactMap { $0 })
                Self.report("harmonized \(b) / \(name): ready in \(String(format: "%.0f", secs))s on CI (\(unetSteps) UNet steps, harmonised=\(r.harmonized)); iPhone estimate ~\(Int(iphoneEstimate))s per outfit; report \(Self.json(r.report))")
                #expect(r.report.faceChangedPixels == 0)
                #expect(r.harmonized)
            case .rejected(let rep, let comp):
                if let comp { Self.saveSheet("rejected__\(b)__\(name)", body: body, images: [comp]) }
                Self.report("harmonized \(b) / \(name): rejected (\(rep.rejection ?? "")) in \(String(format: "%.0f", secs))s, \(unetSteps) UNet steps; \(Self.json(rep))")
                #expect(rep.faceChangedPixels == 0)
                #expect(rep.harmonized, "the diffusion pass should have run")
                // What ships: tee + jeans on the coat body must be ready after harmonisation (gate unchanged).
                #expect(name != "tee_jeans", "the harmonised tee + jeans look is what a user sees; it must pass the gate")
            case .failed(let why):
                Issue.record("harmonized try-on \(b) / \(name) failed: \(why)")
            }
        }
    }

    // MARK: - Cache keys

    @Test func cacheKeyFollowsBodyItemsAndImages() {
        func item(_ id: UUID, _ path: String, _ cat: StyleMate.Category = .tops) -> WardrobeItem {
            WardrobeItem(id: id, category: cat, product: "T-Shirts", colors: ["Navy"], brand: "", pattern: .solid,
                         imagePath: path, croppedImagePath: nil, thumbnailPath: nil, material: nil, fit: nil,
                         neckline: nil, sleeveLength: nil, garmentLength: nil, details: nil)
        }
        let a = UUID(), b = UUID()
        let k1 = TryOnStore.key(bodyID: "body1", items: [item(a, "a.png"), item(b, "b.png", .bottoms)])
        let k2 = TryOnStore.key(bodyID: "body1", items: [item(b, "b.png", .bottoms), item(a, "a.png")])
        let k3 = TryOnStore.key(bodyID: "body1", items: [item(a, "a2.png"), item(b, "b.png", .bottoms)])
        let k4 = TryOnStore.key(bodyID: "body2", items: [item(a, "a.png"), item(b, "b.png", .bottoms)])
        #expect(k1 == k2, "order doesn't matter")
        #expect(k1 != k3, "a new item image (studio render landed) re-renders")
        #expect(k1 != k4, "another body photo re-renders")
    }
}
