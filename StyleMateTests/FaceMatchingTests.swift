import Foundation
import Testing
import UIKit
@testable import StyleMate

/// Sanity checks for the on-device identity pipeline (YuNet detection + 5-point alignment +
/// SFace embedding, `FaceModelProfile.active`) with the real bundled models: the same face
/// survives a re-crop/rescale, different people stay apart, and a fixture benchmark of
/// same-person / different-person similarities goes to $REPORT_DIR/faces.txt.
@Suite(.serialized)
struct FaceMatchingTests {
    private static let userId = "facetest@stylemate.test"

    private func fixture(_ name: String) throws -> UIImage {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FIXTURES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("photos") }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/photos")
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return try #require(UIImage(data: data))
    }

    /// Re-frames a photo the way a different shot of the same moment would:
    /// tighter crop, smaller, slightly darker.
    private func variant(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard let crop = cg.cropping(to: CGRect(x: w * 0.08, y: 0, width: w * 0.84, height: h * 0.7)) else { return nil }
        let size = CGSize(width: CGFloat(crop.width) * 0.75, height: CGFloat(crop.height) * 0.75)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            UIColor.black.withAlphaComponent(0.12).setFill()
            ctx.fill(CGRect(origin: .zero, size: size), blendMode: .normal)   // plain fill() replaces the image
        }.cgImage
    }

    private func useAsSelfie(_ image: UIImage) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facetest_selfie.jpg")
        try #require(image.jpegData(compressionQuality: 0.95)).write(to: url)
        UserDefaults.standard.set(url.path, forKey: "selfieReferencePath_\(Self.userId)")
        FaceMatchingService.shared.clearReference(forUser: Self.userId)
        #expect(FaceMatchingService.shared.loadReference(forUser: Self.userId), "could not build a reference from the selfie")
    }

    /// Writes face diagnostics to $REPORT_DIR/faces.txt (print() from the test
    /// host doesn't reach the xcodebuild log).
    private func report(_ line: String) {
        let base = ProcessInfo.processInfo.environment["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("faces.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    /// The whole pipeline (detect → align → embed) must be deterministic: the
    /// identical photo scores ~1.0 against itself. If this fails, a model or
    /// preprocessing step is broken, not a threshold.
    @Test(arguments: ["kurta_dhoti_turban.jpg", "casual_denim_jacket_hat.jpg", "street_coat_cap.jpg"])
    func identicalPhotoMatchesItself(_ name: String) throws {
        let photo = try fixture(name)
        try useAsSelfie(photo)
        let match = FaceMatchingService.shared.findUserInPhoto(try #require(photo.cgImage))
        report("identical \(name): sim=\(match.similarity ?? -1) faces=\(match.faceCount) gallery=\(FaceMatchingService.shared.referenceCount) model=\(FaceMatchingService.modelVersion)")
        #expect(match.faceCount >= 1, "the detector found no face in \(name)")
        #expect((match.similarity ?? 0) > 0.9, "\(name) vs itself scored \(match.similarity ?? -1)")
    }

    /// Where does a face get lost? Detect on each transformation step separately
    /// (and save the images) — the scan feeds UIGraphicsImageRenderer output to
    /// the detector too, so this must hold for renderer-made images.
    @Test func detectorSurvivesEachTransformStep() throws {
        let photo = try fixture("kurta_dhoti_turban.jpg")
        let cg = try #require(photo.cgImage)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let crop = try #require(cg.cropping(to: CGRect(x: w * 0.08, y: 0, width: w * 0.84, height: h * 0.7)))
        func render(_ src: CGImage, scale s: CGFloat, darken: Bool, opaque: Bool) -> CGImage? {
            let size = CGSize(width: CGFloat(src.width) * s, height: CGFloat(src.height) * s)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1
            fmt.opaque = opaque
            return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIImage(cgImage: src).draw(in: CGRect(origin: .zero, size: size))
                if darken {
                    UIColor.black.withAlphaComponent(0.12).setFill()
                    ctx.fill(CGRect(origin: .zero, size: size), blendMode: .normal)   // plain fill() replaces the image
                }
            }.cgImage
        }
        let steps: [(String, CGImage?)] = [
            ("original", cg), ("crop", crop),
            ("render1x", render(crop, scale: 1, darken: false, opaque: false)),
            ("render075", render(crop, scale: 0.75, darken: false, opaque: false)),
            ("render075opaque", render(crop, scale: 0.75, darken: false, opaque: true)),
            ("render075dark", render(crop, scale: 0.75, darken: true, opaque: false))
        ]
        let base = ProcessInfo.processInfo.environment["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        for (label, img) in steps {
            guard let img else { report("step \(label): nil image"); continue }
            let faces = FaceDetector.shared.detect(in: img)
            report("step \(label): \(img.width)x\(img.height) bpc=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel) alpha=\(img.alphaInfo.rawValue) info=\(img.bitmapInfo.rawValue) faces=\(faces.count) boxes=\(faces.map { "\(Int($0.boxPixels.width))x\(Int($0.boxPixels.height))@\(String(format: "%.2f", $0.score))" })")
            #expect(!faces.isEmpty, "no face after step \(label)")
            try? UIImage(cgImage: img).pngData()?.write(to: base.appendingPathComponent("face_step_\(label).png"))
        }
    }

    @Test(arguments: ["kurta_dhoti_turban.jpg", "casual_denim_jacket_hat.jpg", "street_coat_cap.jpg"])
    func sameFaceMatchesAcrossReframing(_ name: String) throws {
        let photo = try fixture(name)
        try useAsSelfie(photo)
        let cg = try #require(variant(photo))
        let match = FaceMatchingService.shared.findUserInPhoto(cg)
        report("reframed \(name): sim=\(match.similarity ?? -1) faces=\(match.faceCount)")
        #expect(match.faceCount >= 1, "the detector found no face")
        #expect((match.similarity ?? 0) >= FaceMatchingService.highConfidenceThreshold,
                "same face scored \(match.similarity ?? -1)")
    }

    @Test func differentPeopleStayApart() throws {
        try useAsSelfie(try fixture("street_coat_cap.jpg"))
        for other in ["street_coat_boots.jpg", "street_coat_backpack.jpg", "street_coat_scarf.jpg"] {
            let cg = try #require(try fixture(other).cgImage)
            let match = FaceMatchingService.shared.findUserInPhoto(cg)
            report("impostor \(other) vs street_coat_cap: sim=\(match.similarity ?? -1) faces=\(match.faceCount)")
            if let s = match.similarity {
                #expect(s < FaceMatchingService.highConfidenceThreshold, "\(other) would be auto-added as the user (sim \(s))")
            }
        }
    }

    @Test func scanQueuesBorderlineInsteadOfDropping() throws {
        // A gallery of only the selfie: a confident re-framed match is analyzed,
        // a stranger is skipped (never queued as "is this you?" spam).
        let photo = try fixture("street_coat_cap.jpg")
        try useAsSelfie(photo)
        let same = try #require(variant(photo))
        if case .skip = FaceMatchingService.shared.resolveIdentityForScan(in: same, fullImage: UIImage(cgImage: same), userId: Self.userId) {
            Issue.record("the user's own re-framed photo was skipped")
        }
        let stranger = try #require(try fixture("street_coat_boots.jpg").cgImage)
        if case .analyze = FaceMatchingService.shared.resolveIdentityForScan(in: stranger, fullImage: UIImage(cgImage: stranger), userId: Self.userId) {
            Issue.record("a stranger was auto-added")
        }
    }

    // MARK: - Detector contract

    /// The 5 landmarks must come out in the canonical ArcFace order (image-left eye, image-right
    /// eye, nose, image-left mouth corner, image-right mouth corner), or every aligned face is
    /// mirrored or scrambled and identity collapses.
    @Test func landmarksAreInArcFaceOrder() throws {
        let cg = try #require(try fixture("kurta_dhoti_turban.jpg").cgImage)
        let face = try #require(FaceDetector.shared.detect(in: cg, padRetry: false)
            .max { $0.boxPixels.width < $1.boxPixels.width })
        let k = face.keypoints
        report("landmarks kurta: box=\(face.boxPixels.integral) score=\(String(format: "%.3f", face.score)) kps=\(k.map { "(\(Int($0.x)),\(Int($0.y)))" })")
        #expect(k.count == 5)
        #expect(k[0].x < k[1].x, "eyes swapped")
        #expect(k[3].x < k[4].x, "mouth corners swapped")
        #expect(max(k[0].y, k[1].y) < k[2].y && k[2].y < min(k[3].y, k[4].y), "eyes above nose above mouth")
        for p in k {
            #expect(face.boxPixels.insetBy(dx: -4, dy: -4).contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))))
        }
    }

    /// A selfie frame where the face fills the picture is bigger than the detector's training
    /// range; the pad retry must still find it, and it must still be the same person.
    @Test func frameFillingFaceIsFoundWithThePadRetry() throws {
        let photo = try fixture("kurta_dhoti_turban.jpg")
        let cg = try #require(photo.cgImage)
        let face = try #require(FaceDetector.shared.detect(in: cg, padRetry: false).max { $0.boxPixels.width < $1.boxPixels.width })
        let tight = try #require(cg.cropping(to: face.boxPixels.insetBy(dx: face.boxPixels.width * 0.05,
                                                                         dy: face.boxPixels.height * 0.05).integral))
        let size = CGSize(width: 900, height: 900 * CGFloat(tight.height) / CGFloat(tight.width))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let big = try #require(UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: tight).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage)
        let noRetry = FaceDetector.shared.detect(in: big, padRetry: false)
        let withRetry = FaceDetector.shared.detect(in: big, padRetry: true)
        report("frame-filling face: \(big.width)x\(big.height) faces without retry=\(noRetry.count) with retry=\(withRetry.count)")
        #expect(!withRetry.isEmpty, "a frame-filling face was not found even with the pad retry")
        try useAsSelfie(photo)
        let match = FaceMatchingService.shared.findUserInPhoto(big, padRetry: true)
        report("frame-filling face vs its photo: sim=\(match.similarity ?? -1)")
        #expect((match.similarity ?? 0) >= FaceMatchingService.borderlineThreshold)
    }

    /// Front-camera selfies are mirrored, library photos aren't. With flip averaging the
    /// embedding of a mirrored photo is (almost) the embedding of the photo.
    @Test func mirroredPhotoEmbedsTheSame() throws {
        let photo = try fixture("casual_denim_jacket_hat.jpg")
        let cg = try #require(photo.cgImage)
        let mirrored = try #require(SelfieReferenceStore.mirrored(cg))
        let a = try #require(FaceMatchingService.shared.embedFaces(in: cg, padRetry: false).first)
        let b = try #require(FaceMatchingService.shared.embedFaces(in: mirrored, padRetry: false).first)
        let sim = FaceMath.dot(a.embedding, b.embedding)
        report("mirror invariance casual_denim: sim=\(sim) flipAverage=\(FaceModelProfile.active.flipAverage) dim=\(a.embedding.count)")
        #expect(a.embedding.count == FaceModelProfile.active.embeddingDimension)
        #expect(sim >= (FaceModelProfile.active.flipAverage ? 0.95 : FaceMatchingService.highConfidenceThreshold))
    }

    // MARK: - Fixture benchmark

    private static let benchmarkPhotos = [
        "casual_denim_jacket_hat.jpg", "denim_shirt_small_fullbody.jpg", "flannel_shirt_group.jpg",
        "jeans_white_shirt_halfbody.jpg", "kurta_dhoti_turban.jpg", "pink_coat_boots.jpg",
        "ripped_jeans_belt_watch.jpg", "street_back_view.jpg", "street_coat_backpack.jpg",
        "street_coat_boots.jpg", "street_coat_cap.jpg", "street_coat_scarf.jpg", "street_leather_tunic.jpg"
    ]

    /// A photo transform and where it moves a point (to find the same face again by position,
    /// not by similarity, which would bias the genuine scores upward).
    private struct Transform {
        let name: String
        let apply: (CGImage) -> CGImage?
        let map: (CGPoint, CGSize) -> CGPoint
    }

    private static func render(_ cg: CGImage, size: CGSize, _ draw: (CGContext, CGSize) -> Void) -> CGImage? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            draw(ctx.cgContext, size)
        }.cgImage
    }

    private static let transforms: [Transform] = [
        Transform(name: "reframe", apply: { cg in
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            guard let crop = cg.cropping(to: CGRect(x: w * 0.08, y: 0, width: w * 0.84, height: h * 0.7)) else { return nil }
            return render(crop, size: CGSize(width: CGFloat(crop.width) * 0.75, height: CGFloat(crop.height) * 0.75)) { c, s in
                c.setFillColor(UIColor.black.withAlphaComponent(0.12).cgColor); c.fill(CGRect(origin: .zero, size: s))
            }
        }, map: { p, s in CGPoint(x: (p.x - s.width * 0.08) * 0.75, y: p.y * 0.75) }),
        Transform(name: "half", apply: { cg in
            render(cg, size: CGSize(width: CGFloat(cg.width) * 0.5, height: CGFloat(cg.height) * 0.5)) { _, _ in }
        }, map: { p, _ in CGPoint(x: p.x * 0.5, y: p.y * 0.5) }),
        Transform(name: "mirror", apply: { SelfieReferenceStore.mirrored($0) },
                  map: { p, s in CGPoint(x: s.width - p.x, y: p.y) }),
        Transform(name: "dark", apply: { cg in
            render(cg, size: CGSize(width: cg.width, height: cg.height)) { c, s in
                c.setFillColor(UIColor.black.withAlphaComponent(0.4).cgColor); c.fill(CGRect(origin: .zero, size: s))
            }
        }, map: { p, _ in p }),
        Transform(name: "jpeg30", apply: { cg in
            UIImage(cgImage: cg).jpegData(compressionQuality: 0.3).flatMap { UIImage(data: $0)?.cgImage }
        }, map: { p, _ in p }),
    ]

    /// Same-person (each fixture face vs itself under 5 photo transforms) and different-person
    /// (every pair of faces from different photos, and different faces in one photo) similarity
    /// distributions on the CC0 fixtures, with the hit and false-accept rates at the app's bars.
    /// The lab runs the identical protocol on the retired SCRFD + AdaFace stack for the old-vs-new
    /// comparison in docs/MODEL-LICENSING.md §8.
    @Test func fixtureFaceBenchmark() throws {
        struct Face { let photo: String; let index: Int; let face: DetectedFace; let embedding: [Float] }
        var faces: [Face] = []
        var genuine: [Float] = []
        var misses = 0
        for name in Self.benchmarkPhotos {
            let cg = try #require(try fixture(name).cgImage)
            let found = FaceMatchingService.shared.embedFaces(in: cg, padRetry: false)
            report("bench photo \(name) \(cg.width)x\(cg.height): faces=\(found.count) " +
                   found.map { "[\(Int($0.face.boxPixels.width))px s=\(String(format: "%.2f", $0.face.score)) yaw=\(String(format: "%.2f", FaceQuality.yawProxy($0.face.keypoints)))]" }.joined(separator: " "))
            for (i, f) in found.enumerated() { faces.append(Face(photo: name, index: i, face: f.face, embedding: f.embedding)) }
            for t in Self.transforms {
                guard let img = t.apply(cg) else { continue }
                let size = CGSize(width: cg.width, height: cg.height)
                let scale = CGFloat(img.width) / CGFloat(t.name == "reframe" ? CGFloat(cg.width) * 0.84 : CGFloat(cg.width))
                let tFaces = FaceMatchingService.shared.embedFaces(in: img, padRetry: false)
                for (i, f) in found.enumerated() {
                    let c = t.map(CGPoint(x: f.face.boxPixels.midX, y: f.face.boxPixels.midY), size)
                    let tol = f.face.boxPixels.width * max(scale, 0.5) * 0.5
                    let hit = tFaces.min { a, b in
                        hypot(a.face.boxPixels.midX - c.x, a.face.boxPixels.midY - c.y)
                            < hypot(b.face.boxPixels.midX - c.x, b.face.boxPixels.midY - c.y)
                    }
                    if let hit, hypot(hit.face.boxPixels.midX - c.x, hit.face.boxPixels.midY - c.y) <= tol {
                        let s = FaceMath.dot(f.embedding, hit.embedding)
                        genuine.append(s)
                        report("bench gen \(name)#\(i) \(t.name): sim=\(String(format: "%.4f", s))")
                    } else if c.x >= 0, c.y >= 0, c.x < CGFloat(img.width), c.y < CGFloat(img.height) {
                        misses += 1
                        report("bench gen \(name)#\(i) \(t.name): MISS")
                    }
                }
            }
        }
        // The six street_* photos are one Wikimedia series ("Street Style of 2018 2019 in Tehran")
        // and may show the same woman (sunglasses, caps): their cross pairs have no reliable label,
        // so they are reported apart and kept out of the impostor set.
        func series(_ p: String) -> Bool { p.hasPrefix("street_") }
        var impostor: [(Float, String)] = []
        for a in 0..<faces.count {
            for b in (a + 1)..<faces.count {
                let s = FaceMath.dot(faces[a].embedding, faces[b].embedding)
                let pair = "\(faces[a].photo)#\(faces[a].index)~\(faces[b].photo)#\(faces[b].index)"
                if series(faces[a].photo) && series(faces[b].photo) && faces[a].photo != faces[b].photo {
                    report("bench series-pair (identity unknown) \(pair): sim=\(String(format: "%.4f", s))")
                    continue
                }
                impostor.append((s, pair))
            }
        }
        impostor.sort { $0.0 > $1.0 }
        for (s, pair) in impostor.prefix(5) { report("bench imp top \(pair): sim=\(String(format: "%.4f", s))") }
        let g = genuine.sorted()
        func pct(_ v: [Float], _ p: Double) -> Float { v.isEmpty ? -1 : v[min(v.count - 1, Int(Double(v.count) * p))] }
        let hi = FaceMatchingService.highConfidenceThreshold, lo = FaceMatchingService.borderlineThreshold
        let imp = impostor.map(\.0)
        func rate(_ v: [Float], _ t: Float) -> String { v.isEmpty ? "-" : String(format: "%.1f%%", 100 * Double(v.filter { $0 >= t }.count) / Double(v.count)) }
        report("bench SUMMARY model=\(FaceMatchingService.modelVersion) faces=\(faces.count) | genuine n=\(g.count) misses=\(misses) min=\(String(format: "%.3f", g.first ?? -1)) p10=\(String(format: "%.3f", pct(g, 0.1))) median=\(String(format: "%.3f", pct(g, 0.5))) | impostor n=\(imp.count) max=\(String(format: "%.3f", imp.first ?? -1)) mean=\(String(format: "%.3f", imp.isEmpty ? 0 : imp.reduce(0, +) / Float(imp.count))) | high=\(hi): TAR \(rate(g, hi)) FAR \(rate(imp, hi)) | borderline=\(lo): TAR \(rate(g, lo)) FAR \(rate(imp, lo))")
        #expect(faces.count >= 10, "the detector found only \(faces.count) faces in the fixtures")
        #expect(!imp.contains { $0 >= hi }, "a stranger pair scores above the auto-add bar: \(impostor.first.map { "\($0.1) \($0.0)" } ?? "")")
        #expect(pct(g, 0.5) >= hi, "the median same-face score \(pct(g, 0.5)) is under the auto-add bar")
    }
}
