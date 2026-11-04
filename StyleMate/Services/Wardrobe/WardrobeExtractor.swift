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
        guard let parserIn = resized(crop.image, w: WardrobeML.gridW, h: WardrobeML.gridH),
              let labelerIn = resized(crop.image, w: 512, h: 512),
              let parsed = WardrobeML.shared.parse(parserIn),
              let logits = WardrobeML.shared.label(labelerIn) else { return [] }
        let instances = GarmentSegmenter.segment(parser: parsed.labels, labelerLogits: logits)
        guard let cropPixels = GarmentCutout.rgbaPixels(crop.image) else { return [] }

        // 3 + 4.
        var items: [Item] = []
        for inst in instances {
            guard let cut = autoreleasepool(invoking: { GarmentCutout.render(crop: crop.image, cropPixels: cropPixels, instance: inst) }),
                  let attrs = FashionClassifier.classify(cut.image, kind: inst.kind),
                  !blockedProducts.contains(attrs.product) else { continue }
            // Too few source pixels to make a decent wardrobe image (sunglasses
            // 40 px wide in a group shot): skip — a closer photo will catch it.
            let minSide: Float = inst.kind.isSmall || inst.kind == .headwear ? 56 : 110
            guard cut.sourceSide >= minSide else {
                print("[Wardrobe] drop tiny \(attrs.product) (\(Int(cut.sourceSide)) px)")
                continue
            }
            let q = quality(inst, cut: cut, crop: crop)
            guard q >= 0.22 else {
                print("[Wardrobe] drop low-quality \(attrs.product) q=\(String(format: "%.2f", q))")
                continue
            }
            items.append(Item(kind: inst.kind, attributes: attrs, cutout: cut.image, quality: q))
        }
        items = dedupeWithinPhoto(items)
        print("[Wardrobe] extracted \(items.count) items in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s: " +
              items.map { "\($0.attributes.product)(\(String(format: "%.2f", $0.quality)))" }.joined(separator: ", "))
        return items
    }

    // MARK: - Person crop

    private struct Crop {
        let image: CGImage
        /// Crop sides that sit on the photo's own edge — an item touching these
        /// is cut off by the frame, not by our crop.
        let onPhotoEdge: (top: Bool, bottom: Bool, left: Bool, right: Bool)
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
        // Back to photo pixels.
        var r = CGRect(x: (CGFloat(x0) - ox) / k, y: (CGFloat(y0) - oy) / k,
                       width: CGFloat(x1 - x0) / k, height: CGFloat(y1 - y0) / k)
        r = r.insetBy(dx: -r.width * 0.06, dy: -r.height * 0.04)
        // Grow to the grid's 2:3 aspect around the centre.
        let aspect = gw / gh
        if r.width / r.height < aspect {
            let nw = r.height * aspect; r = r.insetBy(dx: -(nw - r.width) / 2, dy: 0)
        } else {
            let nh = r.width / aspect; r = r.insetBy(dx: 0, dy: -(nh - r.height) / 2)
        }
        let onEdge = (top: r.minY <= 1, bottom: r.maxY >= H - 1, left: r.minX <= 1, right: r.maxX >= W - 1)
        // Render the crop (out-of-photo area padded neutral grey), capped at 1536 px tall.
        let scale = min(1, 1536 / r.height)
        let size = CGSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
        let dest = CGRect(x: -r.minX * scale, y: -r.minY * scale, width: W * scale, height: H * scale)
        guard let img = letterbox(photo, into: size, rect: dest) else { return nil }
        return Crop(image: img, onPhotoEdge: onEdge)
    }

    // MARK: - Quality

    private static func quality(_ inst: GarmentInstance, cut: GarmentCutout.Result, crop: Crop) -> Float {
        let size = min(1, cut.sourceSide / (inst.kind.isSmall ? 120 : 380))
        let occlusion = Float(inst.holeCount) / Float(max(1, inst.pixelCount + inst.holeCount))
        // Cut off by the photo frame? (Touching our crop's edge only matters where
        // that edge is the photo's edge.) Shoes at the bottom edge = missing feet.
        let e = inst.touchesEdge, p = crop.onPhotoEdge
        let truncated = (e.top && p.top) || (e.bottom && p.bottom) || (e.left && p.left) || (e.right && p.right)
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
