import Foundation

// Pure, PhotoKit-free scan planning: which photos to look at, in what groups,
// how fast, and how to remember where we got to. Everything here is unit-tested
// (StyleMateTests/ScanEngineTests.swift); `PhotoScanService` drives it.

// MARK: - Asset metadata

/// What the planner needs to know about one library photo. Built from a
/// `PHAsset` (see `PhotoScanService`), but plain data so it can be tested.
struct ScanAssetInfo: Equatable, Sendable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isScreenshot: Bool
    /// PhotoKit burst id: every frame of one burst shares it.
    let burstIdentifier: String?

    init(id: String, creationDate: Date?, pixelWidth: Int, pixelHeight: Int,
         isScreenshot: Bool = false, burstIdentifier: String? = nil) {
        self.id = id
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isScreenshot = isScreenshot
        self.burstIdentifier = burstIdentifier
    }
}

// MARK: - Asset filter

enum ScanSkipReason: String, Equatable, Sendable {
    case screenshot
    case tooSmall
    case extremeAspect
}

/// Photos that can't hold a usable outfit shot are skipped before any image is
/// loaded: screenshots, tiny images (stickers, saved thumbnails) and very long
/// strips (panoramas, scrolling captures, receipts).
enum ScanAssetFilter {
    /// Shorter side below this can't give a wardrobe-quality cutout.
    static let minShortSide = 480
    /// Longer side / shorter side above this is a panorama or a document strip.
    static let maxAspectRatio = 2.6

    static func skipReason(for asset: ScanAssetInfo) -> ScanSkipReason? {
        if asset.isScreenshot { return .screenshot }
        let short = min(asset.pixelWidth, asset.pixelHeight)
        let long = max(asset.pixelWidth, asset.pixelHeight)
        // 0 x 0 means PhotoKit doesn't know yet: let the image load decide.
        guard short > 0 else { return nil }
        if short < minShortSide { return .tooSmall }
        if Double(long) / Double(short) > maxAspectRatio { return .extremeAspect }
        return nil
    }
}

// MARK: - Burst / near-duplicate grouping

/// Consecutive shots of the same moment (a burst, or a few frames seconds apart)
/// show the same outfit. Grouping them lets the scan run identity + extraction
/// on the best frame only instead of 5 near-identical ones.
enum BurstGrouper {
    /// Two photos further apart than this start a new group.
    static let maxGap: TimeInterval = 90
    /// A group never spans more than this, however densely shot (a whole party
    /// at one photo a minute is not one outfit moment).
    static let maxSpan: TimeInterval = 300
    static let maxGroupSize = 24

