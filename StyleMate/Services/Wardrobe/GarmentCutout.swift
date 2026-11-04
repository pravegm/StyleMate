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
    static func render(crop: CGImage, cropPixels: [UInt8], instance: GarmentInstance) -> Result? {
        let gw = WardrobeML.gridW, gh = WardrobeML.gridH
        let cw = crop.width, ch = crop.height
        let sx = Double(cw) / Double(gw), sy = Double(ch) / Double(gh)

        // Item box in crop pixels, with a small margin for the soft edge.
        let (bx0, by0, bx1, by1) = instance.box
        let mx = 3.0, my = 3.0
        let x0 = max(0, Int((Double(bx0) - mx) * sx)), y0 = max(0, Int((Double(by0) - my) * sy))
        let x1 = min(cw, Int(ceil((Double(bx1) + mx) * sx))), y1 = min(ch, Int(ceil((Double(by1) + my) * sy)))
        let w = x1 - x0, h = y1 - y0
        guard w > 8, h > 8 else { return nil }

        guard let maskFull = upsampleMask(instance.mask, guide: crop, edgeAware: true) else { return nil }
        let holeFull: [UInt8]? = instance.holeCount > 0
            ? upsampleMask(instance.holes, guide: crop, edgeAware: false) : nil
        let rgba = cropPixels
        // Region buffers (premultiplied float RGBA) for the item box.
        var buf = [Float](repeating: 0, count: w * h * 4)
        var holeMask = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let si = (y + y0) * cw + (x + x0)
                let a = Float(maskFull[si]) / 255
                let o = (y * w + x) * 4
                buf[o] = Float(rgba[si * 4]) / 255 * a
                buf[o + 1] = Float(rgba[si * 4 + 1]) / 255 * a
                buf[o + 2] = Float(rgba[si * 4 + 2]) / 255 * a
                buf[o + 3] = a
                if let hf = holeFull { holeMask[y * w + x] = Float(hf[si]) / 255 }
            }
        }

        if holeFull != nil { pushPullFill(&buf, holes: holeMask, w: w, h: h) }

        let sharp = sharpness(buf, w: w, h: h)
        guard let img = makeImage(buf, w: w, h: h) else { return nil }
        let framed = frame(img)
        let side = Float(sqrt(Double(instance.pixelCount) * sx * sy))
        return Result(image: framed, sharpness: sharp, sourceSide: side)
    }

    // MARK: - Mask upsampling

    /// Grid mask (0/1) → 8-bit alpha at the guide's resolution.
    private static func upsampleMask(_ grid: [UInt8], guide: CGImage, edgeAware: Bool) -> [UInt8]? {
        let gw = WardrobeML.gridW, gh = WardrobeML.gridH
        var bytes = grid.map { $0 != 0 ? UInt8(255) : UInt8(0) }
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
            let s = min(max((v - 0.18) / 0.64, 0), 1)
            alpha[i] = UInt8(s * 255)
        }
        return alpha
    }

    // MARK: - Hole fill

    /// Pyramid fill: averages the visible fabric down to a coarse level, then
    /// pulls it back up into the holes. Smooth and seam-free on solid fabrics;
    /// holes are small (a hand) so patterns hold up well enough.
    private static func pushPullFill(_ buf: inout [Float], holes: [Float], w: Int, h: Int) {
        // Level 0: only real fabric contributes (alpha-weighted premultiplied colour).
        var levels: [(data: [Float], w: Int, h: Int)] = [(buf, w, h)]
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
        // Pull: composite each level over the upsampled coarser one.
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[li + 1]
            var fine = levels[li]
            for y in 0..<fine.h {
                for x in 0..<fine.w {
                    let o = (y * fine.w + x) * 4
                    let a = fine.data[o + 3]
                    if a >= 0.999 { continue }
                    let co = (min(y / 2, coarse.h - 1) * coarse.w + min(x / 2, coarse.w - 1)) * 4
                    let t = 1 - a
                    fine.data[o] += t * coarse.data[co]
                    fine.data[o + 1] += t * coarse.data[co + 1]
                    fine.data[o + 2] += t * coarse.data[co + 2]
                    fine.data[o + 3] += t * coarse.data[co + 3]
                }
            }
            levels[li] = fine
        }
        let filled = levels[0].data
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
