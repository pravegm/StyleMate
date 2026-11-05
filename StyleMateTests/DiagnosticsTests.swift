import CoreGraphics
import Foundation
import Testing
@testable import StyleMate

/// PerfLog aggregation and persistence, the Diagnostics report's formatting, the hinge check's verdicts,
/// the Acknowledgements loader, and a tiny real benchmark (face check on one sample photo + one model's
/// compute plan). The report goes to $REPORT_DIR/diagnostics/ (`ci-report`).
@Suite(.serialized)
struct DiagnosticsTests {

    // MARK: PerfLog aggregation

    @Test func aggregateCountsTotalsAndRollingMedian() {
        var a = PerfAggregate()
        a.add(seconds: 2, count: 3, outcome: .ok)
        a.add(seconds: 4, count: 1, outcome: .rejected)
        a.add(seconds: 9, count: 0, outcome: .failed)
        a.add(seconds: -1, count: 5, outcome: .ok)          // ignored
        a.add(seconds: .nan, count: 5, outcome: .ok)        // ignored
        #expect(a.events == 3)
        #expect(a.okCount == 1 && a.rejectedCount == 1 && a.failedCount == 1)
        #expect(a.totalCount == 4)
        #expect(a.meanSeconds == 5)
        #expect(a.recentMedianSeconds == 4)
        #expect(a.minSeconds == 2 && a.maxSeconds == 9)
    }

    @Test func aggregateKeepsOnlyTheLastFiftyDurations() {
        var a = PerfAggregate()
        for i in 0..<120 { a.add(seconds: Double(i), count: 1, outcome: .ok) }
        #expect(a.events == 120)
        #expect(a.recentSeconds.count == PerfAggregate.recentLimit)
        #expect(a.recentSeconds.first == 70 && a.recentSeconds.last == 119)
        #expect(a.recentMedianSeconds == 94.5)
        #expect(a.totalCount == 120)
    }

    @Test func medianHandlesEvenOddAndEmpty() {
        #expect(PerfMath.median([]) == nil)
        #expect(PerfMath.median([3]) == 3)
        #expect(PerfMath.median([5, 1, 3]) == 3)
        #expect(PerfMath.median([4, 1, 3, 2]) == 2.5)
    }

    @Test func storePersistsAndResets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PerfStore(fileURL: url)
        store.record(.photoExtraction, seconds: 4, count: 2, outcome: .ok)
        store.record(.photoExtraction, seconds: 6, count: 1, outcome: .ok)
        store.record(.studioRender, seconds: 50, count: 0, outcome: .rejected)
        store.flush()

        let reloaded = PerfStore(fileURL: url).snapshot
        #expect(reloaded[.photoExtraction].events == 2)
        #expect(reloaded[.photoExtraction].totalCount == 3)
        #expect(reloaded[.studioRender].rejectedCount == 1)
        #expect(reloaded[.faceIdentity].events == 0)
        #expect(reloaded.since != nil)
        #expect(reloaded == store.snapshot)

