import Foundation

// "First 40": the very first scan has one job — get the user to a closet they
// recognise (15+ real items) within a few minutes of granting photo access.
// A newest-first walk spends those minutes on food, screenshots and sunsets, so
// the first run ranks the last 90 days by how outfit-like each photo is (one
// person, whole body in view, a face to recognise) and extracts the best ~40
// first. The rest of the 12-month scan continues newest first afterwards.
//
// Pure planning, unit-tested in StyleMateTests/FirstRunTests.swift;
// `PhotoScanService` measures the thumbnails and drives it.

/// Cheap thumbnail measurements for ranking (see `ThumbnailAnalyzer.firstLookSignals`).
struct FirstLookSignals: Equatable, Sendable {
    /// People detected with reasonable confidence.
    var personCount: Int
    /// Tallest person's height as a fraction of the frame (0...1).
    var bodyHeight: Double
    /// Largest face's area as a fraction of the frame (0...1).
    var faceArea: Double

    static let none = FirstLookSignals(personCount: 0, bodyHeight: 0, faceArea: 0)
}

enum FirstLook {
    /// How far back the fast pass looks.
    static let windowDays = 90
    /// Photos (moments) extracted before the normal walk resumes.
    static let photoLimit = 40
    /// Thumbnails measured at most in the ranking pass (newest first), and how
    /// long it may take: ranking must not eat the minutes it's meant to save.
    static let maxRankedUnits = 900
    static let rankingBudget: TimeInterval = 20
    /// Hand-off to Home: as soon as the closet has this many items, or after
    /// this long, whichever comes first. The scan keeps going in the banner.
    static let handoffItems = 8
    static let handoffSeconds: TimeInterval = 90

    /// 0...1 outfit-likeness of a photo, or nil when it can't be an outfit shot
    /// (nobody in it, or the person is a sliver / a close-up).
    static func score(_ s: FirstLookSignals) -> Double? {
        guard s.personCount > 0 else { return nil }
        let body = min(max(s.bodyHeight, 0), 1)
        // Under a third of the frame is a distant figure or a head-and-shoulders crop.
        guard body >= 0.33 else { return nil }
        let bodyScore = min(body / 0.8, 1)                       // whole body in view
        let soloScore: Double = s.personCount == 1 ? 1 : (s.personCount == 2 ? 0.45 : 0.1)
        // Identity needs a face; ~0.2% of the frame embeds, more is no better.
        let faceScore = min(max(s.faceArea, 0) / 0.004, 1)
        return 0.55 * bodyScore + 0.25 * soloScore + 0.20 * faceScore
    }

    /// Is the photo date inside the fast pass's window?
    static func inWindow(_ date: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let date, let start = calendar.date(byAdding: .day, value: -windowDays, to: now) else { return false }
        return date >= start && date <= now.addingTimeInterval(60)
    }

    /// The scan order for the first run: the best `limit` outfit-like units (by
    /// score, ties newest first) up front, then every other unit in its
    /// original (newest-first) order. `scores[i]` is unit i's score, nil when
    /// unranked or not an outfit photo. Returns unit indices; a permutation.
    static func order(unitCount: Int, scores: [Int: Double], limit: Int = photoLimit) -> (order: [Int], priorityCount: Int) {
        let best = scores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
            .filter { $0 >= 0 && $0 < unitCount }
        let chosen = Set(best)
        let rest = (0..<unitCount).filter { !chosen.contains($0) }
        return (best + rest, best.count)
    }

    /// When the onboarding scan screen hands over to Home.
    static func shouldHandOff(itemsFound: Int, elapsed: TimeInterval, scanFinished: Bool) -> Bool {
        scanFinished || itemsFound >= handoffItems || elapsed >= handoffSeconds
    }

    /// "11 items found in 23 photos" (live counter on the scan screen).
    static func counterText(items: Int, photos: Int) -> String {
        let i = "\(items) item\(items == 1 ? "" : "s") found"
        guard photos > 0 else { return i }
        return "\(i) in \(photos) photo\(photos == 1 ? "" : "s")"
    }
}
