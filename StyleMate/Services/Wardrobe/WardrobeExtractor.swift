import CoreGraphics
import UIKit

/// The on-device wardrobe pipeline: photo of the user → one clean cutout +
/// attributes per garment and accessory they're wearing.
///
///   1. Locate the person (parser pass on the whole photo) and crop to them at
///      the parser's 2:3 portrait aspect, so the garments fill the analysis grid.
///   2. Parse the crop (clothing vs body + coarse region) and label it (garment
///      type), then fuse into per-item masks (`GarmentSegmenter`).
///   3. Cut each item out at full resolution with edge-aware masks and filled
///      occlusions (`GarmentCutout`).
///   4. Name it (`FashionClassifier`) and score how good this view of it is, so a
///      better photo of the same item can replace a worse one later.
enum WardrobeExtractor {
    struct Item {
        let kind: GarmentKind
        let attributes: FashionClassifier.Attributes
        let cutout: UIImage
        /// 0...1: how good this photo of the item is (size, sharpness, not cut
        /// off by the frame, little occlusion).
        let quality: Float
        /// Cut off by the photo's frame, or with occluded parts left unfilled
        /// (a print or a big hole): the studio render then generates the whole
        /// garment instead of refining a partial one.
        var truncated: Bool = false
        /// Where the item is in the photo, normalised 0...1 (top-left origin).
        /// Used by the benchmark to match items to hand labels.
        var box: CGRect = .zero
    }

    /// Items we never auto-add from a photo of a person (privacy + they're not
    /// reliably visible): underwear-class garments.
    private static let blockedProducts: Set<String> = ["Underwear", "Boxers", "Briefs", "Bras", "Bralettes", "Thongs", "Lingerie", "Shapewear"]

    static var isAvailable: Bool { WardrobeML.shared.isAvailable }

    static func extract(from image: UIImage, trace: ((String) -> Void)? = nil) -> [Item] {
        func log(_ s: String) { print("[Wardrobe] \(s)"); trace?(s) }
        guard isAvailable, let source = flatten(image) else { return [] }
        let t0 = Date()

        // 1. Person crop.
        guard let crop = personCrop(source) else {
            log("no person found")
            return []
        }

        // 2. Parse + label + fuse.
        guard let seg = segment(crop) else { return [] }
        let scene = SceneLight(photo: source)

        // 2b. Close-ups of the head, hands and feet for small things the
        // full-body pass missed (sunglasses, a cap, a watch, a bag, shoes).
        var uses: [Use] = seg.instances.map { Use(inst: $0, crop: crop, pixels: seg.pixels, zoomed: false) }
        uses += partZooms(seg: seg, crop: crop, photo: source, log: log)
        let hasOuter = uses.contains { $0.inst.kind == .outerLayer }

        // 3 + 4.
        var items: [Item] = []
        for var use in uses {
            // Small accessories cover only a few grid cells in a full-body crop;
            // re-parse a tight crop around them for a crisp, accurate mask.
            if !use.zoomed, needsZoom(use.inst), let z = zoomed(use.inst, in: crop, photo: source) { use = z }
            let inst = use.inst
            let truncated = isTruncated(inst, crop: use.crop)
            var context = FashionClassifier.Context()
            // An inner top under an open layer, or cut off by the frame, is only partly seen.
            context.occluded = inst.kind == .innerTop && (truncated || hasOuter)
            context.parts = inst.partShares
            guard let cut = autoreleasepool(invoking: {
                      GarmentCutout.render(crop: use.crop.image, cropPixels: use.pixels, instance: inst, photoInGrid: use.crop.photoInGrid)
                  }),
                  let attrs = FashionClassifier.classify(cut.image, kind: inst.kind, scene: scene, context: context),
                  !blockedProducts.contains(attrs.product) else { continue }
            // Too few source-photo pixels to make a decent wardrobe image
            // (sunglasses 40 px wide in a group shot): skip — a closer photo will catch it.
            let photoSide = cut.sourceSide / Float(use.crop.scale)
            // sqrt(area): thin sunglasses are ~1/3 of their width. The close-up passes
            // segment these crisply, and the studio render refines them, so the bars
            // only drop what no render could rescue (benchmark: sunglasses 38–45,
            // a turban 47, handbags 87–90 were being dropped).
            let minSide: Float
            switch inst.kind {
            case .eyewear: minSide = 32
            case .headwear: minSide = 40
            case .jewelry, .belt: minSide = 56
            case .footwear: minSide = 64
            case .bag: minSide = 72
            default: minSide = 110
            }
            guard photoSide >= minSide else {
                log("drop tiny \(attrs.product) (\(Int(photoSide)) px)")
                continue
            }
            // A smooth fill over a print, or over a big hole, shows as a blotch:
            // keep the hole out of the cutout and let the studio render make
            // the whole garment instead.
            var image = cut.image, routeToGenerate = truncated
            let holeShare = Float(inst.holeCount) / Float(max(1, inst.pixelCount))
            if inst.holeCount > 0, attrs.pattern != .solid || holeShare > 0.10,
               let plain = GarmentCutout.render(crop: use.crop.image, cropPixels: use.pixels, instance: inst,
                                                photoInGrid: use.crop.photoInGrid, fill: false) {
                image = plain.image
                routeToGenerate = true
            }
            let q = quality(inst, cut: cut, crop: use.crop, photoSide: photoSide)
            guard q >= 0.22 else {
                log("drop low-quality \(attrs.product) q=\(String(format: "%.2f", q))")
                continue
            }
            items.append(Item(kind: attrs.kind, attributes: attrs, cutout: image, quality: q,
                              truncated: routeToGenerate,
                              box: photoBox(inst, crop: use.crop, photo: source)))
        }
        items = dedupeWithinPhoto(items)
        log("extracted \(items.count) items in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s: " +
            items.map { "\($0.attributes.product)(\(String(format: "%.2f", $0.quality)))" }.joined(separator: ", "))
        return items
    }

