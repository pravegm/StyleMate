#if DEBUG
import UIKit

/// DEBUG-only UI-test hook (never compiled into Release): `-uiTestSelfieFixture`.
///
/// The CI simulator has no camera, so the selfie step can't see anyone. With this flag the selfie
/// camera "captures" a face framed from a bundled CC0 sample photo instead (the woman in
/// `sample_casual_denim_jacket_hat.jpg`, the same person the CI photo library is built around:
/// `scripts/ui_test_library.swift`). Each frame then goes down the real path: `SelfieFrameChecker`
/// (YuNet + SFace) and the three-step logic in `SelfieCameraService`, then "Use these photos" (tapped by
/// the test) saves them with `SelfieReferenceStore` and rebuilds the identity. Only the camera and the
/// live Vision framing guide are skipped.
@MainActor
enum DebugSelfieFeed {
    static let argument = "-uiTestSelfieFixture"
    /// The bundled sample whose face is the selfie.
    static let sampleName = "sample_casual_denim_jacket_hat"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// Feeds frames to `camera` until it has all three (or gives up after a dozen tries).
    static func start(feeding camera: SelfieCameraService) {
        Task { @MainActor [weak camera] in
            guard let frames = await makeFrames(), !frames.isEmpty else {
                print("[UITest] selfie fixture: no face found in \(sampleName)")
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // the screen's entrance, as a person would take
            var captures = 0
            while let camera, camera.captureState != .captured, captures < 12 {
                if camera.debugCanCapture {
                    // A slightly different framing each time, like a hand-held phone.
                    camera.debugCapture(frames[captures % frames.count])
                    captures += 1
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            print("[UITest] selfie fixture: \(camera?.frames.count ?? 0) frames kept after \(captures) captures")
        }
    }

    /// Selfie framings of the sample's face: square crops where the face is ~40–50% of the width
    /// (a front camera at arm's length), scaled up to a camera-like 720 px.
    private static func makeFrames() async -> [UIImage]? {
        guard let url = SampleLibrary.photoURLs().first(where: { $0.lastPathComponent.hasPrefix(sampleName) }),
              let photo = UIImage(contentsOfFile: url.path) else { return nil }
        return await IdentityWorker.shared.run { () -> [UIImage]? in
            guard let cg = LibraryFaceScanner.uprightCGImage(photo),
                  let face = FaceDetector.shared.detect(in: cg).max(by: { $0.boxPixels.width < $1.boxPixels.width })
            else { return nil }
            let size = CGSize(width: cg.width, height: cg.height)
            return [2.2, 2.0, 2.4].compactMap { (factor: CGFloat) -> UIImage? in
                let rect = FaceSampleExtractor.paddedSquare(around: face.boxPixels, imageSize: size, factor: factor)
                guard let crop = cg.cropping(to: rect), crop.width > 0, crop.height > 0 else { return nil }
                let scale = 720 / CGFloat(max(crop.width, crop.height))
                let out = CGSize(width: (CGFloat(crop.width) * scale).rounded(), height: (CGFloat(crop.height) * scale).rounded())
                return ImageDownsampler.render(size: out, opaque: true) { _ in
                    UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: out))
                }
            }
        }
    }
}
#endif
