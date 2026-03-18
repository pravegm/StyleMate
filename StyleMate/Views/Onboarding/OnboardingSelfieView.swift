import SwiftUI
import AVFoundation

struct OnboardingSelfieView: View {
    @Binding var selfieImage: UIImage?
    let onAdvance: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject var authService: AuthService
    @StateObject private var cameraService = SelfieCameraService()

    // MARK: - Animation State

    @State private var cameraBlackout: Double = 1.0
    @State private var titleVisible = false
    @State private var searchPulse = false
    @State private var faceProgress: CGFloat = 0
    @State private var showCapturedState = false
    @State private var capturedBounce: CGFloat = 1.0
    @State private var searchDotPhase = 0
    @State private var showConfirmButtons = false

    var isRetakeMode: Bool = false

    private let searchDotTimer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if cameraService.cameraPermissionDenied {
                cameraPermissionDeniedView
            } else {
                cameraView
            }
        }
        .onAppear {
            cameraService.configure()
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                cameraBlackout = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                titleVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    searchPulse = true
                }
            }
        }
        .onDisappear {
            cameraService.stop()
        }
        .onChange(of: cameraService.captureState) { state in
            handleStateChange(state)
        }
    }

    // MARK: - Camera View

    private var cameraView: some View {
        GeometryReader { geo in
            let ovalW = geo.size.width * 0.58
            let ovalH = ovalW * 1.3
            let ovalCenterY = geo.safeAreaInsets.top + 80 + ovalH / 2
            let ovalCenter = CGPoint(x: geo.size.width / 2, y: ovalCenterY)

            ZStack {
                CameraPreviewView(session: cameraService.captureSession)
                    .ignoresSafeArea()

                Color.black.opacity(cameraBlackout)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                OvalCutoutView(
                    center: ovalCenter,
                    ovalSize: CGSize(width: ovalW, height: ovalH),
                    fillColor: Color.black.opacity(0.6)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                ovalBorder(center: ovalCenter, ovalW: ovalW, ovalH: ovalH)
                cornerTicks(center: ovalCenter, ovalW: ovalW, ovalH: ovalH)

                if showCapturedState, let image = cameraService.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: ovalW - 6, height: ovalH - 6)
                        .clipShape(Ellipse())
                        .position(ovalCenter)
                        .transition(.opacity)
                }

                VStack {
                    titleArea
                        .padding(.top, geo.safeAreaInsets.top + DS.Spacing.md)

                    Spacer()
                        .frame(height: ovalCenterY + ovalH / 2 - geo.safeAreaInsets.top - 60 + DS.Spacing.xl)

                    instructionText
                        .padding(.horizontal, DS.Spacing.lg)

                    Spacer()

                    bottomArea
                        .padding(.bottom, DS.Spacing.xl)
                }
            }
        }
    }

    // MARK: - Title

    private var titleArea: some View {
        VStack(spacing: DS.Spacing.micro) {
            Text("Take a Quick Selfie")
                .font(DS.Font.title2)
                .foregroundColor(.white)
            Text("to find your outfit photos")
                .font(DS.Font.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .opacity(titleVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: titleVisible)
    }

    // MARK: - Oval Border

    @ViewBuilder
    private func ovalBorder(center: CGPoint, ovalW: CGFloat, ovalH: CGFloat) -> some View {
        switch cameraService.captureState {
        case .searching:
            Ellipse()
                .stroke(Color.white.opacity(searchPulse ? 0.5 : 0.25), lineWidth: 2)
                .frame(width: ovalW, height: ovalH)
                .position(center)

        case .detected:
            ZStack {
                Ellipse()
                    .stroke(DS.Colors.accent.opacity(0.25), lineWidth: 2)
                    .frame(width: ovalW, height: ovalH)

                Circle()
                    .trim(from: 0, to: faceProgress)
                    .stroke(DS.Colors.accent.opacity(0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .scaleEffect(x: 1.0, y: ovalH / ovalW)
                    .rotationEffect(.degrees(-90))
                    .frame(width: ovalW, height: ovalW)
                    .blur(radius: 8)

                Circle()
                    .trim(from: 0, to: faceProgress)
                    .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .scaleEffect(x: 1.0, y: ovalH / ovalW)
                    .rotationEffect(.degrees(-90))
                    .frame(width: ovalW, height: ovalW)
            }
            .position(center)

        case .captured:
            Ellipse()
                .stroke(DS.Colors.success, lineWidth: 3)
                .frame(width: ovalW, height: ovalH)
                .scaleEffect(capturedBounce)
                .position(center)

        case .denied:
            EmptyView()
        }
    }

    // MARK: - Corner Ticks

    private func cornerTicks(center: CGPoint, ovalW: CGFloat, ovalH: CGFloat) -> some View {
        let tickColor: Color = {
            switch cameraService.captureState {
            case .searching: return .white.opacity(0.6)
            case .detected: return DS.Colors.accent
            case .captured: return DS.Colors.success
            case .denied: return .clear
            }
        }()

        return ZStack {
            // Top
            RoundedRectangle(cornerRadius: 1)
                .fill(tickColor)
                .frame(width: 2, height: 12)
                .position(x: center.x, y: center.y - ovalH / 2 - 8)
            // Bottom
            RoundedRectangle(cornerRadius: 1)
                .fill(tickColor)
                .frame(width: 2, height: 12)
                .position(x: center.x, y: center.y + ovalH / 2 + 8)
            // Left
            RoundedRectangle(cornerRadius: 1)
                .fill(tickColor)
                .frame(width: 12, height: 2)
                .position(x: center.x - ovalW / 2 - 8, y: center.y)
            // Right
            RoundedRectangle(cornerRadius: 1)
                .fill(tickColor)
                .frame(width: 12, height: 2)
                .position(x: center.x + ovalW / 2 + 8, y: center.y)
        }
    }

    // MARK: - Instruction Text

    @ViewBuilder
    private var instructionText: some View {
        switch cameraService.captureState {
        case .searching:
            VStack(spacing: DS.Spacing.xs) {
                if let warning = cameraService.qualityWarning {
                    Text(warning)
                        .font(DS.Font.headline)
                        .foregroundColor(.yellow)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                } else {
                    Text("Position your face in the oval")
                        .font(DS.Font.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: DS.Spacing.micro) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                            .scaleEffect(searchDotPhase == i ? 1.5 : 1.0)
                            .opacity(searchDotPhase == i ? 1.0 : 0.3)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: searchDotPhase)
                    }
                }
                .onReceive(searchDotTimer) { _ in
                    if cameraService.captureState == .searching {
                        searchDotPhase = (searchDotPhase + 1) % 3
                    }
                }
            }
            .transition(.opacity)
            .accessibilityLabel("Position your face in the oval to take a selfie")

        case .detected:
            VStack(spacing: DS.Spacing.xs) {
                Text("Hold still...")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.accent)

                Circle()
                    .trim(from: 0, to: faceProgress)
                    .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 16, height: 16)
            }
            .transition(.opacity)
            .accessibilityLabel("Face detected, hold still")

        case .captured:
            VStack(spacing: DS.Spacing.md) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Colors.success)
                    Text("Looks good!")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.success)
                }
                .scaleEffect(showCapturedState ? 1 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.5), value: showCapturedState)

                if showConfirmButtons {
                    VStack(spacing: DS.Spacing.sm) {
                        Button {
                            Haptics.medium()
                            confirmSelfie()
                        } label: {
                            Text("Use This Photo")
                                .font(DS.Font.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Spacing.sm)
                                .background(DS.Colors.accent)
                                .cornerRadius(DS.CornerRadius.md)
                        }
                        .accessibilityLabel("Use this selfie photo")

                        Button {
                            Haptics.light()
                            retakeSelfie()
                        } label: {
                            Text("Retake")
                                .font(DS.Font.callout)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .accessibilityLabel("Retake selfie photo")
                    }
                    .padding(.horizontal, DS.Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .transition(.opacity)
            .accessibilityLabel("Photo captured, choose to use or retake")

        case .denied:
            EmptyView()
        }
    }

    // MARK: - Bottom Area

    private var bottomArea: some View {
        VStack(spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.micro) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text("Your selfie stays on this device")
                    .font(DS.Font.caption1)
            }
            .foregroundColor(.white.opacity(0.5))

            Button {
                Haptics.light()
                onSkip()
            } label: {
                Text("Skip")
                    .font(DS.Font.callout)
                    .foregroundColor(.white.opacity(0.65))
            }
        }
    }

    // MARK: - State Change Handling

    private func handleStateChange(_ state: SelfieCameraService.CaptureState) {
        switch state {
        case .detected:
            withAnimation(.linear(duration: 1.5)) {
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

    private func handleCapture() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
            showCapturedState = true
            capturedBounce = 1.04
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                capturedBounce = 1.0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showConfirmButtons = true
            }
        }
        print("[StyleMate] Selfie captured, waiting for user confirmation")
    }

    private func confirmSelfie() {
        if let image = cameraService.capturedImage, let userId = authService.user?.id {
            selfieImage = image
            cameraService.saveSelfie(image, userId: userId)
            FaceMatchingService.shared.clearReference()
            print("[StyleMate] Selfie confirmed and saved, reference cleared for reload")
        }
        onAdvance()
    }

    private func retakeSelfie() {
        showCapturedState = false
        showConfirmButtons = false
        capturedBounce = 1.0
        faceProgress = 0
        cameraService.retakeSelfie()
    }

    // MARK: - Permission Denied Fallback

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

// MARK: - Oval Cutout

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

struct OvalCutoutView: View {
    let center: CGPoint
    let ovalSize: CGSize
    let fillColor: Color

    var body: some View {
        OvalCutoutShape(center: center, ovalSize: ovalSize)
            .fill(fillColor, style: FillStyle(eoFill: true))
    }
}
