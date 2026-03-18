import AVFoundation
import Vision
import SwiftUI

@MainActor
class SelfieCameraService: NSObject, ObservableObject {
    @Published var isFaceDetected: Bool = false
    @Published var faceRect: CGRect = .zero
    @Published var capturedImage: UIImage? = nil
    @Published var captureState: CaptureState = .searching
    @Published var cameraPermissionDenied: Bool = false
    @Published var qualityWarning: String? = nil

    enum CaptureState {
        case searching
        case detected
        case captured
        case denied
    }

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.stylemate.selfie.session")
    private var faceDetectedDuration: TimeInterval = 0
    private var lastFaceDetectionTime: Date?
    private let requiredFaceDuration: TimeInterval = 1.5
    private var isCapturing = false

    func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.setupSession()
                    } else {
                        self?.captureState = .denied
                        self?.cameraPermissionDenied = true
                    }
                }
            }
        default:
            captureState = .denied
            cameraPermissionDenied = true
        }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: frontCamera) else {
                self.captureSession.commitConfiguration()
                return
            }

            if self.captureSession.canAddInput(input) { self.captureSession.addInput(input) }

            self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.stylemate.selfie.video"))
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.captureSession.canAddOutput(self.videoOutput) { self.captureSession.addOutput(self.videoOutput) }
            if self.captureSession.canAddOutput(self.photoOutput) { self.captureSession.addOutput(self.photoOutput) }

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            print("[StyleMate] Selfie camera session started")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            print("[StyleMate] Selfie camera session stopped")
        }
    }

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func saveSelfie(_ image: UIImage, userId: String) {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filePath = documentsPath.appendingPathComponent("selfie_reference_\(userId).jpg")
        try? data.write(to: filePath)
        UserDefaults.standard.set(filePath.path, forKey: "selfieReferencePath_\(userId)")
        print("[StyleMate] Selfie saved for user: \(userId) at \(filePath.path)")
    }
}

// MARK: - Face Detection via Video Output

extension SelfieCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] request, _ in
            guard let self else { return }
            let faces = (request.results as? [VNFaceObservation] ?? []).filter { $0.confidence > 0.7 }
            let detected = !faces.isEmpty
            let faceRect = faces.first?.boundingBox ?? .zero
            let faceCount = faces.count

            Task { @MainActor in
                self.processFaceDetection(detected: detected, rect: faceRect, faceCount: faceCount)
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        try? handler.perform([request])
    }

    @MainActor
    private func processFaceDetection(detected: Bool, rect: CGRect, faceCount: Int) {
        guard captureState != .captured else { return }

        isFaceDetected = detected
        faceRect = rect

        if detected {
            let quality = validateFaceQuality(rect: rect, faceCount: faceCount)
            if !quality.isAcceptable {
                qualityWarning = quality.warning
                if captureState == .detected {
                    captureState = .searching
                    faceDetectedDuration = 0
                    lastFaceDetectionTime = nil
                }
                return
            }

            qualityWarning = nil

            if captureState == .searching {
                captureState = .detected
                lastFaceDetectionTime = Date()
                faceDetectedDuration = 0
                print("[StyleMate] Face detected with good quality, starting countdown")
            }

            if let lastTime = lastFaceDetectionTime {
                faceDetectedDuration = Date().timeIntervalSince(lastTime)
                if faceDetectedDuration >= requiredFaceDuration && captureState == .detected {
                    capturePhoto()
                }
            }
        } else {
            qualityWarning = nil
            if captureState == .detected {
                captureState = .searching
                faceDetectedDuration = 0
                lastFaceDetectionTime = nil
            }
        }
    }

    // MARK: - Face Quality Validation

    private struct FaceQuality {
        let isAcceptable: Bool
        let warning: String?
    }

    /// Validates that the detected face is large enough, centered, and alone.
    /// `rect` is in Vision's normalized coordinate space (0..1).
    private func validateFaceQuality(rect: CGRect, faceCount: Int) -> FaceQuality {
        if faceCount > 1 {
            return FaceQuality(isAcceptable: false, warning: "Only one person should be in frame")
        }

        let minFaceWidth: CGFloat = 0.25
        if rect.width < minFaceWidth {
            return FaceQuality(isAcceptable: false, warning: "Move closer to the camera")
        }

        let faceCenterX = rect.midX
        let faceCenterY = rect.midY
        let centerMargin: CGFloat = 0.2
        let isHorizontallyCentered = faceCenterX >= centerMargin && faceCenterX <= (1.0 - centerMargin)
        let isVerticallyCentered = faceCenterY >= centerMargin && faceCenterY <= (1.0 - centerMargin)

        if !isHorizontallyCentered || !isVerticallyCentered {
            return FaceQuality(isAcceptable: false, warning: "Center your face in the oval")
        }

        return FaceQuality(isAcceptable: true, warning: nil)
    }

    // MARK: - Retake

    func retakeSelfie() {
        capturedImage = nil
        captureState = .searching
        isFaceDetected = false
        faceRect = .zero
        faceDetectedDuration = 0
        lastFaceDetectionTime = nil
        isCapturing = false
        qualityWarning = nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                print("[StyleMate] Camera session restarted for retake")
            }
        }
    }
}

// MARK: - Photo Capture

extension SelfieCameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor in
                self.isCapturing = false
            }
            return
        }

        // Render the image to a canonical .up orientation bitmap.
        // The front camera produces .leftMirrored which confuses face
        // recognition models that expect unmirrored faces. Baking the
        // orientation into pixels and discarding the flag gives us a
        // stable reference image identical to how the user appears in
        // their photo library (camera-roll images are also .up).
        let normalized = Self.renderUpOrientation(image)

        Task { @MainActor in
            self.capturedImage = normalized
            self.captureState = .captured
            self.isCapturing = false
            Haptics.success()
            print("[StyleMate] Selfie captured (\(Int(normalized.size.width))x\(Int(normalized.size.height)), orientation: .up)")
        }
    }

    /// Renders the image into a new bitmap with .up orientation,
    /// baking any rotation/mirroring into the pixel data.
    private nonisolated static func renderUpOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, let cgImage = image.cgImage else { return image }
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Camera Preview UIViewRepresentable

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let view = uiView as? CameraPreviewUIView {
            view.previewLayer.frame = view.bounds
        }
    }

    private class CameraPreviewUIView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}
