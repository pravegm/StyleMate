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
    /// The preview layer is owned here so the captured photo can be cropped to
    /// exactly the on-screen oval (WYSIWYG). The view attaches this layer.
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.stylemate.selfie.session")
    private var faceDetectedDuration: TimeInterval = 0
    private var lastFaceDetectionTime: Date?
    private let requiredFaceDuration: TimeInterval = 1.5
    private var isCapturing = false

    /// Geometry of the on-screen preview + oval guide, set by the view. Used to
    /// crop the full-frame photo down to what the user framed in the oval.
    var previewSize: CGSize = .zero
    var ovalRect: CGRect = .zero

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
        // Associate the preview layer with the session HERE, on the main actor,
        // before any session work is dispatched to the session queue. Assigning
        // `previewLayer.session` triggers an internal begin/commitConfiguration on
        // the session; doing it from a concurrent main-actor Task while the queue
        // calls `startRunning()` crashes with "startRunning may not be called
        // between calls to beginConfiguration and commitConfiguration". Doing it
        // up front (serialized before the async block) removes that race.
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = captureSession

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
        // Capture upright and MIRRORED so the saved photo matches the mirrored
        // preview the user is looking at — i.e. exactly what's framed in the oval.
        if let conn = photoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// Crops the full-frame, upright photo down to the on-screen oval region,
    /// reversing the preview layer's resize-aspect-fill transform so the result
    /// is exactly what the user saw inside the oval (plus a little padding).
    static func cropToOval(_ image: UIImage, previewSize: CGSize, oval: CGRect) -> UIImage? {
        guard previewSize.width > 0, previewSize.height > 0,
              oval.width > 0, oval.height > 0,
              let cg = image.cgImage else { return nil }

        let pw = CGFloat(cg.width), ph = CGFloat(cg.height)
        let vw = previewSize.width, vh = previewSize.height
        let scale = max(vw / pw, vh / ph)          // aspect-fill
        let offsetX = (vw - pw * scale) / 2
        let offsetY = (vh - ph * scale) / 2

        func toPixel(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - offsetX) / scale, y: (y - offsetY) / scale)
        }
        let tl = toPixel(oval.minX, oval.minY)
        let br = toPixel(oval.maxX, oval.maxY)
        var rect = CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
        rect = rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12)   // breathing room
        rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: pw, height: ph))

        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    // nonisolated: pure image-encode + file write, no actor state — lets callers
    // run it off the main thread (avoids blocking the UI on confirm).
    nonisolated func saveSelfie(_ image: UIImage, userId: String) {
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

        // Bake orientation/mirroring into pixels, then crop to exactly the oval
        // the user framed (WYSIWYG). All geometry reads happen on the main actor.
        let normalized = Self.renderUpOrientation(image)

        Task { @MainActor in
            let cropped = Self.cropToOval(normalized, previewSize: self.previewSize, oval: self.ovalRect) ?? normalized
            self.capturedImage = cropped
            self.captureState = .captured
            self.isCapturing = false
            Haptics.success()
            print("[StyleMate] Selfie captured & cropped to oval (\(Int(cropped.size.width))x\(Int(cropped.size.height)))")
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
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> UIView {
        let view = CameraPreviewUIView()
        view.attach(previewLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let view = uiView as? CameraPreviewUIView {
            view.previewLayer?.frame = view.bounds
        }
    }

    private class CameraPreviewUIView: UIView {
        private(set) var previewLayer: AVCaptureVideoPreviewLayer?

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            previewLayer = layer
            layer.frame = bounds
            self.layer.addSublayer(layer)
        }

        required override init(frame: CGRect) { super.init(frame: frame) }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}
