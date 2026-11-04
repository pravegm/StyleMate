import CoreGraphics
import Foundation

/// A flat-lay silhouette (t-shirt, shirt, jacket, coat, dress, tank) filled
/// with the garment's own fabric, cut from the most interior part of its
/// cutout: the starting image for a template-guided image-to-image render.
/// It locks the layout (one garment, centred, whole, laid flat — no person,
/// no stack, no props) and the colour/texture, while the model redraws the
/// seams, collar and folds at ~0.65 strength.
enum StudioTemplate {
    enum Shape: String { case tee, shirt, jacket, coat, dress, tank }

    /// The silhouette for an item, or nil when there's none that fits (bottoms,
    /// shoes, accessories are refined from their cutout instead).
    static func shape(product: String, kind: GarmentKind, sleeve: SleeveLength?) -> Shape? {
        let p = product.lowercased()
        switch kind {
        case .onePiece:
            if p.contains("jumpsuit") || p.contains("romper") || p.contains("dungaree") || p.contains("saree") { return nil }
            return .dress
        case .outerLayer:
            if ["coat", "overcoat", "trench", "parka", "raincoat", "sherwani"].contains(where: { p.contains($0) }) { return .coat }
            if p.contains("vest") || p.contains("gilet") || p.contains("cape") || p.contains("poncho") || p.contains("shrug") { return nil }
            return .jacket
        case .innerTop:
            if sleeve == .sleeveless || ["tank", "camisole", "tube", "halter", "corset", "sports bra"].contains(where: { p.contains($0) }) { return .tank }
            if p.contains("kurta") || p.contains("kurti") || p.contains("tunic") { return .coat }
            if sleeve == .shortSleeve || sleeve == .capSleeve { return .tee }
            if ["t-shirt", "tee", "polo", "crop"].contains(where: { p.contains($0) }) && sleeve == nil { return .tee }
            return .shirt
        default:
            return nil
        }
    }

    /// Outline points, x/y in 0...1 of the canvas, y down.
    static func outline(_ s: Shape) -> [(CGFloat, CGFloat)] {
        switch s {
        case .tee: return [(0.40, 0.16), (0.50, 0.21), (0.60, 0.16), (0.73, 0.20), (0.92, 0.38), (0.82, 0.47), (0.71, 0.39),
                           (0.71, 0.88), (0.29, 0.88), (0.29, 0.39), (0.18, 0.47), (0.08, 0.38), (0.27, 0.20)]
        case .shirt: return [(0.41, 0.13), (0.50, 0.18), (0.59, 0.13), (0.72, 0.17), (0.84, 0.40), (0.94, 0.80), (0.85, 0.83),
                             (0.73, 0.48), (0.72, 0.90), (0.28, 0.90), (0.27, 0.48), (0.15, 0.83), (0.06, 0.80), (0.16, 0.40), (0.28, 0.17)]
        case .jacket: return [(0.40, 0.13), (0.50, 0.17), (0.60, 0.13), (0.74, 0.17), (0.86, 0.40), (0.95, 0.78), (0.85, 0.81),
                              (0.74, 0.50), (0.74, 0.86), (0.26, 0.86), (0.26, 0.50), (0.15, 0.81), (0.05, 0.78), (0.14, 0.40), (0.26, 0.17)]
        case .coat: return [(0.42, 0.06), (0.50, 0.10), (0.58, 0.06), (0.70, 0.10), (0.83, 0.35), (0.92, 0.72), (0.84, 0.75),
                            (0.72, 0.42), (0.75, 0.95), (0.25, 0.95), (0.28, 0.42), (0.16, 0.75), (0.08, 0.72), (0.17, 0.35), (0.30, 0.10)]
        case .dress: return [(0.42, 0.08), (0.50, 0.13), (0.58, 0.08), (0.64, 0.10), (0.66, 0.30), (0.62, 0.42), (0.78, 0.94),
                             (0.22, 0.94), (0.38, 0.42), (0.34, 0.30), (0.36, 0.10)]
        case .tank: return [(0.38, 0.12), (0.42, 0.12), (0.50, 0.24), (0.58, 0.12), (0.62, 0.12), (0.66, 0.30), (0.68, 0.88),
                            (0.32, 0.88), (0.34, 0.30)]
        }
    }

