import Accelerate
import CoreGraphics
import Foundation

/// Small pixel-buffer helpers for the try-on pipeline. Everything is top-left origin (row 0 = top),
/// straight (non-premultiplied) RGBA8 unless a name says otherwise.
struct TryOnRaster {
    let width: Int
    let height: Int
    /// RGBA8, straight alpha, row-major, top row first.
    var px: [UInt8]

    init(width: Int, height: Int, px: [UInt8]) {
        self.width = width; self.height = height; self.px = px
    }

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = width; self.height = height
        var p = [UInt8](repeating: 0, count: width * height * 4)
        if fill != (0, 0, 0, 0) {
            for i in 0..<(width * height) {
                p[i * 4] = fill.0; p[i * 4 + 1] = fill.1; p[i * 4 + 2] = fill.2; p[i * 4 + 3] = fill.3
            }
        }
        px = p
    }

    /// Draws `image` into a `width`x`height` raster (scaled to fill it exactly) and un-premultiplies.
    init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let w = width ?? image.width, h = height ?? image.height
        guard w > 0, h > 0 else { return nil }
        var p = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = p.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        Self.unpremultiply(&p)
        self.init(width: w, height: h, px: p)
    }

    static func unpremultiply(_ p: inout [UInt8]) {
        let n = p.count / 4
        for i in 0..<n {
            let a = Int(p[i * 4 + 3])
            if a == 0 || a == 255 { continue }
            p[i * 4] = UInt8(min(255, Int(p[i * 4]) * 255 / a))
            p[i * 4 + 1] = UInt8(min(255, Int(p[i * 4 + 1]) * 255 / a))
            p[i * 4 + 2] = UInt8(min(255, Int(p[i * 4 + 2]) * 255 / a))
        }
    }

    /// Premultiplied copy of the pixels (what CoreGraphics expects).
    func premultiplied() -> [UInt8] {
        var p = px
        let n = width * height
        for i in 0..<n {
            let a = Int(p[i * 4 + 3])
            if a == 255 { continue }
            p[i * 4] = UInt8(Int(p[i * 4]) * a / 255)
            p[i * 4 + 1] = UInt8(Int(p[i * 4 + 1]) * a / 255)
            p[i * 4 + 2] = UInt8(Int(p[i * 4 + 2]) * a / 255)
        }
        return p
    }

    func cgImage() -> CGImage? {
        var p = premultiplied()
        let w = width, h = height
        return p.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    /// An opaque copy (alpha forced to 255).
    func opaqueCGImage() -> CGImage? {
        var c = self
        for i in 0..<(width * height) { c.px[i * 4 + 3] = 255 }
        return c.cgImage()
    }

    func crop(_ r: CGRect) -> TryOnRaster {
        let x0 = max(0, Int(r.minX)), y0 = max(0, Int(r.minY))
        let x1 = min(width, Int(r.maxX.rounded(.up))), y1 = min(height, Int(r.maxY.rounded(.up)))
        let w = max(1, x1 - x0), h = max(1, y1 - y0)
        var out = TryOnRaster(width: w, height: h)
        for y in 0..<h where y0 + y < height {
            let src = ((y0 + y) * width + x0) * 4, dst = y * w * 4
            let n = min(w, width - x0) * 4
            if n > 0 { out.px.replaceSubrange(dst..<(dst + n), with: px[src..<(src + n)]) }
        }
        return out
    }

    /// Luminance (Rec. 601) as floats 0...255.
    func luminance() -> [Float] {
        var y = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            y[i] = 0.299 * Float(px[i * 4]) + 0.587 * Float(px[i * 4 + 1]) + 0.114 * Float(px[i * 4 + 2])
        }
        return y
    }
}

/// A float plane (masks, strength maps, shading).
struct TryOnPlane {
    let width: Int
    let height: Int
    var v: [Float]

    init(width: Int, height: Int, value: Float = 0) {
        self.width = width; self.height = height
        v = [Float](repeating: value, count: width * height)
    }

    init(width: Int, height: Int, v: [Float]) {
        self.width = width; self.height = height; self.v = v
    }

    subscript(x: Int, y: Int) -> Float {
        get { v[y * width + x] }
        set { v[y * width + x] = newValue }
    }

