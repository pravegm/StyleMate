import SwiftUI
import AVFoundation

struct OnboardingSelfieView: View {
    @Binding var selfieImage: UIImage?
    let onAdvance: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject var authService: AuthService
    @StateObject private var cameraService = SelfieCameraService()
    @State private var appeared = false
    @State private var faceProgress: CGFloat = 0
    @State private var showCapturedState = false
    @State private var capturedBounce: CGFloat = 1.0

    private let ovalWidth: CGFloat = 220
    private let ovalHeight: CGFloat = 280

    var body: some View {
        ZStack {
            if cameraService.cameraPermissionDenied {
                cameraPermissionDeniedView
            } else {
                cameraView
            }
        }
        .onAppear {
            appeared = true
            cameraService.configure()
        }
        .onDisappear {
            cameraService.stop()
        }
        .onChange(of: cameraService.captureState) { state in
            switch state {
            case .detected:
                withAnimation(.linear(duration: cameraService.captureState == .detected ? 1.5 : 0)) {
                    faceProgress = 1.0
                }
            case .searching:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    faceProgress = 0
                }
            case .captured:
                handleCapture()
            case .denied:
                break
            }
        }
    }

    // MARK: - Camera View

    private var cameraView: some View {
        ZStack {
            CameraPreviewView(session: cameraService.captureSession)
                .ignoresSafeArea()

            cameraOverlay

            VStack {
                Spacer()
                    .frame(height: 100 + ovalHeight + DS.Spacing.xl)

                instructionText
                    .padding(.horizontal, DS.Spacing.lg)

                Spacer()

                privacyText
                    .padding(.bottom, DS.Spacing.sm)

                Button {
                    Haptics.light()
                    onSkip()
                } label: {
                    Text("Skip")
                        .font(DS.Font.callout)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.bottom, DS.Spacing.xl)
            }
        }
    }

    // MARK: - Camera Overlay with Oval Cutout

    private var cameraOverlay: some View {
        GeometryReader { geometry in
            let ovalCenter = CGPoint(
                x: geometry.size.width / 2,
                y: 100 + ovalHeight / 2
            )

            ZStack {
                OvalCutoutView(
                    center: ovalCenter,
                    ovalSize: CGSize(width: ovalWidth, height: ovalHeight),
                    fillColor: Color.black.opacity(0.55)
                )
                .ignoresSafeArea()

                ovalBorder(center: ovalCenter)

                if showCapturedState, let image = cameraService.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: ovalWidth - 5, height: ovalHeight - 5)
                        .clipShape(Ellipse())
                        .position(ovalCenter)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func ovalBorder(center: CGPoint) -> some View {
        switch cameraService.captureState {
        case .searching:
            Ellipse()
                .stroke(Color.white.opacity(appeared ? 0.5 : 0.3), lineWidth: 2.5)
                .frame(width: ovalWidth, height: ovalHeight)
                .position(center)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: appeared)

        case .detected:
            ZStack {
                Ellipse()
                    .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 2.5)
                    .frame(width: ovalWidth, height: ovalHeight)

                Ellipse()
                    .trim(from: 0, to: faceProgress)
                    .stroke(DS.Colors.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: ovalWidth, height: ovalHeight)
                    .rotationEffect(.degrees(-90))
            }
            .position(center)

        case .captured:
            Ellipse()
                .stroke(DS.Colors.success, lineWidth: 3)
                .frame(width: ovalWidth, height: ovalHeight)
                .scaleEffect(capturedBounce)
                .position(center)

        case .denied:
            EmptyView()
        }
    }

    // MARK: - Instruction Text

    @ViewBuilder
    private var instructionText: some View {
        switch cameraService.captureState {
        case .searching:
            Text("Position your face in the oval")
                .font(DS.Font.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .transition(.opacity)
                .accessibilityLabel("Position your face in the oval to take a selfie")

        case .detected:
            VStack(spacing: DS.Spacing.xs) {
                Text("Hold still...")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.accent)

                HStack(spacing: DS.Spacing.micro) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(DS.Colors.accent)
                            .frame(width: 6, height: 6)
                            .opacity(countdownDotOpacity(for: index))
                    }
                }
            }
            .transition(.opacity)
            .accessibilityLabel("Face detected, hold still")

        case .captured:
            VStack(spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Colors.success)
                    Text("Perfect!")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.success)
                }
                .scaleEffect(showCapturedState ? 1 : 0.5)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showCapturedState)
            }
            .transition(.opacity)
            .accessibilityLabel("Photo captured successfully")

        case .denied:
            EmptyView()
        }
    }

    private func countdownDotOpacity(for index: Int) -> Double {
        let progress = Double(faceProgress)
        let threshold = Double(index + 1) / 3.0
        return progress >= threshold ? 1.0 : 0.3
    }

    // MARK: - Privacy & Skip

    private var privacyText: some View {
        HStack(spacing: DS.Spacing.micro) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
            Text("Your selfie never leaves this device")
                .font(DS.Font.caption1)
        }
        .foregroundColor(.white.opacity(0.6))
    }

    // MARK: - Capture Handling

    private func handleCapture() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            showCapturedState = true
            capturedBounce = 1.05
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                capturedBounce = 1.0
            }
        }

        if let image = cameraService.capturedImage, let userId = authService.user?.id {
            selfieImage = image
            cameraService.saveSelfie(image, userId: userId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            onAdvance()
        }
    }

    // MARK: - Permission Denied View

    private var cameraPermissionDeniedView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(DS.Colors.backgroundSecondary)
                    .frame(width: 100, height: 100)

                Image(systemName: "camera.fill")
                    .font(.system(size: 40))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text("Camera access needed for selfie")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("We'll use your selfie to find photos of you wearing your clothes.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)

            Spacer()

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(DSPrimaryButton())

                Button {
                    Haptics.light()
                    onSkip()
                } label: {
                    Text("Skip for now")
                        .font(DS.Font.callout)
                        .foregroundColor(DS.Colors.accent)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
    }
}

// MARK: - Oval Cutout Shape

private struct OvalCutoutShape: Shape {
    let center: CGPoint
    let ovalSize: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: CGRect(
            x: center.x - ovalSize.width / 2,
            y: center.y - ovalSize.height / 2,
            width: ovalSize.width,
            height: ovalSize.height
        ))
        return path
    }
}

private struct OvalCutoutView: View {
    let center: CGPoint
    let ovalSize: CGSize
    let fillColor: Color

    var body: some View {
        OvalCutoutShape(center: center, ovalSize: ovalSize)
            .fill(fillColor, style: FillStyle(eoFill: true))
    }
}
