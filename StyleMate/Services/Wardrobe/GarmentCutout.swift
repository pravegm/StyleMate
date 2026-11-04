import CoreGraphics
import CoreImage
import UIKit

/// Turns a grid-space garment mask into a clean, catalog-style cutout.
///
/// 1. The 384x576 mask is upsampled to the crop's full resolution with Core
///    Image's edge-preserving upsampler, guided by the photo itself, so the
///    outline snaps to the real fabric edge instead of a blocky grid edge.
/// 2. Holes where a hand, arm, hair, bag strap or belt covered the garment are
///    filled with a pyramid ("push-pull") fill from the surrounding fabric, so a
///    pair of jeans doesn't come out with a hand-shaped hole.
/// 3. The result is trimmed, centred on a transparent square with even padding
///    and capped at 1024 px — every wardrobe item is framed the same way.
enum GarmentCutout {
    struct Result {
        let image: UIImage
        /// 0...1 — fabric detail at the item's own resolution (variance of the
        /// Laplacian); low = blurry / motion-smeared photo.
        let sharpness: Float
        /// Item size in source-photo pixels (sqrt of area) — resolution proxy.
        let sourceSide: Float
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// `cropPixels`: `rgbaPixels(crop)`, computed once per photo by the caller.
    /// `photoInGrid`: where the real photo lies on the grid (the crop may be
    /// padded grey past the photo's edge; nothing outside it is ever garment).
    /// `fill`: fill occluded holes (off for patterned fabric and big holes,
    /// where a smooth fill shows as a blotch).
    static func render(crop: CGImage, cropPixels: [UInt8], instance: GarmentInstance,
                       photoInGrid: CGRect? = nil, fill: Bool = true) -> Result? {
        let gw = WardrobeML.gridW, gh = WardrobeML.gridH
        let cw = crop.width, ch = crop.height
        let sx = Double(cw) / Double(gw), sy = Double(ch) / Double(gh)

        // Item box on the grid and in crop pixels, with a small margin for the
        // soft edge. All the per-pixel work below is limited to this box.
        let (bx0, by0, bx1, by1) = instance.box
        let gx0 = max(0, bx0 - 3), gy0 = max(0, by0 - 3), gx1 = min(gw, bx1 + 3), gy1 = min(gh, by1 + 3)
        let x0 = Int(Double(gx0) * sx), y0 = Int(Double(gy0) * sy)
        let x1 = min(cw, Int(ceil(Double(gx1) * sx))), y1 = min(ch, Int(ceil(Double(gy1) * sy)))
        let w = x1 - x0, h = y1 - y0
        guard w > 8, h > 8, gx1 - gx0 > 1, gy1 - gy0 > 1,
              let guide = crop.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else { return nil }
        let gridBox = (gx0, gy0, gx1, gy1)
        guard let maskBox = upsampleMask(instance.mask, box: gridBox, guide: guide, edgeAware: true) else { return nil }
        let holeBox: [UInt8]? = fill && instance.holeCount > 0
            ? upsampleMask(instance.holes, box: gridBox, guide: guide, edgeAware: false) : nil
        // Padding outside the photo (crop px).
        var valid = CGRect(x: 0, y: 0, width: cw, height: ch)
        if let f = photoInGrid {
            valid = CGRect(x: f.minX * sx, y: f.minY * sy, width: f.width * sx, height: f.height * sy)
        }
        let vx0 = Int(valid.minX.rounded(.up)), vy0 = Int(valid.minY.rounded(.up))
        let vx1 = Int(valid.maxX.rounded(.down)), vy1 = Int(valid.maxY.rounded(.down))
        let rgba = cropPixels
        // Region buffers (premultiplied float RGBA) for the item box.
        var buf = [Float](repeating: 0, count: w * h * 4)
        var holeMask = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let cy = y + y0
            for x in 0..<w {
                let cx = x + x0
                guard cx >= vx0, cx < vx1, cy >= vy0, cy < vy1 else { continue }
                let si = cy * cw + cx, bi = y * w + x
                let a = Float(maskBox[bi]) / 255
                let o = bi * 4
                buf[o] = Float(rgba[si * 4]) / 255 * a
                buf[o + 1] = Float(rgba[si * 4 + 1]) / 255 * a
                buf[o + 2] = Float(rgba[si * 4 + 2]) / 255 * a
                buf[o + 3] = a
                if let hb = holeBox { holeMask[bi] = Float(hb[bi]) / 255 }
            }
        }

        if holeBox != nil { pushPullFill(&buf, holes: holeMask, w: w, h: h) }
        decontaminateEdges(&buf, w: w, h: h)

        let sharp = sharpness(buf, w: w, h: h)
        guard let img = makeImage(buf, w: w, h: h) else { return nil }
        let framed = frame(img)
        let side = Float(sqrt(Double(instance.pixelCount) * sx * sy))
        return Result(image: framed, sharpness: sharp, sourceSide: side)
    }

