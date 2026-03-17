import SwiftUI
import Photos

struct OnboardingPhotoPermissionView: View {
    let onComplete: () -> Void

    // MARK: - State

    @State private var permissionState: PermissionPhase = .checking
    @State private var iconVisible = false
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var showCompletion = false
    @State private var checkmarkScale: CGFloat = 0
    @State private var completionTextVisible = false
    @State private var completionSubtitleVisible = false
    @State private var requestContentFade: Double = 1.0

    private enum PermissionPhase {
        case checking
        case notDetermined
        case authorized
        case limited
        case denied
    }

    var body: some View {
        ZStack {
            if showCompletion {
                completionCelebration
            } else {
                permissionContent
                    .opacity(requestContentFade)
            }
        }
        .onAppear {
            checkCurrentStatus()
        }
    }

    // MARK: - Permission Content

    @ViewBuilder
    private var permissionContent: some View {
        switch permissionState {
        case .checking:
            ProgressView()
                .tint(DS.Colors.accent)

        case .notDetermined:
            notDeterminedView

        case .authorized:
            Color.clear.onAppear { triggerCompletion() }

        case .limited:
            limitedAccessView

        case .denied:
            deniedView
        }
    }

    // MARK: - Not Determined

    private var notDeterminedView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
            .scaleEffect(iconVisible ? 1 : 0.3)
            .opacity(iconVisible ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: iconVisible)

            Text("Almost there...")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .offset(y: titleVisible ? 0 : 15)
                .opacity(titleVisible ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: titleVisible)

            Text("Allow photo access to start building your wardrobe automatically.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
                .offset(y: subtitleVisible ? 0 : 10)
                .opacity(subtitleVisible ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: subtitleVisible)

            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                iconVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                titleVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                subtitleVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                requestPhotoAccess()
            }
        }
    }

    // MARK: - Limited Access

    private var limitedAccessView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "photo.badge.exclamationmark.fill")
                .font(.system(size: 40))
                .foregroundColor(DS.Colors.warning)

            Text("Limited Access")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)

            Text("Auto-scan needs full photo access to find your clothing. You can change this in Settings anytime.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)

            Spacer()

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    openSettings()
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(DSPrimaryButton())

                Button {
                    Haptics.light()
                    triggerCompletion()
                } label: {
                    Text("Continue Anyway")
                }
                .buttonStyle(DSSecondaryButton())
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    // MARK: - Denied

    private var deniedView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "photo.badge.exclamationmark.fill")
                .font(.system(size: 40))
                .foregroundColor(DS.Colors.textTertiary)

            Text("Photo Access Needed")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("You can still add clothes manually using your camera. Enable photo access in Settings to unlock auto-scan later.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)

            Spacer()

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    openSettings()
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(DSPrimaryButton())

                Button {
                    Haptics.light()
                    triggerCompletion()
                } label: {
                    Text("Continue Without Scanning")
                        .font(DS.Font.callout)
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(.top, DS.Spacing.micro)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    // MARK: - Completion Celebration

    private var completionCelebration: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 70))
                .foregroundColor(DS.Colors.success)
                .scaleEffect(checkmarkScale)

            Text("You're all set!")
                .font(DS.Font.title1)
                .foregroundColor(DS.Colors.textPrimary)
                .opacity(completionTextVisible ? 1 : 0)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: completionTextVisible)

            Text("Let's build your wardrobe")
                .font(DS.Font.callout)
                .foregroundColor(DS.Colors.textSecondary)
                .opacity(completionSubtitleVisible ? 1 : 0)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: completionSubtitleVisible)

            Spacer()
        }
    }

    // MARK: - Logic

    private func checkCurrentStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("[StyleMate] Photo permission status: \(status.rawValue)")

        switch status {
        case .authorized:
            permissionState = .authorized
        case .limited:
            permissionState = .limited
        case .denied, .restricted:
            permissionState = .denied
        case .notDetermined:
            permissionState = .notDetermined
        @unknown default:
            permissionState = .notDetermined
        }
    }

    private func requestPhotoAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                print("[StyleMate] Photo permission response: \(status.rawValue)")
                switch status {
                case .authorized:
                    triggerCompletion()
                case .limited:
                    permissionState = .limited
                case .denied, .restricted:
                    permissionState = .denied
                default:
                    permissionState = .denied
                }
            }
        }
    }

    private func triggerCompletion() {
        withAnimation(.easeOut(duration: 0.2)) {
            requestContentFade = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showCompletion = true
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                checkmarkScale = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            completionTextVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completionSubtitleVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            onComplete()
        }
        print("[StyleMate] Photo permission: triggering completion celebration")
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
