import SwiftUI

struct ScanProgressBanner: View {
    @ObservedObject var scanService: PhotoScanService
    @Binding var showReview: Bool

    @State private var rotationAngle: Double = 0
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch scanService.scanState {
            case .scanning:
                scanningBanner
            case .completed:
                if scanService.foundItems.isEmpty {
                    emptyCompletedBanner
                } else {
                    completedBanner
                }
            case .error(let message):
                errorBanner(message)
            case .idle:
                EmptyView()
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: scanService.scanState)
    }

    // MARK: - Scanning State

    private var scanningBanner: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .rotationEffect(.degrees(rotationAngle))
                .onAppear {
                    withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                        rotationAngle = 360
                    }
                }
                .onDisappear { rotationAngle = 0 }
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Scanning your photos...")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)

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

                Text("Found \(scanService.itemsFound) items so far")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
    }

    @ViewBuilder
    private var progressCountText: some View {
        let text = "\(scanService.photosScanned) / \(scanService.totalPhotosToScan)"
        if #available(iOS 17.0, *) {
            Text(text)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textTertiary)
                .contentTransition(.numericText())
                .animation(.default, value: scanService.photosScanned)
        } else {
            Text(text)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Completed State (with items)

    private var completedBanner: some View {
        Button {
            Haptics.light()
            showReview = true
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(DS.Colors.success)

                Text("Found \(scanService.foundItems.count) new items!")
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text("Review →")
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
    }

    // MARK: - Completed State (0 items, auto-dismiss)

    private var emptyCompletedBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            Text("Scan complete. No new items found.")
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

    private func errorBanner(_ message: String) -> some View {
        Button {
            Haptics.light()
            Task {
                scanService.scanState = .idle
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
    }
}
