import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

enum BodyZone {
    static func cropRegion(for category: Category) -> (yStart: CGFloat, yEnd: CGFloat)? {
        switch category {
        case .accessories:
            return nil
        case .tops:
            return (yStart: 0.08, yEnd: 0.52)
        case .midLayers:
            return (yStart: 0.06, yEnd: 0.55)
        case .outerwear:
            return (yStart: 0.04, yEnd: 0.62)
        case .bottoms:
            return (yStart: 0.40, yEnd: 0.85)
        case .onePieces:
            return (yStart: 0.06, yEnd: 0.88)
        case .ethnicWear:
            return (yStart: 0.04, yEnd: 0.90)
        case .activewear:
            return (yStart: 0.06, yEnd: 0.85)
        case .footwear:
            return (yStart: 0.78, yEnd: 1.0)
        case .innerwear:
            return nil
        }
    }

    static func cropToZone(image: UIImage, category: Category) -> UIImage? {
        guard let region = cropRegion(for: category),
              let cgImage = image.cgImage else {
            return nil
        }

        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

        let horizontalInset: CGFloat = 0.05
        let x = imgWidth * horizontalInset
        let width = imgWidth * (1.0 - horizontalInset * 2)

        let y = imgHeight * region.yStart
        let height = imgHeight * (region.yEnd - region.yStart)

        let rect = CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

        guard !rect.isEmpty,
              let cropped = cgImage.cropping(to: rect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}

class BackgroundRemovalService {
    static let shared = BackgroundRemovalService()
    private let ciContext = CIContext()
    private init() {}

    /// Removes the background from an image, keeping only foreground subjects (people, clothing).
    /// Returns the subject on a white background, or nil if processing fails.
    func removeBackground(from image: UIImage) async -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])

                guard let result = request.results?.first else {
                    continuation.resume(returning: nil)
                    return
                }

                let mask = try result.generateScaledMaskForImage(
                    forInstances: result.allInstances,
                    from: handler
                )

                let maskCIImage = CIImage(cvPixelBuffer: mask)
                let originalCIImage = CIImage(cgImage: cgImage)

                let whiteBackground = CIImage(color: .white)
                    .cropped(to: originalCIImage.extent)

                let filter = CIFilter.blendWithMask()
                filter.inputImage = originalCIImage
                filter.maskImage = maskCIImage
                filter.backgroundImage = whiteBackground

                guard let outputCIImage = filter.outputImage,
                      let outputCGImage = self.ciContext.createCGImage(outputCIImage, from: outputCIImage.extent) else {
                    continuation.resume(returning: nil)
                    return
                }

                let finalImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
                continuation.resume(returning: finalImage)
            } catch {
                print("[StyleMate] Background removal failed: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Processes an existing wardrobe item's images with background removal.
    /// Returns updated image paths, or nil if processing fails.
    func processExistingItem(imagePath: String, croppedImagePath: String?) async -> (newImagePath: String, newCroppedPath: String?)? {
        guard let originalImage = WardrobeImageFileHelper.loadImage(at: imagePath) else { return nil }

        guard let bgRemoved = await removeBackground(from: originalImage) else { return nil }

        guard let newImagePath = WardrobeImageFileHelper.saveImage(bgRemoved) else { return nil }

        var newCroppedPath: String? = nil
        if let croppedPath = croppedImagePath,
           let croppedImage = WardrobeImageFileHelper.loadImage(at: croppedPath) {
            if let bgRemovedCropped = await removeBackground(from: croppedImage) {
                newCroppedPath = WardrobeImageFileHelper.saveImage(bgRemovedCropped)
            }
        }

        return (newImagePath, newCroppedPath)
    }
}
