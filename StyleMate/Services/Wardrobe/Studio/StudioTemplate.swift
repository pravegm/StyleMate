import CoreGraphics
import Foundation

/// The starting image for a template-guided image-to-image render: a product
/// silhouette filled with the item's own fabric, cut from the most interior
/// part of its cutout. It locks the layout (one item, centred, whole, in the
/// catalogue pose — no person, no stack, no props) and the colour/texture,
/// while the model redraws seams, collar, laces, sole and folds.
///
/// - Tops, layers, dresses: a flat lay (t-shirt, shirt, jacket, coat, tunic,
///   dress, tank) at 0.65.
/// - Trousers: front view, full length (straight, slim, wide, joggers,
///   leggings) with a waistband and fly, at 0.65 — every pair, not only cut-off
///   ones: refining the worn cutout kept the bent knees, the coat hem across the
///   hips and the boots over the ankles (lab, Nov 2026).
/// - Shoes: ONE shoe, outer side, toe pointing left (sneaker, boot, Chelsea /
///   ankle boot, loafer, heel, sandal), the sole in the shoe's own sole colour,
///   at 0.70. Refining the worn pair at 0.45 mostly reproduced the street photo.
/// - Hats: front three-quarter view (cap, wide brim, beanie, bucket) at 0.65.
/// Every shape shares one light (from above), one soft contact shadow and one
/// framing, so the closet reads as one catalogue.
enum StudioTemplate {
    enum Shape: String, CaseIterable {
        case tee, shirt, jacket, coat, tunic, dress, tank
        case trousers, slimTrousers, wideTrousers, joggers, leggings
        case sneaker, boot, chelsea, loafer, heel, sandal
        case cap, wideBrim, beanie, bucket
    }

    enum Family { case flatLay, trousers, footwear, headwear }

    static func family(_ s: Shape) -> Family {
        switch s {
        case .tee, .shirt, .jacket, .coat, .tunic, .dress, .tank: return .flatLay
        case .trousers, .slimTrousers, .wideTrousers, .joggers, .leggings: return .trousers
        case .sneaker, .boot, .chelsea, .loafer, .heel, .sandal: return .footwear
        case .cap, .wideBrim, .beanie, .bucket: return .headwear
        }
    }

    /// Image-to-image strength from the template. A shoe's flat silhouette needs
    /// a little more freedom to grow a sole, laces and a 3D toe.
    static func strength(_ s: Shape) -> Float { family(s) == .footwear ? 0.70 : 0.65 }

