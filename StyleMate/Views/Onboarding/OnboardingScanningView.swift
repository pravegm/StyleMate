import SwiftUI
import Photos

/// The last onboarding step: the closet fills up in front of the user.
///
/// - **Library**: starts the first scan with the "First 40" pass (the best
///   outfit photos of the last 90 days first, `FirstLook`), with a live counter
///   ("11 items found in 23 photos") and the newest cutouts as they appear.
/// - **Samples**: runs the same pipeline on the bundled sample photos.
///
/// Hands over to Home as soon as there are 8 items, or after 90 s, or when the
/// scan ends; the rest carries on in Home's scan banner and in the background.
struct OnboardingScanningView: View {
    enum Mode { case library, samples }

    let mode: Mode
    let onDone: () -> Void

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var wardrobe: WardrobeViewModel
    @ObservedObject private var scan = PhotoScanService.shared
    @State private var startedAt = Date()
    @State private var now = Date()
    @State private var handingOff = false
    @State private var didFinish = false
    @State private var showSkip = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xs), count: 3)

    private var elapsed: TimeInterval { now.timeIntervalSince(startedAt) }
    private var scanFinished: Bool {
        switch scan.scanState {
        case .completed, .error: return true
        case .idle: return !scan.isWorking && elapsed > 3
        case .scanning: return false
        }
    }

    /// Newest items this run found, newest first.
    private var foundItems: [WardrobeItem] {
        let ids = Set(scan.scanAddedItemIDs)
        return Array(wardrobe.items.filter { ids.contains($0.id) }.reversed().prefix(9))
    }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            header
                .padding(.top, DS.Spacing.lg)

            if foundItems.isEmpty {
                placeholderGrid
            } else {
                LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                    ForEach(foundItems) { item in
                        ItemCutoutTile(image: WardrobeImageFileHelper.loadImage(at: item.thumbnailPath ?? item.imagePath),
                                       height: 104, cornerRadius: 14, inset: 8)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .animation(DS.Motion.bouncy, value: foundItems.map(\.id))
            }

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.xl)
        }
        .onAppear(perform: start)
        .onReceive(ticker) { t in
            now = t
            if elapsed > 12 { showSkip = true }
            checkHandOff()
        }
        .onChange(of: scan.itemsFound) { _ in checkHandOff() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: DS.Spacing.xs) {
            Text(headline)
                .font(DS.Font.title1)
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(FirstLook.counterText(items: scan.itemsFound, photos: scan.photosExamined))
                .font(DS.Font.title3.monospacedDigit())
                .foregroundStyle(DS.Colors.accent)
                .contentTransition(.numericText())
                .animation(DS.Motion.snappy, value: scan.itemsFound)
                .accessibilityIdentifier("onboarding.scanCounter")
            Text(statusLine)
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
        }
    }

    private var headline: String {
        if handingOff && scan.itemsFound == 0 { return "You're all set" }
        if handingOff { return "Your closet is ready" }
        return mode == .samples ? "Building a sample closet" : "Building your closet"
    }

    private var statusLine: String {
        if case .error = scan.scanState, mode == .library {
            // Almost always: the selfie was skipped, so nobody can be recognised yet.
            return "Take a selfie in Profile and StyleMate will start finding your outfits. Until then, add clothes with the camera or from a photo."
        }
        if handingOff {
            return mode == .samples
                ? "The rest of the sample photos finish in the background."
                : "StyleMate keeps looking through your photos while you explore."
        }
        if mode == .samples { return "Cutting out the clothes in a few sample street-style photos, on your iPhone." }
        if scan.isRankingFirstLook { return "Picking your best outfit photos first…" }
        return "Finding you in your photos and cutting out what you wear. Nothing leaves your iPhone."
    }

    private var placeholderGrid: some View {
        LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.backgroundSecondary)
                    .frame(height: 104)
                    .overlay(ProgressView().opacity(i == 0 ? 1 : 0))
                    .opacity(1 - Double(i) * 0.12)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var footer: some View {
        if handingOff {
            Button {
                finish()
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Open my closet")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(DSPrimaryButton())
            .accessibilityIdentifier("onboarding.openCloset")
        } else if showSkip {
            Button("Continue — keep scanning in the background") { finish() }
                .buttonStyle(DSTertiaryButton())
                .font(DS.Font.callout)
                .accessibilityIdentifier("onboarding.skipScanWait")
        }
    }

    // MARK: - Logic

    private func start() {
        startedAt = Date()
        now = startedAt
        guard let user = auth.user, !user.id.isEmpty else { return }
        if wardrobe.currentUserEmail != user.id { wardrobe.load(forUser: user.id) }
        switch mode {
        case .samples:
            SampleLibrary.start(userId: user.id, wardrobe: wardrobe)
        case .library:
            guard !scan.isWorking, PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan else { return }
            let wardrobe = self.wardrobe
            Task {
                if PhotoScanService.shared.hasUnfinishedScan(forUser: user.id) {
                    await PhotoScanService.shared.continueScanning(forUser: user.id, userGender: user.gender,
                                                                   wardrobeViewModel: wardrobe)
                } else {
                    await PhotoScanService.shared.startScan(forUser: user.id, dateRange: Self.firstScanRange,
                                                            userGender: user.gender, wardrobeViewModel: wardrobe,
                                                            trigger: .initial, firstLook: true)
                }
            }
        }
    }

    /// The last 12 months; with Limited access, every photo the user chose
    /// (they picked them on purpose, whatever their date).
    static var firstScanRange: ScanDateRange {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited ? .all : .lastYear
    }

    private func checkHandOff() {
        guard !handingOff, !didFinish else { return }
        guard FirstLook.shouldHandOff(itemsFound: scan.itemsFound, elapsed: elapsed, scanFinished: scanFinished) else { return }
        Haptics.success()
        withAnimation(DS.Motion.smooth) { handingOff = true }
        // Give the "ready" moment a beat, then go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish() }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onDone()
    }
}