    /// An instance with the crop (and its pixels) it was segmented in.
    private struct Use {
        var inst: GarmentInstance
        var crop: Crop
        var pixels: [UInt8]
        var zoomed: Bool
    }

    // MARK: - Person crop

    private struct Crop {
        let image: CGImage
        /// The crop's rectangle in source-photo pixels (may extend past the
        /// photo, padded grey) and crop pixels per photo pixel.
        let rect: CGRect
        let scale: CGFloat
        /// Where the actual photo lies on the 384x576 analysis grid: an item
        /// reaching one of these edges is cut off by the photo's frame.
        let photoInGrid: CGRect
    }

    private struct Segmentation {
        let instances: [GarmentInstance]
        let pixels: [UInt8]
        /// Parser labels on the grid (padding outside the photo zeroed).
        let labels: [UInt8]
    }

    private static func segment(_ crop: Crop) -> Segmentation? {
        let image = crop.image
        guard let parserIn = resized(image, w: WardrobeML.gridW, h: WardrobeML.gridH),
              let labelerIn = resized(image, w: 512, h: 512),
              let parsed = WardrobeML.shared.parse(parserIn),
              let logits = WardrobeML.shared.label(labelerIn),
              let pixels = GarmentCutout.rgbaPixels(image) else { return nil }
        // The grey padding past the photo's edge is never garment (it was
        // segmented as a grey bar on a white shirt, a block under white jeans).
        var labels = parsed.labels
        let w = WardrobeML.gridW, h = WardrobeML.gridH, f = crop.photoInGrid
        let x0 = max(0, Int(f.minX.rounded(.up))), y0 = max(0, Int(f.minY.rounded(.up)))
        let x1 = min(w, Int(f.maxX.rounded(.down))), y1 = min(h, Int(f.maxY.rounded(.down)))
        if x0 > 0 || y0 > 0 || x1 < w || y1 < h {
            for y in 0..<h {
                for x in 0..<w where x < x0 || x >= x1 || y < y0 || y >= y1 { labels[y * w + x] = 0 }
            }
        }
        return Segmentation(instances: GarmentSegmenter.segment(parser: labels, labelerLogits: logits), pixels: pixels, labels: labels)
    }