    /// The silhouette for an item, or nil when none fits (skirts, shorts, bags,
    /// turbans … are refined from their cutout instead).
    static func shape(product: String, kind: GarmentKind, sleeve: SleeveLength?, fit: Fit? = nil) -> Shape? {
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
            if p.contains("kurta") || p.contains("kurti") || p.contains("tunic") { return .tunic }
            if sleeve == .shortSleeve || sleeve == .capSleeve { return .tee }
            if ["t-shirt", "tee", "polo", "crop"].contains(where: { p.contains($0) }) && sleeve == nil { return .tee }
            return .shirt
        case .lower:
            if ["skirt", "short", "skort", "dhoti", "lehenga", "culotte", "capri", "lungi", "mundu", "ghagra"].contains(where: { p.contains($0) }) { return nil }
            if ["legging", "yoga", "churidar", "tights"].contains(where: { p.contains($0) }) { return .leggings }
            if ["jogger", "sweatpant", "track pant"].contains(where: { p.contains($0) }) { return .joggers }
            if ["wide", "palazzo", "sharara", "patiala", "salwar"].contains(where: { p.contains($0) }) { return .wideTrousers }
            if fit == .slim { return .slimTrousers }
            if fit == .oversized && !p.contains("jean") { return .wideTrousers }
            return .trousers
        case .footwear:
            if p.contains("chelsea") || p.contains("ankle boot") { return .chelsea }
            if p.contains("boot") { return .boot }
            if p.contains("heel") || p.contains("pump") || p.contains("wedge") { return .heel }
            if p.contains("sandal") || p.contains("slide") || p.contains("flip") { return .sandal }
            if ["loafer", "oxford", "formal", "flat", "mule", "clog", "slipper", "espadrille", "moccasin", "boat"].contains(where: { p.contains($0) }) {
                return .loafer
            }
            return .sneaker   // sneakers, platform shoes, trainers, anything else laced
        case .headwear:
            if p.contains("cap") || p.contains("visor") { return .cap }
            if p.contains("beanie") || p.contains("beret") { return .beanie }
            if p.contains("bucket") { return .bucket }
            if p.contains("fedora") || p.contains("sun hat") || p.contains("panama") || p.contains("cowboy") { return .wideBrim }
            return nil   // turbans, headbands, bandanas, hair accessories: no product pose to draw
        default:
            return nil
        }
    }

    /// Flat-lay outline points, x/y in 0...1 of the canvas, y down.
    static func outline(_ s: Shape) -> [(CGFloat, CGFloat)] {
        switch s {
        case .tee: return [(0.40, 0.16), (0.50, 0.21), (0.60, 0.16), (0.73, 0.20), (0.92, 0.38), (0.82, 0.47), (0.71, 0.39),
                           (0.71, 0.88), (0.29, 0.88), (0.29, 0.39), (0.18, 0.47), (0.08, 0.38), (0.27, 0.20)]
        case .shirt: return [(0.41, 0.13), (0.50, 0.18), (0.59, 0.13), (0.72, 0.17), (0.84, 0.40), (0.94, 0.80), (0.85, 0.83),
                             (0.73, 0.48), (0.72, 0.90), (0.28, 0.90), (0.27, 0.48), (0.15, 0.83), (0.06, 0.80), (0.16, 0.40), (0.28, 0.17)]
        case .jacket: return [(0.40, 0.13), (0.50, 0.17), (0.60, 0.13), (0.74, 0.17), (0.86, 0.40), (0.95, 0.78), (0.85, 0.81),
                              (0.74, 0.50), (0.74, 0.86), (0.26, 0.86), (0.26, 0.50), (0.15, 0.81), (0.05, 0.78), (0.14, 0.40), (0.26, 0.17)]
        case .coat, .tunic: return [(0.42, 0.06), (0.50, 0.10), (0.58, 0.06), (0.70, 0.10), (0.83, 0.35), (0.92, 0.72), (0.84, 0.75),
                            (0.72, 0.42), (0.75, 0.95), (0.25, 0.95), (0.28, 0.42), (0.16, 0.75), (0.08, 0.72), (0.17, 0.35), (0.30, 0.10)]
        case .dress: return [(0.42, 0.08), (0.50, 0.13), (0.58, 0.08), (0.64, 0.10), (0.66, 0.30), (0.62, 0.42), (0.78, 0.94),
                             (0.22, 0.94), (0.38, 0.42), (0.34, 0.30), (0.36, 0.10)]
        case .tank: return [(0.38, 0.12), (0.42, 0.12), (0.50, 0.24), (0.58, 0.12), (0.62, 0.12), (0.66, 0.30), (0.68, 0.88),
                            (0.32, 0.88), (0.34, 0.30)]
        default: return parts(s)?.first?.points ?? []
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

    // MARK: - Product shapes (trousers, shoes, hats)

    /// How a part of a product template is filled: the item's fabric, its sole
    /// colour, or the fabric shaded (an opening, a band / cuff, a seam line).
    enum Fill { case fabric, sole, opening, band, seam }
    struct Part { let fill: Fill; let points: [(CGFloat, CGFloat)] }

    /// Points on an ellipse arc (degrees, y down), for domes and brims.
    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, from a0: CGFloat, to a1: CGFloat,
                    steps: Int = 24) -> [(CGFloat, CGFloat)] {
        (0...steps).map { i in
            let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            return (cx + rx * cos(a), cy + ry * sin(a))
        }
    }

    /// The parts of a product shape, drawn in order (x/y in 0...1, y down), or
    /// nil for the flat-lay shapes. Shoes stand on y ≈ 0.70–0.78, toe left.
    static func parts(_ s: Shape) -> [Part]? {
        func f(_ p: [(CGFloat, CGFloat)]) -> Part { Part(fill: .fabric, points: p) }
        switch s {
        case .tee, .shirt, .jacket, .coat, .tunic, .dress, .tank:
            return nil
        // Trousers: front view, waistband at the top, legs to the hem.
        case .trousers:
            return [f([(0.30, 0.05), (0.70, 0.05), (0.72, 0.30), (0.73, 0.95), (0.53, 0.95), (0.50, 0.36), (0.47, 0.95), (0.27, 0.95), (0.28, 0.30)]),
                    Part(fill: .band, points: [(0.30, 0.05), (0.70, 0.05), (0.703, 0.09), (0.297, 0.09)]),
                    Part(fill: .seam, points: [(0.497, 0.09), (0.503, 0.09), (0.503, 0.30), (0.497, 0.30)])]
        case .slimTrousers:
            return [f([(0.32, 0.05), (0.68, 0.05), (0.70, 0.30), (0.645, 0.95), (0.53, 0.95), (0.50, 0.38), (0.47, 0.95), (0.355, 0.95), (0.30, 0.30)]),
                    Part(fill: .band, points: [(0.32, 0.05), (0.68, 0.05), (0.683, 0.09), (0.317, 0.09)]),
                    Part(fill: .seam, points: [(0.497, 0.09), (0.503, 0.09), (0.503, 0.30), (0.497, 0.30)])]
        case .wideTrousers:
            return [f([(0.31, 0.05), (0.69, 0.05), (0.73, 0.30), (0.83, 0.95), (0.535, 0.95), (0.50, 0.40), (0.465, 0.95), (0.17, 0.95), (0.27, 0.30)]),
                    Part(fill: .band, points: [(0.31, 0.05), (0.69, 0.05), (0.694, 0.09), (0.306, 0.09)])]
        case .joggers:
            return [f([(0.31, 0.05), (0.69, 0.05), (0.72, 0.30), (0.67, 0.90), (0.53, 0.90), (0.50, 0.38), (0.47, 0.90), (0.33, 0.90), (0.28, 0.30)]),
                    Part(fill: .band, points: [(0.31, 0.05), (0.69, 0.05), (0.695, 0.10), (0.305, 0.10)]),
                    Part(fill: .band, points: [(0.335, 0.89), (0.47, 0.89), (0.465, 0.95), (0.345, 0.95)]),
                    Part(fill: .band, points: [(0.53, 0.89), (0.665, 0.89), (0.655, 0.95), (0.535, 0.95)])]
        case .leggings:
            return [f([(0.35, 0.05), (0.65, 0.05), (0.665, 0.30), (0.61, 0.95), (0.52, 0.95), (0.50, 0.40), (0.48, 0.95), (0.39, 0.95), (0.335, 0.30)])]
        // Shoes: one shoe, outer side, toe pointing left.
        case .sneaker:
            return [f([(0.10, 0.62), (0.11, 0.56), (0.16, 0.52), (0.26, 0.49), (0.38, 0.46), (0.48, 0.43), (0.56, 0.40),
                       (0.63, 0.38), (0.72, 0.39), (0.80, 0.375), (0.86, 0.40), (0.89, 0.47), (0.90, 0.62)]),
                    Part(fill: .opening, points: [(0.63, 0.385), (0.71, 0.395), (0.80, 0.38), (0.80, 0.41), (0.71, 0.425), (0.635, 0.415)]),
                    Part(fill: .sole, points: [(0.08, 0.61), (0.91, 0.61), (0.92, 0.66), (0.90, 0.70), (0.12, 0.70), (0.08, 0.67)])]
        case .boot:
            return [f([(0.10, 0.70), (0.11, 0.64), (0.16, 0.59), (0.28, 0.56), (0.40, 0.53), (0.47, 0.46), (0.49, 0.30),
                       (0.49, 0.12), (0.78, 0.12), (0.79, 0.30), (0.82, 0.48), (0.86, 0.56), (0.87, 0.70)]),
                    Part(fill: .opening, points: [(0.49, 0.12), (0.78, 0.12), (0.78, 0.145), (0.49, 0.145)]),
                    Part(fill: .sole, points: [(0.08, 0.69), (0.89, 0.69), (0.90, 0.77), (0.12, 0.78), (0.08, 0.74)])]
        case .chelsea:
            return [f([(0.10, 0.70), (0.11, 0.64), (0.17, 0.60), (0.30, 0.57), (0.42, 0.54), (0.49, 0.47), (0.51, 0.34),
                       (0.51, 0.20), (0.79, 0.20), (0.80, 0.34), (0.83, 0.50), (0.86, 0.58), (0.87, 0.70)]),
                    Part(fill: .band, points: [(0.60, 0.22), (0.70, 0.22), (0.68, 0.48), (0.64, 0.50), (0.61, 0.48)]),
                    Part(fill: .opening, points: [(0.51, 0.20), (0.79, 0.20), (0.79, 0.225), (0.51, 0.225)]),
                    Part(fill: .sole, points: [(0.08, 0.69), (0.89, 0.69), (0.89, 0.73), (0.88, 0.77), (0.72, 0.77), (0.70, 0.73), (0.10, 0.73)])]
        case .loafer:
            return [f([(0.10, 0.65), (0.12, 0.59), (0.20, 0.55), (0.33, 0.52), (0.45, 0.50), (0.56, 0.48), (0.70, 0.485),
                       (0.84, 0.48), (0.89, 0.52), (0.90, 0.65)]),
                    Part(fill: .opening, points: [(0.52, 0.485), (0.70, 0.49), (0.85, 0.485), (0.84, 0.51), (0.70, 0.515), (0.53, 0.51)]),
                    Part(fill: .sole, points: [(0.09, 0.64), (0.91, 0.64), (0.91, 0.68), (0.90, 0.72), (0.76, 0.72), (0.75, 0.68), (0.11, 0.68)])]
        case .heel:
            return [Part(fill: .sole, points: [(0.80, 0.46), (0.87, 0.46), (0.855, 0.76), (0.835, 0.76)]),
                    f([(0.08, 0.72), (0.09, 0.67), (0.17, 0.63), (0.28, 0.61), (0.38, 0.615), (0.50, 0.57), (0.63, 0.47),
                       (0.75, 0.37), (0.83, 0.32), (0.88, 0.34), (0.88, 0.45), (0.80, 0.455), (0.67, 0.53), (0.52, 0.645), (0.32, 0.72)]),
                    Part(fill: .sole, points: [(0.08, 0.715), (0.32, 0.715), (0.52, 0.64), (0.67, 0.525), (0.80, 0.45), (0.88, 0.445),
                                               (0.88, 0.47), (0.80, 0.475), (0.68, 0.55), (0.53, 0.665), (0.33, 0.74), (0.10, 0.74)])]
        case .sandal:
            return [f([(0.22, 0.65), (0.32, 0.50), (0.42, 0.50), (0.34, 0.65)]),
                    f([(0.52, 0.64), (0.58, 0.46), (0.70, 0.46), (0.66, 0.64)]),
                    f([(0.70, 0.62), (0.76, 0.44), (0.86, 0.44), (0.88, 0.62)]),
                    Part(fill: .sole, points: [(0.08, 0.66), (0.20, 0.63), (0.60, 0.62), (0.90, 0.61), (0.92, 0.66), (0.90, 0.70),
                                               (0.12, 0.72), (0.08, 0.70)])]
        // Hats: front three-quarter view.
        case .cap:
            return [f(arc(0.56, 0.62, 0.30, 0.34, from: 180, to: 360) + [(0.86, 0.66), (0.26, 0.66)]),
                    f([(0.34, 0.58), (0.18, 0.62), (0.07, 0.67), (0.06, 0.71), (0.14, 0.73), (0.30, 0.71), (0.42, 0.66)]),
                    Part(fill: .opening, points: [(0.14, 0.71), (0.30, 0.69), (0.42, 0.655), (0.42, 0.67), (0.30, 0.715), (0.15, 0.735)]),
                    Part(fill: .band, points: arc(0.56, 0.285, 0.025, 0.012, from: 0, to: 360, steps: 12))]
        case .wideBrim:
            // No dark crown opening: below the crown it read as a black band (lab, Nov 2026).
            return [f(arc(0.50, 0.64, 0.44, 0.12, from: 0, to: 360, steps: 40)),
                    f([(0.30, 0.64), (0.31, 0.40), (0.34, 0.31), (0.42, 0.27), (0.50, 0.30), (0.58, 0.27), (0.66, 0.31),
                       (0.69, 0.40), (0.70, 0.64)]),
                    Part(fill: .band, points: [(0.30, 0.55), (0.70, 0.55), (0.70, 0.63), (0.30, 0.63)])]
        case .beanie:
            return [f(arc(0.50, 0.62, 0.27, 0.38, from: 180, to: 360) + [(0.77, 0.66), (0.23, 0.66)]),
                    Part(fill: .band, points: [(0.22, 0.56), (0.78, 0.56), (0.79, 0.72), (0.21, 0.72)])]
        case .bucket:
            return [f([(0.28, 0.56), (0.31, 0.36), (0.36, 0.29), (0.50, 0.27), (0.64, 0.29), (0.69, 0.36), (0.72, 0.56)]),
                    f([(0.28, 0.54), (0.72, 0.54), (0.88, 0.68), (0.84, 0.71), (0.16, 0.71), (0.12, 0.68)]),
                    Part(fill: .opening, points: [(0.30, 0.545), (0.70, 0.545), (0.72, 0.565), (0.28, 0.565)])]
        }
    }

    /// The template image (opaque, white background), or nil when the cutout
    /// has no solid fabric area to sample.
    /// `solid`: a plain garment — sample only fabric of its main colour (an open
    /// coat's cutout also holds a scarf end or the dark strip between its
    /// halves, which the model would otherwise paint on as a print).
    /// `backdrop`: the canvas grey (1 = white, what every render uses).
    static func render(cutout: CGImage, shape: Shape, solid: Bool = false, side: Int = 512, backdrop: CGFloat = 1) -> CGImage? {
        if let parts = parts(shape) {
            return renderProduct(cutout: cutout, shape: shape, parts: parts, solid: solid, side: side, backdrop: backdrop)
        }
        return renderFlatLay(cutout: cutout, shape: shape, solid: solid, side: side)
    }

    /// Tops, layers and dresses (unchanged since the template path landed).
    static func renderFlatLay(cutout: CGImage, shape: Shape, solid: Bool, side: Int) -> CGImage? {
        guard let patch = (solid ? fabricPatch(cutout, mainColourOnly: true) : nil) ?? fabricPatch(cutout) else { return nil }
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
    static func fabricPatch(_ cutout: CGImage, mainColourOnly: Bool = false) -> CGImage? {
        let g = 96
        let k = CGFloat(g) / CGFloat(max(cutout.width, cutout.height))
        guard let ctx = CGContext(data: nil, width: g, height: g, bitsPerComponent: 8, bytesPerRow: g * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cutout, in: CGRect(x: 0, y: 0, width: CGFloat(cutout.width) * k, height: CGFloat(cutout.height) * k))
        let p = data.assumingMemoryBound(to: UInt8.self)
        var m = [UInt8](repeating: 0, count: g * g)
        for i in 0..<(g * g) { m[i] = p[i * 4 + 3] > 230 ? 1 : 0 }
        if mainColourOnly {
            // Keep pixels within ΔE 18 of the median fabric colour.
            var labs: [(Float, Float, Float)?] = Array(repeating: nil, count: g * g)
            var Ls: [Float] = [], As: [Float] = [], Bs: [Float] = []
            for i in 0..<(g * g) where m[i] != 0 {
                let a = Float(p[i * 4 + 3]) / 255
                let c = ColorNamer.lab(Float(p[i * 4]) / 255 / a, Float(p[i * 4 + 1]) / 255 / a, Float(p[i * 4 + 2]) / 255 / a)
                labs[i] = c; Ls.append(c.0); As.append(c.1); Bs.append(c.2)
            }
            guard Ls.count > 50 else { return nil }
            func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
            let ref = (median(Ls), median(As), median(Bs))
            for i in 0..<(g * g) {
                guard let c = labs[i] else { continue }
                let d = sqrt(pow(c.0 - ref.0, 2) + pow(c.1 - ref.1, 2) + pow(c.2 - ref.2, 2))
                if d > 18 { m[i] = 0 }
            }
        }
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
        guard depth >= (mainColourOnly ? 4 : 3), let centre = last.first else { return nil }
        // Back to cutout pixels (bitmap rows are top-down here; CG drew with a y-up origin).
        let cx = CGFloat(centre % g) / k, cyFromBottom = CGFloat(centre / g)
        let cy = CGFloat(cutout.height) - (CGFloat(g) - 1 - cyFromBottom) / k
        let r = CGFloat(depth) * 0.75 / k
        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            .intersection(CGRect(x: 0, y: 0, width: cutout.width, height: cutout.height))
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return cutout.cropping(to: rect.integral)
    }

    // MARK: - Product template drawing

    /// Trousers, shoes and hats: each part filled with the fabric (or the sole
    /// colour), then one shared light — brighter on top, a soft rim toward the
    /// edges — and a soft contact shadow, the same for every item so renders
    /// across the closet share a look.
    static func renderProduct(cutout: CGImage, shape: Shape, parts: [Part], solid: Bool, side: Int, backdrop: CGFloat = 1) -> CGImage? {
        guard let raw = (solid ? fabricPatch(cutout, mainColourOnly: true) : nil) ?? fabricPatch(cutout),
              let mean = meanColour(raw) else { return nil }
        // A plain item's patch keeps its fine texture (knit, grain, wash) but not
        // its larger blotches: mirror-tiled, those read as a print.
        let patch = solid ? (flattened(raw, mean: mean) ?? raw) : raw
        let fam = family(shape)
        let sole = fam == .footwear ? soleColour(cutout, fabric: mean) : mean
        let s = CGFloat(side)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: s, height: s)
        ctx.setFillColor(red: backdrop, green: backdrop, blue: backdrop, alpha: 1)
        ctx.fill(canvas)
        func path(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map { CGPoint(x: $0.0 * s, y: s - $0.1 * s) })   // CG is y-up
            p.closeSubpath()
            return p
        }
        let paths = parts.map { path($0.points) }
        let union = paths.dropFirst().reduce(paths[0]) { $0.union($1) }
        let box = union.boundingBoxOfPath

        // Contact shadow: a soft flat ellipse under shoes and hats; trousers lie
        // flat, so a drop shadow like the flat lays.
        if fam == .footwear || fam == .headwear {
            ctx.saveGState()
            let rx = box.width * 0.48
            ctx.translateBy(x: box.midX + box.width * 0.02, y: box.minY + s * 0.004)
            ctx.scaleBy(x: 1, y: 0.07)
            let colors = [CGColor(gray: 0, alpha: 0.34), CGColor(gray: 0, alpha: 0)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
            }
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 5, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.28))
            ctx.setFillColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
            ctx.addPath(union); ctx.fillPath()
            ctx.restoreGState()
        }

        // Parts.
        let k = 0.8 * s / (0.86 * CGFloat(max(cutout.width, cutout.height)))
        let t = min(max(CGFloat(patch.width) * k, 48), 256)
        for (part, p) in zip(parts, paths) {
            ctx.saveGState()
            ctx.addPath(p); ctx.clip()
            if part.fill == .sole {
                ctx.setFillColor(red: sole.0, green: sole.1, blue: sole.2, alpha: 1)
                ctx.fill(canvas)
            } else {
                ctx.interpolationQuality = .high
                drawMirrorTiles(patch, tile: t, in: ctx, side: s)
                let shade: CGFloat
                switch part.fill {
                case .opening: shade = 0.62
                case .band: shade = 0.22
                case .seam: shade = 0.38
                default: shade = 0
                }
                if shade > 0 { ctx.setFillColor(gray: 0, alpha: shade); ctx.fill(canvas) }
            }
            ctx.restoreGState()
        }

        // One light for every product: from above, falling off toward the edges.
        ctx.saveGState()
        ctx.addPath(union); ctx.clip()
        let solidLook = fam == .footwear || fam == .headwear
        let top = CGColor(gray: 1, alpha: solidLook ? 0.10 : 0.03), bottom = CGColor(gray: 0, alpha: solidLook ? 0.16 : 0.06)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        }
        // Rim: the shadow of everything outside the silhouette, cast inward.
        let outside = CGPath(rect: canvas.insetBy(dx: -64, dy: -64), transform: nil).subtracting(union)
        ctx.setShadow(offset: .zero, blur: solidLook ? 14 : 20, color: CGColor(gray: 0, alpha: solidLook ? 0.45 : 0.30))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.addPath(outside); ctx.fillPath()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Where a product shot's template puts the product, eroded by `inset`
    /// pixels: a side×side mask (row 0 = top). The simulator's white key may not
    /// flood into it (it ate a white sneaker's toe and laces), so it must be a
    /// safe core well inside where the model draws the item.
    static func core(_ shape: Shape, side: Int, inset: Int = 14) -> [Bool]? {
        guard let parts = parts(shape), side > 2 * inset else { return nil }
        let s = CGFloat(side)
        var px = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        for part in parts {
            let p = CGMutablePath()
            p.addLines(between: part.points.map { CGPoint(x: $0.0 * s, y: s - $0.1 * s) })
            p.closeSubpath()
            ctx.addPath(p)
        }
        ctx.fillPath()
        var mask = px.map { $0 > 127 }
        // Erode: a pixel stays only if everything within `inset` (a square) is inside.
        for _ in 0..<inset {
            var next = mask
            for y in 0..<side {
                for x in 0..<side where mask[y * side + x] {
                    if x == 0 || y == 0 || x == side - 1 || y == side - 1 || !mask[y * side + x - 1] || !mask[y * side + x + 1]
                        || !mask[(y - 1) * side + x] || !mask[(y + 1) * side + x] { next[y * side + x] = false }
                }
            }
            mask = next
        }
        return mask
    }

    /// The patch mirror-tiled over the canvas (no seams).
    private static func drawMirrorTiles(_ patch: CGImage, tile t: CGFloat, in ctx: CGContext, side s: CGFloat) {
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
    }

    /// Mean colour of an opaque image, 0...1.
    static func meanColour(_ image: CGImage) -> (CGFloat, CGFloat, CGFloat)? {
        guard let px = GarmentCutout.rgbaPixels(image) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in 0..<(image.width * image.height) where px[i * 4 + 3] > 200 {
            let a = Double(px[i * 4 + 3])
            r += Double(px[i * 4]) / a; g += Double(px[i * 4 + 1]) / a; b += Double(px[i * 4 + 2]) / a; n += 1
        }
        guard n > 0 else { return nil }
        return (CGFloat(min(r / n, 1)), CGFloat(min(g / n, 1)), CGFloat(min(b / n, 1)))
    }

    /// The patch's fine texture on its mean colour: mean + 0.6 × (patch − blur).
    static func flattened(_ patch: CGImage, mean: (CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let w = patch.width, h = patch.height
        guard w >= 8, h >= 8, var px = GarmentCutout.rgbaPixels(patch) else { return nil }
        let r = max(2, min(w, h) / 10)
        // Separable box blur of each channel.
        var src = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { src[i * 3 + c] = Float(px[i * 4 + c]) } }
        var tmp = src, blur = src
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var acc: Float = 0, n: Float = 0
                    for dx in -r...r { let xx = min(max(x + dx, 0), w - 1); acc += src[(y * w + xx) * 3 + c]; n += 1 }
                    tmp[(y * w + x) * 3 + c] = acc / n
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var acc: Float = 0, n: Float = 0
                    for dy in -r...r { let yy = min(max(y + dy, 0), h - 1); acc += tmp[(yy * w + x) * 3 + c]; n += 1 }
                    blur[(y * w + x) * 3 + c] = acc / n
                }
            }
        }
        let m = [Float(mean.0 * 255), Float(mean.1 * 255), Float(mean.2 * 255)]
        for i in 0..<(w * h) {
            for c in 0..<3 { px[i * 4 + c] = UInt8(min(max(m[c] + 0.6 * (src[i * 3 + c] - blur[i * 3 + c]), 0), 255)) }
            px[i * 4 + 3] = 255
        }
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// A shoe's sole colour, from the bottom 15% of its cutout: a clearly
    /// lighter colour there (a white sole under a black upper) when it covers a
    /// third of that band, else the upper's own colour a little darker; a light
    /// shoe gets a light sole.
    static func soleColour(_ cutout: CGImage, fabric: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let lum = (fabric.0 + fabric.1 + fabric.2) / 3
        if lum > 0.67 { return (min(fabric.0 * 1.02, 0.98), min(fabric.1 * 1.02, 0.98), min(fabric.2 * 1.02, 0.98)) }
        let dark = (fabric.0 * 0.85, fabric.1 * 0.85, fabric.2 * 0.85)
        guard let px = GarmentCutout.rgbaPixels(cutout) else { return dark }
        let w = cutout.width, h = cutout.height
        var y0 = h, y1 = -1
        for y in 0..<h { for x in stride(from: 0, to: w, by: 2) where px[(y * w + x) * 4 + 3] > 230 { y0 = min(y0, y); y1 = max(y1, y); break } }
        guard y1 > y0 else { return dark }
        let from = y1 - (y1 - y0) * 15 / 100
        var n = 0, m = 0, acc = (0.0, 0.0, 0.0)
        let f = (Double(fabric.0) * 255, Double(fabric.1) * 255, Double(fabric.2) * 255)
        for y in from...y1 {
            for x in stride(from: 0, to: w, by: 2) {
                let o = (y * w + x) * 4
                let a = Double(px[o + 3])
                guard a > 230 else { continue }
                n += 1
                let c = (Double(px[o]) * 255 / a, Double(px[o + 1]) * 255 / a, Double(px[o + 2]) * 255 / a)
                let d = sqrt(pow(c.0 - f.0, 2) + pow(c.1 - f.1, 2) + pow(c.2 - f.2, 2))
                if d > 60 && (c.0 + c.1 + c.2) > (f.0 + f.1 + f.2) { m += 1; acc.0 += c.0; acc.1 += c.1; acc.2 += c.2 }
            }
        }
        guard n >= 20, m * 3 >= n else { return dark }
        return (CGFloat(acc.0 / Double(m) / 255), CGFloat(acc.1 / Double(m) / 255), CGFloat(acc.2 / Double(m) / 255))
    }
}
