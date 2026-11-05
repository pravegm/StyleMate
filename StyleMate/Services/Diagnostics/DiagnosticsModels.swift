import CoreGraphics
import Foundation

// Value types behind the Diagnostics screen: the benchmark's result, the Duo hinge check, and the plain-text
// report the founder shares. Pure (no UIKit), so the report is unit-tested.

// MARK: - Benchmark result

struct BenchmarkResult: Codable, Equatable {
    struct PhotoTiming: Codable, Equatable {
        var name: String
        /// One duration per round, in order (the very first of the whole run is the cold start).
        var seconds: [Double] = []
        /// Items found on the first round.
        var items = 0
    }

    struct StudioRun: Codable, Equatable {
        var seconds: Double
        /// "kept", "rejected" (no candidate looked like the item) or "failed".
        var outcome: String
        /// The diffusion model's own timing for the call (StudioRenderer.lastStats), when available.
        var setupSeconds: Double?
        var diffusionSeconds: Double?
        var denoisingSteps: Int?
        var images: Int?
    }

    var startedAt: Date
    var finishedAt: Date?
    /// All requested parts ran to the end.
    var completed = false
    /// Why it stopped early or what was left out.
    var notes: [String] = []
    var chargingAtStart = false
    var thermalAtStart = ""
    var thermalAtEnd = ""
    var rounds = 0

    var photos: [PhotoTiming] = []
    /// The first extraction of the run (models loading, Neural Engine compile if not done yet).
    var coldExtractionSeconds: Double?

    var faceColdSeconds: Double?
    /// Every face run after the first.
    var faceWarmSeconds: [Double] = []
    var facesFound = 0

    var studio: [StudioRun] = []
    var studioItem: String?

    var peakMemoryBytes: UInt64 = 0
    var placements: [ModelPlacement] = []

    /// Median of every extraction except the very first (cold) one.
    var warmExtractionMedian: Double? {
        var all = photos.flatMap(\.seconds)
        if coldExtractionSeconds != nil, !all.isEmpty { all.removeFirst() }
        return PerfMath.median(all)
    }

    var extractionRuns: Int { photos.reduce(0) { $0 + $1.seconds.count } }
    var faceWarmMedian: Double? { PerfMath.median(faceWarmSeconds) }
    var studioMedian: Double? { PerfMath.median(studio.map(\.seconds)) }
    var itemsFound: Int { photos.reduce(0) { $0 + $1.items } }
}

// MARK: - Duo hinge check

/// One step of the guided hinge check.
enum HingeTarget: String, Codable, CaseIterable, Identifiable {
    case flat, half, closed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return "Open flat"
        case .half: return "Hold at about 90°"
        case .closed: return "Close to the cover screen"
        }
    }

    var instruction: String {
        switch self {
        case .flat: return "Open the phone all the way, so the big screen is flat. Then tap Record."
        case .half: return "Fold the phone half open, like an L (about 90°), and hold it still. Then tap Record."
        case .closed: return "Close the phone. On the cover screen, tap Record."
        }
    }

    var degrees: Double {
        switch self {
        case .flat: return 180
        case .half: return 90
        case .closed: return 0
        }
    }

    /// How far off (degrees) still reads as "as expected": the sensor is good to ~5°, a hand-held
    /// "about 90°" much less.
    var tolerance: Double {
        switch self {
        case .flat: return 10
        case .half: return 20
        case .closed: return 15
        }
    }

    /// The `DuoHingeState` raw value the phone should report.
    var expectedStatus: String {
        switch self {
        case .flat: return "fullyOpen"
        case .half: return "partiallyOpen"
        case .closed: return "closed"
        }
    }
}

/// What the phone reported at one moment.
struct HingeReading: Codable, Equatable {
    /// Degrees from `onHingeChange` (unrounded), 180 = flat.
    var angle: Double?
    /// DuoLayout's 5°-step angle (what the layout uses).
    var layoutAngle: Double?
    /// DuoHingeState raw value.
    var status: String
    /// DuoPosture raw value.
    var posture: String
    var crease: CGRect?
    var creaseActive: Bool
    var windowSize: CGSize
    var wideLayout: Bool
    var at: Date
}

