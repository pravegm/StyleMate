import AVFoundation
import Vision
import SwiftUI

/// Front-camera capture for the identity reference: three frames (looking straight, then a
/// slight turn each way), each checked with the same SCRFD + AdaFace models the scan uses before
/// it's accepted. More than one angle gives the reference something to match profile and
/// three-quarter photos against, which a single straight-on selfie can't.
@MainActor
class SelfieCameraService: NSObject, ObservableObject {
    @Published var isFaceDetected: Bool = false
    @Published var faceRect: CGRect = .zero
    /// The accepted front frame (the primary reference).
    @Published var capturedImage: UIImage? = nil
    @Published var captureState: CaptureState = .searching
    @Published var cameraPermissionDenied: Bool = false
    /// Live guidance while framing ("Move closer", "Now turn the other way").
    @Published var qualityWarning: String? = nil

    /// Which of the three frames we're on.
    @Published var step: SelfieStep = .front
    /// Accepted frames, in `SelfieStep` order.
    @Published var frames: [UIImage] = []
    /// A frame was captured and is being checked.
    @Published var isChecking = false
    /// Friendly copy explaining why the last frame wasn't used.
    @Published var frameFeedback: String? = nil

    enum CaptureState {
        case searching   // waiting for a good, still face in the right pose
        case detected    // countdown to capture
        case captured    // all frames accepted
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
    private var isCapturing = false

    private var frontEmbedding: [Float]?
    /// Sign of the live yaw on the first turn, so the second turn goes the other way.
    private var firstTurnSign: Float = 0
    private var rejectionsThisStep = 0
    private var stepStartedAt = Date()
    private var lastYaw: Float?

    /// Geometry of the on-screen preview + oval guide, set by the view. Used to
    /// crop the full-frame photo down to what the user framed in the oval.
    var previewSize: CGSize = .zero
    var ovalRect: CGRect = .zero

    private var requiredFaceDuration: TimeInterval { step == .front ? 1.2 : 0.7 }

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
            dlog("[StyleMate] Selfie camera session started")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            dlog("[StyleMate] Selfie camera session stopped")
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

    /// Saves the front frame where FaceMatchingService reads it (`selfieReferencePath_<userId>`).
    /// nonisolated: pure encode + file write, safe off the main thread.
    nonisolated func saveSelfie(_ image: UIImage, userId: String) {
        SelfieReferenceStore.savePrimary(image, userId: userId)
    }

    // MARK: - Frame check

    private func handleCaptured(_ image: UIImage) {
        isChecking = true
        let step = self.step
        let front = frontEmbedding
        Task {
            let result = await IdentityWorker.shared.run {
                SelfieFrameChecker.check(image, step: step, frontEmbedding: front)
            }
            self.finishCheck(image, result: result)
        }
    }

    private func finishCheck(_ image: UIImage, result: SelfieFrameResult) {
        isChecking = false
        isCapturing = false
        guard captureState != .captured else { return }

        // Quality issues are forgiven after two tries (a reference that's a bit dark beats being
        // stuck); issues that would poison the reference (no face, someone else) never are.
        if let issue = result.issue, issue.isBlocking || rejectionsThisStep < 2 {
            rejectionsThisStep += 1
            frameFeedback = issue.message
            Haptics.warning()
            resetCountdown()
            captureState = .searching
            return
        }

        frames.append(image)
        frameFeedback = nil
        rejectionsThisStep = 0
        Haptics.success()
        switch step {
        case .front:
            capturedImage = image
            frontEmbedding = result.embedding
        case .left:
            if let y = lastYaw, abs(y) > 0.05 { firstTurnSign = y > 0 ? 1 : -1 }
        case .right:
            break
        }

        if let next = step.next {
            step = next
            stepStartedAt = Date()
            resetCountdown()
            captureState = .searching
        } else {
            captureState = .captured
            dlog("[StyleMate] Selfie: all \(frames.count) reference frames accepted")
        }
    }

