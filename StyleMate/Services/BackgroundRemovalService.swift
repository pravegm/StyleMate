import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

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