    /// Groups `assets` (already in scan order, newest first or oldest first)
    /// into runs of near-duplicate shots. Order inside and across groups is kept.
    static func group(_ assets: [ScanAssetInfo], calendar: Calendar = .current) -> [[ScanAssetInfo]] {
        var groups: [[ScanAssetInfo]] = []
        var current: [ScanAssetInfo] = []
        for asset in assets {
            if let last = current.last, let first = current.first,
               current.count < maxGroupSize,
               belongTogether(last, asset, groupStart: first, calendar: calendar) {
                current.append(asset)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [asset]
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    static func belongTogether(_ a: ScanAssetInfo, _ b: ScanAssetInfo, groupStart: ScanAssetInfo,
                               calendar: Calendar = .current) -> Bool {
        if let ba = a.burstIdentifier, let bb = b.burstIdentifier, ba == bb { return true }
        guard let da = a.creationDate, let db = b.creationDate, let d0 = groupStart.creationDate else { return false }
        guard calendar.isDate(da, inSameDayAs: db) else { return false }
        return abs(da.timeIntervalSince(db)) <= maxGap && abs(d0.timeIntervalSince(db)) <= maxSpan
    }
}

/// Cheap per-thumbnail signals used to pick the best frame of a group.
struct ThumbnailSignals: Equatable, Sendable {
    /// A person was detected (same bar as `FaceMatchingService.photoContainsAnyPerson`).
    var hasPerson: Bool
    /// Tallest person's height as a fraction of the frame (0...1): full-body
    /// shots show the whole outfit.
    var bodyHeight: Double = 0
    /// Largest face's area as a fraction of the frame (0...1): identity needs a
    /// face big enough to embed.
    var faceArea: Double = 0
    /// 0...1, higher is sharper (normalised Laplacian variance).
    var sharpness: Double = 0
}

enum BurstPicker {
    /// How good a frame is for the wardrobe: mostly how much of the person is in
    /// view, then sharpness, then face size (enough to recognise, not a close-up).
    static func score(_ s: ThumbnailSignals) -> Double {
        guard s.hasPerson else { return -1 }
        let body = min(max(s.bodyHeight, 0), 1)
        let sharp = min(max(s.sharpness, 0), 1)
        // A face covering ~4% of the frame is plenty to embed; beyond that it's a
        // close-up that hides the clothes, so it doesn't earn more.
        let face = min(max(s.faceArea, 0) / 0.04, 1)
        return 0.55 * body + 0.30 * sharp + 0.15 * face
    }

    /// Candidate ids, best first; frames without a person are left out.
    /// Ties keep the original (library) order.
    static func ranked(_ candidates: [(id: String, signals: ThumbnailSignals)]) -> [String] {
        candidates.enumerated()
            .filter { $0.element.signals.hasPerson }
            .sorted { lhs, rhs in
                let a = score(lhs.element.signals), b = score(rhs.element.signals)
                return a != b ? a > b : lhs.offset < rhs.offset
            }
            .map { $0.element.id }
    }
}

// MARK: - Throttling (thermal, Low Power Mode, background)

enum ScanRunContext: Equatable, Sendable {
    /// App on screen.
    case foreground
    /// App just left the screen; a `beginBackgroundTask` grace period is running.
    case briefBackground
    /// Overnight `BGProcessingTask` (on external power).
    case processingTask
}

enum ScanThrottle {
    struct Policy: Equatable, Sendable {
        /// Photos prepared (thumbnail, person check, iCloud download, identity)
        /// ahead of the one being extracted. 0 = strictly one at a time.
        let prefetchDepth: Int
        /// Pause between photos, seconds — lets the device cool / save battery.
        let delayBetweenPhotos: Double
        /// Non-nil: stop working until conditions change.
        let pauseReason: String?
    }

    static func policy(thermal: ProcessInfo.ThermalState, lowPowerMode: Bool,
                       context: ScanRunContext) -> Policy {
        if thermal == .critical {
            return Policy(prefetchDepth: 0, delayBetweenPhotos: 0, pauseReason: "Paused while your iPhone cools down")
        }
        if lowPowerMode && context != .foreground {
            return Policy(prefetchDepth: 0, delayBetweenPhotos: 0, pauseReason: "Paused for Low Power Mode")
        }
        var depth: Int
        var delay: Double
        switch thermal {
        case .serious: depth = 0; delay = 2.0
        case .fair: depth = 1; delay = 0.15
        default: depth = 2; delay = 0
        }
        if lowPowerMode { depth = min(depth, 1); delay = max(delay, 0.5) }
        // The brief background grace period is short: don't start downloads we
        // can't finish, just complete the photo in hand.
        if context == .briefBackground { depth = 0 }
        return Policy(prefetchDepth: depth, delayBetweenPhotos: delay, pauseReason: nil)
    }
}

// MARK: - Time remaining

/// Smoothed seconds-per-unit estimate for the "about N min left" text.
struct ScanETA: Equatable, Sendable {
    private(set) var secondsPerUnit: Double?
    private(set) var samples = 0
    /// Weight of the newest sample. Photos vary a lot (no person: 30 ms; the
    /// user in an iCloud-only original: several seconds), so smooth heavily.
    static let alpha = 0.12
    static let minSamples = 3
    /// Up-front guess before any photo is timed (most library photos have no
    /// person in them and are rejected from the thumbnail).
    static let typicalSecondsPerPhoto = 0.4

    mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples += 1
        if let s = secondsPerUnit {
            secondsPerUnit = s + Self.alpha * (seconds - s)
        } else {
            secondsPerUnit = seconds
        }
    }

    func secondsRemaining(units: Int) -> Double? {
        guard units > 0 else { return 0 }
        guard samples >= Self.minSamples, let s = secondsPerUnit else { return nil }
        return s * Double(units)
    }

    static func estimate(photoCount: Int) -> Double {
        Double(max(photoCount, 0)) * typicalSecondsPerPhoto
    }

    /// "Less than a minute left", "About 4 min left", "About 2 hr 10 min left".
    static func describe(secondsLeft: Double) -> String {
        "\(describeDuration(secondsLeft).capitalizedFirst) left"
    }

    /// "less than a minute", "about 4 min", "about 2 hr 10 min".
    static func describeDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        let h = minutes / 60
        // Round to 10 min past an hour; precision is fake beyond that.
        let m = Int((Double(minutes % 60) / 10).rounded()) * 10
        if m == 0 || m == 60 { return "about \(m == 60 ? h + 1 : h) hr" }
        return "about \(h) hr \(m) min"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Date ranges

extension ScanDateRange {
    /// Concrete bounds for this range. `end == nil` means "up to now", so photos
    /// taken while a long scan runs are included when it resumes.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (start: Date?, end: Date?) {
        switch self {
        case .lastMonth: return (calendar.date(byAdding: .month, value: -1, to: now), nil)
        case .lastSixMonths: return (calendar.date(byAdding: .month, value: -6, to: now), nil)
        case .lastYear: return (calendar.date(byAdding: .year, value: -1, to: now), nil)
        case .all: return (nil, nil)
        case .custom(let from, let to):
            // A range ending today is open-ended; one ending in the past is fixed.
            let end: Date? = to >= calendar.startOfDay(for: now) ? nil : to
            return (from, end)
        }
    }
}

// MARK: - Resumable job + checkpoint bookkeeping

/// The scan that's in progress (persisted inside `ScanProgress`), so it can
/// continue exactly where it stopped: after a pause, backgrounding, an overnight
/// background task, or the app being killed.
struct ScanJob: Codable, Equatable, Sendable {
    /// nil = from the oldest photo.
    var rangeStart: Date?
    /// nil = up to now.
    var rangeEnd: Date?
    /// Photos to include whatever their date (new photos imported with an old
    /// creation date, found through the library's change history).
    var extraAssetIDs: [String]?
    /// Started by the app itself (resume / new photos), not by the user: stays
    /// quiet when there's nothing to do.
    var isAutomatic: Bool
    var createdAt: Date
    /// Items this job added, across every session it ran in.
    var addedItemIDs: [String] = []
    /// First run only: before the newest-first walk, rank the last 90 days by
    /// how outfit-like each photo is and extract the best ~40 first (`FirstLook`).
    /// Cleared once that pass is done. Optional so older checkpoints decode.
    var firstLook: Bool? = nil
    /// Photos this job finished (looked at, skipped or extracted), across sessions.
    var photosDone: Int = 0

    func covers(start: Date?, end: Date?) -> Bool {
        rangeStart == start && rangeEnd == end
    }
}

extension ScanProgress {
    /// Bump when the extraction pipeline changes enough that photos scanned by
    /// the old one should be looked at again. 2 = on-device wardrobe engine.
    static let currentPipelineVersion = 2
    /// A photo whose image can't be loaded (offline iCloud original) is retried
    /// on later scans, then given up on.
    static let maxLoadAttempts = 3

    static func fresh() -> ScanProgress {
        ScanProgress(scannedAssetIDs: [], totalItemsFound: 0, pipelineVersion: currentPipelineVersion)
    }

    /// Photos scanned by an older pipeline are scanned again (their items are
    /// matched as duplicates and upgraded, so nothing doubles up). Pending
    /// reviews and history stay. Returns true if anything changed.
    @discardableResult
    mutating func migratePipelineIfNeeded() -> Bool {
        guard (pipelineVersion ?? 1) < Self.currentPipelineVersion else { return false }
        scannedAssetIDs = []
        failedAttempts = nil
        activeJob = nil
        pipelineVersion = Self.currentPipelineVersion
        return true
    }

    func isDone(_ id: String) -> Bool { scannedAssetIDs.contains(id) }

    /// `ordered` minus the photos already done, order kept.
    func pending(_ ordered: [String]) -> [String] {
        ordered.filter { !scannedAssetIDs.contains($0) }
    }

    mutating func markDone<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            scannedAssetIDs.insert(id)
            failedAttempts?.removeValue(forKey: id)
        }
        if failedAttempts?.isEmpty == true { failedAttempts = nil }
    }

