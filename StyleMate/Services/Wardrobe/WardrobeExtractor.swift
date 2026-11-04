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
        /// Cut off by the photo's frame (the studio render then generates the
        /// whole garment instead of refining a partial one).
        var truncated: Bool = false
    }

    /// Items we never auto-add from a photo of a person (privacy + they're not
    /// reliably visible): underwear-class garments.
    private static let blockedProducts: Set<String> = ["Underwear", "Boxers", "Briefs", "Bras", "Bralettes", "Thongs", "Lingerie", "Shapewear"]

    static var isAvailable: Bool { WardrobeML.shared.isAvailable }

    static func extract(from image: UIImage) -> [Item] {
        guard isAvailable, let source = flatten(image) else { return [] }
        let t0 = Date()

        // 1. Person crop.
        guard let crop = personCrop(source) else {
            print("[Wardrobe] no person found")
            return []
        }

        // 2. Parse + label + fuse.
        guard let seg = segment(crop.image) else { return [] }

        // 3 + 4.
        var items: [Item] = []
        for inst in seg.instances {
            var use = (inst: inst, crop: crop, pixels: seg.pixels)
            // Small accessories cover only a few grid cells in a full-body crop;
            // re-parse a tight crop around them for a crisp, accurate mask.
            if needsZoom(inst), let z = zoomed(inst, in: crop, photo: source) { use = z }
            guard let cut = autoreleasepool(invoking: { GarmentCutout.render(crop: use.crop.image, cropPixels: use.pixels, instance: use.inst) }),
                  let attrs = FashionClassifier.classify(cut.image, kind: use.inst.kind),
                  !blockedProducts.contains(attrs.product) else { continue }
            // Too few source-photo pixels to make a decent wardrobe image
            // (sunglasses 40 px wide in a group shot): skip — a closer photo will catch it.
            let photoSide = cut.sourceSide / Float(use.crop.scale)
            let minSide: Float = inst.kind.isSmall || inst.kind == .headwear ? 56 : 110
            guard photoSide >= minSide else {
                print("[Wardrobe] drop tiny \(attrs.product) (\(Int(photoSide)) px)")
                continue
            }
            let q = quality(use.inst, cut: cut, crop: use.crop, photoSide: photoSide)
            guard q >= 0.22 else {
                print("[Wardrobe] drop low-quality \(attrs.product) q=\(String(format: "%.2f", q))")
                continue
            }
            items.append(Item(kind: inst.kind, attributes: attrs, cutout: cut.image, quality: q,
                              truncated: isTruncated(use.inst, crop: use.crop)))
        }
        items = dedupeWithinPhoto(items)
        print("[Wardrobe] extracted \(items.count) items in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s: " +
              items.map { "\($0.attributes.product)(\(String(format: "%.2f", $0.quality)))" }.joined(separator: ", "))
        return items
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
    }

    private static func segment(_ image: CGImage) -> Segmentation? {
        guard let parserIn = resized(image, w: WardrobeML.gridW, h: WardrobeML.gridH),
              let labelerIn = resized(image, w: 512, h: 512),
              let parsed = WardrobeML.shared.parse(parserIn),
              let logits = WardrobeML.shared.label(labelerIn),
              let pixels = GarmentCutout.rgbaPixels(image) else { return nil }
        return Segmentation(instances: GarmentSegmenter.segment(parser: parsed.labels, labelerLogits: logits), pixels: pixels)
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

    // MARK: - Zoom pass for small accessories

    private static func needsZoom(_ inst: GarmentInstance) -> Bool {
        guard [GarmentKind.eyewear, .jewelry, .headwear, .belt].contains(inst.kind) else { return false }
        let (_, y0, _, y1) = inst.box
        return Double(y1 - y0) < Double(WardrobeML.gridH) * 0.16
    }

    /// Re-segments a tight crop around a small item; returns the matching
    /// instance in that crop (or nil to keep the original).
    private static func zoomed(_ inst: GarmentInstance, in crop: Crop, photo: CGImage)
        -> (inst: GarmentInstance, crop: Crop, pixels: [UInt8])? {
        let gw = CGFloat(WardrobeML.gridW), gh = CGFloat(WardrobeML.gridH)
        let (bx0, by0, bx1, by1) = inst.box
        func toPhoto(_ gx: Int, _ gy: Int) -> CGPoint {
            CGPoint(x: crop.rect.minX + CGFloat(gx) / gw * crop.rect.width,
                    y: crop.rect.minY + CGFloat(gy) / gh * crop.rect.height)
        }
        let p0 = toPhoto(bx0, by0), p1 = toPhoto(bx1, by1)
        let box = CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y)
        // Enough context around it for the parser to recognise a head / wrist.
        let r = box.insetBy(dx: -box.width * 1.2, dy: -box.height * 1.6)
        guard r.width > 4, r.height > 4,
              let z = makeCrop(photo, rect: r, minHeight: gh),
              let seg = segment(z.image) else { return nil }
        func distance(_ i: GarmentInstance) -> CGFloat {
            let cx = CGFloat(i.box.0 + i.box.2) / 2, cy = CGFloat(i.box.1 + i.box.3) / 2
            return hypot(cx - gw / 2, cy - gh / 2)
        }
        guard let m = seg.instances.filter({ $0.kind == inst.kind }).min(by: { distance($0) < distance($1) })
        else { return nil }
        return (m, z, seg.pixels)
    }

    // MARK: - Quality

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
        return 0.35 * size + 0.15 * (1 - occlusion * 2) + 0.30 * complete + 0.20 * cut.sharpness
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