    /// The neck opening of open-front shapes (lab, Nov 2026: without it four of
    /// four denim-jacket renders grew a white t-shirt inside).
    static func neckV(_ s: Shape) -> [(CGFloat, CGFloat)]? {
        switch s {
        case .jacket, .shirt: return [(0.44, 0.15), (0.56, 0.15), (0.50, 0.42)]
        case .coat: return [(0.45, 0.08), (0.55, 0.08), (0.50, 0.36)]
        default: return nil
        }
    }

    /// The template image (opaque, white background), or nil when the cutout
    /// has no solid fabric area to sample.
    static func render(cutout: CGImage, shape: Shape, side: Int = 512) -> CGImage? {
        guard let patch = fabricPatch(cutout) else { return nil }
        let s = CGFloat(side)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let path = CGMutablePath()
        let pts = outline(shape).map { CGPoint(x: $0.0 * s, y: s - $0.1 * s) }   // CG is y-up
        path.addLines(between: pts)
        path.closeSubpath()
        // Soft contact shadow under the garment.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 5, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.28))
        ctx.setFillColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        // Fabric: the patch mirror-tiled (no seams) at the garment's own scale
        // (the template garment spans ~80% of the canvas, the real one ~86% of
        // its cutout), clipped to the outline.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.interpolationQuality = .high
        let k = 0.8 * s / (0.86 * CGFloat(max(cutout.width, cutout.height)))
        let t = min(max(CGFloat(patch.width) * k, 48), 256)
        let tiles = Int((s / t).rounded(.up))
        for row in 0..<tiles {
            for col in 0..<tiles {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(col) * t + (col % 2 == 1 ? t : 0), y: CGFloat(row) * t + (row % 2 == 1 ? t : 0))
                ctx.scaleBy(x: col % 2 == 1 ? -1 : 1, y: row % 2 == 1 ? -1 : 1)
                ctx.draw(patch, in: CGRect(x: 0, y: 0, width: t, height: t))
                ctx.restoreGState()
            }
        }
        // Open-front garments: a shaded V at the neck reads as the inside of the
        // garment, so the model doesn't invent a white tee in the opening.
        if let v = neckV(shape) {
            let vp = CGMutablePath()
            vp.addLines(between: v.map { CGPoint(x: $0.0 * s, y: s - $0.1 * s) })
            vp.closeSubpath()
            ctx.setFillColor(gray: 0, alpha: 0.5)
            ctx.addPath(vp); ctx.fillPath()
        }
        // Gentle light falloff toward the edges, so it reads as cloth, not a cut-out shape.
        let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 0, alpha: 0.14)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                                   endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.55, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The largest square of solid fabric deep inside the cutout (away from
    /// edges, holes and fills), found by eroding a downscaled mask.
    static func fabricPatch(_ cutout: CGImage) -> CGImage? {
        let g = 96
        let k = CGFloat(g) / CGFloat(max(cutout.width, cutout.height))
        guard let ctx = CGContext(data: nil, width: g, height: g, bitsPerComponent: 8, bytesPerRow: g * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cutout, in: CGRect(x: 0, y: 0, width: CGFloat(cutout.width) * k, height: CGFloat(cutout.height) * k))
        let p = data.assumingMemoryBound(to: UInt8.self)
        var m = [UInt8](repeating: 0, count: g * g)
        for i in 0..<(g * g) { m[i] = p[i * 4 + 3] > 230 ? 1 : 0 }
        // Erode until nothing is left; the last survivors are the most interior points.
        var depth = 0, last: [Int] = []
        while true {
            let alive = (0..<(g * g)).filter { m[$0] != 0 }
            if alive.isEmpty { break }
            last = alive
            var next = m
            for i in alive {
                let x = i % g, y = i / g
                if x == 0 || y == 0 || x == g - 1 || y == g - 1 || m[i - 1] == 0 || m[i + 1] == 0 || m[i - g] == 0 || m[i + g] == 0 {
                    next[i] = 0
                }
            }
            m = next
            depth += 1
        }
        guard depth >= 3, let centre = last.first else { return nil }
        // Back to cutout pixels (bitmap rows are top-down here; CG drew with a y-up origin).
        let cx = CGFloat(centre % g) / k, cyFromBottom = CGFloat(centre / g)
        let cy = CGFloat(cutout.height) - (CGFloat(g) - 1 - cyFromBottom) / k
        let r = CGFloat(depth) * 0.75 / k
        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            .intersection(CGRect(x: 0, y: 0, width: cutout.width, height: cutout.height))
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return cutout.cropping(to: rect.integral)
    }
}
