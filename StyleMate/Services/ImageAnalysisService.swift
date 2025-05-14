import Foundation
import UIKit
import Vision

class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}
    
    func analyze(image: UIImage) async -> (category: Category?, product: String?, color: String?) {
        async let color = detectDominantColor(image: image)
        async let (category, product) = classifyImage(image: image)
        return (await category, await product, await color)
    }
    
    private func detectDominantColor(image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        // 1. Get saliency mask for the main object
        let mask: CGImage? = await withCheckedContinuation { continuation in
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNGenerateObjectnessBasedSaliencyImageRequest()
            try? handler.perform([request])
            if let result = request.results?.first as? VNSaliencyImageObservation {
                let pixelBuffer = result.pixelBuffer
                // Convert pixelBuffer to CGImage
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let context = CIContext()
                let maskImage = context.createCGImage(ciImage, from: ciImage.extent)
                continuation.resume(returning: maskImage)
            } else {
                continuation.resume(returning: nil)
            }
        }
        // 2. Downscale image for performance
        let width = 40, height = 40
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // 3. If mask exists, use it to only count foreground pixels
        var colorCounts: [UInt32: Int] = [:]
        var totalForeground = 0
        var maskData: CFData? = nil
        var maskPtr: UnsafePointer<UInt8>? = nil
        if let mask = mask {
            let maskContext = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            maskContext?.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            maskData = maskContext?.makeImage()?.dataProvider?.data
            if let maskData = maskData {
                maskPtr = CFDataGetBytePtr(maskData)
            }
        }
        for x in 0..<width {
            for y in 0..<height {
                let offset = 4 * (y * width + x)
                let r = ptr[offset]
                let g = ptr[offset+1]
                let b = ptr[offset+2]
                let rgb = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                // If mask exists, only count if mask pixel is "on"
                if let maskPtr = maskPtr {
                    let maskVal = maskPtr[y * width + x]
                    if maskVal < 128 { continue } // skip background
                }
                colorCounts[rgb, default: 0] += 1
                totalForeground += 1
            }
        }
        if let (rgb, _) = colorCounts.max(by: { $0.value < $1.value }), totalForeground > 0 {
            let r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF
            return Self.closestColorName(r: Int(r), g: Int(g), b: Int(b))
        }
        return nil
    }
    
    private static func closestColorName(r: Int, g: Int, b: Int) -> String {
        // Simple mapping for demo; can be expanded
        let colors: [(name: String, rgb: (Int, Int, Int))] = [
            ("black", (0,0,0)), ("white", (255,255,255)), ("gray", (128,128,128)),
            ("red", (220,20,60)), ("green", (34,139,34)), ("blue", (30,144,255)),
            ("yellow", (255,215,0)), ("orange", (255,140,0)), ("purple", (128,0,128)),
            ("brown", (139,69,19)), ("beige", (245,245,220)), ("navy", (0,0,128))
        ]
        func dist(_ c: (Int,Int,Int)) -> Int {
            let dr = r - c.0, dg = g - c.1, db = b - c.2
            return dr*dr + dg*dg + db*db
        }
        return colors.min(by: { dist($0.rgb) < dist($1.rgb) })?.name ?? "unknown"
    }
    
    private func classifyImage(image: UIImage) async -> (Category?, String?) {
        guard let ciImage = CIImage(image: image) else { return (nil, nil) }
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNClassifyImageRequest()
        do {
            try handler.perform([request])
            guard let results = request.results, !results.isEmpty else { return (nil, nil) }
            let topLabels = results.prefix(5).map { $0.identifier.lowercased() }
            // Fuzzy match each label to all products in productTypesByCategory
            var bestScore = Int.max
            var bestCategory: Category? = nil
            var bestProduct: String? = nil
            for label in topLabels {
                for (category, products) in productTypesByCategory {
                    for product in products {
                        let score = Self.levenshtein(label, product.lowercased())
                        if score < bestScore {
                            bestScore = score
                            bestCategory = category
                            bestProduct = product
                        }
                    }
                }
            }
            // Only accept a match if it's reasonably close
            if let cat = bestCategory, let prod = bestProduct, bestScore <= 5 {
                return (cat, prod)
            }
            // Fallback: return top label as product
            return (nil, topLabels.first?.capitalized)
        } catch {
            return (nil, nil)
        }
    }
    
    // Levenshtein distance for fuzzy matching
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        var dist = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i-1] == b[j-1] {
                    dist[i][j] = dist[i-1][j-1]
                } else {
                    dist[i][j] = min(dist[i-1][j-1], dist[i][j-1], dist[i-1][j]) + 1
                }
            }
        }
        return dist[a.count][b.count]
    }
} 