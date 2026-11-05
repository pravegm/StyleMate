import CoreML
import Foundation
import UIKit

/// The Diagnostics benchmark: runs the real on-device pipeline on the bundled sample photos
/// (`SampleLibrary`) and times each heavy step, so the founder's first TestFlight session gives us real
/// iPhone numbers (CI only has a simulator CPU: no Neural Engine).
///
/// For `rounds` rounds (default 3; medians are reported):
///   1. garment extraction of every sample photo (`WardrobeExtractor.extract`); the very first is the cold
///      start (model load, and the Neural Engine compile on a first launch);
///   2. face detect + embed of every sample photo (`FaceMatchingService.embedFaces`);
///   3. one studio render of a garment found in the first photo (`StudioPipeline.studioOutcome`, exactly what
///      the background queue runs per item);
/// then 4. where Core ML runs every bundled model (`ModelPlacementProbe`), and the app's peak memory throughout.
///
/// It calls the pipeline below the app's PerfLog hooks, so it never pollutes the live stats. While it runs, the
/// photo scan is paused, the studio queue is stopped and the screen stays on; all three are restored after.
/// Cancellable at any step (a studio render stops at its next denoising step).
@MainActor
final class DiagnosticsBenchmark: ObservableObject {
    static let shared = DiagnosticsBenchmark()

    struct Options {
        var rounds = 3
        var photoLimit = Int.max
        var extraction = true
        var face = true
        var studio = true
        var placements = true
        /// One "On you" try-on (body = a sample photo, pieces = another sample's clothes); a note.
        var tryOn = true
        /// Which models to plan (nil = all bundled).
        var placementFilter: ((String) -> Bool)? = nil
    }

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage = ""
    @Published private(set) var last: BenchmarkResult?

    private var task: Task<Void, Never>?
    private var cancelReason: String?
    private var backgroundObserver: NSObjectProtocol?
    let resultURL: URL?

    init(resultURL: URL? = LocalStore.directory("Diagnostics").appendingPathComponent("benchmark.json")) {
        self.resultURL = resultURL
        if let url = resultURL, let data = try? Data(contentsOf: url) {
            last = try? JSONDecoder.perf.decode(BenchmarkResult.self, from: data)
        }
    }

