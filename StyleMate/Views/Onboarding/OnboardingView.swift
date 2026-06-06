import SwiftUI
import Photos

struct OnboardingView: View {
    @EnvironmentObject var onboardingManager: OnboardingManager
    @EnvironmentObject var authService: AuthService

    @State private var currentStep = 0
    @State private var selfieImage: UIImage? = nil
    @State private var showReferenceBuilder = false

    private let totalSteps = 5

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                progressDots
                    .padding(.top, DS.Spacing.lg)

                ZStack {
                    Group {
                        switch currentStep {
                        case 0:
                            OnboardingWelcomeView(onAdvance: advance)
                        case 1:
                            OnboardingProfileView(onAdvance: advance)
                        case 2:
                            OnboardingPhotoExplanationView(onAdvance: advance, onSkip: skipToEnd)
                        case 3:
                            OnboardingSelfieView(
                                selfieImage: $selfieImage,
                                onAdvance: advance,
                                onSkip: { advance() }
                            )
                        case 4:
                            OnboardingPhotoPermissionView(onComplete: handlePhotoPermissionDone)
                        default:
                            EmptyView()
                        }
                    }
                    .id(currentStep)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showReferenceBuilder, onDismiss: { completeOnboarding() }) {
            if let userId = authService.user?.id {
                FaceReferenceBuilderView(userId: userId, isPresented: $showReferenceBuilder)
            }
        }
    }

    /// After photo permission: if granted, let the user build their face
    /// reference ("tap which photos are you") before finishing onboarding.
    private func handlePhotoPermissionDone() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited {
            showReferenceBuilder = true
        } else {
            completeOnboarding()
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == currentStep ? 1.15 : 1.0)
                    .animation(
                        index == currentStep
                            ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                            : .spring(response: 0.35, dampingFraction: 0.7),
                        value: currentStep
                    )
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: currentStep)
    }

    private func dotColor(for index: Int) -> Color {
        if index == currentStep {
            return DS.Colors.accent
        } else if index < currentStep {
            return DS.Colors.accent.opacity(0.5)
        } else {
            return DS.Colors.textTertiary.opacity(0.25)
        }
    }

    // MARK: - Navigation

    private func advance() {
        Haptics.light()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            currentStep += 1
        }
        print("[StyleMate] Onboarding: advancing to step \(currentStep)")
    }

    private func skipToEnd() {
        Haptics.medium()
        guard let userId = authService.user?.id else { return }
        onboardingManager.complete(forUser: userId)
        print("[StyleMate] Onboarding: skipped to end")
    }

    private func completeOnboarding() {
        Haptics.success()
        guard let userId = authService.user?.id else { return }
        onboardingManager.complete(forUser: userId)
        print("[StyleMate] Onboarding: completed")
    }
}
