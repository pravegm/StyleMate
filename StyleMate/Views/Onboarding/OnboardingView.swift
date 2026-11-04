import SwiftUI
import Photos

struct OnboardingView: View {
    @EnvironmentObject var onboardingManager: OnboardingManager
    @EnvironmentObject var authService: AuthService

    @State private var currentStep = 0
    @State private var selfieImage: UIImage? = nil

    /// welcome → about you → photo explainer → selfie → photo access → find yourself.
    /// Completing the last step marks onboarding done, which starts the first library scan.
    private let totalSteps = 6

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
                        case 5:
                            FindYourselfView(userId: authService.user?.id ?? "", mode: .onboarding) { _ in
                                completeOnboarding()
                            }
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
        .onAppear { Haptics.prepare() }   // warm the Taptic Engine so the first tap is instant
    }

    /// After photo permission: if granted, "Find yourself" builds a strong face reference from
    /// the library before onboarding finishes (and the first scan starts).
    private func handlePhotoPermissionDone() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited {
            advance()
        } else {
            completeOnboarding()
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule()
                    .fill(dotColor(for: index))
                    .frame(width: index == currentStep ? 22 : 8, height: 8)
            }
        }
        .animation(DS.Motion.snappy, value: currentStep)
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
