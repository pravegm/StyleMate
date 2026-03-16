import SwiftUI
import Photos

struct OnboardingPhotoPermissionView: View {
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var permissionState: PermissionState = .checking
    @State private var showCompletion = false
    @State private var completionScale: CGFloat = 0

    private enum PermissionState {
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
            }
        }
        .onAppear {
            appeared = true
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
            EmptyView()
                .onAppear { triggerCompletion() }

        case .limited:
            limitedAccessView

        case .denied:
            deniedView
        }
    }

    // MARK: - Not Determined (Request Permission)

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
                    .frame(width: 100, height: 100)

                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
            }
            .scaleEffect(appeared ? 1 : 0.5)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: appeared)

            Text("One last thing...")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .offset(y: appeared ? 0 : 15)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: appeared)

            Text("Allow photo access so we can find your clothes automatically.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
                .offset(y: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.45), value: appeared)

            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                requestPhotoAccess()
            }
        }
    }

    // MARK: - Limited Access

    private var limitedAccessView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 50))
                .foregroundColor(DS.Colors.warning)

            Text("Limited Access")
                .font(DS.Font.title1)
                .foregroundColor(DS.Colors.textPrimary)

            Text("Auto-scan works best with full photo access. You can change this anytime in Settings.")
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

            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 50))
                .foregroundColor(DS.Colors.textTertiary)

            Text("Photo Access Not Granted")
                .font(DS.Font.title1)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("You can still add clothes manually by taking photos or choosing from your gallery. Enable photo access anytime in Settings to unlock auto-scanning.")
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
                }
                .buttonStyle(DSSecondaryButton())
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
                .font(.system(size: 80))
                .foregroundColor(DS.Colors.success)
                .scaleEffect(completionScale)
                .animation(.spring(response: 0.5, dampingFraction: 0.55), value: completionScale)

            Text("You're all set!")
                .font(DS.Font.title1)
                .foregroundColor(DS.Colors.textPrimary)
                .opacity(completionScale > 0.5 ? 1 : 0)
                .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.2), value: completionScale)

            Text("Let's build your wardrobe")
                .font(DS.Font.callout)
                .foregroundColor(DS.Colors.textSecondary)
                .opacity(completionScale > 0.5 ? 1 : 0)
                .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.35), value: completionScale)

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
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            showCompletion = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            completionScale = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            onComplete()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
