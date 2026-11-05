import CoreGraphics
import Foundation

/// One try-on, end to end: composite the pieces onto the body, optionally harmonise with the on-device
/// diffusion model, then gate the result. Pure function of its inputs (deterministic seed), so results
/// can be cached by (body photo, item ids, item image versions).
enum TryOnRenderer {
    struct Result {
        /// The finished image (person crop, opaque).
        let image: CGImage
        let report: TryOnGate.Report
        let harmonized: Bool
        let seconds: Double
        /// The deterministic composite before the diffusion pass (for the lab sheets / tests).
        let composite: CGImage?
    }

    enum Outcome {
        case ready(Result)
        /// Rendered, but the gate said it isn't faithful enough: show the pieces instead.
        case rejected(TryOnGate.Report, composite: CGImage?)
        case failed(String)
    }

    /// Harmonise schedule (DPM-Solver++ Karras). 20 scheduled steps; with the largest strength ~0.8 the
    /// pass runs ~16 UNet steps.
    static var steps = 20
    static var guidance: Float = 5

    static func render(body: TryOnBodyModel, garments: [TryOnGarmentSpec], harmonize: Bool,
                       seed: UInt32 = 1) async -> Outcome {
        let start = CFAbsoluteTimeGetCurrent()
        guard let comp = TryOnCompositor.composite(body: body, garments: garments) else { return .failed("composite") }
        var final = comp.image
        var harmonized = false
        if harmonize, TryOnHarmonizer.shared.isAvailable {
            let strength = strengthMap(body: body, composite: comp)
            let tile = tileRect(body)
            if let input = tileImage(comp.image, tile: tile), let s64 = tileStrength(strength, body: body, tile: tile),
               let out = await TryOnHarmonizer.shared.harmonize(image: input, strength: s64, prompt: prompt(garments),
                                                                negativePrompt: negativePrompt(garments), steps: steps,
                                                                guidance: guidance, seed: seed),
               let pasted = paste(out, into: comp, body: body, tile: tile, strength: strength) {
                final = pasted
                harmonized = true
            }
        }
        var refs: [UUID: CGImage] = [:]
        for g in garments { refs[g.id] = g.image }
        let report = TryOnGate.check(final: final, body: body, composite: comp, references: refs, harmonized: harmonized)
        let compImage = comp.image.opaqueCGImage()
        guard let image = final.opaqueCGImage() else { return .failed("encode") }
        if let why = report.rejection {
            print("[TryOn] rejected: \(why)")
            return .rejected(report, composite: compImage)
        }
        return .ready(Result(image: image, report: report, harmonized: harmonized,
                             seconds: CFAbsoluteTimeGetCurrent() - start, composite: compImage))
    }

    // MARK: - Prompt

    static let negativePrompt = "deformed, blurry, extra limbs, extra arms, extra fingers, text, watermark, cartoon, painting, plastic skin, nude"

    static func prompt(_ garments: [TryOnGarmentSpec]) -> String {
        let worn = garments.filter { $0.role.isWorn }.map { ClosetText.displayProduct($0.product).lowercased() }
        var extra: [String] = []
        // Say what is bare, or the model repaints an old sleeve / legging where the new piece has none.
        let uppers = garments.filter { [.top, .onePiece, .outer].contains($0.role) }
        if !uppers.isEmpty, uppers.allSatisfy({ $0.sleeve == .sleeveless || $0.product.lowercased().contains("tank") }) {
            extra.append("bare arms, bare shoulders")
        }
        if !garments.contains(where: { $0.role == .bottom }), garments.contains(where: { $0.role == .onePiece }) {
            extra.append("bare legs")
        }
        return "photo of a person wearing " + worn.joined(separator: ", ") + (extra.isEmpty ? "" : ", " + extra.joined(separator: ", ")) +
            ", natural skin, realistic fabric, natural light, high quality photo"
    }

    static func negativePrompt(_ garments: [TryOnGarmentSpec]) -> String {
        var n = negativePrompt
        let uppers = garments.filter { [.top, .onePiece, .outer].contains($0.role) }
        if !uppers.isEmpty, uppers.allSatisfy({ $0.sleeve == .sleeveless }) { n += ", sleeves, jacket, cardigan" }
        if !garments.contains(where: { $0.role == .bottom }) { n += ", leggings, tights, trousers" }
        return n
    }

    // MARK: - Strength map (photo resolution), tile, paste

    /// 0 = keep, 0.25 garments (relight; their texture is restored after), 0.45 seams, 0.6 around fills, 0.75 uncovered skin, 0.85 uncovered background.
    static func strengthMap(body: TryOnBodyModel, composite c: TryOnCompositor.Output) -> TryOnPlane {
        let W = body.width, H = body.height, n = W * H
        var personRows = 0
        for y in 0..<H where (0..<W).contains(where: { body.labels[y * W + $0] != 0 }) { personRows += 1 }
        let band = max(3, Int(Float(personRows) * 0.012))
        let cov = TryOnPlane(width: W, height: H, v: c.cover.map { $0 > 0.4 ? 1 : 0 })
        let outer = cov.morph(band / 2 + 1), inner = cov.morph(-(band / 2 + 1))
        let exposed = TryOnPlane(width: W, height: H, v: (0..<n).map { c.exposedSkin[$0] || c.exposedBackground[$0] ? 1 : 0 }).morph(band / 2 + 1)
        var m = TryOnPlane(width: W, height: H)
        for i in 0..<n {
            var s: Float = 0
            if cov.v[i] > 0 { s = 0.25 }
            if outer.v[i] > 0 && inner.v[i] == 0 { s = 0.45 }
            if exposed.v[i] > 0 { s = max(s, 0.6) }
            if c.exposedSkin[i] { s = 0.75 }
            if c.exposedBackground[i] { s = 0.85 }
            if c.protected[i] { s = 0 }
            m.v[i] = s
        }
        return m.blurred(sigma: Float(band) * 0.5)
    }

