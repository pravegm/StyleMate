import CoreGraphics
import UIKit

/// The on-device wardrobe pipeline: photo of the user → one clean cutout +
/// attributes per garment and accessory they're wearing.
///
///   1. Locate the person (GarmentNet pass on the whole photo) and crop to them at
///      the grid's 2:3 portrait aspect, so the garments fill the analysis grid
///      (the first pass is reused when the person already fills the photo).
///   2. Segment the crop (garment class / body / scene per pixel) and group it into
///      per-item masks (`GarmentSegmenter`).
///   2b. Close-ups only where the full-body pass says a small item is likely
///      (sunglasses, a hat, a watch, a bag, shoes) or a found one is too small to
///      cut out cleanly; overlapping close-ups share one pass.
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
        _ = WardrobeML.shared.takeTiming()

        // 1. Person crop (and, when the person fills the photo, its segmentation).
        guard let found = personCrop(source) else {
            log("no person found")
            return []
        }
        let (crop, reused) = found

        // 2. Segment + group.
        guard let seg = reused ?? segment(crop) else { return [] }
        let scene = SceneLight(photo: source)

        // 2b. Close-ups where the full-body pass says a small item is likely.
        var uses: [Use] = seg.instances.map { Use(inst: $0, crop: crop, pixels: seg.pixels, zoomed: false) }
        closeUps(&uses, seg: seg, crop: crop, photo: source, log: log)
        let hasOuter = uses.contains { $0.inst.kind == .outerLayer }

        // 3 + 4.
        var items: [Item] = []
        for use in uses {
            let inst = use.inst
            let truncated = isTruncated(inst, crop: use.crop)
            var context = FashionClassifier.Context()
            // An inner top under an open layer, or cut off by the frame, is only partly seen.
            context.occluded = inst.kind == .innerTop && (truncated || hasOuter)
            context.parts = inst.partShares
            context.allowTie = inst.labelerClass == 17
            let tc = Date()
            guard let cut = autoreleasepool(invoking: {
                      GarmentCutout.render(crop: use.crop.image, cropPixels: use.pixels, instance: inst, photoInGrid: use.crop.photoInGrid)
                  }) else { continue }
            WardrobeML.shared.record("cutout", Date().timeIntervalSince(tc))
            let tk = Date()
            guard let attrs = FashionClassifier.classify(cut.image, kind: inst.kind, scene: scene, context: context),
                  !blockedProducts.contains(attrs.product) else { continue }
            WardrobeML.shared.record("classify", Date().timeIntervalSince(tk))
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
        log("timing: " + WardrobeML.shared.takeTiming())
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
        /// GarmentNet classes on the grid (padding outside the photo zeroed).
        let labels: [UInt8]
        let map: GarmentMap
    }

    private static func segment(_ crop: Crop) -> Segmentation? {
        guard let input = resized(crop.image, w: WardrobeML.inputW, h: WardrobeML.inputH),
              let out = WardrobeML.shared.segment(input),
              let pixels = GarmentCutout.rgbaPixels(crop.image) else { return nil }
        return segmentation(out, crop: crop, pixels: pixels)
    }

    private static func segmentation(_ out: GarmentMap, crop: Crop, pixels: [UInt8]) -> Segmentation {
        // The grey padding past the photo's edge is never garment (it was
        // segmented as a grey bar on a white shirt, a block under white jeans).
        var map = out
        let w = WardrobeML.gridW, h = WardrobeML.gridH, f = crop.photoInGrid
        let x0 = max(0, Int(f.minX.rounded(.up))), y0 = max(0, Int(f.minY.rounded(.up)))
        let x1 = min(w, Int(f.maxX.rounded(.down))), y1 = min(h, Int(f.maxY.rounded(.down)))
        if x0 > 0 || y0 > 0 || x1 < w || y1 < h {
            for y in 0..<h {
                for x in 0..<w where x < x0 || x >= x1 || y < y0 || y >= y1 { map.classes[y * w + x] = 0 }
            }
        }
        let tf = Date()
        let instances = GarmentSegmenter.segment(map)
        WardrobeML.shared.record("fuse", Date().timeIntervalSince(tf))
        return Segmentation(instances: instances, pixels: pixels, labels: map.classes, map: map)
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

    /// The person's crop. When the person already fills the photo, the crop IS the
    /// whole-photo pass, and its segmentation is returned too (one model run, not two).
    private static func personCrop(_ photo: CGImage) -> (Crop, Segmentation?)? {
        let W = CGFloat(photo.width), H = CGFloat(photo.height)
        // The whole photo, grown to the grid's aspect and centred (grey padding).
        guard let whole = makeCrop(photo, rect: CGRect(x: 0, y: 0, width: W, height: H)),
              let input = resized(whole.image, w: WardrobeML.inputW, h: WardrobeML.inputH),
              let out = WardrobeML.shared.segment(input) else { return nil }

        // Largest connected person blob (garments + body), inside the photo.
        let w = WardrobeML.gridW, h = WardrobeML.gridH, f = whole.photoInGrid
        var person = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where out.classes[i] != 0 {
            let x = CGFloat(i % w), y = CGFloat(i / w)
            if x >= f.minX, x < f.maxX, y >= f.minY, y < f.maxY { person[i] = 1 }
        }
        let (comp, sizes) = GarmentSegmenter.components(person, w: w, h: h)
        guard let maxSize = sizes.max(), maxSize > w * h / 200, let id = sizes.firstIndex(of: maxSize).map({ $0 + 1 }) else { return nil }
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for i in 0..<(w * h) where comp[i] == id {
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
        }
        // Back to photo pixels, with a margin.
        var r = photoRect((x0, y0, x1, y1), in: whole)
        r = r.insetBy(dx: -r.width * 0.06, dy: -r.height * 0.04)
        guard let crop = makeCrop(photo, rect: r) else { return nil }
        // Nearly the whole frame anyway: keep the first pass (a slightly looser crop).
        let inter = crop.rect.intersection(whole.rect)
        let overlap = inter.isNull ? 0 : inter.width * inter.height / (whole.rect.width * whole.rect.height)
        if overlap > 0.8, crop.rect.width * crop.rect.height > 0.8 * whole.rect.width * whole.rect.height,
           let pixels = GarmentCutout.rgbaPixels(whole.image) {
            return (whole, segmentation(out, crop: whole, pixels: pixels))
        }
        return (crop, nil)
    }

    // MARK: - Close-ups for small items

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

    /// A close-up to run: a photo rectangle, the kinds to look for, and the found
    /// (too small) instances it should re-segment.
    private struct Zoom {
        var rect: CGRect
        var wanted: Set<GarmentKind>
        var replace: [Int]
        var label: String
    }

    /// Cheap checks on the full-body pass decide which close-ups run:
    /// - a found small accessory (sunglasses, watch, cap, belt) under 16% of the grid
    ///   tall is re-segmented in a tight crop for a crisp mask;
    /// - a missing item the low-res probabilities still point at (glasses / a hat in
    ///   the head, a bag, a watch, shoes at the feet) gets a close-up around the evidence.
    /// Overlapping close-ups (sunglasses and a cap) share one pass.
    private static func closeUps(_ uses: inout [Use], seg: Segmentation, crop: Crop, photo: CGImage, log: (String) -> Void) {
        let gw = CGFloat(WardrobeML.gridW), gh = CGFloat(WardrobeML.gridH)
        let w = WardrobeML.gridW
        let found = Set(seg.instances.map { $0.kind })
        let map = seg.map
        var zooms: [Zoom] = []

        // Found but small: re-segment tightly (enough context for the head / wrist).
        for (k, use) in uses.enumerated() where needsZoom(use.inst) {
            let box = photoRect(use.inst.box, in: crop)
            zooms.append(Zoom(rect: box.insetBy(dx: -box.width * 1.2, dy: -box.height * 1.6), wanted: [], replace: [k], label: "small \(use.inst.kind.rawValue)"))
        }
        // The person on the grid.
        var px0 = w, py0 = WardrobeML.gridH, px1 = 0, py1 = 0
        for (i, l) in seg.labels.enumerated() where l != 0 {
            let x = i % w, y = i / w
            px0 = min(px0, x); px1 = max(px1, x + 1); py0 = min(py0, y); py1 = max(py1, y + 1)
        }
        guard px1 > px0, py1 > py0 else { return }
        let ph = py1 - py0
        // Head: everything above the upper garments (or the top fifth of the person).
        let headBottom = min(py1, max(py0 + ph / 8, GarmentSegmenter.upperTop(seg.labels) ?? (py0 + ph / 5)) + ph / 30)
        let headZone = (px0, py0, px1, headBottom)
        var headKinds: Set<GarmentKind> = []
        if !found.contains(.eyewear), map.peak([14], in: headZone).p >= 0.15 { headKinds.insert(.eyewear) }
        if !found.contains(.headwear), map.peak([15, 16], in: headZone).p >= 0.25 { headKinds.insert(.headwear) }
        if !headKinds.isEmpty {
            var hx0 = w, hy0 = WardrobeML.gridH, hx1 = 0, hy1 = 0
            for y in headZone.1..<headZone.3 {
                for x in headZone.0..<headZone.2 where seg.labels[y * w + x] != 0 {
                    hx0 = min(hx0, x); hx1 = max(hx1, x + 1); hy0 = min(hy0, y); hy1 = max(hy1, y + 1)
                }
            }
            if hx1 > hx0, hy1 > hy0 {
                let r = photoRect((hx0, hy0, hx1, hy1), in: crop)
                let side = max(r.width, r.height) * 2.2
                zooms.append(Zoom(rect: CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side),
                                  wanted: headKinds, replace: [], label: "head"))
            }
        }
        // Bag / watch anywhere on the person; shoes in the bottom quarter.
        let personBox = (px0, py0, px1, py1)
        let feetZone = (px0, py0 + ph * 3 / 4, px1, py1)
        let evidence: [(GarmentKind, [Int], Float, (Int, Int, Int, Int), CGFloat, String)] = [
            (.bag, [25], 0.35, personBox, 2.5, "bag"),
            (.jewelry, [19], 0.15, personBox, 4, "wrist"),
            (.footwear, [23, 24], 0.25, feetZone, 1.6, "feet")
        ]
        for (kind, classes, t, zone, grow, label) in evidence where !found.contains(kind) {
            let pk = map.peak(classes, in: zone)
            guard pk.p >= t, let b = map.blob(classes, threshold: t * 0.5, within: zone) else { continue }
            var r = photoRect(b.box, in: crop)
            let minSide = crop.rect.height * (kind == .footwear ? 0.18 : 0.12)
            let side = max(max(r.width, r.height) * grow, minSide)
            r = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
            zooms.append(Zoom(rect: r, wanted: [kind], replace: [], label: "\(label) p=\(String(format: "%.2f", pk.p))"))
        }

        // Merge close-ups that mostly overlap.
        var merged: [Zoom] = []
        for z in zooms.sorted(by: { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }) {
            if let j = merged.firstIndex(where: { m in
                let i = m.rect.intersection(z.rect)
                return !i.isNull && i.width * i.height >= 0.5 * min(z.rect.width * z.rect.height, m.rect.width * m.rect.height)
                    && m.rect.union(z.rect).width * m.rect.union(z.rect).height <= 1.8 * max(m.rect.width * m.rect.height, z.rect.width * z.rect.height)
            }) {
                merged[j].rect = merged[j].rect.union(z.rect)
                merged[j].wanted.formUnion(z.wanted)
                merged[j].replace += z.replace
                merged[j].label += " + " + z.label
            } else {
                merged.append(z)
            }
        }

        // Everything the full-body pass already assigned to a garment, on its grid (built on first use).
        var claimedMap: [UInt8]?
        /// Share of a close-up instance lying on pixels the full-body pass gave to another
        /// garment (a coat's leather cuff re-read as a "handbag" in a wrist close-up).
        func claimedShare(_ inst: GarmentInstance, in z: Crop) -> Float {
            if claimedMap == nil {
                var m = [UInt8](repeating: 0, count: WardrobeML.gridCount)
                for other in seg.instances { for i in 0..<m.count where other.mask[i] != 0 { m[i] = 1 } }
                claimedMap = m
            }
            let claimed = claimedMap ?? []
            var hit = 0, total = 0
            for i in stride(from: 0, to: inst.mask.count, by: 3) where inst.mask[i] != 0 {
                total += 1
                let px = z.rect.minX + CGFloat(i % w) / gw * z.rect.width
                let py = z.rect.minY + CGFloat(i / w) / gh * z.rect.height
                let mx = Int((px - crop.rect.minX) / crop.rect.width * gw), my = Int((py - crop.rect.minY) / crop.rect.height * gh)
                if mx >= 0, my >= 0, mx < w, my < WardrobeML.gridH, claimed[my * w + mx] != 0 { hit += 1 }
            }
            return total == 0 ? 0 : Float(hit) / Float(total)
        }

        var foundNow = found
        for zoom in merged {
            guard zoom.rect.width > 4, zoom.rect.height > 4,
                  let z = makeCrop(photo, rect: zoom.rect, minHeight: gh), let s = segment(z) else { continue }
            log("close-up [\(zoom.label)]: \(s.instances.map { $0.kind.rawValue }.joined(separator: ","))")
            // Re-segmented small items: the same kind nearest to where the original is.
            for k in zoom.replace {
                let r = photoRect(uses[k].inst.box, in: crop)
                let cx = (r.midX - z.rect.minX) / z.rect.width * gw, cy = (r.midY - z.rect.minY) / z.rect.height * gh
                func distance(_ i: GarmentInstance) -> CGFloat {
                    hypot(CGFloat(i.box.0 + i.box.2) / 2 - cx, CGFloat(i.box.1 + i.box.3) / 2 - cy)
                }
                if let m = s.instances.filter({ $0.kind == uses[k].inst.kind }).min(by: { distance($0) < distance($1) }) {
                    uses[k] = Use(inst: m, crop: z, pixels: s.pixels, zoomed: true)
                }
            }
            for kind in zoom.wanted.subtracting(foundNow) {
                guard let best = s.instances.filter({ $0.kind == kind }).max(by: { $0.pixelCount < $1.pixelCount }) else { continue }
                // Bags and watches only: shoes the full-body pass merged into black
                // trousers are exactly what the feet close-up is for.
                let share = [.bag, .jewelry].contains(kind) ? claimedShare(best, in: z) : 0
                guard share < 0.5 else {
                    log("close-up: \(kind.rawValue) is \(Int(share * 100))% another garment, skipped")
                    continue
                }
                uses.append(Use(inst: best, crop: z, pixels: s.pixels, zoomed: true))
                foundNow.insert(kind)
                log("close-up found \(kind.rawValue)")
            }
            // A head close-up without headwear: is the "hair" a turban or headscarf?
            if zoom.wanted.contains(.headwear), !foundNow.contains(.headwear),
               let hair = GarmentSegmenter.headInstance(labels: s.labels),
               let cut = GarmentCutout.render(crop: z.image, cropPixels: s.pixels, instance: hair, photoInGrid: z.photoInGrid),
               let cg = cut.image.cgImage, let input = FashionClassifier.onWhite(cg, side: 224),
               let emb = WardrobeML.shared.embed(input), let vocab = WardrobeML.shared.vocabulary,
               let best = vocab.best(in: "hair_check", for: emb), best.label != "Hair", best.margin > 0.02 {
                uses.append(Use(inst: hair, crop: z, pixels: s.pixels, zoomed: true))
                foundNow.insert(.headwear)
                log("head close-up: the hair is \(best.label) (+\(String(format: "%.3f", best.margin)))")
            }
        }
        log("close-ups: \(merged.count) run (\(zooms.count) wanted)")
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