        store.reset()
        store.flush()
        #expect(store.snapshot.isEmpty)
        #expect(PerfStore(fileURL: url).snapshot.isEmpty)
    }

    @Test func spanRecordsIntoTheLiveStore() {
        let before = PerfLog.store.snapshot[.faceIdentity].events
        let value = PerfLog.measure(.faceIdentity) { 42 }
        let span = PerfLog.begin(.faceIdentity)
        span.end(count: 2)
        #expect(value == 42)
        #expect(PerfLog.store.snapshot[.faceIdentity].events >= before + 2)
    }

    @Test func studioOutcomeMapsToPerfOutcome() {
        #expect(PerfLog.Outcome(StudioPipeline.Outcome.rejected(bestSimilarity: 0.5)) == .rejected)
        #expect(PerfLog.Outcome(StudioPipeline.Outcome.failed) == .failed)
        #expect(PerfLog.Outcome.ok.studioWord == "kept")
    }

    // MARK: Hinge check

    private func reading(_ angle: Double?, _ status: String, _ posture: String) -> HingeReading {
        HingeReading(angle: angle, layoutAngle: angle.map { ($0 / 5).rounded() * 5 }, status: status, posture: posture,
                     crease: CGRect(x: 456, y: 0, width: 40, height: 669), creaseActive: status == "partiallyOpen",
                     windowSize: CGSize(width: 951, height: 669), wideLayout: true, at: Date(timeIntervalSince1970: 0))
    }

    @Test func hingeVerdicts() {
        let flat = HingeCheckResult(target: .flat, reading: reading(178, "fullyOpen", "flat"))
        #expect(flat.asExpected)
        #expect(flat.verdict == "As expected")

        let half = HingeCheckResult(target: .half, reading: reading(115, "partiallyOpen", "book"))
        #expect(!half.asExpected)
        #expect(half.delta == 25)
        #expect(half.verdict == "Check: 25° more than 90°")

        let closed = HingeCheckResult(target: .closed, reading: reading(3, "partiallyOpen", "closed"))
        #expect(closed.angleMatches && !closed.statusMatches)
        #expect(closed.verdict == "Check: status partiallyOpen, expected closed")

        #expect(HingeCheckResult(target: .flat, reading: reading(nil, "unavailable", "noHinge")).verdict == "No angle reported")
    }

    // MARK: Report

    static func sampleFacts() -> DeviceFacts {
        DeviceFacts(modelIdentifier: "iPhone18,2", isSimulator: false, systemVersion: "iOS 27.1", appVersion: "1.0",
                    appBuild: "12", distribution: "TestFlight", thermalState: "nominal", lowPowerMode: false,
                    batteryLevel: 0.84, batteryState: "charging", physicalMemoryBytes: 12 * 1_073_741_824,
                    appAvailableMemoryBytes: 5 * 1_073_741_824, appFootprintBytes: 300 * 1_048_576,
                    freeDiskBytes: 120 * 1_073_741_824, computeDevices: ["CPU", "GPU", "Neural Engine (16 cores)"],
                    hasNeuralEngine: true)
    }

    static func sampleBenchmark() -> BenchmarkResult {
        var b = BenchmarkResult(startedAt: Date(timeIntervalSince1970: 1_793_000_000))
        b.finishedAt = b.startedAt.addingTimeInterval(400)
        b.completed = true
        b.rounds = 3
        b.chargingAtStart = true
        b.thermalAtStart = "nominal"
        b.thermalAtEnd = "fair"
        b.photos = [.init(name: "street coat boots", seconds: [12, 4, 4.2], items: 5),
                    .init(name: "pink coat boots", seconds: [3.8, 4.4, 3.6], items: 4)]
        b.coldExtractionSeconds = 12
        b.faceColdSeconds = 0.8
        b.faceWarmSeconds = [0.1, 0.12, 0.2]
        b.facesFound = 2
        b.studio = [.init(seconds: 70, outcome: "kept", setupSeconds: 20, diffusionSeconds: 39, denoisingSteps: 13, images: 3),
                    .init(seconds: 48, outcome: "kept"), .init(seconds: 50, outcome: "rejected")]
        b.studioItem = "Trench Coats"
        b.peakMemoryBytes = 1_932_735_283
        b.placements = [ModelPlacement(model: "GarmentNet", shares: ["Neural Engine": 0.97, "CPU": 0.03], operationCount: 812),
                        ModelPlacement(model: "Broken", shares: [:], operationCount: 0, error: "load failed")]
        b.notes = ["Stopped by you."]
        return b
    }

    @Test func reportListsEverySectionInPlainLanguage() {
        var live = PerfSnapshot(since: Date(timeIntervalSince1970: 1_792_990_000))
        var ex = PerfAggregate()
        ex.add(seconds: 4, count: 2, outcome: .ok)
        ex.add(seconds: 5, count: 1, outcome: .ok)
        live[.photoExtraction] = ex
        var st = PerfAggregate()
        st.add(seconds: 50, count: 0, outcome: .ok)
        st.add(seconds: 40, count: 0, outcome: .rejected)
        live[.studioRender] = st
        let hinge = [HingeCheckResult(target: .flat, reading: reading(178, "fullyOpen", "flat"))]

        let text = DiagnosticsReport.make(facts: Self.sampleFacts(), benchmark: Self.sampleBenchmark(), live: live,
                                          hingeAvailable: true, hinge: hinge, liveHinge: reading(110, "partiallyOpen", "book"),
                                          now: Date(timeIntervalSince1970: 1_793_000_500))
        let lines = Set(text.components(separatedBy: "\n"))
        #expect(text.hasPrefix("StyleMate diagnostics report\n"))
        #expect(lines.contains("App: 1.0 (12), TestFlight"))
        #expect(lines.contains("Model: iPhone18,2"))
        #expect(lines.contains("Battery: 84%, charging"))
        #expect(lines.contains("Neural Engine: Yes"))
        #expect(lines.contains("AI processors: CPU, GPU, Neural Engine (16 cores)"))
        #expect(lines.contains("Memory: 12.0 GB in the phone; app using 300 MB; 5.0 GB more available to the app"))
        #expect(lines.contains("Finding clothes, first photo (cold start): 12.0 s"))
        // Median of every run but the first: [4, 4.2, 3.8, 4.4, 3.6] -> 4.0
        #expect(lines.contains("Finding clothes, typical photo (median): 4.0 s per photo (6 runs, 9 items on round 1)"))
        #expect(lines.contains("  - street coat boots: 12.0 s, 4.0 s, 4.2 s; median 4.2 s; 5 items"))
        #expect(lines.contains("Face check, typical photo (median): 0.12 s (3 runs, 2 faces on round 1)"))
        #expect(lines.contains("Studio photo (median): 50.0 s per item (3 runs, Trench Coats)"))
        #expect(lines.contains("  - run 1: 1 min 10 s, kept; drawing 39.0 s for 3 images × 13 steps (1.0 s per step per image); model load 20.0 s"))
        #expect(lines.contains("Peak app memory: 1.8 GB"))
        #expect(lines.contains("  - GarmentNet: Neural Engine 97%, CPU 3% (812 ops)"))
        #expect(lines.contains("  - Broken: unknown (load failed) (0 ops)"))
        #expect(lines.contains("Note: Stopped by you."))
        #expect(lines.contains("Photos searched for clothes: 2; typical 4.5 s per photo (last 2), average 4.5 s, slowest 5.0 s"))
        #expect(lines.contains("Items found: 3"))
        #expect(lines.contains("Studio photos: 1 kept, 1 rejected, 0 failed; average 45.0 s, typical 45.0 s"))
        #expect(lines.contains("Open flat (target 180°): angle 178° (layout 180°), status fullyOpen, posture flat, fold x 456, y 0, 40 × 669 pt inactive, window 951 × 669 pt (wide). As expected"))
        #expect(text.contains("Now: angle 110°, status partiallyOpen, posture book"))
        #expect(!text.contains("Photos checked for your face"))   // no face events: no line
    }

    @Test func reportWithNothingYet() {
        let text = DiagnosticsReport.make(facts: Self.sampleFacts(), benchmark: nil, live: PerfSnapshot(),
                                          hingeAvailable: false, hinge: [], liveHinge: nil)
        #expect(text.contains("Not run yet (Diagnostics → Run benchmark)."))
        #expect(text.contains("Nothing measured yet."))
        #expect(text.contains("No hinge on this phone."))
    }

    @Test func benchmarkResultRoundTripsThroughJSON() throws {
        let b = Self.sampleBenchmark()
        let data = try JSONEncoder.perf.encode(b)
        #expect(try JSONDecoder.perf.decode(BenchmarkResult.self, from: data) == b)
        #expect(b.warmExtractionMedian == 4.0)
        #expect(b.extractionRuns == 6)
        #expect(b.studioMedian == 50)
    }

    // MARK: Acknowledgements

    @Test func parsesTitleHeaderLinesAndBody() {
        let a = Acknowledgement.parse(id: "ACK-99-x", text: "# Thing\r\nlicence: MIT License\r\nkind: Code\r\nsource: https://example.com/x\r\n\r\nBody line one\r\ncontinues.\r\n\r\n- bullet\r\n---\r\n## Sub")
        #expect(a.title == "Thing")
        #expect(a.licence == "MIT License")
        #expect(a.kind == "Code")
        #expect(a.source?.absoluteString == "https://example.com/x")
        #expect(MarkdownBlocks.parse(a.body) == [.paragraph("Body line one continues."), .bullet("bullet"), .rule,
                                                 .heading(level: 2, text: "Sub")])
        #expect(Acknowledgement.parse(id: "plain", text: "Just text: here").title == "plain")
    }

    @Test func bundledAcknowledgementsAreListed() throws {
        let all = Acknowledgement.all()
        let ids = all.map(\.id)
        #expect(ids == ids.sorted())
        let siglip = try #require(all.first { $0.id.contains("fashionsiglip") })
        #expect(siglip.licence == "Apache License 2.0")
        #expect(siglip.body.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        #expect(siglip.body.contains("Notice of modification"))
        let sd = try #require(all.first { $0.id.contains("stable-diffusion") })
        #expect(sd.licence == "CreativeML Open RAIL-M")
        #expect(sd.body.contains("Attachment A"))
        #expect(sd.body.contains("You agree not to use the Model or Derivatives of the Model"))
        #expect(all.contains { $0.id.contains("apple-ml-stable-diffusion") && $0.body.contains("MIT License") })
        #expect(all.contains { $0.title.contains("MET Norway") })
        #expect(all.contains { $0.title.contains("Open-Meteo") })
        #expect(all.allSatisfy { !$0.title.isEmpty && $0.source != nil && !$0.body.isEmpty })
    }

    // MARK: Tiny real benchmark

    @MainActor
    @Test(.timeLimit(.minutes(10)))
    func tinyBenchmarkOnOneSamplePhoto() async throws {
        let models = ModelPlacementProbe.bundledModels().map(\.name)
        #expect(models.contains("SCRFD10G"), "bundled models: \(models)")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let bench = DiagnosticsBenchmark(resultURL: url)
        var options = DiagnosticsBenchmark.Options()
        options.rounds = 2
        options.photoLimit = 1
        options.extraction = false
        options.studio = false
        options.placementFilter = { $0 == "SCRFD10G" }
        let result = await bench.run(options: options)

        #expect(result.completed)
        #expect(result.faceColdSeconds != nil)
        #expect(result.faceWarmSeconds.count == 1)
        #expect(result.peakMemoryBytes > 0)
        let placement = try #require(result.placements.first)
        #expect(result.placements.count == 1)
        #expect(placement.error == nil, "compute plan: \(placement.summary)")
        #expect(placement.operationCount > 0)
        let shareSum = placement.shares.values.reduce(0, +)
        #expect(abs(shareSum - 1) < 0.001)
        #expect(bench.last == result)
        // Persisted for the screen.
        #expect(DiagnosticsBenchmark(resultURL: url).last == result)

        let report = DiagnosticsReport.make(facts: DeviceFacts.current(), benchmark: result, live: PerfStore.shared.snapshot,
                                            hingeAvailable: false, hinge: [], liveHinge: nil)
        #expect(report.contains("Face check, first photo (cold start): "))
        #expect(report.contains("  - SCRFD10G: "))
        Self.save(report, "report.txt")
        print("[Report] diagnostics: SCRFD10G \(placement.summary); face cold \(DiagFormat.seconds(result.faceColdSeconds)), warm \(DiagFormat.seconds(result.faceWarmMedian))")
    }

    private static func save(_ text: String, _ name: String) {
        let base = ProcessInfo.processInfo.environment["REPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wardrobe-report")
        let dir = base.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