    /// Records that `id` couldn't be loaded. After `maxLoadAttempts` it's marked
    /// done so it doesn't hold up every future scan. Returns true when given up.
    @discardableResult
    mutating func recordLoadFailure(_ id: String, maxAttempts: Int = ScanProgress.maxLoadAttempts) -> Bool {
        var attempts = failedAttempts ?? [:]
        let n = (attempts[id] ?? 0) + 1
        if n >= maxAttempts {
            attempts.removeValue(forKey: id)
            failedAttempts = attempts.isEmpty ? nil : attempts
            scannedAssetIDs.insert(id)
            return true
        }
        attempts[id] = n
        failedAttempts = attempts
        return false
    }

    /// "Is this you?" questions kept at most. Each holds an embedding and the whole list is
    /// rewritten at every checkpoint; nobody answers thousands. Past it the least likely go.
    static let maxPendingReviews = 200

    /// Queues an "Is this you?" question (once per photo), keeping the `maxPendingReviews`
    /// most similar to the user.
    mutating func queueReview(_ review: PendingFaceReview) {
        var pending = pendingReviews ?? []
        guard !pending.contains(where: { $0.assetId == review.assetId }) else { return }
        pending.append(review)
        if pending.count > Self.maxPendingReviews,
           let weakest = pending.indices.min(by: { pending[$0].similarity < pending[$1].similarity }) {
            pending.remove(at: weakest)
        }
        pendingReviews = pending
    }

