import SwiftUI
import Photos

struct ScanRangePickerView: View {
    @Binding var isPresented: Bool
    let userId: String
    let onStartScan: (ScanDateRange) -> Void

    @State private var selectedOption: ScanOption? = nil
    @State private var customFromDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @State private var customToDate = Date()
    @State private var photoCounts: [ScanOption: Int] = [:]
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
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                headerSection
                scanHistorySection
                optionsList
                Spacer()
                startButton
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.md)
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
                }
            }
        }
        .presentationDetents([.medium, .large])
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

            Text("Choose a time period")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - Scan History

    @ViewBuilder
    private var scanHistorySection: some View {
        if let history = scanHistory, let lastDate = history.lastScanDate {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)

                Text("Last scanned: \(lastDate, style: .relative) ago")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    // MARK: - Options List

    private var optionsList: some View {
        VStack(spacing: DS.Spacing.xs) {
            ForEach(ScanOption.allCases) { option in
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
                Circle()
                    .strokeBorder(
                        selectedOption == option ? DS.Colors.accent : DS.Colors.textTertiary,
                        lineWidth: 2
                    )
                    .frame(width: 20, height: 20)
                    .overlay {
                        if selectedOption == option {
                            Circle()
                                .fill(DS.Colors.accent)
                                .frame(width: 10, height: 10)
                        }
                    }

                Text(option.label)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Colors.textPrimary)

                if option.isRecommended(scanHistory: scanHistory) {
                    Text("Recommended")
                        .font(DS.Font.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(DS.Colors.accent, in: Capsule())
                }

                Spacer()

                if isLoadingCounts {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if let count = photoCounts[option] {
                    Text("~\(count.formatted()) photos")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                }
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
        .accessibilityLabel("\(option.label). \(photoCounts[option].map { "Approximately \($0) photos" } ?? "Loading")")
        .accessibilityAddTraits(selectedOption == option ? .isSelected : [])
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
        if !userId.isEmpty {
            scanHistory = PhotoScanService.shared.getScanHistory(forUser: userId)
        }

        Task.detached {
            var counts: [ScanOption: Int] = [:]
            for option in ScanOption.allCases where option != .custom {
                let range: ScanDateRange
                switch option {
                case .lastMonth: range = .lastMonth
                case .lastSixMonths: range = .lastSixMonths
                case .lastYear: range = .lastYear
                case .allPhotos: range = .all
                case .custom: continue
                }
                counts[option] = PhotoScanService.shared.estimatePhotoCount(for: range)
            }
            await MainActor.run {
                photoCounts = counts
                isLoadingCounts = false
            }
        }
    }
}

// MARK: - Scan Option

enum ScanOption: String, CaseIterable, Identifiable {
    case lastMonth
    case lastSixMonths
    case lastYear
    case allPhotos
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastMonth: return "Last month"
        case .lastSixMonths: return "Last 6 months"
        case .lastYear: return "Last year"
        case .allPhotos: return "All photos"
        case .custom: return "Custom range"
        }
    }

    func isRecommended(scanHistory: ScanHistoryInfo?) -> Bool {
        if scanHistory?.lastScanDate != nil {
            return self == .lastYear
        }
        return self == .lastSixMonths
    }
}
