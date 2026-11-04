import SwiftUI
import AVFoundation

/// Captures the identity reference: three quick frames (straight on, slight turn left, slight
/// turn right), each checked on the phone for a clear, well-lit, single face before it's kept.
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
    @State private var stepFlash = false

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
        .onChange(of: cameraService.frames.count) { count in
            guard count > 0, count < SelfieStep.allCases.count else { return }
            // A frame was kept and the next one starts: a brief green confirmation.
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { stepFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeOut(duration: 0.3)) { stepFlash = false }
            }
        }
    }

    // MARK: - Camera View

    private var cameraView: some View {
        GeometryReader { geo in
            // Oval centered, slightly above the vertical middle (where faces sit
            // naturally). The oval rect (in full-screen coords) is handed to the
            // camera service so the captured photo is cropped to exactly this.
            let ovalW = geo.size.width * 0.62
            let ovalH = ovalW * 1.28
            let ovalCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.43)
            let ovalRect = CGRect(x: ovalCenter.x - ovalW / 2, y: ovalCenter.y - ovalH / 2,
                                  width: ovalW, height: ovalH)

            ZStack {
                CameraPreviewView(previewLayer: cameraService.previewLayer)
                    .ignoresSafeArea()

                Color.black.opacity(cameraBlackout)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                OvalCutoutView(
                    center: ovalCenter,
                    ovalSize: CGSize(width: ovalW, height: ovalH),
                    fillColor: Color.black.opacity(0.55)
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

                // Title above the oval, instruction below it, controls at the bottom.
                titleArea
                    .position(x: geo.size.width / 2,
                              y: max(geo.safeAreaInsets.top + 52, ovalCenter.y - ovalH / 2 - 70))

                instructionText
                    .padding(.horizontal, DS.Spacing.lg)
                    .position(x: geo.size.width / 2, y: ovalCenter.y + ovalH / 2 + 62)

                VStack {
                    Spacer()
                    bottomArea
                        .padding(.bottom, geo.safeAreaInsets.bottom + DS.Spacing.md)
                }
            }
            .onAppear {
                cameraService.previewSize = geo.size
                cameraService.ovalRect = ovalRect
            }
            .onChange(of: geo.size) { _ in
                cameraService.previewSize = geo.size
                cameraService.ovalRect = ovalRect
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Title

    private var titleArea: some View {
        VStack(spacing: DS.Spacing.xs) {
            VStack(spacing: DS.Spacing.micro) {
                Text(isRetakeMode ? "Retake your selfie" : "Take a quick selfie")
                    .font(DS.Font.title2)
                    .foregroundColor(.white)
                Text("so StyleMate can find you in your photos")
                    .font(DS.Font.subheadline)
                    .foregroundColor(.white.opacity(0.65))
            }
            if cameraService.captureState != .captured {
                tipsRow
            }
        }
        .opacity(titleVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: titleVisible)
    }

    private var tipsRow: some View {
        HStack(spacing: DS.Spacing.xs) {
            tip("sun.max.fill", "Face the light")
            tip("eyeglasses", "No sunglasses")
            tip("person.fill", "Just you")
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(DS.Font.caption2)
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
    }

    // MARK: - Oval Border

    @ViewBuilder
    private func ovalBorder(center: CGPoint, ovalW: CGFloat, ovalH: CGFloat) -> some View {
        switch cameraService.captureState {
        case .searching:
            Ellipse()
                .stroke(stepFlash ? DS.Colors.success : Color.white.opacity(searchPulse ? 0.5 : 0.25),
                        lineWidth: stepFlash ? 3 : 2)
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
            case .searching: return stepFlash ? DS.Colors.success : .white.opacity(0.6)
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

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(SelfieStep.allCases, id: \.rawValue) { s in
                let done = cameraService.frames.count > s.rawValue
                let current = !done && cameraService.step == s
                HStack(spacing: 4) {
                    Image(systemName: done ? "checkmark.circle.fill" : (current ? "circle.inset.filled" : "circle"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(s.label).font(DS.Font.caption1)
                }
                .foregroundColor(done ? DS.Colors.success : (current ? .white : .white.opacity(0.45)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo \(min(cameraService.frames.count + 1, 3)) of 3")
    }

    // MARK: - Instruction Text

    @ViewBuilder
    private var instructionText: some View {
        switch cameraService.captureState {
        case .searching, .detected:
            VStack(spacing: DS.Spacing.xs) {
                stepIndicator

                if cameraService.isChecking {
                    HStack(spacing: DS.Spacing.xs) {
                        ProgressView().tint(.white).controlSize(.small)
                        Text("Checking…")
                            .font(DS.Font.headline)
                            .foregroundColor(.white)
                    }
                } else if let warning = cameraService.qualityWarning ?? cameraService.frameFeedback {
                    Text(warning)
                        .font(DS.Font.headline)
                        .foregroundColor(.yellow)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if cameraService.captureState == .detected {
                    Text("Hold still…")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.accent)
                } else {
                    HStack(spacing: DS.Spacing.xs) {
                        if cameraService.step == .left { Image(systemName: "arrow.turn.up.left") }
                        Text(cameraService.step.prompt)
                        if cameraService.step == .right { Image(systemName: "arrow.turn.up.right") }
                    }
                    .font(DS.Font.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                }

                if cameraService.captureState == .searching, !cameraService.isChecking {
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
            }
            .animation(.easeInOut(duration: 0.2), value: cameraService.step)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(cameraService.frameFeedback ?? cameraService.step.prompt)

        case .captured:
            VStack(spacing: DS.Spacing.md) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Colors.success)
                    Text("Looks great!")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.success)
                }
                .scaleEffect(showCapturedState ? 1 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.5), value: showCapturedState)

                if showConfirmButtons {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Array(cameraService.frames.enumerated()), id: \.offset) { _, frame in
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                                    .strokeBorder(.white.opacity(0.6), lineWidth: 1))
                        }
                    }
                    .accessibilityLabel("\(cameraService.frames.count) reference photos")

                    VStack(spacing: DS.Spacing.sm) {
                        Button {
                            Haptics.medium()
                            confirmSelfie()
                        } label: {
                            Text("Use these photos")
                                .font(DS.Font.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Spacing.sm)
                                .background(DS.Colors.accent)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                        }
                        .accessibilityLabel("Use these selfie photos")

                        Button {
                            Haptics.light()
                            retakeSelfie()
                        } label: {
                            Text("Retake")
                                .font(DS.Font.callout)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .accessibilityLabel("Retake selfie photos")
                    }
                    .padding(.horizontal, DS.Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .transition(.opacity)

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
                Text("Your selfie never leaves this phone")
                    .font(DS.Font.caption1)
            }
            .foregroundColor(.white.opacity(0.55))

            if cameraService.captureState != .captured {
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
    }

    // MARK: - State Change Handling

    private func handleStateChange(_ state: SelfieCameraService.CaptureState) {
        switch state {
        case .detected:
            faceProgress = 0
            withAnimation(.linear(duration: cameraService.step == .front ? 1.2 : 0.7)) {
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
        print("[StyleMate] Selfie frames captured, waiting for user confirmation")
    }

    private func confirmSelfie() {
        if let front = cameraService.frames.first, let userId = authService.user?.id {
            selfieImage = front
            let turns = Array(cameraService.frames.dropFirst())
            // Advance immediately; the save + identity rebuild runs in the background and the
            // "Find yourself" step waits for it before ranking faces against the new selfie.
            IdentityBuild.start {
                SelfieReferenceStore.savePrimary(front, userId: userId)
                SelfieReferenceStore.saveTurnFrames(turns, userId: userId)
                SelfieReferenceStore.rebuildIdentity(forUser: userId)
                print("[StyleMate] Selfie frames saved, identity rebuilt")
            }
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

            Text("A quick selfie lets StyleMate find the photos of you wearing your clothes. It stays on this phone.")
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
