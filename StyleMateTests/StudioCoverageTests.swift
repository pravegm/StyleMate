import Foundation
import Testing
import UIKit
@testable import StyleMate

/// Studio renders for every product family the closet shows, every CI run:
/// shoes (sneakers, boots, oxfords, boat shoes), hats (cap, wide brim),
/// full-length trousers (chinos, black trousers, leggings, joggers, jeans) and
/// a light-grey coat. Inputs are fixed item cutouts (`Fixtures/studio/`, listed
/// in `studio_manifest.json` with their source photo), so a run-to-run change is
/// the studio pipeline's, not the extractor's. Each item is named by the real
/// classifier, planned by `StudioPlan.make`, rendered by the bundled diffusion
/// model (2 candidates; the app renders 3) and gated by `StudioPipeline`.
///
/// Heavy (the simulator runs the UNet on its CPU, ~6 min per candidate), so it
/// only runs in CI's `studio` job, one shard of the manifest per runner
/// (`STUDIO_SHARD`); everywhere else it returns at once. Everything lands in
/// $REPORT_DIR/studio_coverage: `<item>_cutout/_template/_raw<k>/_cand<k>/_studio.png`
/// and `coverage_shard<n>.json` with every candidate's scores.
@Suite(.serialized)
struct StudioCoverageTests {
    struct Case: Decodable {
        let file: String
        let kind: String
        let shard: Int
        let note: String
        let source: String
    }

    static func family(_ kind: GarmentKind) -> String {
        switch kind {
        case .footwear: return "shoes"
        case .headwear: return "hats"
        case .lower: return "trousers"
        default: return "tops & layers"
        }
    }

