import SwiftUI
import UIKit

/// Profile → About → Diagnostics: the numbers we can't measure in CI (real Neural Engine, real hinge).
/// Phone facts, a benchmark on the bundled sample photos, live stats from real use (PerfLog), the iPhone Duo
/// hinge check, and a plain-text report to share. Nothing leaves the phone unless the user shares the report.
///
/// Duo: two columns on a wide layout (`FoldAwareSplit`, split at the crease when half-open); one column on
/// the cover display and other iPhones.
struct DiagnosticsView: View {
    @EnvironmentObject private var wardrobeViewModel: WardrobeViewModel
    @Environment(\.duoLayout) private var duo
    @ObservedObject private var benchmark = DiagnosticsBenchmark.shared
    @StateObject private var hingeCheck = HingeCheckStore()
    @ObservedObject private var studio = StudioQueue.shared

    @State private var facts: DeviceFacts?
    @State private var live = PerfSnapshot()
    @State private var scan = ScanTrace.Snapshot()
    @State private var hinge = RawHinge()
    @State private var includeStudio = true
    @State private var confirmOnBattery = false
    @State private var confirmReset = false
    @State private var copied = false

    private var hingeAvailable: Bool { duo.hinge != .unavailable || hinge.status != nil }

    var body: some View {
        ScrollView {
            // Everything inside the split, so nothing (not even the intro line) runs across a half-open fold.
            FoldAwareSplit(gutter: DS.Spacing.lg) {
                Text("Numbers for the StyleMate team: how fast the on-device AI runs on this phone. Nothing leaves your phone unless you share the report.")
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                phoneCard
                benchmarkCard
            } trailing: {
                scanCard
                studioCard
                liveCard
                if hingeAvailable { hingeCard }
                shareCard
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("diagnostics.root")
        .modifier(RawHingeReader { hinge = $0 })
        .task {
            #if DEBUG
            DiagnosticsDebugSeed.applyIfRequested()
            #endif
            while !Task.isCancelled {
                facts = DeviceFacts.current()
                live = PerfStore.shared.snapshot
                scan = ScanTrace.shared.snapshot
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .confirmationDialog("Your iPhone isn't charging", isPresented: $confirmOnBattery, titleVisibility: .visible) {
            Button("Run on battery") { startBenchmark() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The benchmark works the phone hard for several minutes. Plugged in, it uses no battery and the numbers are steadier.")
        }
        .alert("Reset live stats?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                PerfStore.shared.reset()
                live = PerfStore.shared.snapshot
            }
        } message: {
            Text("Starts counting again from now. Your wardrobe isn't touched.")
        }
    }

    // MARK: Phone

    private var phoneCard: some View {
        DiagCard(title: "This phone", icon: "iphone") {
            if let f = facts {
                DiagRow("Model", f.modelText)
                DiagRow("System", f.systemVersion)
                DiagRow("App", "\(f.appVersion) (\(f.appBuild)) · \(f.distribution)")
                DiagRow("Temperature", f.thermalText, warn: f.thermalState == "serious" || f.thermalState == "critical")
                DiagRow("Low Power Mode", f.lowPowerMode ? "On" : "Off", warn: f.lowPowerMode)
                DiagRow("Battery", f.batteryText)
                DiagRow("Memory in the phone", DiagFormat.bytes(f.physicalMemoryBytes))
                DiagRow("App is using", DiagFormat.bytes(f.appFootprintBytes))
                if let avail = f.appAvailableMemoryBytes { DiagRow("App can still use", DiagFormat.bytes(avail)) }
                DiagRow("Free storage", DiagFormat.bytes(f.freeDiskBytes))
                DiagRow("AI processors", f.computeDevices.joined(separator: ", "))
                DiagRow("Neural Engine", f.hasNeuralEngine ? "Yes" : "No", warn: !f.hasNeuralEngine)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Benchmark

    private var benchmarkCard: some View {
        DiagCard(title: "Benchmark", icon: "speedometer") {
            Text("Runs the real on-device AI on the 6 sample photos, 3 times: finding clothes, checking faces and making a studio photo. Takes about 5 to 10 minutes on an iPhone. The photo scan pauses meanwhile.")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let f = facts, !f.isCharging, !f.isSimulator {
                Label("Plug in your iPhone first for steady numbers.", systemImage: "bolt.slash.fill")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diagnostics.chargeWarning")
            }

            if benchmark.isRunning {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ProgressView(value: benchmark.progress)
                        .tint(DS.Colors.accent)
                    Text(benchmark.stage)
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Stop") { benchmark.cancel() }
                        .buttonStyle(DSOutlineButton())
                        .accessibilityIdentifier("diagnostics.benchmarkStop")
                }
            } else {
                Toggle("Include a studio photo", isOn: $includeStudio)
                    .font(DS.Font.subheadline)
                    .tint(DS.Colors.accent)
                Button {
                    Haptics.medium()
                    if let f = facts, !f.isCharging, !f.isSimulator { confirmOnBattery = true } else { startBenchmark() }
                } label: {
                    Label(benchmark.last == nil ? "Run benchmark" : "Run again", systemImage: "play.fill")
                }
                .buttonStyle(DSPrimaryButton())
                .accessibilityIdentifier("diagnostics.benchmark")
            }

            if let b = benchmark.last {
                Divider()
                Text("Last run \(b.startedAt.formatted(date: .abbreviated, time: .shortened))\(b.completed ? "" : " (stopped early)")")
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textTertiary)
                if b.coldExtractionSeconds != nil {
                    DiagRow("Finding clothes, first photo", DiagFormat.seconds(b.coldExtractionSeconds))
                    DiagRow("Finding clothes, typical photo", DiagFormat.seconds(b.warmExtractionMedian))
                }
                if b.faceColdSeconds != nil {
                    DiagRow("Face check, typical photo", DiagFormat.seconds(b.faceWarmMedian))
                }
                if !b.studio.isEmpty {
                    DiagRow("Studio photo, typical", DiagFormat.seconds(b.studioMedian))
                }
                DiagRow("Peak memory", DiagFormat.bytes(b.peakMemoryBytes))
                if !b.placements.isEmpty {
                    let onANE = b.placements.filter { $0.neuralEngineShare >= 0.5 }.count
                    DiagRow("Models mostly on the Neural Engine", "\(onANE) of \(b.placements.count)")
                }
                ForEach(b.notes, id: \.self) { note in
                    Text(note)
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func startBenchmark() {
        var options = DiagnosticsBenchmark.Options()
        options.studio = includeStudio
        benchmark.start(options: options, wardrobe: wardrobeViewModel)
    }

    // MARK: Photo scan

    /// What the scan is doing now and how long each step took (ScanTrace): a scan stuck on one
    /// photo shows the step it's waiting on.
    private var scanCard: some View {
        DiagCard(title: "Photo scan", icon: "photo.stack") {
            if scan.isEmpty {
                Text("The scan hasn't run since StyleMate opened.")
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                ForEach(Array(ScanTrace.describe(scan).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("diagnostics.scan")
    }

    // MARK: Product photos

    /// The studio queue: how many pieces have their product photo, and what it's doing or waiting for.
    private var studioCard: some View {
        DiagCard(title: "Product photos", icon: "sparkles") {
            ForEach(Array(studio.describe(items: wardrobeViewModel.items).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("diagnostics.studio")
    }

    // MARK: Live stats

    private var liveCard: some View {
        DiagCard(title: "Live stats", icon: "waveform.path.ecg") {
            if live.isEmpty {
                Text("Nothing measured yet. Numbers appear as StyleMate scans your photos and makes studio photos.")
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let since = live.since {
                    Text("Since \(since.formatted(date: .abbreviated, time: .shortened))")
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                let face = live[.faceIdentity]
                let ex = live[.photoExtraction]
                let st = live[.studioRender]
                DiagRow("Photos checked for your face", face.events.formatted())
                if face.events > 0 { DiagRow("Face check, typical", DiagFormat.seconds(face.recentMedianSeconds)) }
                DiagRow("Photos searched for clothes", ex.events.formatted())
                if ex.events > 0 {
                    DiagRow("Seconds per photo, typical", DiagFormat.seconds(ex.recentMedianSeconds))
                    DiagRow("Items found", ex.totalCount.formatted())
                }
                DiagRow("Studio photos kept / rejected", "\(st.okCount) / \(st.rejectedCount)")
                if st.events > 0 { DiagRow("Studio photo, average", DiagFormat.seconds(st.meanSeconds)) }
                Button("Reset live stats") { confirmReset = true }
                    .buttonStyle(DSTertiaryButton())
                    .font(DS.Font.subheadline)
            }
        }
        .accessibilityIdentifier("diagnostics.live")
    }

    // MARK: Duo hinge

    private var currentReading: HingeReading {
        HingeReading(angle: hinge.angle ?? duo.hingeAngle, layoutAngle: duo.hingeAngle,
                     status: hinge.status?.rawValue ?? duo.hinge.rawValue, posture: duo.posture.rawValue,
                     crease: duo.creaseInGlobal, creaseActive: duo.isCreaseActive, windowSize: duo.windowSize,
                     wideLayout: duo.isWideLayout, at: Date())
    }

    private var hingeCard: some View {
        DiagCard(title: "iPhone Duo hinge", icon: "rectangle.portrait.split.2x1") {
            let r = currentReading
            DiagRow("Angle now", DiagFormat.degrees(r.angle))
            DiagRow("Hinge", DiagFormat.hingeWord(r.status))
            DiagRow("Pose", DiagFormat.postureWord(r.posture))
            DiagRow("Fold", DiagFormat.foldWord(r.crease, active: r.creaseActive))
            if r.crease != nil {
                // The raw values (what the report carries) for whoever is debugging the layout.
                DisclosureGroup("Details") {
                    DiagRow("Fold area", DiagFormat.rect(r.crease))
                    DiagRow("Reported as", "\(r.status), \(r.posture)")
                }
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .accessibilityIdentifier("diagnostics.hinge.details")
            }
            Divider()
            Text("Guided check: do each step, then tap Record. The phone's reading is about 5° accurate.")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(HingeTarget.allCases) { target in
                HingeStepRow(target: target, result: hingeCheck.results[target]) {
                    Haptics.success()
                    hingeCheck.record(HingeCheckResult(target: target, reading: currentReading))
                }
            }
        }
    }

    // MARK: Share

    private var reportText: String {
        DiagnosticsReport.make(facts: facts ?? DeviceFacts.current(), benchmark: benchmark.last, live: live,
                               hingeAvailable: hingeAvailable, hinge: hingeCheck.ordered,
                               liveHinge: hingeAvailable ? currentReading : nil,
                               studio: studio.describe(items: wardrobeViewModel.items))
    }

    private var shareCard: some View {
        DiagCard(title: "Send to the team", icon: "paperplane") {
            Text("A plain-text report of everything on this screen. No photos, faces or wardrobe items are in it.")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ShareLink(item: reportText, subject: Text("StyleMate diagnostics"),
                      preview: SharePreview("StyleMate diagnostics report")) {
                Label("Share report", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(DSPrimaryButton())
            .accessibilityIdentifier("diagnostics.share")
            Button {
                UIPasteboard.general.string = reportText
                Haptics.success()
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(DSOutlineButton())
            .accessibilityIdentifier("diagnostics.copy")
        }
    }
}

// MARK: - Pieces

private struct DiagCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label(title, systemImage: icon)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

/// Label on the left, value on the right; stacked at accessibility text sizes.
private struct DiagRow: View {
    let label: String
    let value: String
    var warn = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ label: String, _ value: String, warn: Bool = false) {
        self.label = label
        self.value = value
        self.warn = warn
    }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DS.Spacing.sm))
        layout {
            Text(label)
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(DS.Font.subheadline.weight(.medium))
                .foregroundStyle(warn ? DS.Colors.warning : DS.Colors.textPrimary)
                .multilineTextAlignment(stacked ? .leading : .trailing)
                .frame(maxWidth: .infinity, alignment: stacked ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HingeStepRow: View {
    let target: HingeTarget
    let result: HingeCheckResult?
    let onRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: result == nil ? "circle" : (result!.asExpected ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                    .foregroundStyle(result == nil ? DS.Colors.textTertiary : (result!.asExpected ? DS.Colors.success : DS.Colors.warning))
                Text(target.title)
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer(minLength: DS.Spacing.xs)
                Button(result == nil ? "Record" : "Again", action: onRecord)
                    .font(DS.Font.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(DS.Colors.accent)
                    .accessibilityIdentifier("diagnostics.hinge.\(target.rawValue)")
            }
            Text(target.instruction)
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let r = result {
                Text("Read \(DiagFormat.degrees(r.reading.angle)), \(DiagFormat.hingeWord(r.reading.status).lowercased()), "
                     + "\(DiagFormat.postureWord(r.reading.posture).lowercased()). \(r.verdict)")
                    .font(DS.Font.footnote.weight(.medium))
                    .foregroundStyle(r.asExpected ? DS.Colors.success : DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DS.Spacing.micro)
    }
}

// MARK: - Hinge check storage

/// The guided check's last reading per step (`Application Support/Diagnostics/hinge-check.json`).
@MainActor
final class HingeCheckStore: ObservableObject {
    @Published private(set) var results: [HingeTarget: HingeCheckResult] = [:]
    private let url = LocalStore.directory("Diagnostics").appendingPathComponent("hinge-check.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.perf.decode([HingeCheckResult].self, from: data) {
            results = Dictionary(saved.map { ($0.target, $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    var ordered: [HingeCheckResult] { HingeTarget.allCases.compactMap { results[$0] } }

    func record(_ result: HingeCheckResult) {
        results[result.target] = result
        if let data = try? JSONEncoder.perf.encode(ordered) { LocalStore.write(data, to: url) }
    }
}

// MARK: - Raw hinge angle

/// The unrounded hinge reading (DuoLayout publishes 5° steps for layout; the check wants the raw value).
struct RawHinge: Equatable {
    var status: DuoHingeState?
    var angle: Double?
}

private struct RawHingeReader: ViewModifier {
    let onChange: (RawHinge) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange(isEnabled: true) { _, context in
                guard let hinge = context.hinge else { onChange(RawHinge(status: .unavailable, angle: nil)); return }
                let degrees = hinge.angle.degrees
                if hinge.status == .closed { onChange(RawHinge(status: .closed, angle: degrees)) }
                else if hinge.status == .partiallyOpen { onChange(RawHinge(status: .partiallyOpen, angle: degrees)) }
                else { onChange(RawHinge(status: .fullyOpen, angle: degrees)) }
            }
        } else {
            content
        }
    }
}

#if DEBUG
/// `-uiTestSeedDiagnostics` (DEBUG only): sample live stats and a sample benchmark, so UI screenshots show the
/// filled-in screen. The numbers are made up and labelled as such.
enum DiagnosticsDebugSeed {
    static let argument = "-uiTestSeedDiagnostics"
    private static var applied = false

    @MainActor
    static func applyIfRequested() {
        guard !applied, ProcessInfo.processInfo.arguments.contains(argument) else { return }
        applied = true
        let now = Date()
        var snap = PerfSnapshot(since: now.addingTimeInterval(-3600))
        var face = PerfAggregate(), ex = PerfAggregate(), st = PerfAggregate()
        for i in 0..<120 { face.add(seconds: 0.12 + Double(i % 5) * 0.01, count: 1, outcome: .ok, at: now) }
        for i in 0..<40 { ex.add(seconds: 3.8 + Double(i % 7) * 0.3, count: 2, outcome: .ok, at: now) }
        for i in 0..<9 { st.add(seconds: 46 + Double(i), count: 0, outcome: i % 4 == 3 ? .rejected : .ok, at: now) }
        snap[.faceIdentity] = face
        snap[.photoExtraction] = ex
        snap[.studioRender] = st
        PerfStore.shared.replace(with: snap)

        var b = BenchmarkResult(startedAt: now.addingTimeInterval(-600))
        b.finishedAt = now.addingTimeInterval(-120)
        b.completed = true
        b.rounds = 3
        b.chargingAtStart = true
        b.thermalAtStart = "nominal"
        b.thermalAtEnd = "fair"
        b.photos = SampleLibrary.credits.map {
            BenchmarkResult.PhotoTiming(name: DiagnosticsBenchmark.shortName($0.file), seconds: [4.2, 3.9, 4.0], items: 4)
        }
        b.coldExtractionSeconds = 11.5
        b.photos[0].seconds[0] = 11.5
        b.faceColdSeconds = 0.9
        b.faceWarmSeconds = Array(repeating: 0.11, count: 17)
        b.facesFound = 6
        b.studio = [.init(seconds: 71, outcome: "kept"), .init(seconds: 48, outcome: "kept"), .init(seconds: 47, outcome: "rejected")]
        b.studioItem = "Trench Coats"
        b.peakMemoryBytes = 1_900_000_000
        b.placements = [ModelPlacement(model: "GarmentNet", shares: ["Neural Engine": 0.97, "CPU": 0.03], operationCount: 812)]
        b.notes = ["Sample numbers for UI screenshots (-uiTestSeedDiagnostics), not a real run."]
        DiagnosticsBenchmark.shared.replaceLast(with: b)
    }
}
#endif