    // MARK: - Mask upsampling

    /// The `box` (grid x0, y0, x1, y1) of a grid mask (0/1) → 8-bit alpha at the
    /// resolution of `guide`, which is the same region of the crop.
    private static func upsampleMask(_ grid: [UInt8], box: (Int, Int, Int, Int), guide: CGImage, edgeAware: Bool) -> [UInt8]? {
        let fullW = WardrobeML.gridW
        let gw = box.2 - box.0, gh = box.3 - box.1
        var bytes = [UInt8](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            let row = (y + box.1) * fullW + box.0
            for x in 0..<gw where grid[row + x] != 0 { bytes[y * gw + x] = 255 }
        }
        guard let provider = CGDataProvider(data: Data(bytes: &bytes, count: bytes.count) as CFData),
              let small = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        let guideCI = CIImage(cgImage: guide)
        let smallCI = CIImage(cgImage: small)
            .applyingGaussianBlur(sigma: 0.6)
            .cropped(to: CGRect(x: 0, y: 0, width: gw, height: gh))
        var out: CIImage
        if edgeAware, let f = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            f.setValue(guideCI, forKey: kCIInputImageKey)
            f.setValue(smallCI, forKey: "inputSmallImage")
            f.setValue(3.0, forKey: "inputSpatialSigma")
            f.setValue(0.15, forKey: "inputLumaSigma")
            out = f.outputImage ?? smallCI
        } else {
            out = smallCI
        }
        if out.extent.width != guideCI.extent.width || out.extent.height != guideCI.extent.height {
            out = smallCI.transformed(by: CGAffineTransform(scaleX: guideCI.extent.width / CGFloat(gw),
                                                             y: guideCI.extent.height / CGFloat(gh)))
        }
        out = out.cropped(to: guideCI.extent)

