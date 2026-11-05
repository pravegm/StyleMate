import Foundation
import os

/// A tiny timing helper for the app's heavy on-device work: an Instruments signpost (Points of Interest,
/// subsystem `com.stylemates.StyleMate`) plus a small persisted aggregate per metric, shown in
/// Profile → About → Diagnostics ("Live stats") and in the shareable report. Nothing leaves the phone.
///
/// Call sites are one line each, at the top-level entry point of the work:
///
///     let perf = PerfLog.begin(.photoExtraction)      // where the work starts
///     ...
///     perf.end(count: items.count)                    // where it ends (count = items found, faces, …)
///
/// or, when the whole function is the work:
///
///     let perf = PerfLog.begin(.faceIdentity); defer { perf.end() }
///
/// `measure(_:_:)` wraps a closure instead. A span that is never ended records nothing (an early return
/// before the work started). Thread-safe; recording costs a lock and a dictionary update; the file is
/// written at most every few seconds on a background queue.
///
/// Adding a metric: add a case to `Metric` (with a `label`, a `signpostName` and the report order in
/// `allCases`). Aggregates of unknown metrics in an older file are ignored.
enum PerfLog {
    enum Metric: String, Codable, CaseIterable, Sendable {
        /// One photo through garment extraction (`ImageAnalysisService.analyzeAndSegment`); count = items found.
        case photoExtraction
        /// Face detect + embed + match for one scanned photo (`FaceMatchingService.resolveIdentityForScan`).
        case faceIdentity
        /// One studio render of a wardrobe item, all candidates + checks (`StudioQueue`); outcome = kept / rejected.
        case studioRender

        /// Plain-language name for the Diagnostics screen and the report.
        var label: String {
            switch self {
            case .photoExtraction: return "Clothes found in a photo"
            case .faceIdentity: return "Face check on a photo"
            case .studioRender: return "Studio photo"
            }
        }

        fileprivate var signpostName: StaticString {
            switch self {
            case .photoExtraction: return "photoExtraction"
            case .faceIdentity: return "faceIdentity"
            case .studioRender: return "studioRender"
            }
        }
    }

    enum Outcome: String, Codable, Sendable {
        /// Finished and kept (a studio render that was accepted; any other finished work).
        case ok
        /// Finished but the result was thrown away (a studio render that didn't look like the item).
        case rejected
        /// Didn't finish (cancelled, model error).
        case failed
    }

    /// A started measurement. Value type: copy it freely, end it once.
    struct Span {
        let metric: Metric
        fileprivate let start: UInt64
        fileprivate let state: OSSignpostIntervalState

        /// Records the elapsed time. `count`: what the work produced (items, faces); `outcome`: see `Outcome`.
        func end(count: Int = 0, outcome: Outcome = .ok) {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
            PerfLog.signposter.endInterval(metric.signpostName, state)
            PerfLog.record(metric, seconds: seconds, count: count, outcome: outcome)
        }
    }

    static let signposter = OSSignposter(subsystem: "com.stylemates.StyleMate", category: .pointsOfInterest)

    /// The store live stats go to. Tests swap in their own.
    static var store = PerfStore.shared

    static func begin(_ metric: Metric) -> Span {
        let state = signposter.beginInterval(metric.signpostName, id: signposter.makeSignpostID())
        return Span(metric: metric, start: DispatchTime.now().uptimeNanoseconds, state: state)
    }

    static func record(_ metric: Metric, seconds: Double, count: Int = 0, outcome: Outcome = .ok) {
        store.record(metric, seconds: seconds, count: count, outcome: outcome)
    }

    /// Times `body` as one event of `metric`. `count` derives the event's count from the result.
    @discardableResult
    static func measure<T>(_ metric: Metric, count: (T) -> Int = { _ in 0 }, _ body: () throws -> T) rethrows -> T {
        let span = begin(metric)
        let value = try body()
        span.end(count: count(value))
        return value
    }

    @discardableResult
    static func measure<T>(_ metric: Metric, count: (T) -> Int = { _ in 0 },
                           _ body: () async throws -> T) async rethrows -> T {
        let span = begin(metric)
        let value = try await body()
        span.end(count: count(value))
        return value
    }
}

// MARK: - Aggregates