struct HingeCheckResult: Codable, Equatable, Identifiable {
    var target: HingeTarget
    var reading: HingeReading
    var id: String { target.rawValue }

    var delta: Double? { reading.angle.map { $0 - target.degrees } }
    var statusMatches: Bool { reading.status == target.expectedStatus }
    var angleMatches: Bool { delta.map { abs($0) <= target.tolerance } ?? false }
    var asExpected: Bool { statusMatches && angleMatches }

    /// "As expected" / "Read 104° (14° more than 90°)" …
    var verdict: String {
        guard let angle = reading.angle else { return "No angle reported" }
        let d = angle - target.degrees
        var parts: [String] = []
        if !angleMatches {
            parts.append("\(DiagFormat.degrees(abs(d))) \(d > 0 ? "more" : "less") than \(DiagFormat.degrees(target.degrees))")
        }
        if !statusMatches { parts.append("status \(reading.status), expected \(target.expectedStatus)") }
        return parts.isEmpty ? "As expected" : "Check: " + parts.joined(separator: "; ")
    }
}

// MARK: - Report

enum DiagnosticsReport {
    /// The plain-text report the founder pastes to us. Labels are plain language; numbers keep units.
    static func make(facts: DeviceFacts, benchmark: BenchmarkResult?, live: PerfSnapshot,
                     hingeAvailable: Bool, hinge: [HingeCheckResult], liveHinge: HingeReading?,
                     now: Date = Date()) -> String {
        var out: [String] = []
        func line(_ label: String, _ value: String) { out.append("\(label): \(value)") }
        func header(_ title: String) { out.append(""); out.append("== \(title) ==") }

        out.append("StyleMate diagnostics report")
        line("Made", DiagFormat.date(now))
        line("App", "\(facts.appVersion) (\(facts.appBuild)), \(facts.distribution)")

        header("Phone")
        line("Model", facts.modelText)
        line("System", facts.systemVersion)
        line("Temperature", facts.thermalText)
        line("Low Power Mode", facts.lowPowerMode ? "On" : "Off")
        line("Battery", facts.batteryText)
        line("Memory", "\(DiagFormat.bytes(facts.physicalMemoryBytes)) in the phone; app using \(DiagFormat.bytes(facts.appFootprintBytes))"
             + (facts.appAvailableMemoryBytes.map { "; \(DiagFormat.bytes($0)) more available to the app" } ?? ""))
        line("Free storage", DiagFormat.bytes(facts.freeDiskBytes))
        line("AI processors",facts.computeDevices.isEmpty ? "unknown" : facts.computeDevices.joined(separator: ", "))
        line("Neural Engine", facts.hasNeuralEngine ? "Yes" : "No")

        header("Benchmark (bundled sample photos)")
        if let b = benchmark {
            line("Run", "\(DiagFormat.date(b.startedAt)), \(b.completed ? "finished" : "stopped early")"
                 + ", \(b.rounds) round\(b.rounds == 1 ? "" : "s"), \(b.chargingAtStart ? "plugged in" : "on battery")"
                 + ", temperature \(b.thermalAtStart) → \(b.thermalAtEnd)")
            if let started = b.finishedAt.map({ $0.timeIntervalSince(b.startedAt) }) {
                line("Took", DiagFormat.seconds(started))
            }
            if !b.photos.isEmpty {
                line("Finding clothes, first photo (cold start)", DiagFormat.seconds(b.coldExtractionSeconds))
                line("Finding clothes, typical photo (median)", "\(DiagFormat.seconds(b.warmExtractionMedian)) per photo (\(b.extractionRuns) runs, \(b.itemsFound) items on round 1)")
                for p in b.photos {
                    out.append("  - \(p.name): \(p.seconds.map { DiagFormat.seconds($0) }.joined(separator: ", ")); median \(DiagFormat.seconds(PerfMath.median(p.seconds))); \(p.items) items")
                }
            }
            if b.faceColdSeconds != nil {
                line("Face check, first photo (cold start)", DiagFormat.seconds(b.faceColdSeconds))
                line("Face check, typical photo (median)", "\(DiagFormat.seconds(b.faceWarmMedian)) (\(b.faceWarmSeconds.count) runs, \(b.facesFound) faces on round 1)")
            }
            if !b.studio.isEmpty {
                line("Studio photo (median)", "\(DiagFormat.seconds(b.studioMedian)) per item (\(b.studio.count) runs\(b.studioItem.map { ", \($0)" } ?? ""))")
                for (i, r) in b.studio.enumerated() {
                    var s = "  - run \(i + 1): \(DiagFormat.seconds(r.seconds)), \(r.outcome)"
                    if let d = r.diffusionSeconds, let steps = r.denoisingSteps, let n = r.images, steps > 0, n > 0 {
                        s += "; drawing \(DiagFormat.seconds(d)) for \(n) image\(n == 1 ? "" : "s") × \(steps) steps"
                            + " (\(DiagFormat.seconds(d / Double(steps * n))) per step per image)"
                    }
                    if let setup = r.setupSeconds { s += "; model load \(DiagFormat.seconds(setup))" }
                    out.append(s)
                }
            }
            line("Peak app memory", DiagFormat.bytes(b.peakMemoryBytes))
            if !b.placements.isEmpty {
                out.append("Where each model runs (Core ML plan, cpuAndNeuralEngine):")
                for p in b.placements { out.append("  - \(p.model): \(p.summary) (\(p.operationCount) ops)") }
            }
            for note in b.notes { out.append("Note: \(note)") }
        } else {
            out.append("Not run yet (Diagnostics → Run benchmark).")
        }

        header("Live stats from real use")
        if live.isEmpty {
            out.append("Nothing measured yet.")
        } else {
            if let since = live.since { line("Since", DiagFormat.date(since)) }
            let face = live[.faceIdentity]
            if face.events > 0 {
                line("Photos checked for your face", "\(face.events); typical \(DiagFormat.seconds(face.recentMedianSeconds)) (last \(face.recentSeconds.count)), average \(DiagFormat.seconds(face.meanSeconds))")
            }
            let ex = live[.photoExtraction]
            if ex.events > 0 {
                line("Photos searched for clothes", "\(ex.events); typical \(DiagFormat.seconds(ex.recentMedianSeconds)) per photo (last \(ex.recentSeconds.count)), average \(DiagFormat.seconds(ex.meanSeconds)), slowest \(DiagFormat.seconds(ex.maxSeconds))")
                line("Items found", "\(ex.totalCount)")
            }
            let st = live[.studioRender]
            if st.events > 0 {
                line("Studio photos", "\(st.okCount) kept, \(st.rejectedCount) rejected, \(st.failedCount) failed; average \(DiagFormat.seconds(st.meanSeconds)), typical \(DiagFormat.seconds(st.recentMedianSeconds))")
            }
        }

        header("iPhone Duo hinge")
        if !hingeAvailable {
            out.append("No hinge on this phone.")
        } else {
            if let r = liveHinge { line("Now", describe(r)) }
            if hinge.isEmpty { out.append("Guided check not done.") }
            for target in HingeTarget.allCases {
                guard let res = hinge.first(where: { $0.target == target }) else { continue }
                line("\(target.title) (target \(DiagFormat.degrees(target.degrees)))", "\(describe(res.reading)). \(res.verdict)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func describe(_ r: HingeReading) -> String {
        var s = "angle \(DiagFormat.degrees(r.angle))"
        if let l = r.layoutAngle, l != r.angle { s += " (layout \(DiagFormat.degrees(l)))" }
        s += ", status \(r.status), posture \(r.posture)"
        s += ", fold \(DiagFormat.rect(r.crease))\(r.crease == nil ? "" : (r.creaseActive ? " active" : " inactive"))"
        s += String(format: ", window %.0f × %.0f pt", locale: Locale(identifier: "en_US_POSIX"),
                    Double(r.windowSize.width), Double(r.windowSize.height))
        if r.wideLayout { s += " (wide)" }
        return s
    }
}
