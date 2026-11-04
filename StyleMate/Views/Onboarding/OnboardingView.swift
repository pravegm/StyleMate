import SwiftUI
import Photos

/// Four screens to a filling closet: welcome/privacy → three-frame selfie →
/// photo permission → Find yourself → scanning ("First 40"), then Home.
/// "Try with sample photos" on the welcome screen skips straight to a sample
/// scan. No account, no "about you" form (it lives in Profile), no tour.
struct OnboardingView: View {
    @EnvironmentObject var onboardingManager: OnboardingManager
    @EnvironmentObject var authService: AuthService

    private enum Step: Int, CaseIterable {
        case welcome, selfie, permission, findYourself, scanning
    }

    @State private var step: Step = .welcome
    @State private var scanMode: OnboardingScanningView.Mode = .library
    @State private var selfieImage: UIImage? = nil

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                if scanMode == .library {
                    progressDots
                        .padding(.top, DS.Spacing.lg)
                }

                ZStack {
                    Group {
                        switch step {
                        case .welcome:
                            OnboardingWelcomeView(onAdvance: { go(to: .selfie) },
                                                  onTrySamples: trySamplesAction)
                        case .selfie:
                            OnboardingSelfieView(
                                selfieImage: $selfieImage,
                                onAdvance: { go(to: .permission) },
                                onSkip: { go(to: .permission) }
                            )
                        case .permission:
                            OnboardingPhotoPermissionView(onComplete: handlePhotoPermissionDone)
                        case .findYourself:
                            FindYourselfView(userId: authService.user?.id ?? "", mode: .onboarding) { _ in
                                go(to: .scanning)
                            }
                        case .scanning:
                            OnboardingScanningView(mode: scanMode, onDone: completeOnboarding)
                        }
                    }
                    .id(step)
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

    /// Granted (fully or limited) → Find yourself, then the scan. Denied → Home
    /// (camera and the photo picker still work).
    private func handlePhotoPermissionDone() {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan {
            go(to: .findYourself)
        } else {
            completeOnboarding()
        }
    }

    private var trySamplesAction: (() -> Void)? {
        guard SampleLibrary.isAvailable else { return nil }
        return { startSamples() }
    }

    private func startSamples() {
        scanMode = .samples
        go(to: .scanning)
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(dotColor(for: s))
                    .frame(width: s == step ? 22 : 8, height: 8)
            }
        }
        .animation(DS.Motion.snappy, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private func dotColor(for s: Step) -> Color {
        if s == step { return DS.Colors.accent }
        if s.rawValue < step.rawValue { return DS.Colors.accent.opacity(0.5) }
        return DS.Colors.textTertiary.opacity(0.25)
    }

    // MARK: - Navigation

    private func go(to next: Step) {
        Haptics.light()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step = next }
        print("[StyleMate] Onboarding: step \(next)")
    }

    private func completeOnboarding() {
        Haptics.success()
        guard let userId = authService.user?.id else { return }
        onboardingManager.complete(forUser: userId)
        print("[StyleMate] Onboarding: completed")
    }
}
