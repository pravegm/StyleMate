import SwiftUI
import Photos

struct ScanRangePickerView: View {
    @Binding var isPresented: Bool
    let userId: String
    let onStartScan: (ScanDateRange) -> Void

    /// "All photos" is the default: it's what builds a complete wardrobe, and it
    /// costs nothing up front — the scan runs newest first, items appear as they
    /// are found, and it continues in the background and overnight.
    @State private var selectedOption: ScanOption? = .allPhotos
    @State private var customFromDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @State private var customToDate = Date()
    @State private var counts: [ScanOption: ScanOption.Count] = [:]
    @State private var isLoadingCounts = true
    @State private var scanHistory: ScanHistoryInfo?

    private var isScanRunning: Bool {
        PhotoScanService.shared.scanState == .scanning
    }

    private var dateRange: ScanDateRange? {
        guard let option = selectedOption else { return nil }
        switch option {
        case .lastMonth: return .lastMonth
        case .lastSixMonths: return .lastSixMonths
        case .lastYear: return .lastYear
        case .allPhotos: return .all
        case .custom: return .custom(from: customFromDate, to: customToDate)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    headerSection
                    allPhotosCard
                    shorterPeriods
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.md)
            }
            .safeAreaInset(edge: .bottom) {
                startButton
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Colors.backgroundPrimary)
            }
            .background(DS.Colors.backgroundPrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(DS.Colors.backgroundSecondary)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            loadData()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Scan Photos for Clothing")
                .font(DS.Font.title3)
                .foregroundColor(DS.Colors.textPrimary)

            Text("StyleMate finds the photos of you and adds what you're wearing. Everything stays on your iPhone.")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let history = scanHistory, let lastDate = history.lastScanDate {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text("Last scanned \(lastDate, style: .relative) ago · \(history.totalScannedAssets.formatted()) photos so far")
                        .font(DS.Font.caption1)
                }
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, DS.Spacing.micro)
            }
        }
    }

    // MARK: - All photos (hero)

    private var allPhotosCard: some View {
        let selected = selectedOption == .allPhotos
        return Button {
            Haptics.selection()
            selectedOption = .allPhotos
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(selected ? .white : DS.Colors.accent)
                        .frame(width: 44, height: 44)
                        .background(selected ? DS.Colors.accent : DS.Colors.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Spacing.xs) {
                            Text("All photos")
                                .font(DS.Font.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Best results")
                                .font(DS.Font.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, DS.Spacing.xs)
                                .padding(.vertical, 2)
                                .background(DS.Colors.accent, in: Capsule())
                        }
                        Text("Your whole wardrobe, from every photo of you")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    radio(selected)
                }

                countLabel(for: .allPhotos)

                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    bullet("sparkles", "Newest photos first — items appear as they're found")
                    bullet("moon.zzz.fill", "Keeps going overnight while your iPhone charges")
                    bullet("lock.fill", "Nothing leaves your iPhone")
                }
            }
            .padding(DS.Spacing.md)
            .background(selected ? DS.Colors.accent.opacity(0.06) : DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(selected ? DS.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All photos. Best results. \(accessibilityCount(for: .allPhotos))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 16)
            Text(text)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - Shorter periods

    private var shorterPeriods: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Or a shorter period")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.leading, DS.Spacing.micro)

            ForEach(ScanOption.shorterPeriods) { option in
                optionRow(option)
            }

            if selectedOption == .custom {
                customDatePickers
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedOption)
    }

    private func optionRow(_ option: ScanOption) -> some View {
        Button {
            Haptics.selection()
            selectedOption = option
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                radio(selectedOption == option)

                Text(option.label)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                if option != .custom { countLabel(for: option) }
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            .background(
                selectedOption == option
                    ? DS.Colors.accent.opacity(0.06)
                    : DS.Colors.backgroundCard
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .stroke(
                        selectedOption == option ? DS.Colors.accent.opacity(0.3) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.label). \(option == .custom ? "" : accessibilityCount(for: option))")
        .accessibilityAddTraits(selectedOption == option ? .isSelected : [])
    }

    private func radio(_ selected: Bool) -> some View {
        Circle()
            .strokeBorder(selected ? DS.Colors.accent : DS.Colors.textTertiary, lineWidth: 2)
            .frame(width: 20, height: 20)
            .overlay {
                if selected {
                    Circle()
                        .fill(DS.Colors.accent)
                        .frame(width: 10, height: 10)
                }
            }
    }

    @ViewBuilder
    private func countLabel(for option: ScanOption) -> some View {
        if isLoadingCounts {
            ProgressView()
                .scaleEffect(0.7)
        } else if let count = counts[option] {
            Text(count.summary)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func accessibilityCount(for option: ScanOption) -> String {
        counts[option]?.summary ?? "Counting photos"
    }

    private var customDatePickers: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack {
                Text("From")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                DatePicker("", selection: $customFromDate, in: ...customToDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            HStack {
                Text("To")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                DatePicker("", selection: $customToDate, in: customFromDate...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
    }

    // MARK: - Start Button

    private var startButton: some View {
        VStack(spacing: DS.Spacing.xs) {
            if isScanRunning {
                Text("A scan is already in progress")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.warning)
            }

            Button {
                Haptics.medium()
                if isScanRunning {
                    PhotoScanService.shared.cancelScan()
                }
                if let range = dateRange {
                    onStartScan(range)
                }
            } label: {
                HStack {
                    Spacer()
                    Text(isScanRunning ? "Cancel Current & Start New" : "Start Scanning")
                    Spacer()
                }
            }
            .buttonStyle(DSPrimaryButton(isDisabled: selectedOption == nil))
            .disabled(selectedOption == nil)
            .opacity(selectedOption == nil ? 0.5 : 1.0)
            .accessibilityLabel(isScanRunning ? "Cancel current scan and start new" : "Start scanning")
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        var scanned: Set<String> = []
        if !userId.isEmpty {
            scanHistory = PhotoScanService.shared.getScanHistory(forUser: userId)
            scanned = PhotoScanService.shared.loadProgress(forUser: userId).scannedAssetIDs
        }
        let alreadyScanned = scanned
        Task.detached(priority: .userInitiated) {
            let result = ScanOption.countLibrary(scanned: alreadyScanned)
            await MainActor.run {
                counts = result
                isLoadingCounts = false
            }
        }
    }
}

// MARK: - Scan Option

enum ScanOption: String, CaseIterable, Identifiable {
    case allPhotos
    case lastMonth
    case lastSixMonths
    case lastYear
    case custom

    var id: String { rawValue }

    static let shorterPeriods: [ScanOption] = [.lastMonth, .lastSixMonths, .lastYear, .custom]

    var label: String {
        switch self {
        case .lastMonth: return "Last month"
        case .lastSixMonths: return "Last 6 months"
        case .lastYear: return "Last 12 months"
        case .allPhotos: return "All photos"
        case .custom: return "Custom range"
        }
    }

    /// Photos in a range, and how many of them haven't been scanned yet.
    struct Count: Equatable {
        var total = 0
        var remaining = 0

        /// "~2,340 photos · about 15 min", "120 new of 2,340 · about 1 min",
        /// "All 2,340 scanned".
        var summary: String {
            if total == 0 { return "No photos" }
            if remaining == 0 { return "All \(total.formatted()) scanned" }
            let time = ScanETA.describeDuration(ScanETA.estimate(photoCount: remaining))
            if remaining < total { return "\(remaining.formatted()) new of \(total.formatted()) · \(time)" }
            return "~\(total.formatted()) photos · \(time)"
        }
    }

    /// One pass over the library (call off the main thread).
    static func countLibrary(scanned: Set<String>, now: Date = Date()) -> [ScanOption: Count] {
        let ranges: [(ScanOption, ScanDateRange)] = [
            (.allPhotos, .all), (.lastMonth, .lastMonth), (.lastSixMonths, .lastSixMonths), (.lastYear, .lastYear),
        ]
        let starts = ranges.map { ($0.0, $0.1.bounds(now: now).start) }
        var result: [ScanOption: Count] = [:]
        for (option, _) in ranges { result[option] = Count() }
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in
            let date = asset.creationDate
            let done = scanned.contains(asset.localIdentifier)
            for (option, start) in starts {
                if let start {
                    guard let date, date >= start else { continue }
                }
                result[option]?.total += 1
                if !done { result[option]?.remaining += 1 }
            }
        }
        return result
    }
}
