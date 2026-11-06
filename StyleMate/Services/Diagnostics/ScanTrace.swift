import Foundation

/// What the photo scan is doing right now, and how long each step has taken, for
/// Profile → About → Diagnostics ("Photo scan") and the shared report. A scan that sits on
/// one photo then shows which step it's waiting on and for how long ("Loading the full
/// photo: 6 min"). Step names and times only: no photo ids, faces or items. In memory only.
///
///     let span = ScanTrace.shared.begin(.fullPhoto)
///     ...
///     ScanTrace.shared.end(span)
final class ScanTrace: @unchecked Sendable {
    static let shared = ScanTrace()

    enum Step: String, CaseIterable, Sendable {
        case library, ranking, thumbnails, personCheck, fullPhoto, faceWait, faceCheck,
             clothesWait, clothes, saving, describing, paused

        var label: String {
            switch self {
            case .library: return "Reading the photo library"
            case .ranking: return "Picking the best outfit photos"
            case .thumbnails: return "Loading thumbnails"
            case .personCheck: return "Looking for a person"
            case .fullPhoto: return "Loading the full photo (may download from iCloud)"
            case .faceWait: return "Waiting to check faces"
            case .faceCheck: return "Checking faces"
            case .clothesWait: return "Waiting to find clothes"
            case .clothes: return "Finding clothes"
            case .saving: return "Saving pieces"
            case .describing: return "Describing a piece (Apple Intelligence)"
            case .paused: return "Paused"
            }
        }
    }

    struct Span: Sendable {
        fileprivate let id: Int
    }

    struct Stat: Sendable {
        var count = 0
        var totalSeconds = 0.0
        var maxSeconds = 0.0
        var lastSeconds = 0.0
    }

    struct Snapshot: Sendable {
        /// Steps under way now, oldest first.
        var active: [(step: Step, since: Date)] = []
        var stats: [Step: Stat] = [:]
        var lastProgress: Date?
        /// Loads the scan stopped waiting for (time limit hit), per step. Those photos are retried later.
        var timeouts: [Step: Int] = [:]
        /// How the scan works on this phone ("Person check: Vision"), in the order set.
        var notes: [(key: String, value: String)] = []
        var isEmpty: Bool { active.isEmpty && stats.isEmpty && timeouts.isEmpty }
    }

    private let lock = NSLock()
    private var nextID = 0
    private var open: [Int: (Step, Date)] = [:]
    private var stats: [Step: Stat] = [:]
    private var lastProgress: Date?
    private var timeouts: [Step: Int] = [:]
    private var notes: [(key: String, value: String)] = []

    func begin(_ step: Step, at now: Date = Date()) -> Span {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        open[nextID] = (step, now)
        return Span(id: nextID)
    }

    func end(_ span: Span, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let (step, started) = open.removeValue(forKey: span.id) else { return }
        let seconds = now.timeIntervalSince(started)
        var s = stats[step] ?? Stat()
        s.count += 1
        s.totalSeconds += seconds
        s.maxSeconds = max(s.maxSeconds, seconds)
        s.lastSeconds = seconds
        stats[step] = s
    }

    /// A photo (or group) finished.
    func noteProgress(at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastProgress = now
    }

    /// A load in `step` hit its time limit (e.g. a thumbnail stuck behind iCloud): the scan moved on.
    func noteTimeout(_ step: Step) {
        lock.lock(); defer { lock.unlock() }
        timeouts[step, default: 0] += 1
    }

    /// A fact about how the scan runs here (set once, e.g. which person check works). Kept across `reset()`.
    func setNote(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = notes.firstIndex(where: { $0.key == key }) { notes[i].value = value } else { notes.append((key, value)) }
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        let active = open.values.sorted { $0.1 < $1.1 }.map { (step: $0.0, since: $0.1) }
        return Snapshot(active: active, stats: stats, lastProgress: lastProgress, timeouts: timeouts, notes: notes)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        open.removeAll()
        stats.removeAll()
        lastProgress = nil
        timeouts.removeAll()
    }

    /// Plain-text lines for the report and the Diagnostics card.
    static func describe(_ snap: Snapshot, now: Date = Date()) -> [String] {
        var out: [String] = []
        if snap.active.isEmpty {
            out.append("Now: nothing running")
        } else {
            for a in snap.active {
                out.append("Now: \(a.step.label), for \(DiagFormat.seconds(now.timeIntervalSince(a.since)))")
            }
        }
        if let p = snap.lastProgress {
            out.append("Last photo finished: \(DiagFormat.seconds(now.timeIntervalSince(p))) ago")
        }
        for step in Step.allCases {
            guard let s = snap.stats[step], s.count > 0 else { continue }
            out.append("\(step.label): \(s.count)×, average \(DiagFormat.seconds(s.totalSeconds / Double(s.count))), "
                       + "slowest \(DiagFormat.seconds(s.maxSeconds)), last \(DiagFormat.seconds(s.lastSeconds))")
        }
        for step in Step.allCases {
            guard let n = snap.timeouts[step], n > 0 else { continue }
            out.append("Gave up waiting (\(step.label)): \(n) photo\(n == 1 ? "" : "s"), retried on a later scan")
        }
        for note in snap.notes { out.append("\(note.key): \(note.value)") }
        return out
    }
}
