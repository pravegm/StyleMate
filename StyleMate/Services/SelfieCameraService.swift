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
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filePath = documentsPath.appendingPathComponent("selfie_reference_\(userId).jpg")
        try? data.write(to: filePath)
        UserDefaults.standard.set(filePath.path, forKey: "selfieReferencePath_\(userId)")
        print("[StyleMate] Selfie saved for user: \(userId)")
    }
}

// MARK: - Face Detection via Video Output

extension SelfieCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] request, _ in
            guard let self else { return }
            let faces = request.results as? [VNFaceObservation] ?? []
            let detected = faces.contains { $0.confidence > 0.7 }
            let faceRect = faces.first(where: { $0.confidence > 0.7 })?.boundingBox ?? .zero

            Task { @MainActor in
                self.processFaceDetection(detected: detected, rect: faceRect)
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        try? handler.perform([request])
    }

    @MainActor
    private func processFaceDetection(detected: Bool, rect: CGRect) {
        guard captureState != .captured else { return }

        isFaceDetected = detected
        faceRect = rect

        if detected {
            if captureState == .searching {
                captureState = .detected
                lastFaceDetectionTime = Date()
                faceDetectedDuration = 0
                print("[StyleMate] Face detected, starting countdown")
            }

            if let lastTime = lastFaceDetectionTime {
                faceDetectedDuration = Date().timeIntervalSince(lastTime)
                if faceDetectedDuration >= requiredFaceDuration && captureState == .detected {
                    capturePhoto()
                }
            }
        } else {
            if captureState == .detected {
                captureState = .searching
                faceDetectedDuration = 0
                lastFaceDetectionTime = nil
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

        let mirrored = UIImage(cgImage: image.cgImage!, scale: image.scale, orientation: .leftMirrored)

        Task { @MainActor in
            self.capturedImage = mirrored
            self.captureState = .captured
            self.isCapturing = false
            Haptics.success()
            print("[StyleMate] Selfie captured successfully")
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