/// What the app keeps about one metric: totals plus the last `recentLimit` durations (for a rolling median).
struct PerfAggregate: Codable, Equatable, Sendable {
    static let recentLimit = 50

    var events = 0
    var okCount = 0
    var rejectedCount = 0
    var failedCount = 0
    var totalSeconds: Double = 0
    /// Sum of the events' counts (items found, faces …).
    var totalCount = 0
    var minSeconds: Double?
    var maxSeconds: Double?
    /// The most recent durations, oldest first.
    var recentSeconds: [Double] = []
    var lastAt: Date?

    mutating func add(seconds: Double, count: Int, outcome: PerfLog.Outcome, at date: Date = Date()) {
        guard seconds.isFinite, seconds >= 0 else { return }
        events += 1
        switch outcome {
        case .ok: okCount += 1
        case .rejected: rejectedCount += 1
        case .failed: failedCount += 1
        }
        totalSeconds += seconds
        totalCount += max(0, count)
        minSeconds = min(minSeconds ?? seconds, seconds)
        maxSeconds = max(maxSeconds ?? seconds, seconds)
        recentSeconds.append(seconds)
        if recentSeconds.count > Self.recentLimit { recentSeconds.removeFirst(recentSeconds.count - Self.recentLimit) }
        lastAt = date
    }

    var meanSeconds: Double? { events > 0 ? totalSeconds / Double(events) : nil }
    var recentMedianSeconds: Double? { PerfMath.median(recentSeconds) }
}

/// Every metric's aggregate since `since` (first record, or the last reset).
struct PerfSnapshot: Codable, Equatable, Sendable {
    var since: Date?
    var metrics: [String: PerfAggregate] = [:]

    subscript(metric: PerfLog.Metric) -> PerfAggregate {
        get { metrics[metric.rawValue] ?? PerfAggregate() }
        set { metrics[metric.rawValue] = newValue }
    }

    var isEmpty: Bool { metrics.values.allSatisfy { $0.events == 0 } }
}

/// Thread-safe, persisted `PerfSnapshot` (`Application Support/Diagnostics/perf-stats.json` via `LocalStore`).
final class PerfStore: @unchecked Sendable {
    static let shared = PerfStore(fileURL: LocalStore.directory("Diagnostics").appendingPathComponent("perf-stats.json"))

    /// nil = memory only (tests).
    let fileURL: URL?
    private let lock = NSLock()
    private var current: PerfSnapshot
    private var saveScheduled = false
    private let queue = DispatchQueue(label: "com.stylemates.StyleMate.perfstore", qos: .utility)
    /// Writes are coalesced: at most one per `saveDelay`.
    var saveDelay: TimeInterval = 3

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.perf.decode(PerfSnapshot.self, from: data) {
            current = saved
        } else {
            current = PerfSnapshot()
        }
    }

    var snapshot: PerfSnapshot { lock.withLock { current } }

    func record(_ metric: PerfLog.Metric, seconds: Double, count: Int, outcome: PerfLog.Outcome, at date: Date = Date()) {
        lock.withLock {
            if current.since == nil { current.since = date }
            var agg = current[metric]
            agg.add(seconds: seconds, count: count, outcome: outcome, at: date)
            current[metric] = agg
        }
        scheduleSave()
    }

    func reset() {
        lock.withLock { current = PerfSnapshot() }
        scheduleSave(immediately: true)
    }

    /// Replaces everything (DEBUG seeding for UI screenshots).
    func replace(with snapshot: PerfSnapshot) {
        lock.withLock { current = snapshot }
        scheduleSave(immediately: true)
    }

    /// Writes now (tests; the app relies on the coalesced background write).
    func flush() {
        guard let url = fileURL else { return }
        let snap = snapshot
        if let data = try? JSONEncoder.perf.encode(snap) { LocalStore.write(data, to: url) }
    }

    private func scheduleSave(immediately: Bool = false) {
        guard fileURL != nil else { return }
        let shouldSchedule: Bool = lock.withLock {
            if saveScheduled && !immediately { return false }
            saveScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + (immediately ? 0 : saveDelay)) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.saveScheduled = false }
            self.flush()
        }
    }
}

enum PerfMath {
    static func median(_ values: [Double]) -> Double? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        let mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }
}

extension JSONEncoder {
    static var perf: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var perf: JSONDecoder {
        let d = JSONDecoder()
        return d
    }
}