    /// Approximate Gaussian blur (three box passes, vImage).
    func blurred(sigma: Float) -> TryOnPlane {
        guard sigma >= 0.5, width > 2, height > 2 else { return self }
        // Box width for 3 passes approximating a Gaussian (Wells 1986).
        var k = Int((sqrt(12 * sigma * sigma / 3 + 1)).rounded())
        if k % 2 == 0 { k += 1 }
        k = max(3, min(k, (min(width, height) / 2) * 2 - 1))
        var src = v, dst = [Float](repeating: 0, count: v.count)
        let w = width, h = height
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var bs = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var bd = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                let kernel = [Float](repeating: 1 / Float(k), count: k)
                for _ in 0..<3 {
                    // Separable: rows then columns.
                    _ = kernel.withUnsafeBufferPointer { kp in
                        vImageConvolve_PlanarF(&bs, &bd, nil, 0, 0, kp.baseAddress!, 1, UInt32(k), 0, vImage_Flags(kvImageEdgeExtend))
                    }
                    _ = kernel.withUnsafeBufferPointer { kp in
                        vImageConvolve_PlanarF(&bd, &bs, nil, 0, 0, kp.baseAddress!, UInt32(k), 1, 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
            }
        }
        return TryOnPlane(width: w, height: h, v: src)
    }

    /// Bilinear resample to a new size.
    func resized(width nw: Int, height nh: Int) -> TryOnPlane {
        var out = TryOnPlane(width: nw, height: nh)
        let sx = Float(width) / Float(nw), sy = Float(height) / Float(nh)
        for y in 0..<nh {
            let fy = (Float(y) + 0.5) * sy - 0.5
            let y0 = max(0, min(height - 1, Int(fy.rounded(.down)))), y1 = min(height - 1, y0 + 1)
            let ty = max(0, min(1, fy - Float(y0)))
            for x in 0..<nw {
                let fx = (Float(x) + 0.5) * sx - 0.5
                let x0 = max(0, min(width - 1, Int(fx.rounded(.down)))), x1 = min(width - 1, x0 + 1)
                let tx = max(0, min(1, fx - Float(x0)))
                let a = v[y0 * width + x0] * (1 - tx) + v[y0 * width + x1] * tx
                let b = v[y1 * width + x0] * (1 - tx) + v[y1 * width + x1] * tx
                out.v[y * nw + x] = a * (1 - ty) + b * ty
            }
        }
        return out
    }

    /// Area-average downsample by an integer-free factor (box filter).
    func averaged(width nw: Int, height nh: Int) -> TryOnPlane {
        var out = TryOnPlane(width: nw, height: nh)
        var cnt = [Float](repeating: 0, count: nw * nh)
        for y in 0..<height {
            let oy = min(nh - 1, y * nh / height)
            for x in 0..<width {
                let ox = min(nw - 1, x * nw / width)
                out.v[oy * nw + ox] += v[y * width + x]
                cnt[oy * nw + ox] += 1
            }
        }
        for i in 0..<(nw * nh) where cnt[i] > 0 { out.v[i] /= cnt[i] }
        return out
    }

    /// Binary dilation (r > 0) or erosion (r < 0) of a 0/1 mask with a square of radius |r|, via box sums.
    func morph(_ r: Int) -> TryOnPlane {
        guard r != 0 else { return self }
        let rad = abs(r)
        let bin = v.map { $0 > 0.5 ? Float(1) : 0 }
        let k = Float(2 * rad + 1)
        let box = TryOnPlane(width: width, height: height, v: bin).boxSum(rad)
        var out = TryOnPlane(width: width, height: height)
        for i in 0..<v.count {
            out.v[i] = r > 0 ? (box.v[i] > 0.5 ? 1 : 0) : (box.v[i] >= k * k - 0.5 ? 1 : 0)
        }
        return out
    }

    /// Sum over a (2r+1)^2 window (edges clamp).
    private func boxSum(_ r: Int) -> TryOnPlane {
        let w = width, h = height
        var rows = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            var acc: Float = 0
            let base = y * w
            for x in -r...r { acc += v[base + min(w - 1, max(0, x))] }
            for x in 0..<w {
                rows[base + x] = acc
                acc += v[base + min(w - 1, x + r + 1)] - v[base + max(0, x - r)]
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for x in 0..<w {
            var acc: Float = 0
            for y in -r...r { acc += rows[min(h - 1, max(0, y)) * w + x] }
            for y in 0..<h {
                out[y * w + x] = acc
                acc += rows[min(h - 1, y + r + 1) * w + x] - rows[max(0, y - r) * w + x]
            }
        }
        return TryOnPlane(width: w, height: h, v: out)
    }
}

enum TryOnDraw {
    /// A premultiplied RGBA8 context, y-down (row 0 at the top, like the rasters).
    static func context(width: Int, height: Int) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Draws `image` (pixel coords, y-down) through `transform` (image px -> context px).
    static func draw(_ image: CGImage, in ctx: CGContext, transform: CGAffineTransform) {
        ctx.saveGState()
        ctx.concatenate(transform)
        // The context is y-down; CG draws images y-up, so flip about the image.
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
    }

    /// The context's pixels as a straight-alpha raster.
    static func raster(_ ctx: CGContext) -> TryOnRaster? {
        guard let data = ctx.data else { return nil }
        let w = ctx.width, h = ctx.height
        let p = data.assumingMemoryBound(to: UInt8.self)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let stride = ctx.bytesPerRow
        for y in 0..<h {
            for x in 0..<(w * 4) { px[y * w * 4 + x] = p[y * stride + x] }
        }
        TryOnRaster.unpremultiply(&px)
        return TryOnRaster(width: w, height: h, px: px)
    }
}
