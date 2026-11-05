import CoreGraphics
import Foundation

/// "Better no image than a wrong one": checks a finished try-on before it is ever shown.
///
/// Per worn piece (shoes and accessories excluded):
/// - **visible**: enough of the piece shows (an inner top under a coat is exempt);
/// - **looks like the item**: FashionSigLIP similarity between the piece as it appears on the body
///   (masked crop on white) and the item's own image;
/// - **colour**: median Lab of the piece on the body vs the item (lighting may darken it, not recolour it).
/// Whole image:
/// - **face unchanged**: face / hair / hands pixels are byte-identical to the photo;
/// - **little invented**: the share of the person that had to be filled (old clothes the new outfit
///   doesn't cover) stays small, smaller still without the diffusion pass.
/// Thresholds are calibrated in `tryon-lab/gate_cal.py` (see docs/TRY-ON.md).
enum TryOnGate {
    static var minSimilarity: Float = 0.50
    static var minVisible: Float = 0.30
    static var maxChromaShift: Float = 22
    static var maxLightShift: Float = 34
    static var maxFilledShare: Float = 0.12
    static var maxFilledShareHarmonized: Float = 0.35

    struct Piece: Codable {
        let id: UUID
        let role: String
        var visible: Float
        var similarity: Float?
        var chromaShift: Float?
        var lightShift: Float?
        var rejection: String?
    }

    struct Report: Codable {
        var pieces: [Piece]
        var faceChangedPixels: Int
        var filledShare: Float
        var harmonized: Bool
        var rejection: String?
        var passed: Bool { rejection == nil }
    }

    /// - Parameters:
    ///   - final: the finished image (body working size).
    ///   - references: each piece's item image (transparent background), keyed by id.
    static func check(final: TryOnRaster, body: TryOnBodyModel, composite: TryOnCompositor.Output,
                      references: [UUID: CGImage], harmonized: Bool) -> Report {
        let n = body.width * body.height
        // Face / hair / hands untouched.
        var changed = 0
        for i in 0..<n where composite.protected[i] {
            if final.px[i * 4] != body.image.px[i * 4] || final.px[i * 4 + 1] != body.image.px[i * 4 + 1]
                || final.px[i * 4 + 2] != body.image.px[i * 4 + 2] { changed += 1 }
        }
        var personPx = 0, filled = 0
        for i in 0..<n where body.labels[i] != TryOnLabel.background {
            personPx += 1
            if composite.exposedSkin[i] || composite.exposedBackground[i] { filled += 1 }
        }
        let filledShare = personPx > 0 ? Float(filled) / Float(personPx) : 1

        var pieces: [Piece] = []
        let hasOuter = composite.items.contains { $0.role == .outer }
        for (k, item) in composite.items.enumerated() {
            // Visible = own alpha x not covered by later layers x not protected.
            var vis = [Float](repeating: 0, count: n)
            var own: Float = 0, shown: Float = 0
            for i in 0..<n {
                let a = item.alpha[i]
                guard a > 0 else { continue }
                var v = composite.protected[i] ? 0 : a
                for later in composite.items[(k + 1)...] where v > 0 { v *= 1 - later.alpha[i] }
                vis[i] = v
                own += a; shown += v
            }
            var piece = Piece(id: item.id, role: "\(item.role)", visible: own > 0 ? shown / own : 0)
            let exempt = item.role == .top && hasOuter
            if !exempt && piece.visible < minVisible {
                piece.rejection = "mostly hidden (\(String(format: "%.2f", piece.visible)))"
            }
            if let ref = references[item.id], shown > 200 {
                if let crop = maskedCrop(final, mask: vis, width: body.width, height: body.height),
                   let a = embedOnWhite(crop), let b = embedOnWhite(ref) {
                    piece.similarity = WardrobeExtractor.cosine(a, b)
                }
                if let onBody = medianLab(final, mask: vis), let r = medianLab(ref) {
                    piece.chromaShift = hypot(onBody.1 - r.1, onBody.2 - r.2)
                    piece.lightShift = abs(onBody.0 - r.0)
                }
                if piece.rejection == nil, !exempt {
                    if let s = piece.similarity, s < minSimilarity {
                        piece.rejection = "doesn't look like the item (sim \(String(format: "%.3f", s)))"
                    } else if let c = piece.chromaShift, c > maxChromaShift {
                        piece.rejection = "colour shifted (ΔC \(String(format: "%.1f", c)))"
                    } else if let l = piece.lightShift, l > maxLightShift {
                        piece.rejection = "lightness shifted (ΔL \(String(format: "%.1f", l)))"
                    }
                }
            }
            pieces.append(piece)
        }
        var report = Report(pieces: pieces, faceChangedPixels: changed, filledShare: filledShare, harmonized: harmonized)
        if changed > 0 { report.rejection = "face / hands changed (\(changed) px)" }
        else if pieces.isEmpty { report.rejection = "nothing to wear on the body" }
        else if filledShare > (harmonized ? maxFilledShareHarmonized : maxFilledShare) {
            report.rejection = "too much of the body invented (\(String(format: "%.2f", filledShare)))"
        } else if let bad = pieces.first(where: { $0.rejection != nil }) {
            report.rejection = "\(bad.role): \(bad.rejection!)"
        }
        return report
    }

    static func embedOnWhite(_ image: CGImage) -> [Float]? {
        guard let onWhite = FashionClassifier.onWhite(image, side: 224) else { return nil }
        return WardrobeML.shared.embed(onWhite)
    }

    /// The mask's bounding box of `image`, with the mask as alpha.
    static func maskedCrop(_ image: TryOnRaster, mask: [Float], width w: Int, height h: Int) -> CGImage? {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where mask[y * w + x] > 0.5 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 > x0 + 4, y1 > y0 + 4 else { return nil }
        var crop = TryOnRaster(width: x1 - x0 + 1, height: y1 - y0 + 1)
        for y in y0...y1 {
            for x in x0...x1 {
                let s = (y * w + x) * 4, d = ((y - y0) * crop.width + (x - x0)) * 4
                crop.px[d] = image.px[s]; crop.px[d + 1] = image.px[s + 1]; crop.px[d + 2] = image.px[s + 2]
                crop.px[d + 3] = UInt8(min(255, max(0, mask[y * w + x] * 255)))
            }
        }
        return crop.cgImage()
    }

    static func medianLab(_ image: TryOnRaster, mask: [Float]) -> (Float, Float, Float)? {
        var L: [Float] = [], A: [Float] = [], B: [Float] = []
        let n = image.width * image.height
        let step = max(1, n / 60000)
        var i = 0
        while i < n {
            if mask[i] > 0.8 {
                let c = ColorNamer.lab(Float(image.px[i * 4]) / 255, Float(image.px[i * 4 + 1]) / 255, Float(image.px[i * 4 + 2]) / 255)
                L.append(c.0); A.append(c.1); B.append(c.2)
            }
            i += step
        }
        guard L.count > 30 else { return nil }
        func med(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        return (med(L), med(A), med(B))
    }

    static func medianLab(_ image: CGImage) -> (Float, Float, Float)? {
        let k = min(1, 256 / CGFloat(max(image.width, image.height)))
        guard let r = TryOnRaster(image, width: max(1, Int(CGFloat(image.width) * k)), height: max(1, Int(CGFloat(image.height) * k))) else { return nil }
        return medianLab(r, mask: (0..<(r.width * r.height)).map { Float(r.px[$0 * 4 + 3]) / 255 })
    }
}
