import UIKit

/// Trust before volume: a closet with one hair-and-sunglasses "tie" in it feels
/// broken, however many good items sit next to it. The extractor keeps anything
/// that is probably a garment; this decides which of those StyleMate is sure
/// enough about to add *by itself*. Uncertain items are never auto-added by the
/// scan (they wait in "We weren't sure about 1 item — tap to add") and start
/// deselected in the manual review screen.
///
/// Doubts, from the cutout and the extractor's 0...1 view quality:
/// - **fragmented**: the mask is several separate pieces (hair + lens + strap),
///   unless the item naturally comes in two (shoes, earrings, an open jacket);
/// - **low quality**: quality under 0.4 (small, blurry, cut off or occluded);
/// - **tiny jewelry** / **unsure accessory**: rings, earrings, necklaces… and
///   ties / belts are the classic false positives unless the view is good.
enum ItemTrust {
    enum Doubt: String, Equatable, Sendable {
        case fragmented
        case lowQuality
        case tinyJewelry
        case unsureAccessory
    }

    static let minQuality: Float = 0.4
    static let minJewelryQuality: Float = 0.6
    static let minTieBeltQuality: Float = 0.55

    static let jewelryProducts: Set<String> = [
        "Rings", "Earrings", "Necklaces", "Pendants", "Chains", "Bracelets", "Jewelry", "Anklets", "Brooches",
    ]
    static let tieBeltProducts: Set<String> = ["Ties", "Bowties", "Belts", "Suspenders", "Pocket Squares"]
    /// Items whose cutout is legitimately two separate pieces.
    static let pairProducts: Set<String> = [
        "Earrings", "Gloves", "Socks", "Sunglasses", "Eyeglasses", "Glasses",
    ]

    // MARK: Decision (pure)

    /// Why StyleMate isn't sure about this item, or nil when it can add it.
    /// `pieces`: separate opaque pieces in the cutout (`pieceCount`), nil if unknown.
    static func doubt(category: Category, product: String, quality: Float, pieces: Int?) -> Doubt? {
        // Shoes and earrings come in two; a bag's strap is often cut by a hand.
        let isPair = pairProducts.contains(product) || category == .footwear
            || product.localizedCaseInsensitiveContains("bag") || product == "Backpacks" || product == "Clutches"
        if let pieces {
            let allowed = isPair || category == .outerwear || category == .midLayers ? 2 : (category == .accessories ? 1 : 2)
            if pieces > allowed { return .fragmented }
        }
        if jewelryProducts.contains(product), quality < minJewelryQuality { return .tinyJewelry }
        if tieBeltProducts.contains(product), quality < minTieBeltQuality { return .unsureAccessory }
        if quality < minQuality { return .lowQuality }
        return nil
    }

    static func isConfident(category: Category, product: String, quality: Float, cutout: UIImage?) -> Bool {
        doubt(category: category, product: product, quality: quality, cutout: cutout) == nil
    }

    /// `doubt(…, pieces:)` measured on the cutout. Remembered per cutout image,
    /// so review screens can ask again cheaply (`cachedDoubt`).
    static func doubt(category: Category, product: String, quality: Float, cutout: UIImage?) -> Doubt? {
        let pieces = cutout.flatMap { pieceCount(of: $0) }
        let result = doubt(category: category, product: product, quality: quality, pieces: pieces)
        if let cutout { remember(result, for: cutout) }
        return result
    }

    static func doubt(_ seg: ImageAnalysisService.SegmentedItem) -> Doubt? {
        guard let cat = seg.category, let product = seg.product else { return .lowQuality }
        return doubt(category: cat, product: product, quality: seg.quality, cutout: seg.maskImage)
    }

    static func isConfident(_ seg: ImageAnalysisService.SegmentedItem) -> Bool { doubt(seg) == nil }

    // MARK: Cache (by cutout image object)

    private static let lock = NSLock()
    private static let verdicts = NSMapTable<UIImage, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality],
                                                                valueOptions: .strongMemory)

    private static func remember(_ doubt: Doubt?, for image: UIImage) {
        lock.lock(); defer { lock.unlock() }
        verdicts.setObject((doubt?.rawValue ?? "") as NSString, forKey: image)
    }

    /// The verdict computed earlier for this cutout: `.some(nil)` = confident,
    /// nil = never assessed.
    static func cachedDoubt(for image: UIImage) -> Doubt?? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = verdicts.object(forKey: image) as String? else { return nil }
        return .some(Doubt(rawValue: raw))
    }

    // MARK: Pieces

    /// Separate opaque pieces in a transparent cutout that each hold at least
    /// `minShare` of the opaque area (specks of fringe don't count).
    static func pieceCount(of image: UIImage, longSide: Int = 112, minShare: Double = 0.04) -> Int? {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let k = min(1, Double(longSide) / Double(max(cg.width, cg.height)))
        let w = max(2, Int((Double(cg.width) * k).rounded())), h = max(2, Int((Double(cg.height) * k).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        return pieceCount(alpha: alpha, width: w, height: h, minShare: minShare)
    }

    /// 8-connected components of alpha > `threshold` with at least `minShare`
    /// of all opaque pixels.
    static func pieceCount(alpha: [UInt8], width w: Int, height h: Int,
                           threshold: UInt8 = 96, minShare: Double = 0.04) -> Int {
        guard w > 0, h > 0, alpha.count >= w * h else { return 0 }
        var label = [Int32](repeating: 0, count: w * h)
        var sizes: [Int] = []
        var stack: [Int] = []
        var total = 0
        for start in 0..<(w * h) where alpha[start] > threshold && label[start] == 0 {
            let id = Int32(sizes.count + 1)
            label[start] = id
            stack.append(start)
            var size = 0
            while let p = stack.popLast() {
                size += 1
                let x = p % w, y = p / w
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let q = ny * w + nx
                        if alpha[q] > threshold && label[q] == 0 {
                            label[q] = id
                            stack.append(q)
                        }
                    }
                }
            }
            sizes.append(size)
            total += size
        }
        guard total > 0 else { return 0 }
        let minSize = Double(total) * minShare
        return sizes.filter { Double($0) >= minSize }.count
    }
}
