import SwiftUI

struct ScanProgressBanner: View {
    @ObservedObject var scanService: PhotoScanService
    @Binding var showReview: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService

    @State private var autoDismissTask: Task<Void, Never>?
    @State private var showSelfie = false

    var body: some View {
        Group {
            switch scanService.scanState {
            case .scanning:
                scanningBanner
            case .completed:
                if scanService.scanAddedItemIDs.isEmpty {
                    emptyCompletedBanner
                } else {
                    completedBanner
                }
            case .error:
                errorBanner
            case .idle:
                if scanService.pendingReviewCount > 0 { pendingReviewBanner } else { EmptyView() }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: scanService.scanState)
        .task(id: wardrobeViewModel.currentUserEmail) {
            guard !wardrobeViewModel.currentUserEmail.isEmpty else { return }
            _ = scanService.pendingReviews(forUser: wardrobeViewModel.currentUserEmail)
        }
        .sheet(isPresented: $showFaceReview) {
            FaceReviewView(scanService: scanService, isPresented: $showFaceReview)
                .environmentObject(wardrobeViewModel)
        }
    }

    @State private var showFaceReview = false

    // MARK: - "Is this you?" pending

    private var pendingReviewBanner: some View {
        Button {
            Haptics.light()
            showFaceReview = true
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scanService.pendingReviewCount) more photo\(scanService.pendingReviewCount == 1 ? "" : "s") might be you")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Confirm them to add those outfits")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(DS.Spacing.md)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow()
        }
        .buttonStyle(DSTapBounce())
        .accessibilityHint("Opens a grid of photos to confirm")
    }

    // MARK: - Scanning State

    private var scanningBanner: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: scanService.isPaused ? "pause.circle.fill" : "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.Colors.accent)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative.reversing, isActive: !scanService.isPaused)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(scanService.isPaused ? "Scan paused"
                     : (scanService.systemPauseReason ?? "Building your wardrobe…"))
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(scanService.progressDetail)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: DS.Spacing.xs) {
                    ProgressView(
                        value: scanService.totalPhotosToScan > 0
                            ? Double(scanService.photosScanned) / Double(scanService.totalPhotosToScan)
                            : 0
                    )
                    .tint(DS.Colors.accent)
                    .frame(height: 4)

                    progressCountText
                }

                Text("Added \(scanService.itemsFound) items to your wardrobe")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer(minLength: DS.Spacing.xs)

            Button {
                Haptics.light()
                scanService.togglePause()
            } label: {
                Image(systemName: scanService.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(scanService.isPaused ? "Resume scan" : "Pause scan")
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var progressCountText: some View {
        let text = "\(scanService.photosScanned) / \(scanService.totalPhotosToScan)"
        if #available(iOS 17.0, *) {
            Text(text)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textSecondary)
                .contentTransition(.numericText())
                .animation(.default, value: scanService.photosScanned)
        } else {
            Text(text)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - Completed State (with items)

    private var completedBanner: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(DS.Colors.success)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scanService.pendingReviewCount > 0
                     ? "Added \(scanService.scanAddedItemIDs.count) items · \(scanService.pendingReviewCount) photos to confirm"
                     : "Added \(scanService.scanAddedItemIDs.count) items to your wardrobe!")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Check your Wardrobe tab to see them")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()
            }

            Button {
                Haptics.light()
                autoDismissTask?.cancel()
                showReview = true
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                    Text("Review & remove any mistakes")
                        .font(DS.Font.caption1)
                }
                .foregroundColor(DS.Colors.accent)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan complete. Added \(scanService.scanAddedItemIDs.count) items to your wardrobe.")
        .onAppear {
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                scanService.dismissCompleted()
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }

    // MARK: - Completed State (0 items, auto-dismiss)

    private var emptyCompletedBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            // Past the free tier's 50, new finds wait for Premium (Home's card) instead of joining the closet.
            let waiting = wardrobeViewModel.lockedItems.count
            Text(waiting > 0 ? "Scan complete. \(waiting) piece\(waiting == 1 ? " is" : "s are") waiting for Premium."
                             : "Scan complete. No new items found.")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .onAppear {
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                scanService.dismissCompleted()
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }

    // MARK: - Error State

    /// The scan can't start without a selfie to recognise the person by.
    private var needsSelfie: Bool {
        if case .error(let message) = scanService.scanState {
            return message.localizedCaseInsensitiveContains("selfie")
        }
        return false
    }

    @ViewBuilder
    private var errorBanner: some View {
        if needsSelfie { selfieBanner } else { retryBanner }
    }

    private var selfieBanner: some View {
        Button {
            Haptics.light()
            showSelfie = true
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take a selfie so we can find you")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("StyleMate matches it to your photos, on your iPhone")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: DS.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(DS.Spacing.md)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow()
        }
        .buttonStyle(DSTapBounce())
        .accessibilityHint("Opens the camera for a selfie")
        .accessibilityIdentifier("scan.takeSelfie")
        .sheet(isPresented: $showSelfie, onDismiss: {
            // Try again with the new selfie (a cancelled sheet just shows the banner again).
            Task { await scanService.retryScan(wardrobeViewModel: wardrobeViewModel) }
        }) {
            RetakeSelfieSheet()
                .environmentObject(authService)
        }
    }

    private var retryBanner: some View {
        Button {
            Haptics.light()
            Task {
                await scanService.retryScan(wardrobeViewModel: wardrobeViewModel)
            }
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.warning)

                Text("Scan paused")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text("Retry →")
                    .font(DS.Font.callout)
                    .foregroundColor(DS.Colors.accent)
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow()
        }
        .buttonStyle(DSTapBounce())
        .accessibilityLabel("Scan paused. Double tap to retry.")
        .accessibilityHint("Retries the photo scan")
    }
}