    private func resetCountdown() {
        faceDetectedDuration = 0
        lastFaceDetectionTime = nil
    }
}

// MARK: - Face Detection via Video Output

extension SelfieCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Live framing only (presence, size, pose). The identity embedding never uses Vision
        // landmarks; each captured frame is checked with SCRFD + AdaFace.
        let request = VNDetectFaceRectanglesRequest { [weak self] request, _ in
            guard let self else { return }
            let faces = (request.results as? [VNFaceObservation] ?? []).filter { $0.confidence > 0.7 }
            let detected = !faces.isEmpty
            let face = faces.max { $0.boundingBox.width < $1.boundingBox.width }
            let faceRect = face?.boundingBox ?? .zero
            let yaw: Float? = face?.yaw.map { $0.floatValue }
            let faceCount = faces.count

            Task { @MainActor in
                self.processFaceDetection(detected: detected, rect: faceRect, faceCount: faceCount, yaw: yaw)
            }
        }
        request.revision = VNDetectFaceRectanglesRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        try? handler.perform([request])
    }

    @MainActor
    private func processFaceDetection(detected: Bool, rect: CGRect, faceCount: Int, yaw: Float?) {
        guard captureState != .captured, captureState != .denied, !isChecking, !isCapturing else { return }

        isFaceDetected = detected
        faceRect = rect
        lastYaw = yaw

        guard detected else {
            qualityWarning = nil
            if captureState == .detected {
                captureState = .searching
                resetCountdown()
            }
            return
        }

        let quality = validateFaceQuality(rect: rect, faceCount: faceCount)
        let pose = quality.isAcceptable ? poseCheck(yaw: yaw) : PoseCheck(ready: false, warning: nil)
        guard quality.isAcceptable, pose.ready else {
            qualityWarning = quality.warning ?? pose.warning
            if captureState == .detected {
                captureState = .searching
                resetCountdown()
            }
            return
        }

        qualityWarning = nil

        if captureState == .searching {
            captureState = .detected
            lastFaceDetectionTime = Date()
            faceDetectedDuration = 0
        }

        if let lastTime = lastFaceDetectionTime {
            faceDetectedDuration = Date().timeIntervalSince(lastTime)
            if faceDetectedDuration >= requiredFaceDuration && captureState == .detected {
                capturePhoto()
            }
        }
    }

    // MARK: - Pose

    private struct PoseCheck {
        let ready: Bool
        let warning: String?
    }

    /// Vision yaw is in radians. Front: roughly straight on. Turns: a slight turn (about 10–40°),
    /// the second one the opposite way to the first. Without a yaw reading, give the user a
    /// moment to turn before capturing.
    private func poseCheck(yaw: Float?) -> PoseCheck {
        let elapsed = Date().timeIntervalSince(stepStartedAt)
        switch step {
        case .front:
            if let y = yaw, abs(y) > 0.3 { return PoseCheck(ready: false, warning: "Look straight at the camera") }
            return PoseCheck(ready: true, warning: nil)
        case .left, .right:
            guard let y = yaw else { return PoseCheck(ready: elapsed > 1.6, warning: nil) }
            if abs(y) > 0.75 { return PoseCheck(ready: false, warning: "Not quite so far, just a slight turn") }
            if abs(y) < 0.15 { return PoseCheck(ready: false, warning: nil) }
            if step == .right, firstTurnSign != 0, (y > 0 ? Float(1) : Float(-1)) == firstTurnSign {
                return PoseCheck(ready: false, warning: "Now turn the other way")
            }
            return PoseCheck(ready: elapsed > 0.5, warning: nil)
        }
    }

    // MARK: - Face Quality Validation

    private struct LiveFaceQuality {
        let isAcceptable: Bool
        let warning: String?
    }

    /// Validates that the detected face is large enough, centered, and alone.
    /// `rect` is in Vision's normalized coordinate space (0..1).
    private func validateFaceQuality(rect: CGRect, faceCount: Int) -> LiveFaceQuality {
        if faceCount > 1 {
            return LiveFaceQuality(isAcceptable: false, warning: "Only one person should be in frame")
        }

        let minFaceWidth: CGFloat = 0.25
        if rect.width < minFaceWidth {
            return LiveFaceQuality(isAcceptable: false, warning: "Move closer to the camera")
        }

        let faceCenterX = rect.midX
        let faceCenterY = rect.midY
        let centerMargin: CGFloat = 0.2
        let isHorizontallyCentered = faceCenterX >= centerMargin && faceCenterX <= (1.0 - centerMargin)
        let isVerticallyCentered = faceCenterY >= centerMargin && faceCenterY <= (1.0 - centerMargin)

        if !isHorizontallyCentered || !isVerticallyCentered {
            return LiveFaceQuality(isAcceptable: false, warning: "Center your face in the oval")
        }

        return LiveFaceQuality(isAcceptable: true, warning: nil)
    }

    // MARK: - Retake

    func retakeSelfie() {
        capturedImage = nil
        frames = []
        step = .front
        frontEmbedding = nil
        firstTurnSign = 0
        rejectionsThisStep = 0
        frameFeedback = nil
        stepStartedAt = Date()
        captureState = .searching
        isFaceDetected = false
        faceRect = .zero
        resetCountdown()
        isCapturing = false
        isChecking = false
        qualityWarning = nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                dlog("[StyleMate] Camera session restarted for retake")
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
            dlog("[StyleMate] Selfie frame \(self.step.label) captured (\(Int(cropped.size.width))x\(Int(cropped.size.height))), checking")
            self.handleCaptured(cropped)
        }
    }

    /// Renders the image into a new bitmap with .up orientation,
    /// baking any rotation/mirroring into the pixel data.
    private nonisolated static func renderUpOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, image.cgImage != nil else { return image }
        // Scale 1: the default renderer format uses the screen scale (9x the pixels).
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return ImageDownsampler.render(size: size) { _ in
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