        let w = guide.width, h = guide.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(out, toBitmap: &px, rowBytes: w * 4,
                         bounds: guideCI.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            // Sharpen the soft upsampled edge a touch so fabric edges stay crisp.
            let v = Float(px[i * 4]) / 255
            let s = min(max((v - 0.30) / 0.50, 0), 1)
            alpha[i] = UInt8(s * 255)
        }
        return alpha
    }

    // MARK: - Hole fill

    /// Push-pull core: every pixel gets the (premultiplied) colour of the nearest
    /// known pixels, smoothly. `src` alpha = how much each pixel is known.
    private static func pyramidFill(_ src: [Float], w: Int, h: Int) -> [Float] {
        // Level 0: only real fabric contributes (alpha-weighted premultiplied colour).
        var levels: [(data: [Float], w: Int, h: Int)] = [(src, w, h)]
        while let last = levels.last, last.w > 1 || last.h > 1 {
            let nw = max(1, (last.w + 1) / 2), nh = max(1, (last.h + 1) / 2)
            var d = [Float](repeating: 0, count: nw * nh * 4)
            for y in 0..<nh {
                for x in 0..<nw {
                    var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let xx = min(x * 2 + dx, last.w - 1), yy = min(y * 2 + dy, last.h - 1)
                            let o = (yy * last.w + xx) * 4
                            acc.0 += last.data[o]; acc.1 += last.data[o + 1]; acc.2 += last.data[o + 2]; acc.3 += last.data[o + 3]
                        }
                    }
                    let o = (y * nw + x) * 4
                    // Renormalize so alpha means "coverage", capped at 1.
                    let a = min(acc.3, 1), k: Float = acc.3 > 0 ? a / acc.3 : 0
                    d[o] = acc.0 * k; d[o + 1] = acc.1 * k; d[o + 2] = acc.2 * k; d[o + 3] = a
                }
            }
            levels.append((d, nw, nh))
            if levels.count > 14 { break }
        }
        // Pull: composite each level over the coarser one, sampled BILINEARLY —
        // nearest-neighbour here showed up as visible blocks in large fills.
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[li + 1]
            var fine = levels[li]
            for y in 0..<fine.h {
                let cy = max(0, min(Float(coarse.h - 1), (Float(y) + 0.5) / 2 - 0.5))
                let y0 = Int(cy), y1 = min(y0 + 1, coarse.h - 1), fy = cy - Float(y0)
                for x in 0..<fine.w {
                    let o = (y * fine.w + x) * 4
                    let a = fine.data[o + 3]
                    if a >= 0.999 { continue }
                    let cx = max(0, min(Float(coarse.w - 1), (Float(x) + 0.5) / 2 - 0.5))
                    let x0 = Int(cx), x1 = min(x0 + 1, coarse.w - 1), fx = cx - Float(x0)
                    let t = 1 - a
                    for c in 0..<4 {
                        let v00 = coarse.data[(y0 * coarse.w + x0) * 4 + c], v10 = coarse.data[(y0 * coarse.w + x1) * 4 + c]
                        let v01 = coarse.data[(y1 * coarse.w + x0) * 4 + c], v11 = coarse.data[(y1 * coarse.w + x1) * 4 + c]
                        let v = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + v01 * (1 - fx) * fy + v11 * fx * fy
                        fine.data[o + c] += t * v
                    }
                }
            }
            levels[li] = fine
        }
        return levels[0].data
    }

    /// Colour decontamination: a soft edge pixel is part fabric, part whatever
    /// was behind it (pavement, sky), which shows as a light/dark halo on the
    /// studio backdrop. Re-colour every semi-transparent pixel with the nearby
    /// solid fabric colour, keeping its alpha.
    private static func decontaminateEdges(_ buf: inout [Float], w: Int, h: Int) {
        var known = buf
        for i in 0..<(w * h) where known[i * 4 + 3] < 0.95 {
            known[i * 4] = 0; known[i * 4 + 1] = 0; known[i * 4 + 2] = 0; known[i * 4 + 3] = 0
        }
        let filled = pyramidFill(known, w: w, h: h)
        for i in 0..<(w * h) {
            let o = i * 4
            let a = buf[o + 3]
            guard a > 0.004, a < 0.95 else { continue }
            let fa = max(filled[o + 3], 1e-4)
            buf[o] = filled[o] / fa * a; buf[o + 1] = filled[o + 1] / fa * a; buf[o + 2] = filled[o + 2] / fa * a
        }
    }

    /// Pyramid fill: averages the visible fabric down to a coarse level, then
    /// pulls it back up into the holes. Smooth and seam-free on solid fabrics;
    /// holes are small (a hand) so patterns hold up well enough.
    private static func pushPullFill(_ buf: inout [Float], holes: [Float], w: Int, h: Int) {
        let filled = pyramidFill(buf, w: w, h: h)
        for i in 0..<(w * h) {
            let hm = holes[i]
            guard hm > 0.02 else { continue }
            let o = i * 4
            let fa = max(filled[o + 3], 1e-4)
            // Colour of the fill, un-premultiplied, then laid in at the hole's coverage.
            let r = filled[o] / fa, g = filled[o + 1] / fa, b = filled[o + 2] / fa
            let a0 = buf[o + 3]
            let a = max(a0, hm)
            let wNew = a - a0
            buf[o] += r * wNew; buf[o + 1] += g * wNew; buf[o + 2] += b * wNew; buf[o + 3] = a
        }
    }

    // MARK: - Quality

    private static func sharpness(_ buf: [Float], w: Int, h: Int) -> Float {
        // Laplacian variance of luminance over solidly-covered pixels, at <= 512 px.
        let step = max(1, max(w, h) / 512)
        var sum: Double = 0, sum2: Double = 0, n: Double = 0
        func lum(_ x: Int, _ y: Int) -> Float? {
            let o = (y * w + x) * 4
            let a = buf[o + 3]; guard a > 0.9 else { return nil }
            return (0.299 * buf[o] + 0.587 * buf[o + 1] + 0.114 * buf[o + 2]) / a
        }
        var y = step
        while y < h - step {
            var x = step
            while x < w - step {
                if let c = lum(x, y), let l = lum(x - step, y), let r = lum(x + step, y),
                   let u = lum(x, y - step), let d = lum(x, y + step) {
                    let v = Double(l + r + u + d - 4 * c)
                    sum += v; sum2 += v * v; n += 1
                }
                x += step
            }
            y += step
        }
        guard n > 50 else { return 0 }
        let variance = sum2 / n - (sum / n) * (sum / n)
        // ~0.002 is soft, ~0.02+ is crisp fabric texture (luminance in 0...1).
        return Float(min(1, max(0, (variance - 0.0008) / 0.012)))
    }

    // MARK: - Image helpers

    static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// Premultiplied float RGBA → CGImage.
    private static func makeImage(_ buf: [Float], w: Int, h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h * 4) { px[i] = UInt8(min(max(buf[i] * 255, 0), 255)) }
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// Trims transparent margins, centres on a square with 7% padding, caps at 1024 px.
    static func frame(_ image: CGImage) -> UIImage {
        let w = image.width, h = image.height
        guard let px = rgbaPixels(image) else { return UIImage(cgImage: image) }
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 20 {
                x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
            }
        }
        guard x1 > x0, y1 > y0, let trimmed = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { return UIImage(cgImage: image) }
        let tw = CGFloat(trimmed.width), th = CGFloat(trimmed.height)
        let side = max(tw, th) / 0.86
        let scale = min(1, 1024 / side)
        let canvas = CGSize(width: (side * scale).rounded(), height: (side * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in
            let dw = tw * scale, dh = th * scale
            UIImage(cgImage: trimmed).draw(in: CGRect(x: (canvas.width - dw) / 2, y: (canvas.height - dh) / 2, width: dw, height: dh))
        }
    }
}
