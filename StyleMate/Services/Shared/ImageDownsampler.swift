import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Memory-safe image sizing. A 24–48 MP photo decodes to 96–190 MB; the extraction
/// pipeline never needs more than ~2048 px on the long side.
enum ImageDownsampler {
    /// Long-side cap for photos entering garment extraction (picker, camera).
    static let extractionMaxPixels: CGFloat = 2048

    /// Decodes encoded image data straight to at most `maxPixels` on the long side with
    /// ImageIO — the full-size bitmap is never materialized. EXIF orientation is baked
    /// in, so the result is `.up`. Returns nil for data ImageIO can't read.
    static func downsample(data: Data, maxPixels: CGFloat = extractionMaxPixels) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        return downsample(source: source, maxPixels: maxPixels)
    }

    /// As `downsample(data:)`, reading from a file.
    static func downsample(fileURL: URL, maxPixels: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, srcOptions) else { return nil }
        return downsample(source: source, maxPixels: maxPixels)
    }

    private static func downsample(source: CGImageSource, maxPixels: CGFloat) -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels))
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Pixel size of an image file without decoding it (nil if unreadable).
    static func pixelSize(ofFile url: URL) -> CGSize? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Pixel size of an in-memory image (accounts for `scale`).
    static func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage { return CGSize(width: cg.width, height: cg.height) }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// Redraws an already-decoded image at most `maxPixels` on the long side, at scale 1,
    /// orientation baked in. Returns the image itself when it is already small enough and
    /// upright. Use `downsample(data:)` instead whenever the encoded data is available.
    static func downsample(image: UIImage, maxPixels: CGFloat = extractionMaxPixels) -> UIImage {
        let px = pixelSize(of: image)
        let longSide = max(px.width, px.height)
        guard longSide > 0 else { return image }
        if longSide <= maxPixels, image.imageOrientation == .up, image.scale == 1 { return image }
        let factor = min(1, maxPixels / longSide)
        // Size in points at scale 1 == pixels. `image.size` is already orientation-corrected.
        let target = CGSize(width: max(1, (image.size.width * image.scale * factor).rounded()),
                            height: max(1, (image.size.height * image.scale * factor).rounded()))
        return render(size: target, opaque: !hasAlpha(image)) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// `UIGraphicsImageRenderer` at scale 1 — `size` is in pixels. The default renderer
    /// format uses the screen scale (3x), i.e. 9x the pixels asked for.
    static func render(size: CGSize, opaque: Bool = false,
                       _ actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: actions)
    }

    static func hasAlpha(_ image: UIImage) -> Bool {
        guard let a = image.cgImage?.alphaInfo else { return false }
        return ![.none, .noneSkipFirst, .noneSkipLast].contains(a)
    }
}