    @Test(.timeLimit(.minutes(120)))
    func studioCoverage() throws {
        let env = ProcessInfo.processInfo.environment
        guard let shard = env["STUDIO_SHARD"].flatMap(Int.init) else { return }   // CI's studio job only
        try #require(WardrobeExtractor.isAvailable, "needs the bundled wardrobe models")
        try #require(StudioRenderer.shared.isAvailable, "studio models not bundled")
        let root = try #require(FixtureExtraction.fixturesRoot)
        let dir = root.appendingPathComponent("studio")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("studio_manifest.json")))
            .filter { shard < 0 || $0.shard == shard }
        try #require(!cases.isEmpty, "no studio fixtures for shard \(shard)")
        let out = FixtureExtraction.reportRoot.appendingPathComponent("studio_coverage")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var report: [[String: Any]] = []
        var accepted = 0
        for c in cases {
            let stem = (c.file as NSString).deletingPathExtension
            let kind = try #require(GarmentKind(rawValue: c.kind), "unknown kind \(c.kind)")
            let cutout = try #require(UIImage(contentsOfFile: dir.appendingPathComponent(c.file).path), "can't read \(c.file)")
            let cg = try #require(cutout.cgImage)
            let a = try #require(FashionClassifier.classify(cutout, kind: kind), "classifier failed on \(c.file)")
            let shape = StudioTemplate.shape(product: a.product, kind: a.kind, sleeve: a.sleeveLength, fit: a.fit)
            let full = StudioPlan.make(product: a.product, category: a.category, colors: a.colors, pattern: a.pattern,
                                       material: a.material, sleeve: a.sleeveLength, neckline: a.neckline, details: nil,
                                       kind: a.kind, truncated: false, cutout: cg, embedding: a.embedding, fit: a.fit)
            let plan = StudioPlan(mode: full.mode, prompt: full.prompt, negativePrompt: full.negativePrompt,
                                  candidates: 2, productLabel: full.productLabel, isSolid: full.isSolid,
                                  template: full.template, templateStrength: full.templateStrength,
                                  productShot: full.productShot)
            try? cutout.pngData()?.write(to: out.appendingPathComponent("\(stem)_cutout.png"))
            if let t = plan.template { try? UIImage(cgImage: t).pngData()?.write(to: out.appendingPathComponent("\(stem)_template.png")) }
            // A stable seed per fixture (FNV-1a of the name), like the app's per-item UUID seed.
            var seed: UInt32 = 2_166_136_261
            for b in c.file.utf8 { seed = (seed ^ UInt32(b)) &* 16_777_619 }
            var candidates: [[String: Any]] = []
            let start = Date()
            let outcome = StudioPipeline.studioOutcome(cutout: cutout, embedding: a.embedding, plan: plan, seedBase: seed) { k, raw, cand in
                try? UIImage(cgImage: raw).pngData()?.write(to: out.appendingPathComponent("\(stem)_raw\(k).png"))
                var row: [String: Any] = ["candidate": k]
                if let cand {
                    try? cand.image.pngData()?.write(to: out.appendingPathComponent("\(stem)_cand\(k).png"))
                    row.merge(cand.summary, uniquingKeysWith: { $1 })
                } else {
                    row["rejection"] = "nothing separable"
                }
                candidates.append(row)
            }
            let seconds = Date().timeIntervalSince(start)
            var mode = "generate"
            var stepsPerImage = StudioPlan.steps
            switch plan.mode {
            case .refine(let s): mode = "refine \(s)"; stepsPerImage = Int(Float(StudioPlan.steps) * s)
            case .generate:
                if plan.template != nil { mode = "template \(plan.templateStrength)"; stepsPerImage = Int(Float(StudioPlan.steps) * plan.templateStrength) }
                else { mode = "text-to-image" }
            }
            var entry: [String: Any] = [
                "file": c.file, "note": c.note, "source": c.source, "family": Self.family(a.kind), "kind": a.kind.rawValue,
                "product": a.product, "colors": a.colors, "pattern": a.pattern.rawValue, "material": a.material ?? "",
                "fit": a.fit?.rawValue ?? "", "shape": shape?.rawValue ?? "", "mode": mode,
                "prompt": plan.prompt, "negative": plan.negativePrompt, "minSimilarity": StudioPipeline.minSimilarity(for: plan),
                "seconds": Int(seconds), "steps_per_image": stepsPerImage,
                // ~1 s per denoising step on an A17 Pro / A18 Pro Neural Engine (6-bit SD 1.5 UNet, 512 px,
                // Apple ml-stable-diffusion benchmarks) for the app's 3 candidates, plus ~10 s of model
                // loads. NOT measured on a device.
                "ane_estimate_seconds_3_candidates": 10 + stepsPerImage * 3,
                "candidates": candidates]
            var verdict: String
            switch outcome {
            case .rendered(let r):
                try? r.image.pngData()?.write(to: out.appendingPathComponent("\(stem)_studio.png"))
                accepted += 1
                entry["accepted"] = true
                entry["similarity"] = r.similarity
                entry["score"] = r.score
                verdict = "ACCEPTED sim=\(String(format: "%.3f", r.similarity))"
            case .rejected(let best):
                entry["accepted"] = false
                entry["best_similarity"] = best ?? -1
                verdict = "rejected (best sim \(best.map { String(format: "%.3f", $0) } ?? "-"))"
            case .failed:
                entry["accepted"] = false
                verdict = "render failed"
            }
            report.append(entry)
            let lines = candidates.map { r -> String in
                let sim = (r["similarity"] as? Float).map { String(format: "%.3f", $0) } ?? "-"
                let rej = (r["rejection"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ok"
                return "c\(r["candidate"] ?? ""): sim=\(sim) \(rej)"
            }
            print("[Report] studio-coverage \(stem) [\(Self.family(a.kind))] \(a.product) \(a.colors.joined(separator: "/")) " +
                  "shape=\(shape?.rawValue ?? "-") \(mode): \(verdict) in \(Int(seconds))s — " + lines.joined(separator: "; "))
            if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: out.appendingPathComponent("coverage_shard\(shard).json"))
            }
        }
        // Per-family acceptance for the log.
        var byFamily: [String: (Int, Int)] = [:]
        for e in report {
            let f = e["family"] as? String ?? "?"
            let ok = (e["accepted"] as? Bool) == true
            byFamily[f, default: (0, 0)].0 += ok ? 1 : 0
            byFamily[f, default: (0, 0)].1 += 1
        }
        print("[Report] studio-coverage shard \(shard): " + byFamily.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.0)/\($0.value.1) accepted" }.joined(separator: ", "))
        #expect(accepted >= 1, "no studio render accepted in shard \(shard)")
    }
}