    /// Starts in the background (the screen's button). `wardrobe` lets the studio queue resume afterwards.
    func start(options: Options = Options(), wardrobe: WardrobeViewModel?) {
        guard !isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let scan = PhotoScanService.shared
            let pausedScan = scan.isWorking && !scan.isPaused
            if pausedScan { scan.pauseScan() }
            StudioQueue.shared.cancel()
            UIApplication.shared.isIdleTimerDisabled = true
            self.backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DiagnosticsBenchmark.shared.cancel(reason: "Stopped: StyleMate left the screen.") }
            }
            _ = await self.run(options: options)
            if let o = self.backgroundObserver { NotificationCenter.default.removeObserver(o) }
            self.backgroundObserver = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if pausedScan { scan.resumeScan() }
            if let wardrobe { StudioQueue.shared.enqueueMissing(wardrobe) }
            self.task = nil
        }
    }

    func cancel(reason: String = "Stopped by you.") {
        guard isRunning, cancelReason == nil else { return }
        cancelReason = reason
        stage = "Stopping…"
        StudioPipeline.generator?.cancelRenders()
    }

    private var isCancelled: Bool { cancelReason != nil || Task.isCancelled }

    /// Runs the benchmark now and returns (and keeps) its result. Unit tests call this directly.
    @discardableResult
    func run(options: Options) async -> BenchmarkResult {
        isRunning = true
        cancelReason = nil
        progress = 0
        let facts = DeviceFacts.current()
        var result = BenchmarkResult(startedAt: Date())
        result.chargingAtStart = facts.isCharging
        result.thermalAtStart = facts.thermalState
        result.rounds = max(1, options.rounds)
        let sampler = PeakMemorySampler()
        sampler.start()

        let samples = Array(zip(SampleLibrary.credits.map(\.file), SampleLibrary.loadImages()).prefix(options.photoLimit))
        let rounds = result.rounds
        let models = options.placements
            ? ModelPlacementProbe.bundledModels().filter { options.placementFilter?($0.name) ?? true } : []
        // Progress weights: a studio render takes about as long as ~8 photos.
        let studioWeight = 8.0
        let total = Double((options.extraction ? samples.count * rounds : 0) + (options.face ? samples.count * rounds : 0) + models.count)
            + (options.studio ? studioWeight * Double(rounds) : 0)
        var done = 0.0
        func advance(_ by: Double = 1) { done += by; progress = total > 0 ? min(1, done / total) : 1 }

        if samples.isEmpty { result.notes.append("The sample photos are missing from this build.") }

        // 1. Garment extraction.
        var studioSource: WardrobeExtractor.Item?
        var tryOnPieces: [WardrobeExtractor.Item] = []
        if options.extraction, !samples.isEmpty {
            if !WardrobeExtractor.isAvailable { result.notes.append("Garment models are missing from this build.") }
            result.photos = samples.map { BenchmarkResult.PhotoTiming(name: Self.shortName($0.0)) }
            outer: for round in 0..<rounds {
                for (i, sample) in samples.enumerated() {
                    if isCancelled { break outer }
                    stage = "Finding clothes: photo \(i + 1) of \(samples.count), round \(round + 1) of \(rounds)"
                    let image = sample.1
                    let (seconds, items) = await Task.detached(priority: .userInitiated) { () -> (Double, [WardrobeExtractor.Item]) in
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let items = autoreleasepool { WardrobeExtractor.extract(from: image) }
                        return (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, items)
                    }.value
                    result.photos[i].seconds.append(seconds)
                    if round == 0 {
                        result.photos[i].items = items.count
                        if i == 0 { result.coldExtractionSeconds = seconds }
                        if studioSource == nil { studioSource = Self.studioCandidate(items) }
                        if tryOnPieces.isEmpty, !sample.0.contains("pink_coat"),
                           items.contains(where: { $0.kind == .innerTop || $0.kind == .outerLayer }),
                           items.contains(where: { $0.kind == .lower }) { tryOnPieces = items }
                    }
                    advance()
                }
            }
        }

        // 2. Face detect + embed.
        if options.face, !samples.isEmpty, !isCancelled {
            var first = true
            outer: for round in 0..<rounds {
                for (i, sample) in samples.enumerated() {
                    if isCancelled { break outer }
                    stage = "Checking faces: photo \(i + 1) of \(samples.count), round \(round + 1) of \(rounds)"
                    guard let cg = sample.1.cgImage else { advance(); continue }
                    let (seconds, faces) = await Task.detached(priority: .userInitiated) { () -> (Double, Int) in
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let n = autoreleasepool { FaceMatchingService.shared.embedFaces(in: cg, padRetry: false).count }
                        return (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, n)
                    }.value
                    if first { result.faceColdSeconds = seconds; first = false } else { result.faceWarmSeconds.append(seconds) }
                    if round == 0 { result.facesFound += faces }
                    advance()
                }
            }
        }

        // 3. Studio render.
        if options.studio, !isCancelled {
            await runStudio(source: studioSource, rounds: rounds, into: &result, weight: studioWeight, advance: advance)
        }

        // 3b. One try-on (timing note only).
        if options.tryOn, !isCancelled, !tryOnPieces.isEmpty,
           let body = samples.first(where: { $0.0.contains("pink_coat") })?.1.cgImage {
            stage = "Dressing a sample photo (On you)"
            let pieces = tryOnPieces
            let note = await Task.detached(priority: .userInitiated) { () async -> String in
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard case .success(let model) = TryOnBodyAnalyzer.analyze(body) else { return "On you: the sample body couldn't be analysed." }
                let t1 = DispatchTime.now().uptimeNanoseconds
                let garments = pieces.compactMap { item -> TryOnGarmentSpec? in
                    guard let cg = item.cutout.cgImage else { return nil }
                    let role: TryOnRole
                    switch item.kind {
                    case .innerTop: role = .top
                    case .outerLayer: role = .outer
                    case .onePiece: role = .onePiece
                    case .lower: role = .bottom
                    case .footwear: role = .shoes
                    default: return nil
                    }
                    return TryOnGarmentSpec(role: role, product: item.attributes.product, image: cg)
                }
                let outcome = await TryOnRenderer.render(body: model, garments: garments, harmonize: true)
                let t2 = DispatchTime.now().uptimeNanoseconds
                let verdict: String
                switch outcome {
                case .ready(let r): verdict = r.harmonized ? "kept (with the diffusion pass)" : "kept (composite only)"
                case .rejected(let rep, _): verdict = "shown as pieces (\(rep.rejection ?? ""))"
                case .failed(let why): verdict = "failed (\(why))"
                }
                return String(format: "On you: body analysis %.1f s, try-on %.1f s, %@.",
                              Double(t1 - t0) / 1e9, Double(t2 - t1) / 1e9, verdict)
            }.value
            result.notes.append(note)
            TryOnHarmonizer.shared.unload()
        }

        // 4. Where each model runs.
        for (k, model) in models.enumerated() {
            if isCancelled { break }
            stage = "Checking where each model runs (\(k + 1) of \(models.count))"
            let placement = await Task.detached(priority: .userInitiated) {
                await ModelPlacementProbe.placement(name: model.name, url: model.url)
            }.value
            result.placements.append(placement)
            advance()
        }

        sampler.stop()
        result.peakMemoryBytes = sampler.peakBytes
        result.thermalAtEnd = DeviceFacts.word(ProcessInfo.processInfo.thermalState)
        result.finishedAt = Date()
        if let reason = cancelReason { result.notes.insert(reason, at: 0) }
        result.completed = cancelReason == nil
        last = result
        save(result)
        stage = cancelReason == nil ? "Done" : "Stopped"
        progress = cancelReason == nil ? 1 : progress
        cancelReason = nil
        isRunning = false
        return result
    }

    private func runStudio(source: WardrobeExtractor.Item?, rounds: Int, into result: inout BenchmarkResult,
                           weight: Double, advance: (Double) -> Void) async {
        guard let generator = StudioPipeline.generator, generator.isAvailable else {
            result.notes.append("Studio photo skipped: the studio models aren't in this build.")
            advance(weight * Double(rounds)); return
        }
        guard let item = source, let cg = item.cutout.cgImage else {
            result.notes.append("Studio photo skipped: no garment was found to render (it needs the clothes step).")
            advance(weight * Double(rounds)); return
        }
        if let free = MemoryProbe.availableToApp, free < StudioQueue.minFreeMemory {
            result.notes.append("Studio photo skipped: only \(DiagFormat.bytes(free)) of memory free (needs \(DiagFormat.bytes(StudioQueue.minFreeMemory))).")
            advance(weight * Double(rounds)); return
        }
        let a = item.attributes
        let plan = StudioPlan.make(product: a.product, category: a.category, colors: a.colors, pattern: a.pattern,
                                   material: a.material, sleeve: a.sleeveLength, neckline: a.neckline, details: nil,
                                   kind: item.kind, truncated: item.truncated, cutout: cg, embedding: a.embedding, fit: a.fit)
        result.studioItem = a.product
        let cutout = item.cutout, embedding = a.embedding
        for run in 0..<rounds {
            if isCancelled { break }
            stage = "Making a studio photo: \(run + 1) of \(rounds) (about a minute each on an iPhone)"
            let renderer = generator as? StudioRenderer
            let (seconds, outcome, stats) = await Task.detached(priority: .userInitiated) {
                () -> (Double, StudioPipeline.Outcome, StudioRenderer.RenderStats?) in
                let t0 = DispatchTime.now().uptimeNanoseconds
                let o = StudioPipeline.studioOutcome(cutout: cutout, embedding: embedding, plan: plan,
                                                     seedBase: 4242 &+ UInt32(run))
                return (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, o, renderer?.lastStats)
            }.value
            var r = BenchmarkResult.StudioRun(seconds: seconds, outcome: PerfLog.Outcome(outcome).studioWord)
            if let s = stats {
                r.setupSeconds = s.setupSeconds
                r.diffusionSeconds = s.totalSeconds - s.setupSeconds
                r.denoisingSteps = s.denoisingSteps
                r.images = s.imageCount
            }
            if case .failed = outcome, isCancelled { break }   // a cancelled render isn't a timing
            result.studio.append(r)
            advance(weight)
        }
        generator.unload()
    }

    /// A garment the studio renders the way it does most items: a top or layer first.
    private static func studioCandidate(_ items: [WardrobeExtractor.Item]) -> WardrobeExtractor.Item? {
        let preferred: [GarmentKind] = [.outerLayer, .innerTop, .onePiece, .lower]
        for kind in preferred { if let i = items.first(where: { $0.kind == kind }) { return i } }
        return items.first
    }

    static func shortName(_ file: String) -> String {
        var s = (file as NSString).deletingPathExtension
        if s.hasPrefix("sample_") { s.removeFirst("sample_".count) }
        return s.replacingOccurrences(of: "_", with: " ")
    }

    private func save(_ result: BenchmarkResult) {
        guard let url = resultURL, let data = try? JSONEncoder.perf.encode(result) else { return }
        LocalStore.write(data, to: url)
    }

    /// DEBUG: shows a finished result without running (UI screenshots).
    func replaceLast(with result: BenchmarkResult?) {
        last = result
        if let result { save(result) }
    }
}

extension PerfLog.Outcome {
    /// A studio render's outcome: kept, rejected (no candidate looked like the item), failed.
    init(_ outcome: StudioPipeline.Outcome) {
        switch outcome {
        case .rendered: self = .ok
        case .rejected: self = .rejected
        case .failed: self = .failed
        }
    }

    var studioWord: String {
        switch self {
        case .ok: return "kept"
        case .rejected: return "rejected"
        case .failed: return "failed"
        }
    }
}