    /// A square around the person (the diffusion model works on 512x512).
    static func tileRect(_ body: TryOnBodyModel) -> CGRect {
        var x0 = body.width, y0 = body.height, x1 = 0, y1 = 0
        for y in 0..<body.height {
            for x in 0..<body.width where body.labels[y * body.width + x] != 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 > x0, y1 > y0 else { return CGRect(x: 0, y: 0, width: body.width, height: body.height) }
        let side = min(CGFloat(max(body.width, body.height)), CGFloat(max(y1 - y0, x1 - x0)) * 1.06)
        let cx = CGFloat(x0 + x1) / 2, cy = CGFloat(y0 + y1) / 2
        let X = min(max(0, cx - side / 2), max(0, CGFloat(body.width) - side))
        let Y = min(max(0, cy - side / 2), max(0, CGFloat(body.height) - side))
        return CGRect(x: X, y: Y, width: side, height: side)
    }

    /// The tile scaled to 512x512 (parts outside the image are black).
    static func tileImage(_ img: TryOnRaster, tile: CGRect) -> CGImage? {
        guard let cg = img.opaqueCGImage(), let ctx = TryOnDraw.context(width: TryOnHarmonizer.side, height: TryOnHarmonizer.side) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: TryOnHarmonizer.side, height: TryOnHarmonizer.side))
        let k = CGFloat(TryOnHarmonizer.side) / tile.width
        TryOnDraw.draw(cg, in: ctx, transform: CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: -tile.minX * k, ty: -tile.minY * k))
        guard let r = TryOnDraw.raster(ctx) else { return nil }
        return r.opaqueCGImage()
    }

    /// The strength map over the tile, area-averaged to the 64x64 latent grid.
    static func tileStrength(_ m: TryOnPlane, body: TryOnBodyModel, tile: CGRect) -> [Float]? {
        let L = TryOnHarmonizer.latentSide
        var out = [Float](repeating: 0, count: L * L)
        var cnt = [Float](repeating: 0, count: L * L)
        let k = CGFloat(L) / tile.width
        for y in Int(tile.minY)..<min(body.height, Int(tile.maxY)) {
            let ly = min(L - 1, max(0, Int((CGFloat(y) - tile.minY) * k)))
            for x in Int(tile.minX)..<min(body.width, Int(tile.maxX)) {
                let lx = min(L - 1, max(0, Int((CGFloat(x) - tile.minX) * k)))
                out[ly * L + lx] += m.v[y * body.width + x]
                cnt[ly * L + lx] += 1
            }
        }
        for i in 0..<(L * L) where cnt[i] > 0 { out[i] /= cnt[i] }
        return out
    }

    /// Back into the photo: garments keep the composite's own texture (high frequencies) under the
    /// diffusion's light (low frequencies); filled areas take the diffusion result; untouched pixels
    /// stay the photo's.
    static func paste(_ out: CGImage, into c: TryOnCompositor.Output, body: TryOnBodyModel, tile: CGRect,
                      strength: TryOnPlane) -> TryOnRaster? {
        let W = body.width, H = body.height
        guard let ctx = TryOnDraw.context(width: W, height: H) else { return nil }
        let k = tile.width / CGFloat(out.width)
        TryOnDraw.draw(out, in: ctx, transform: CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: tile.minX, ty: tile.minY))
        guard let R = TryOnDraw.raster(ctx) else { return nil }
        let sigma = Float(tile.width / 512 * 3)
        let n = W * H
        var final = c.image
        var lowR: [TryOnPlane] = [], lowC: [TryOnPlane] = []
        for ch in 0..<3 {
            lowR.append(TryOnPlane(width: W, height: H, v: (0..<n).map { Float(R.px[$0 * 4 + ch]) }).blurred(sigma: sigma))
            lowC.append(TryOnPlane(width: W, height: H, v: (0..<n).map { Float(c.image.px[$0 * 4 + ch]) }).blurred(sigma: sigma))
        }
        let wgt = TryOnPlane(width: W, height: H, v: strength.v.map { $0 > 0.02 ? 1 : 0 }).blurred(sigma: sigma)
        let softCover = TryOnPlane(width: W, height: H, v: c.cover).blurred(sigma: max(1, sigma * 0.5))
        for i in 0..<n {
            let w = min(1, wgt.v[i] * 1.2)
            guard w > 0.001, !c.protected[i], R.px[i * 4 + 3] > 0 else { continue }
            // Garments take only the diffusion's light (a luminance ratio), never its colour: the item's
            // own colour and texture stay exactly the composite's. The garment weight is the soft (blurred)
            // coverage, so garment and repainted fill cross-fade instead of meeting at a hard seam.
            let gw = min(1, max(0, (softCover.v[i] - 0.15) / 0.7))
            let garment = gw > 0
            var ratio: Float = 1
            if garment {
                let yr = 0.299 * lowR[0].v[i] + 0.587 * lowR[1].v[i] + 0.114 * lowR[2].v[i] + 4
                let yc = 0.299 * lowC[0].v[i] + 0.587 * lowC[1].v[i] + 0.114 * lowC[2].v[i] + 4
                ratio = min(1.25, max(0.75, yr / yc))
            }
            for ch in 0..<3 {
                let comp = Float(c.image.px[i * 4 + ch])
                let v: Float = comp * ratio * gw + Float(R.px[i * 4 + ch]) * (1 - gw)
                final.px[i * 4 + ch] = UInt8(min(255, max(0, comp * (1 - w) + v * w)))
            }
        }
        TryOnCompositor.restoreProtected(&final, body: body)
        return final
    }
}