    /// Starts `job`, or keeps the unfinished one if it's the same range (so a
    /// restart of the same scan resumes instead of restarting its counters).
    /// Returns the job now active.
    @discardableResult
    mutating func begin(_ job: ScanJob) -> ScanJob {
        if let current = activeJob, current.covers(start: job.rangeStart, end: job.rangeEnd) {
            var merged = current
            merged.isAutomatic = current.isAutomatic && job.isAutomatic
            if let extra = job.extraAssetIDs, !extra.isEmpty {
                merged.extraAssetIDs = Array(Set((current.extraAssetIDs ?? []) + extra))
            }
            activeJob = merged
            return merged
        }
        activeJob = job
        return job
    }

    /// The oldest date the user has asked to cover with an open-ended range.
    /// New-photo scans keep everything from here to now up to date.
    mutating func extendCoverage(start: Date?, end: Date?) {
        guard end == nil else { return }
        let s = start ?? .distantPast
        if let c = coverageStart { coverageStart = min(c, s) } else { coverageStart = s }
    }

    mutating func recordAdded(_ itemID: UUID) {
        totalItemsFound += 1
        activeJob?.addedItemIDs.append(itemID.uuidString)
    }

    mutating func recordPhotosDone(_ n: Int) {
        activeJob?.photosDone += n
    }

    /// Closes the active job: it becomes the "last scan" shown on Home. A scan
    /// the user started replaces that list; an automatic one (new photos) adds
    /// to it, so items not reviewed yet aren't lost.
    mutating func finishJob(at date: Date = Date()) {
        guard let job = activeJob else { return }
        lastScanDate = date
        if job.isAutomatic {
            let known = Set(lastScanAddedItemIDs)
            lastScanAddedItemIDs += job.addedItemIDs.filter { !known.contains($0) }
        } else {
            lastScanAddedItemIDs = job.addedItemIDs
        }
        activeJob = nil
    }
}
