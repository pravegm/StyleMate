import SwiftUI
import Photos

/// Onboarding step 3: why StyleMate needs the photo library, then the system
/// prompt on one tap. Limited access is handled, not punished: StyleMate
/// explains it will only see the photos picked, offers "Select more photos",
/// and still scans whatever is shared. Denied → the app still works with the
/// camera and the photo picker.
struct OnboardingPhotoPermissionView: View {
    let onComplete: () -> Void

    @State private var permissionState: PermissionPhase = .checking
    @State private var sharedCount = 0
    @State private var appeared = false
    @State private var requestContentFade: Double = 1.0

    private enum PermissionPhase {
        case checking, notDetermined, authorized, limited, denied
    }

    var body: some View {
        content
            .opacity(requestContentFade)
            .onAppear {
                checkCurrentStatus()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch permissionState {
        case .checking:
            ProgressView().tint(DS.Colors.accent)
        case .notDetermined:
            askView
        case .authorized:
            Color.clear.onAppear { triggerCompletion() }
        case .limited:
            limitedView
        case .denied:
            deniedView
        }
    }

    // MARK: - Ask

    private var askView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            icon("photo.stack.fill", tint: DS.Colors.accent)

            Text("Let StyleMate find your outfits")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                bullet("sparkles", "Starts with your best outfit photos from the last few months, so your closet fills up in minutes")
                bullet("person.crop.square", "Only photos of you are used, and only your clothes, never other people's")
                bullet("lock.shield.fill", "Photos are looked at on this iPhone and never uploaded")
            }
            .padding(.horizontal, DS.Spacing.xl)

            Spacer()

            Button {
                Haptics.medium()
                requestPhotoAccess()
            } label: {
                Text("Allow photo access")
            }
            .buttonStyle(DSPrimaryButton())
            .accessibilityIdentifier("onboarding.allowPhotos")
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
    }

    // MARK: - Limited

    private var limitedView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            icon("photo.badge.checkmark.fill", tint: DS.Colors.warning)

            Text(sharedCount == 0 ? "No photos shared yet" : "You shared \(sharedCount) photo\(sharedCount == 1 ? "" : "s")")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("StyleMate can only see the photos you pick, so it will find fewer of your outfits. Pick photos where you're wearing different clothes, or allow all photos in Settings. Either way they're only looked at on this iPhone.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)

            Spacer()

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    LibraryFaceScanner.presentLimitedLibraryPicker { refreshSharedCount() }
                } label: {
                    Text("Select more photos")
                }
                .buttonStyle(DSPrimaryButton())

                Button {
                    Haptics.light()
                    triggerCompletion()
                } label: {
                    Text(sharedCount == 0 ? "Continue without photos" : "Continue with \(sharedCount) photo\(sharedCount == 1 ? "" : "s")")
                }
                .buttonStyle(DSSecondaryButton())

                Button("Allow all photos in Settings") {
                    Haptics.light()
                    openSettings()
                }
                .font(DS.Font.callout)
                .foregroundColor(DS.Colors.accent)
                .padding(.top, DS.Spacing.micro)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
        .onAppear { refreshSharedCount() }
    }

    // MARK: - Denied

    private var deniedView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            icon("photo.badge.exclamationmark.fill", tint: DS.Colors.textTertiary)

            Text("Photo access is off")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("You can still add clothes with the camera or by picking photos one at a time. Turn on photo access in Settings anytime to let StyleMate build your closet for you.")
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
                    Text("Continue without scanning")
                        .font(DS.Font.callout)
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(.top, DS.Spacing.micro)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    // MARK: - Pieces

    private func icon(_ name: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 90, height: 90)
            Image(systemName: name)
                .font(.system(size: 40))
                .foregroundColor(.white)
        }
        .accessibilityHidden(true)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 28, height: 28)
                .background(DS.Colors.accent.opacity(0.1), in: Circle())
            Text(text)
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Logic

    private func checkCurrentStatus() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: permissionState = .authorized
        case .limited: permissionState = .limited
        case .denied, .restricted: permissionState = .denied
        case .notDetermined: permissionState = .notDetermined
        @unknown default: permissionState = .notDetermined
        }
    }

    private func requestPhotoAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                print("[StyleMate] Photo permission response: \(status.rawValue)")
                switch status {
                case .authorized: triggerCompletion()
                case .limited: permissionState = .limited
                default: permissionState = .denied
                }
            }
        }
    }

    private func refreshSharedCount() {
        Task.detached(priority: .userInitiated) {
            let n = PHAsset.fetchAssets(with: .image, options: nil).count
            await MainActor.run { sharedCount = n }
        }
    }

    private func triggerCompletion() {
        withAnimation(.easeOut(duration: 0.2)) { requestContentFade = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onComplete() }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