    /// Renders `r0` (photo pixels, grown to the grid's 2:3 aspect) as a crop.
    /// `minHeight` upsamples tiny regions so the parser sees them at full grid size.
    private static func makeCrop(_ photo: CGImage, rect r0: CGRect, maxHeight: CGFloat = 1536, minHeight: CGFloat = 0) -> Crop? {
        let W = CGFloat(photo.width), H = CGFloat(photo.height)
        let gw = CGFloat(WardrobeML.gridW), gh = CGFloat(WardrobeML.gridH)
        var r = r0
        let aspect = gw / gh
        if r.width / r.height < aspect {
            let nw = r.height * aspect; r = r.insetBy(dx: -(nw - r.width) / 2, dy: 0)
        } else {
            let nh = r.width / aspect; r = r.insetBy(dx: 0, dy: -(nh - r.height) / 2)
        }
        let scale = max(min(1, maxHeight / r.height), minHeight / r.height)
        let size = CGSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
        let dest = CGRect(x: -r.minX * scale, y: -r.minY * scale, width: W * scale, height: H * scale)
        guard let img = letterbox(photo, into: size, rect: dest) else { return nil }
        let gx = gw / size.width, gy = gh / size.height
        let photoInGrid = CGRect(x: dest.minX * gx, y: dest.minY * gy, width: dest.width * gx, height: dest.height * gy)
        return Crop(image: img, rect: r, scale: scale, photoInGrid: photoInGrid)
    }

    private static func personCrop(_ photo: CGImage) -> Crop? {
        let W = CGFloat(photo.width), H = CGFloat(photo.height)
        let gw = CGFloat(WardrobeML.gridW), gh = CGFloat(WardrobeML.gridH)
        // Letterbox the whole photo into the grid (aspect preserved) to find the person.
        let k = min(gw / W, gh / H)
        let dw = W * k, dh = H * k, ox = (gw - dw) / 2, oy = (gh - dh) / 2
        guard let box = letterbox(photo, into: CGSize(width: gw, height: gh), rect: CGRect(x: ox, y: oy, width: dw, height: dh)),
              let parsed = WardrobeML.shared.parse(box) else { return nil }

        // Largest connected person blob (non-background).
        let w = WardrobeML.gridW, h = WardrobeML.gridH
        let person = parsed.labels.map { $0 == 0 ? UInt8(0) : UInt8(1) }
        let (comp, sizes) = GarmentSegmenter.components(person, w: w, h: h)
        guard let maxSize = sizes.max(), maxSize > w * h / 200, let id = sizes.firstIndex(of: maxSize).map({ $0 + 1 }) else { return nil }
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for i in 0..<(w * h) where comp[i] == id {
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
        }
        // Back to photo pixels, with a margin.
        var r = CGRect(x: (CGFloat(x0) - ox) / k, y: (CGFloat(y0) - oy) / k,
                       width: CGFloat(x1 - x0) / k, height: CGFloat(y1 - y0) / k)
        r = r.insetBy(dx: -r.width * 0.06, dy: -r.height * 0.04)
        return makeCrop(photo, rect: r)
    }

    // MARK: - Zoom passes for small items

    private static func needsZoom(_ inst: GarmentInstance) -> Bool {
        guard [GarmentKind.eyewear, .jewelry, .headwear, .belt].contains(inst.kind) else { return false }
        let (_, y0, _, y1) = inst.box
        return Double(y1 - y0) < Double(WardrobeML.gridH) * 0.16
    }

    /// Grid box → photo rectangle.
    private static func photoRect(_ b: (Int, Int, Int, Int), in crop: Crop) -> CGRect {
        let gw = CGFloat(WardrobeML.gridW), gh = CGFloat(WardrobeML.gridH)
        let x0 = crop.rect.minX + CGFloat(b.0) / gw * crop.rect.width, y0 = crop.rect.minY + CGFloat(b.1) / gh * crop.rect.height
        let x1 = crop.rect.minX + CGFloat(b.2) / gw * crop.rect.width, y1 = crop.rect.minY + CGFloat(b.3) / gh * crop.rect.height
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Bounding box of the grid pixels whose parser label is in `classes`.
    private static func labelBox(_ labels: [UInt8], _ classes: Set<UInt8>) -> (Int, Int, Int, Int, Int)? {
        let w = WardrobeML.gridW
        var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0, n = 0
        for (i, l) in labels.enumerated() where classes.contains(l) {
            let x = i % w, y = i / w
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1); n += 1
        }
        return n > 0 ? (x0, y0, x1, y1, n) : nil
    }

    /// Re-segments close-ups of the head (face + hair x2.2), each hand (x4) and
    /// the feet (bottom 22% of the person) at full grid resolution and adds the
    /// eyewear / headwear / bag / watch / footwear the full-body pass didn't
    /// find. A head close-up without headwear also checks whether the "hair"
    /// is a turban or headscarf.
    private static func partZooms(seg: Segmentation, crop: Crop, photo: CGImage, log: (String) -> Void) -> [Use] {
        typealias P = GarmentSegmenter.P
        let gh = CGFloat(WardrobeML.gridH)
        let found = Set(seg.instances.map { $0.kind })
        var out: [Use] = []
        var foundNow = found

        // Everything the full-body pass already assigned to a garment, on its grid.
        let gw = CGFloat(WardrobeML.gridW)
        var claimed = [UInt8](repeating: 0, count: WardrobeML.gridCount)
        for inst in seg.instances { for i in 0..<claimed.count where inst.mask[i] != 0 { claimed[i] = 1 } }
        /// Share of a close-up instance lying on pixels the full-body pass gave to another
        /// garment (a coat's leather cuff re-read as a "handbag" in a hand close-up).
        func claimedShare(_ inst: GarmentInstance, in z: Crop) -> Float {
            var hit = 0, total = 0
            let w = WardrobeML.gridW
            for i in stride(from: 0, to: inst.mask.count, by: 3) where inst.mask[i] != 0 {
                total += 1
                let px = z.rect.minX + CGFloat(i % w) / gw * z.rect.width
                let py = z.rect.minY + CGFloat(i / w) / gh * z.rect.height
                let mx = Int((px - crop.rect.minX) / crop.rect.width * gw), my = Int((py - crop.rect.minY) / crop.rect.height * gh)
                if mx >= 0, my >= 0, mx < w, my < WardrobeML.gridH, claimed[my * w + mx] != 0 { hit += 1 }
            }
            return total == 0 ? 0 : Float(hit) / Float(total)
        }

        var zoomCrops: [String: Crop] = [:]
        func zoom(_ r0: CGRect, kinds: Set<GarmentKind>, label: String) -> Segmentation? {
            let wanted = kinds.subtracting(foundNow)
            guard !wanted.isEmpty, r0.width > 4, r0.height > 4,
                  let z = makeCrop(photo, rect: r0, minHeight: gh), let s = segment(z) else { return nil }
            for k in wanted {
                guard let best = s.instances.filter({ $0.kind == k }).max(by: { $0.pixelCount < $1.pixelCount }) else { continue }
                // Bags and watches only: shoes the full-body pass merged into black
                // trousers are exactly what the feet close-up is for.
                let share = [.bag, .jewelry].contains(k) ? claimedShare(best, in: z) : 0
                guard share < 0.5 else {
                    log("\(label) zoom: \(k.rawValue) is \(Int(share * 100))% another garment, skipped")
                    continue
                }
                out.append(Use(inst: best, crop: z, pixels: s.pixels, zoomed: true))
                foundNow.insert(k)
                log("\(label) zoom found \(k.rawValue)")
            }
            zoomCrops[label] = z
            return s
        }

        // Head.
        if let hb = labelBox(seg.labels, [P.face.rawValue, P.hair.rawValue, P.hat.rawValue, P.glasses.rawValue]), hb.4 > 40 {
            let r = photoRect((hb.0, hb.1, hb.2, hb.3), in: crop)
            let side = max(r.width, r.height) * 2.2
            let head = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
            if let s = zoom(head, kinds: [.eyewear, .headwear], label: "head"), !foundNow.contains(.headwear),
               let z = zoomCrops["head"], let hair = GarmentSegmenter.instance(kind: .headwear, parserClass: .hair, labels: s.labels),
               let cut = GarmentCutout.render(crop: z.image, cropPixels: s.pixels, instance: hair, photoInGrid: z.photoInGrid),
               let cg = cut.image.cgImage, let input = FashionClassifier.onWhite(cg, side: 224),
               let emb = WardrobeML.shared.embed(input), let vocab = WardrobeML.shared.vocabulary,
               let best = vocab.best(in: "hair_check", for: emb), best.label != "Hair", best.margin > 0.02 {
                out.append(Use(inst: hair, crop: z, pixels: s.pixels, zoomed: true))
                foundNow.insert(.headwear)
                log("head zoom: the hair is \(best.label) (+\(String(format: "%.3f", best.margin)))")
            }
        }
        // Hands: bags and watches.
        let (comp, sizes) = GarmentSegmenter.components(seg.labels.map { $0 == P.hands.rawValue ? UInt8(1) : UInt8(0) },
                                                         w: WardrobeML.gridW, h: WardrobeML.gridH)
        for (ci, size) in sizes.enumerated().sorted(by: { $0.element > $1.element }).prefix(2) where size >= 30 {
            var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0
            for (i, c) in comp.enumerated() where c == ci + 1 {
                let x = i % WardrobeML.gridW, y = i / WardrobeML.gridW
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
            }
            let r = photoRect((x0, y0, x1, y1), in: crop)
            let side = max(r.width, r.height) * 4
            _ = zoom(CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side),
                     kinds: [.bag, .jewelry], label: "hand\(ci)")
        }
        // Feet.
        let body = Set((1...17).map { UInt8($0) })
        if let pb = labelBox(seg.labels, body) {
            let top = pb.1 + Int(Double(pb.3 - pb.1) * 0.78)
            let r = photoRect((pb.0, top, pb.2, pb.3), in: crop)
            _ = zoom(r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.25), kinds: [.footwear], label: "feet")
        }
        return out
    }

    /// Re-segments a tight crop around a small item; returns the matching
    /// instance in that crop (or nil to keep the original).
    private static func zoomed(_ inst: GarmentInstance, in crop: Crop, photo: CGImage) -> Use? {
        let gh = CGFloat(WardrobeML.gridH)
        let box = photoRect(inst.box, in: crop)
        // Enough context around it for the parser to recognise a head / wrist.
        let r = box.insetBy(dx: -box.width * 1.2, dy: -box.height * 1.6)
        guard r.width > 4, r.height > 4,
              let z = makeCrop(photo, rect: r, minHeight: gh),
              let seg = segment(z) else { return nil }
        let gw = CGFloat(WardrobeML.gridW)
        func distance(_ i: GarmentInstance) -> CGFloat {
            let cx = CGFloat(i.box.0 + i.box.2) / 2, cy = CGFloat(i.box.1 + i.box.3) / 2
            return hypot(cx - gw / 2, cy - gh / 2)
        }
        guard let m = seg.instances.filter({ $0.kind == inst.kind }).min(by: { distance($0) < distance($1) })
        else { return nil }
        return Use(inst: m, crop: z, pixels: seg.pixels, zoomed: true)
    }

    // MARK: - Quality

    /// The instance's grid box in normalised photo coordinates.
    private static func photoBox(_ inst: GarmentInstance, crop: Crop, photo: CGImage) -> CGRect {
        let gw = CGFloat(WardrobeML.gridW), gh = CGFloat(WardrobeML.gridH)
        let W = CGFloat(photo.width), H = CGFloat(photo.height)
        let (x0, y0, x1, y1) = inst.box
        func px(_ gx: Int) -> CGFloat { (crop.rect.minX + CGFloat(gx) / gw * crop.rect.width) / W }
        func py(_ gy: Int) -> CGFloat { (crop.rect.minY + CGFloat(gy) / gh * crop.rect.height) / H }
        let r = CGRect(x: px(x0), y: py(y0), width: px(x1) - px(x0), height: py(y1) - py(y0))
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func isTruncated(_ inst: GarmentInstance, crop: Crop) -> Bool {
        let (x0, y0, x1, y1) = inst.box
        let f = crop.photoInGrid, tol: CGFloat = 2
        return CGFloat(y0) <= f.minY + tol || CGFloat(y1) >= f.maxY - tol
            || CGFloat(x0) <= f.minX + tol || CGFloat(x1) >= f.maxX - tol
    }

    private static func quality(_ inst: GarmentInstance, cut: GarmentCutout.Result, crop: Crop, photoSide: Float) -> Float {
        let size = min(1, photoSide / (inst.kind.isSmall ? 120 : 380))
        let occlusion = Float(inst.holeCount) / Float(max(1, inst.pixelCount + inst.holeCount))
        // Cut off by the photo's frame? Compared against where the photo sits on
        // the grid — the crop may extend past it, padded grey. Shoes at the
        // bottom edge = missing feet.
        let (x0, y0, x1, y1) = inst.box
        let f = crop.photoInGrid, tol: CGFloat = 2
        let truncated = CGFloat(y0) <= f.minY + tol || CGFloat(y1) >= f.maxY - tol
            || CGFloat(x0) <= f.minX + tol || CGFloat(x1) >= f.maxX - tol
        let complete: Float = truncated ? (inst.kind == .footwear || inst.kind == .lower || inst.kind == .onePiece ? 0.1 : 0.45) : 1
        // A one-piece garment in several floating pieces (a sleeve apart from
        // the body) is a poor view of it; pairs (shoes, an open coat) are fine.
        let paired = inst.kind == .footwear || inst.kind == .outerLayer || inst.kind == .eyewear
        let fragments = Float(max(0, inst.parts - (paired ? 2 : 1)))
        return 0.35 * size + 0.15 * (1 - occlusion * 2) + 0.30 * complete + 0.20 * cut.sharpness - 0.1 * fragments
    }

    /// The labeler occasionally names two touching blobs of one garment
    /// differently; merge same-product results from one photo (keep the larger).
    private static func dedupeWithinPhoto(_ items: [Item]) -> [Item] {
        var out: [Item] = []
        for it in items {
            if let j = out.firstIndex(where: { o in
                o.attributes.category == it.attributes.category &&
                cosine(o.attributes.embedding, it.attributes.embedding) > 0.92
            }) {
                if it.quality > out[j].quality { out[j] = it }
            } else {
                out.append(it)
            }
        }
        return out
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    // MARK: - Image helpers

    /// Bakes orientation and flattens transparency onto neutral grey (isolated-
    /// person images are transparent around the user; the models expect a scene).
    private static func flatten(_ image: UIImage) -> CGImage? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longSide = max(px.width, px.height)
        let s = min(1, 2048 / longSide)
        let size = CGSize(width: (px.width * s).rounded(), height: (px.height * s).rounded())
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Draws `image` into `rect` on a neutral-grey canvas of `size` (top-left origin).
    private static func letterbox(_ image: CGImage, into size: CGSize, rect: CGRect) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        // CGContext is bottom-left origin: flip the destination rect.
        ctx.draw(image, in: CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
        return ctx.makeImage()
    }

    private static func resized(_ image: CGImage, w: Int, h: Int) -> CGImage? {
        letterbox(image, into: CGSize(width: w, height: h), rect: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
