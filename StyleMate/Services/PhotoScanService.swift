import UIKit
import Photos
import Vision

// MARK: - Scan Date Range

enum ScanDateRange {
    case lastMonth
    case lastSixMonths
    case lastYear
    case custom(from: Date, to: Date)
    case all
}

// MARK: - Scan Progress Persistence

struct ScanProgress: Codable {
    var scannedAssetIDs: Set<String>
    var lastScanDate: Date?
    var scanStartDate: Date?
    var scanEndDate: Date?
    var totalItemsFound: Int
    var lastScanAddedItemIDs: [String] = []
    /// Photos that are probably the user but not certain enough to add silently.
    /// Optional so progress files written before this field still decode.
    var pendingReviews: [PendingFaceReview]?
    /// Which extraction pipeline `scannedAssetIDs` were scanned with (nil = before
    /// versioning). See `ScanProgress.currentPipelineVersion`.
    var pipelineVersion: Int?
    /// Load failures per photo (offline iCloud originals), retried up to a limit.
    var failedAttempts: [String: Int]?
    /// The scan in progress, so it resumes exactly where it stopped.
    var activeJob: ScanJob?
    /// Oldest date the user asked to cover: new-photo scans keep it up to date.
    var coverageStart: Date?
    /// Archived `PHPersistentChangeToken` from the last new-photo check.
    var libraryChangeToken: Data?
}

/// One "Is this you?" question queued by the scan.
struct PendingFaceReview: Codable, Identifiable, Hashable {
    var id: String { assetId }
    let assetId: String
    let similarity: Float
    let embedding: [Float]
    /// Normalized face box, Vision convention (bottom-left origin): x, y, w, h.
    let faceBox: [CGFloat]
    let faceCount: Int

    var faceRect: CGRect {
        guard faceBox.count == 4 else { return .zero }
        return CGRect(x: faceBox[0], y: faceBox[1], width: faceBox[2], height: faceBox[3])
    }
}

// MARK: - Scan History Info

struct ScanHistoryInfo {
    let lastScanDate: Date?
    let totalScannedAssets: Int
    let totalItemsFound: Int
}

/// Who started a scan.
enum ScanTrigger {
    /// The user picked a range.
    case user
    /// The first scan after onboarding.
    case initial
    /// The app itself: resuming an unfinished scan or picking up new photos.
    /// Stays quiet (no banner) when there's nothing to do.
    case automatic
}

// MARK: - Photo Scan Service

/// Walks the photo library newest first and turns photos of the user into
/// wardrobe items, entirely on-device:
///
///   metadata filter (screenshots, tiny images, panoramas)
///   → near-duplicate grouping (bursts / shots seconds apart: best frame only)
///   → thumbnail person check → full image (iCloud download if needed)
///   → identity (`FaceMatchingService`) → extraction (`ImageAnalysisService`)
///   → duplicate match → add, or upgrade the stored image if this view is better.
///
/// The next photos are prepared (thumbnail, download, identity) while the
/// current one is extracted; the two ML stages are each serialized. Progress is
/// checkpointed so a scan resumes exactly — after a pause, the app being
/// backgrounded or killed, or in the overnight background task
/// (`BackgroundScanCoordinator`). Work slows down or pauses with the device's
/// thermal state and Low Power Mode.
@MainActor
class PhotoScanService: ObservableObject {
    static let shared = PhotoScanService()

    // MARK: - Published State

    @Published var scanState: ScanState = .idle
    @Published var totalPhotosToScan: Int = 0
    @Published var photosScanned: Int = 0
    @Published var itemsFound: Int = 0
    @Published var currentPhase: String = ""
    @Published var scanAddedItemIDs: [UUID] = []
    /// User-controlled pause. The scan loop parks (without ending) while true.
    @Published var isPaused: Bool = false
    /// "About 12 min left" while scanning (nil until there's an estimate).
    @Published private(set) var timeRemainingText: String?
    /// Why the scan is holding by itself (device too hot, Low Power Mode in the
    /// background, background time used up). nil when running or user-paused.
    @Published private(set) var systemPauseReason: String?
    @Published var pendingReviewCount: Int = 0
    /// Photos actually looked at (thumbnail, identity, extraction) in this run —
    /// the "in 23 photos" of the first-run counter. Skipped screenshots don't count.
    @Published private(set) var photosExamined: Int = 0
    /// True while the first run ranks the last 90 days for its best outfit photos.
    @Published private(set) var isRankingFirstLook = false

    /// "1,204 of 5,310 photos · About 12 min left" — for the progress banner.
    var progressDetail: String {
        var parts = ["\(photosScanned.formatted()) of \(totalPhotosToScan.formatted()) photos"]
        if let reason = systemPauseReason { parts.append(reason) }
        else if isPaused { parts.append("Paused") }
        else if let eta = timeRemainingText { parts.append(eta) }
        return parts.joined(separator: " · ")
    }

    /// True while a scan loop is running (including paused). Unlike `scanState`
    /// it is also true for a quiet automatic scan that hasn't shown anything yet.
    var isWorking: Bool { isRunning }

    /// Set by `BackgroundScanCoordinator` when the app leaves / returns to the screen.
    var runContext: ScanRunContext = .foreground

    private var lastUIUpdate = ContinuousClock.now
    private var lastScanContext: ScanContext?
    private var isRunning = false
    /// Bumped on every start/cancel so a superseded loop stops at its next check.
    private var scanGeneration = 0
    /// Set when the OS is about to suspend us (background time used up).
    private var suspendedReason: String?

    private var progressCache: [String: ScanProgress] = [:]
    private var dirtyProgressUsers: Set<String> = []
    private var lastProgressFlush = ContinuousClock.now

    private let identityGate = AsyncGate()
    private let thumbnailManager = PHCachingImageManager()
    private static let thumbnailSize = CGSize(width: 640, height: 640)
    private static let checkpointInterval: Duration = .seconds(5)
    /// Frames of a near-duplicate group tried before giving up on the group.
    private static let maxFramesPerGroup = 3

    private struct ScanContext {
        let userId: String
        let dateRange: ScanDateRange
        let userGender: String?
    }

    enum ScanState: Equatable {
        case idle
        case scanning
        case completed
        case error(String)

        static func == (lhs: ScanState, rhs: ScanState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning), (.completed, .completed): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private init() {}

    private func isCurrent(_ generation: Int) -> Bool {
        // Not Task.isCancelled: the scan runs in its own task (see `run`) and only
        // stops through cancelScan(), not because a calling view went away.
        isRunning && generation == scanGeneration
    }

    // MARK: - Pause / Resume

    func pauseScan() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        currentPhase = "Scan paused"
        flushProgress()
        print("[StyleMate] Auto-scan paused")
    }

    func resumeScan() {
        guard isPaused else { return }
        isPaused = false
        currentPhase = "Scanning your photos..."
        print("[StyleMate] Auto-scan resumed")
    }

    func togglePause() { isPaused ? resumeScan() : pauseScan() }

    /// The OS is about to suspend the app (background time used up, or the
    /// background task expired): stop at the next photo and checkpoint now.
    func suspend(reason: String) {
        suspendedReason = reason
        flushProgress()
        print("[StyleMate] Auto-scan suspended: \(reason)")
    }

    /// Back on screen / given background time again.
    func endSuspension() {
        guard suspendedReason != nil else { return }
        suspendedReason = nil
        print("[StyleMate] Auto-scan continuing")
    }

    private func currentPolicy() -> ScanThrottle.Policy {
        ScanThrottle.policy(thermal: ProcessInfo.processInfo.thermalState,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            context: runContext)
    }

    /// Parks the loop while paused by the user or the system (without exiting).
    /// Returns false if the scan was cancelled or superseded meanwhile.
    private func waitUntilRunnable(_ generation: Int) async -> Bool {
        var announced = false
        while true {
            guard isCurrent(generation) else { return false }
            let reason = suspendedReason ?? currentPolicy().pauseReason
            if !isPaused && reason == nil {
                if systemPauseReason != nil {
                    systemPauseReason = nil
                    currentPhase = "Scanning your photos..."
                }
                return true
            }
            if systemPauseReason != reason { systemPauseReason = reason }
            if let reason, !isPaused, currentPhase != reason { currentPhase = reason }
            if !announced { flushProgress(); announced = true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Progress Persistence (JSON file in Application Support)

    private static func progressFileURL(forUser userId: String) -> URL {
        // Backup-excluded and file-protected (LocalStore).
        LocalStore.directory("ScanProgress").appendingPathComponent("scanProgress_\(userId).json")
    }

    /// The user's scan progress. Kept in memory once read, so the scan loop and
    /// the review flow always see (and save) the same copy.
    func loadProgress(forUser userId: String) -> ScanProgress {
        if let cached = progressCache[userId] { return cached }
        var progress = Self.readProgressFromDisk(forUser: userId) ?? .fresh()
        let migrated = progress.migratePipelineIfNeeded()
        progressCache[userId] = progress
        if migrated {
            print("[StyleMate] Scan progress: new extraction pipeline, photos will be scanned again")
            writeProgress(progress, forUser: userId)
        }
        return progress
    }

    private static func readProgressFromDisk(forUser userId: String) -> ScanProgress? {
        let fileURL = progressFileURL(forUser: userId)
        // Migrate from UserDefaults if the file doesn't exist yet.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let legacyKey = "scanProgress_\(userId)"
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let progress = try? JSONDecoder().decode(ScanProgress.self, from: data) {
                UserDefaults.standard.removeObject(forKey: legacyKey)
                return progress
            }
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ScanProgress.self, from: data)
    }

    /// Checkpoint writes (asset ids + pending-review embeddings, easily MBs) are
    /// encoded and written off the main actor, in order, on one serial queue.
    private nonisolated static let progressWriter = DispatchQueue(label: "StyleMate.scanProgressWriter", qos: .utility)

    private func writeProgress(_ progress: ScanProgress, forUser userId: String) {
        let fileURL = Self.progressFileURL(forUser: userId)
        Self.progressWriter.async {
            if let data = try? JSONEncoder().encode(progress) {
                LocalStore.write(data, to: fileURL)
            }
        }
    }

    private func saveProgress(_ progress: ScanProgress, forUser userId: String) {
        progressCache[userId] = progress
        dirtyProgressUsers.remove(userId)
        writeProgress(progress, forUser: userId)
    }

    /// Changes the cached progress; written by the next `flushProgress()`.
    private func updateProgress(forUser userId: String, _ change: (inout ScanProgress) -> Void) {
        var progress = loadProgress(forUser: userId)
        change(&progress)
        progressCache[userId] = progress
        dirtyProgressUsers.insert(userId)
    }

    /// Writes every changed progress file now (checkpoint).
    func flushProgress() {
        for userId in dirtyProgressUsers {
            if let progress = progressCache[userId] { writeProgress(progress, forUser: userId) }
        }
        dirtyProgressUsers = []
        lastProgressFlush = ContinuousClock.now
    }

    private func checkpointIfDue() {
        if ContinuousClock.now - lastProgressFlush >= Self.checkpointInterval { flushProgress() }
    }

    /// True when an unfinished scan is waiting to continue.
    func hasUnfinishedScan(forUser userId: String) -> Bool {
        loadProgress(forUser: userId).activeJob != nil
    }

    // MARK: - Scan History

    func getScanHistory(forUser userId: String) -> ScanHistoryInfo {
        let progress = loadProgress(forUser: userId)
        return ScanHistoryInfo(
            lastScanDate: progress.lastScanDate,
            totalScannedAssets: progress.scannedAssetIDs.count,
            totalItemsFound: progress.totalItemsFound
        )
    }

    // MARK: - Main Scan

    /// Scans `dateRange`, newest photo first. Photos already scanned are skipped,
    /// so starting the same (or an overlapping) range again just continues.
    func startScan(
        forUser userId: String,
        dateRange: ScanDateRange,
        userGender: String?,
        wardrobeViewModel: WardrobeViewModel,
        trigger: ScanTrigger = .user,
        firstLook: Bool = false
    ) async {
        guard !isRunning else {
            print("[StyleMate] Scan already in progress, ignoring")
            return
        }
        lastScanContext = ScanContext(userId: userId, dateRange: dateRange, userGender: userGender)
        let bounds = dateRange.bounds()
        let job = ScanJob(rangeStart: bounds.start, rangeEnd: bounds.end, extraAssetIDs: nil,
                          isAutomatic: trigger == .automatic, createdAt: Date(),
                          firstLook: firstLook ? true : nil)
        await run(job, forUser: userId, userGender: userGender, wardrobeViewModel: wardrobeViewModel,
                  extendsCoverage: true)
    }

    /// Continues whatever is unfinished: the interrupted scan if there is one,
    /// otherwise photos added to the library since the last check (within the
    /// range the user has scanned). Quiet when there's nothing new.
    /// Returns false when there was nothing to start.
    @discardableResult
    func continueScanning(forUser userId: String, userGender: String?,
                          wardrobeViewModel: WardrobeViewModel) async -> Bool {
        guard !isRunning else { return false }
        let progress = loadProgress(forUser: userId)
        if let job = progress.activeJob {
            print("[StyleMate] Auto-scan: resuming unfinished scan (\(job.photosDone) photos done)")
            await run(job, forUser: userId, userGender: userGender, wardrobeViewModel: wardrobeViewModel,
                      extendsCoverage: false)
            return true
        }
        guard let coverage = progress.coverageStart else { return false }

        // Photos inserted since the last check, whatever their date.
        let token = progress.libraryChangeToken
        let inserted = await Task.detached(priority: .utility) {
            LibraryChangeTracker.insertedAssetIDs(since: token)
        }.value
        let newToken = LibraryChangeTracker.currentToken()
        updateProgress(forUser: userId) { $0.libraryChangeToken = newToken }

        let job = ScanJob(rangeStart: coverage == .distantPast ? nil : coverage, rangeEnd: nil,
                          extraAssetIDs: inserted.map { Array($0) }, isAutomatic: true, createdAt: Date())
        await run(job, forUser: userId, userGender: userGender, wardrobeViewModel: wardrobeViewModel,
                  extendsCoverage: false)
        return true
    }

    /// Runs the scan in a task of its own and waits for it. A caller's task being
    /// cancelled (e.g. a SwiftUI `.task` whose view went away) doesn't stop it.
    private func run(_ requested: ScanJob, forUser userId: String, userGender: String?,
                     wardrobeViewModel: WardrobeViewModel, extendsCoverage: Bool) async {
        guard !isRunning else { return }
        let task = Task(priority: .utility) { [weak self] in
            await self?.runLoop(requested, forUser: userId, userGender: userGender,
                                wardrobeViewModel: wardrobeViewModel, extendsCoverage: extendsCoverage)
        }
        await task.value
    }

    private func runLoop(_ requested: ScanJob, forUser userId: String, userGender: String?,
                         wardrobeViewModel: WardrobeViewModel, extendsCoverage: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        scanGeneration += 1
        let generation = scanGeneration
        let quiet = requested.isAutomatic
        isPaused = false
        systemPauseReason = nil
        timeRemainingText = nil
        if !quiet {
            scanState = .scanning
            photosScanned = 0
            totalPhotosToScan = 0
            photosExamined = 0
        }

        print("[StyleMate] Auto-scan starting for user: \(userId)\(quiet ? " (automatic)" : "")")

        currentPhase = "Loading face reference..."
        let hasFaceRef = FaceMatchingService.shared.loadSelfieReference(forUser: userId)
        guard hasFaceRef else {
            print("[StyleMate] Auto-scan: No selfie reference loaded -- scan requires a selfie for accurate results")
            isRunning = false
            if quiet {
                currentPhase = ""
            } else {
                scanState = .error("No selfie found. Please take a selfie in Profile to enable scanning.")
            }
            return
        }

        var job = requested
        updateProgress(forUser: userId) { p in
            job = p.begin(requested)
            if extendsCoverage { p.extendCoverage(start: requested.rangeStart, end: requested.rangeEnd) }
            if p.libraryChangeToken == nil { p.libraryChangeToken = LibraryChangeTracker.currentToken() }
        }
        flushProgress()
        let jobItemIDs = job.addedItemIDs.compactMap { UUID(uuidString: $0) }
        if !quiet {
            scanAddedItemIDs = jobItemIDs
            itemsFound = jobItemIDs.count
        }

        currentPhase = "Preparing your photo library..."
        let start = job.rangeStart, end = job.rangeEnd, extra = job.extraAssetIDs ?? []
        let library = await Task.detached(priority: .utility) {
            Self.fetchAssets(start: start, end: end, extraIDs: extra)
        }.value
        guard isCurrent(generation) else { return }

        // Plan: drop what's done, skip what can't be an outfit photo, group bursts.
        let progress = loadProgress(forUser: userId)
        let pending = library.infos.filter { !progress.isDone($0.id) }
        var skipped: [String] = []
        var candidates: [ScanAssetInfo] = []
        for info in pending {
            if ScanAssetFilter.skipReason(for: info) != nil { skipped.append(info.id) } else { candidates.append(info) }
        }
        var units = BurstGrouper.group(candidates)
        let doneBefore = job.photosDone
        updateProgress(forUser: userId) { p in
            p.markDone(skipped)
            p.recordPhotosDone(skipped.count)
        }
        print("[StyleMate] Auto-scan: \(pending.count) to scan of \(library.infos.count) in range " +
              "(\(skipped.count) screenshots/small, \(candidates.count) photos in \(units.count) moments)")

        guard !units.isEmpty else {
            finishRun(forUser: userId, generation: generation, shown: !quiet,
                      emptyMessage: pending.isEmpty ? "No new photos to scan" : "Scan complete!")
            return
        }

        if quiet {
            // Something to do after all: now show it (a quiet check that finds
            // nothing never touches the banner).
            scanState = .scanning
            scanAddedItemIDs = jobItemIDs
            itemsFound = jobItemIDs.count
        }
        totalPhotosToScan = doneBefore + pending.count
        var scannedCount = doneBefore + skipped.count
        photosScanned = scannedCount
        currentPhase = "Scanning your photos..."
        var eta = ScanETA()
        updateTimeRemaining(eta, unitsLeft: units.count)

        let assetsByID = Dictionary(library.assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        // First run: the best ~40 outfit photos of the last 90 days go first.
        var firstLookCount = 0
        if job.firstLook == true {
            let ranked = await rankFirstLook(units, assets: assetsByID, generation: generation)
            guard isCurrent(generation) else { return }
            units = ranked.order.map { units[$0] }
            firstLookCount = ranked.priorityCount
            if firstLookCount == 0 { updateProgress(forUser: userId) { $0.activeJob?.firstLook = nil } }
            currentPhase = "Scanning your photos..."
        }

        let cacheWindow = 48
        var cachedUpTo = 0
        func cacheThumbnails(from index: Int) {
            guard index >= cachedUpTo, index < units.count else { return }
            let upper = min(units.count, index + cacheWindow)
            let assets = units[index..<upper].flatMap { $0 }.compactMap { assetsByID[$0.id] }
            thumbnailManager.startCachingImages(for: assets, targetSize: Self.thumbnailSize,
                                                contentMode: .aspectFit, options: Self.thumbnailOptions)
            cachedUpTo = upper
        }
        cacheThumbnails(from: 0)

        var queue: [Task<PreparedUnit, Never>] = []
        var nextToPrepare = 0
        var consumed = 0
        defer { thumbnailManager.stopCachingImagesForAllAssets() }

        while consumed < units.count {
            guard await waitUntilRunnable(generation) else { queue.forEach { $0.cancel() }; return }
            let tick = ContinuousClock.now
            let policy = currentPolicy()

            while queue.count < policy.prefetchDepth + 1, nextToPrepare < units.count {
                queue.append(prepareTask(units[nextToPrepare], userId: userId, assets: assetsByID))
                nextToPrepare += 1
            }
            let prepared = await queue.removeFirst().value
            guard isCurrent(generation) else { queue.forEach { $0.cancel() }; return }

            // Start preparing the next photos while this one is extracted.
            while queue.count < policy.prefetchDepth, nextToPrepare < units.count {
                queue.append(prepareTask(units[nextToPrepare], userId: userId, assets: assetsByID))
                nextToPrepare += 1
            }

            await consume(prepared, userId: userId, userGender: userGender, wardrobeViewModel: wardrobeViewModel)
            guard isCurrent(generation) else { queue.forEach { $0.cancel() }; return }
            consumed += 1
            photosExamined += prepared.memberIDs.count
            if firstLookCount > 0, consumed == firstLookCount {
                updateProgress(forUser: userId) { $0.activeJob?.firstLook = nil }
                print("[StyleMate] Auto-scan: first-look pass done (\(itemsFound) items so far)")
            }

            updateProgress(forUser: userId) { p in
                p.markDone(prepared.doneIDs)
                for id in prepared.failedIDs {
                    if p.recordLoadFailure(id) { print("[StyleMate] Auto-scan: giving up on \(id) after repeated load failures") }
                }
                p.recordPhotosDone(prepared.doneIDs.count)
            }
            scannedCount = min(totalPhotosToScan, scannedCount + prepared.memberIDs.count)
            throttleUIUpdate(scanned: scannedCount, total: totalPhotosToScan)
            eta.record(seconds: Self.seconds(ContinuousClock.now - tick))
            updateTimeRemaining(eta, unitsLeft: units.count - consumed)
            checkpointIfDue()
            if consumed % 24 == 0 { cacheThumbnails(from: consumed) }

            if policy.delayBetweenPhotos > 0, consumed < units.count {
                try? await Task.sleep(nanoseconds: UInt64(policy.delayBetweenPhotos * 1_000_000_000))
            }
        }

        guard isCurrent(generation) else { return }
        finishRun(forUser: userId, generation: generation, shown: true, emptyMessage: "Scan complete!")
    }

    /// `shown`: this run put the scanning banner up. A quiet (automatic) run that
    /// found nothing to scan leaves the UI exactly as it was.
    private func finishRun(forUser userId: String, generation: Int, shown: Bool, emptyMessage: String) {
        guard isCurrent(generation) else { return }
        let job = loadProgress(forUser: userId).activeJob
        let quiet = job?.isAutomatic ?? true
        updateProgress(forUser: userId) { $0.finishJob() }
        flushProgress()
        if job?.isAutomatic == false {
            UserDefaults.standard.set(true, forKey: "hasCompletedInitialScan_\(userId)")
        }
        isRunning = false
        isPaused = false
        systemPauseReason = nil
        timeRemainingText = nil
        guard shown else {
            currentPhase = ""
            return
        }
        photosScanned = totalPhotosToScan
        if quiet && (job?.addedItemIDs.isEmpty ?? true) {
            // An automatic check that added nothing: just take the banner down.
            scanState = .idle
            currentPhase = ""
        } else {
            scanState = .completed
            currentPhase = scanAddedItemIDs.isEmpty ? emptyMessage : "Scan complete!"
        }
        print("[StyleMate] Auto-scan complete: added \(scanAddedItemIDs.count) items")
    }

    private func updateTimeRemaining(_ eta: ScanETA, unitsLeft: Int) {
        let seconds = eta.secondsRemaining(units: unitsLeft) ?? ScanETA.estimate(photoCount: unitsLeft)
        timeRemainingText = unitsLeft > 0 ? ScanETA.describe(secondsLeft: seconds) : nil
    }

    private nonisolated static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // MARK: - Pipeline stages

    /// One near-duplicate group after its thumbnails, download and identity check.
    private struct PreparedUnit: @unchecked Sendable {
        enum Outcome {
            case analyze(UIImage)
            case review(PendingFaceReview)
            case skip
        }
        let memberIDs: [String]
        var outcome: Outcome = .skip
        /// The photo behind an `.analyze` outcome (for "Wore this on Tue?").
        var photoID: String?
        var photoDate: Date?
        /// Photos that couldn't be loaded and should be retried on a later scan.
        var failedIDs: [String] = []
        var doneIDs: [String] { memberIDs.filter { !failedIDs.contains($0) } }
    }

    private func prepareTask(_ unit: [ScanAssetInfo], userId: String,
                             assets: [String: PHAsset]) -> Task<PreparedUnit, Never> {
        Task(priority: .utility) { [weak self] in
            guard let self else { return PreparedUnit(memberIDs: unit.map(\.id)) }
            return await self.prepare(unit, userId: userId, assets: assets)
        }
    }

    private func prepare(_ unit: [ScanAssetInfo], userId: String,
                         assets: [String: PHAsset]) async -> PreparedUnit {
        var result = PreparedUnit(memberIDs: unit.map(\.id))
        let members = unit.compactMap { assets[$0.id] }
        guard !members.isEmpty, !Task.isCancelled else { return result }

        // 1. Thumbnails → person check (+ frame quality when there's a choice).
        let thumbnails = await loadThumbnails(for: members)
        var thumbFailed: [String] = []
        var thumbCGs: [(String, CGImage)] = []
        for (asset, thumb) in zip(members, thumbnails) {
            if let cg = thumb?.cgImage { thumbCGs.append((asset.localIdentifier, cg)) }
            else { thumbFailed.append(asset.localIdentifier) }   // retried on a later scan
        }
        let rankFrames = thumbCGs.count > 1
        let frames = thumbCGs
        let signals: [(id: String, signals: ThumbnailSignals)] = await Task.detached(priority: .utility) {
            frames.map { pair in
                (id: pair.0, signals: rankFrames ? ThumbnailAnalyzer.signals(for: pair.1)
                                                 : ThumbnailSignals(hasPerson: ThumbnailAnalyzer.hasPerson(pair.1)))
            }
        }.value
        let ranked = BurstPicker.ranked(signals)
        guard !ranked.isEmpty else {
            result.failedIDs = thumbFailed
            return result
        }

        // 2. Best frames: full image → identity, until one is the user.
        var loadFailed: [String] = []
        for id in ranked.prefix(Self.maxFramesPerGroup) {
            guard !Task.isCancelled else { result.failedIDs = result.memberIDs; return result }
            guard let asset = assets[id], let full = await loadFullImage(for: asset), let cg = full.cgImage else {
                // Usually an iCloud download that failed or timed out (offline).
                loadFailed.append(id)
                continue
            }
            await identityGate.acquire()
            let identity: ScanIdentity = await Task.detached(priority: .utility) {
                autoreleasepool {
                    FaceMatchingService.shared.resolveIdentityForScan(in: cg, fullImage: full, userId: userId)
                }
            }.value
            await identityGate.release()

            switch identity {
            case .skip:
                continue
            case .analyze(let image):
                result.outcome = .analyze(image)
                result.photoID = id
                result.photoDate = asset.creationDate
                return result          // the whole group is covered by this frame
            case let .review(sim, embedding, faceBox, faceCount):
                result.outcome = .review(PendingFaceReview(
                    assetId: id, similarity: sim, embedding: embedding,
                    faceBox: [faceBox.origin.x, faceBox.origin.y, faceBox.width, faceBox.height],
                    faceCount: faceCount))
                return result
            }
        }
        // Nobody in the group is the user. Frames that failed to load may still
        // be: retry those later.
        result.failedIDs = thumbFailed + loadFailed
        return result
    }

    private func consume(_ prepared: PreparedUnit, userId: String, userGender: String?,
                         wardrobeViewModel: WardrobeViewModel) async {
        switch prepared.outcome {
        case .skip:
            break
        case .review(let review):
            updateProgress(forUser: userId) { p in
                var pending = p.pendingReviews ?? []
                if !pending.contains(where: { $0.assetId == review.assetId }) {
                    pending.append(review)
                    p.pendingReviews = pending
                }
            }
            pendingReviewCount = loadProgress(forUser: userId).pendingReviews?.count ?? 0
        case .analyze(let image):
            let outcome = await extractItems(from: image, userId: userId, userGender: userGender,
                                             wardrobeViewModel: wardrobeViewModel)
            if !outcome.added.isEmpty {
                updateProgress(forUser: userId) { p in outcome.added.forEach { p.recordAdded($0) } }
            }
            // A recent photo of the user wearing closet items: offer to log the
            // look on that day ("Wore this on Tue?"), so the calendar fills itself.
            if let photoID = prepared.photoID, let date = prepared.photoDate {
                WearLogSuggestions.shared.consider(photoID: photoID, date: date,
                                                   itemIDs: outcome.added + outcome.matched,
                                                   wardrobe: wardrobeViewModel.items, userId: userId)
            }
        }
    }

    // MARK: - Extraction

    /// What one photo gave the wardrobe.
    struct ExtractionOutcome {
        /// New items added.
        var added: [UUID] = []
        /// Items already in the wardrobe that this photo shows again.
        var matched: [UUID] = []
        /// Items StyleMate wasn't sure about, held for "tap to add".
        var held = 0
        /// New items past the free tier's limit, kept locked for Premium (`WardrobeViewModel.lockedItems`).
        var locked = 0
    }

    /// Runs the on-device garment extractor on an image of the user and adds every
    /// new item it's sure about to the wardrobe. Duplicates of items already there
    /// are matched (and may upgrade the stored image); uncertain items (fragments,
    /// poor views, tiny jewelry — `ItemTrust`) are held for the user to add.
    /// Nothing lands if the profile changed meanwhile. `gated`: past the free tier's limit new
    /// items are locked for Premium (`WardrobeAllowance`); off for the sample photos, which don't count.
    private func extractItems(from image: UIImage, userId: String, userGender: String?, holdUncertain: Bool = true,
                              gated: Bool = true,
                              wardrobeViewModel: WardrobeViewModel) async -> ExtractionOutcome {
        await ExtractionGate.shared.acquire()   // shared with manual add
        let results = await ImageAnalysisService.shared.analyzeAndSegment(image: image, userGender: userGender)
        await ExtractionGate.shared.release()
        var outcome = ExtractionOutcome()
        for seg in results {
            // The profile was reset / deleted while this photo was being analysed.
            guard wardrobeViewModel.currentUserEmail == userId else {
                print("[StyleMate] Auto-scan: profile changed mid-extraction, dropping results")
                return ExtractionOutcome()
            }
            guard let cat = seg.category, let prod = seg.product,
                  let pat = seg.pattern, !seg.colors.isEmpty else { continue }
            let doubt = ItemTrust.doubt(seg)

            let isDup = DuplicateDetector.shared.findBestMatch(
                category: cat, product: prod, colors: seg.colors,
                pattern: pat, material: seg.material, fit: seg.fit,
                neckline: seg.neckline, sleeveLength: seg.sleeveLength,
                brand: seg.brand,
                existingItems: wardrobeViewModel.items,
                featurePrint: seg.featurePrint
            )
            if let dup = isDup {
                // An uncertain view never replaces a good image.
                if doubt == nil {
                    await upgradeImageIfBetter(dup.existingItem, with: seg, wardrobeViewModel: wardrobeViewModel)
                    outcome.matched.append(dup.existingItem.id)
                }
                continue
            }
            // Already found and waiting for Premium: don't lock the same garment twice.
            if gated, !wardrobeViewModel.lockedItems.isEmpty,
               DuplicateDetector.shared.findBestMatch(
                   category: cat, product: prod, colors: seg.colors, pattern: pat, material: seg.material,
                   fit: seg.fit, neckline: seg.neckline, sleeveLength: seg.sleeveLength, brand: seg.brand,
                   existingItems: wardrobeViewModel.lockedItems, featurePrint: seg.featurePrint) != nil {
                continue
            }

            guard let garmentImage = seg.maskImage else { continue }
            // PNG + thumbnail encodes off the main actor.
            let (imagePath, thumbnailPath) = await Task.detached(priority: .utility) {
                autoreleasepool {
                    let ip = WardrobeImageFileHelper.saveImageAsPNG(garmentImage)
                        ?? WardrobeImageFileHelper.saveImage(garmentImage) ?? ""
                    let tp = WardrobeImageFileHelper.saveThumbnail(garmentImage)
                    return (ip, tp)
                }
            }.value
            guard wardrobeViewModel.currentUserEmail == userId else {
                WardrobeImageFileHelper.deleteImage(at: imagePath)
                WardrobeImageFileHelper.deleteImage(at: thumbnailPath)
                return ExtractionOutcome()
            }

            // Apple Intelligence devices: on-device details + visible brand.
            let notes = doubt == nil ? await GarmentDescriber.describe(garmentImage, product: prod, colors: seg.colors) : nil
            let wardrobeItem = WardrobeItem(
                category: cat,
                product: prod,
                colors: seg.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                brand: notes?.brand ?? seg.brand,
                pattern: pat,
                imagePath: imagePath,
                croppedImagePath: imagePath,
                thumbnailPath: thumbnailPath,
                material: seg.material,
                fit: seg.fit,
                neckline: seg.neckline,
                sleeveLength: seg.sleeveLength,
                garmentLength: seg.garmentLength,
                details: (notes?.details).flatMap { $0.isEmpty ? nil : $0 } ?? seg.details
            )

            if let doubt {
                guard holdUncertain else {
                    WardrobeImageFileHelper.deleteImage(at: imagePath)
                    WardrobeImageFileHelper.deleteImage(at: thumbnailPath)
                    continue
                }
                // Not sure enough to add by itself: "We weren't sure about 1 item — tap to add".
                UncertainItemsStore.shared.hold(wardrobeItem, embedding: seg.featurePrint, quality: seg.quality,
                                                doubt: doubt, forUser: userId)
                outcome.held += 1
                print("[StyleMate] Auto-scan: held uncertain \(prod) (\(doubt.rawValue), q \(String(format: "%.2f", seg.quality)))")
                continue
            }
            // Free tier full: the piece is kept (locked) for Premium instead of shown.
            if gated, PremiumGate.freeSlots(in: wardrobeViewModel) == 0 {
                PremiumGate.lock(wardrobeItem, embedding: seg.featurePrint, quality: seg.quality,
                                 truncated: seg.truncated, in: wardrobeViewModel)
                outcome.locked += 1
                print("[StyleMate] Auto-scan: locked \(prod) for Premium (free tier full)")
                continue
            }
            if let fp = seg.featurePrint {
                ItemEmbeddingStore.shared.set(fp, quality: seg.quality, truncated: seg.truncated, for: wardrobeItem.id)
            }
            // Appears in the wardrobe straight away, while the scan goes on.
            wardrobeViewModel.items.append(wardrobeItem)
            wardrobeViewModel.syncItemToCloud(wardrobeItem)
            scanAddedItemIDs.append(wardrobeItem.id)
            itemsFound = scanAddedItemIDs.count
            // First scan, app in the background: "Your closet is ready: 25 pieces" (if allowed).
            if gated { ClosetReadyNotifier.shared.closetGrew(to: PremiumGate.countedItems(in: wardrobeViewModel), userId: userId) }
            outcome.added.append(wardrobeItem.id)
            print("[StyleMate] Auto-scan: Added \(prod) (\(cat.rawValue)) to wardrobe")
        }
        return outcome
    }

    /// The same garment shows up in many photos. Keep the best view of it: when
    /// this photo's cutout is clearly better (bigger, sharper, less occluded, not
    /// cut off) than the one in the wardrobe, swap the image — the item, its
    /// metadata and any edits the user made stay as they are.
    private func upgradeImageIfBetter(_ existing: WardrobeItem, with seg: ImageAnalysisService.SegmentedItem,
                                      wardrobeViewModel: WardrobeViewModel) async {
        guard let cutout = seg.maskImage, let fp = seg.featurePrint else { return }
        let store = ItemEmbeddingStore.shared
        // Items from before the on-device pipeline have no score: any new cutout wins.
        let current = store.quality(for: existing.id) ?? 0
        guard seg.quality > current + 0.08 else { return }
        // PNG + thumbnail encodes off the main actor.
        let (ip, tp) = await Task.detached(priority: .utility) {
            autoreleasepool { (WardrobeImageFileHelper.saveImageAsPNG(cutout) ?? "", WardrobeImageFileHelper.saveThumbnail(cutout)) }
        }.value
        guard !ip.isEmpty else { return }
        // Re-find it after the await: the wardrobe may have changed meanwhile.
        guard let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == existing.id }) else {
            WardrobeImageFileHelper.deleteImage(at: ip)
            WardrobeImageFileHelper.deleteImage(at: tp)
            return
        }
        let live = wardrobeViewModel.items[idx]
        WardrobeImageFileHelper.deleteImage(at: live.imagePath)
        if live.croppedImagePath != live.imagePath { WardrobeImageFileHelper.deleteImage(at: live.croppedImagePath) }
        WardrobeImageFileHelper.deleteImage(at: live.thumbnailPath)
        let updated = live.withImages(imagePath: ip, croppedImagePath: ip, thumbnailPath: tp)
        wardrobeViewModel.items[idx] = updated
        wardrobeViewModel.syncItemToCloud(updated)
        store.set(fp, quality: seg.quality, truncated: seg.truncated, for: existing.id)
        print("[StyleMate] Auto-scan: better photo of \(existing.product) (q \(String(format: "%.2f→%.2f", current, seg.quality)))")
    }

    // MARK: - "Is this you?" review queue

    func pendingReviews(forUser userId: String) -> [PendingFaceReview] {
        let list = loadProgress(forUser: userId).pendingReviews ?? []
        pendingReviewCount = list.count
        return list.sorted { $0.similarity > $1.similarity }
    }

    /// Applies the user's answers. Confirmed photos teach the face gallery and are
    /// extracted; rejected ones are dropped. Returns how many items were added.
    func resolveReviews(confirmed: [PendingFaceReview], rejected: [PendingFaceReview],
                        forUser userId: String, userGender: String?,
                        wardrobeViewModel: WardrobeViewModel) async -> Int {
        let answered = Set((confirmed + rejected).map(\.assetId))
        updateProgress(forUser: userId) { p in
            p.pendingReviews = (p.pendingReviews ?? []).filter { !answered.contains($0.assetId) }
        }
        flushProgress()
        pendingReviewCount = loadProgress(forUser: userId).pendingReviews?.count ?? 0

        if !isRunning { scanAddedItemIDs = [] }
        var addedIDs: [UUID] = []
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: confirmed.map(\.assetId), options: nil)
        var byId: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }

        for review in confirmed {
            guard let asset = byId[review.assetId],
                  let full = await loadFullImage(for: asset), let cg = full.cgImage else { continue }
            await identityGate.acquire()
            let image: UIImage? = await Task.detached(priority: .userInitiated) {
                FaceMatchingService.shared.imageForConfirmedReview(
                    cgImage: cg, fullImage: full, faceBox: review.faceRect,
                    embedding: review.embedding, faceCount: review.faceCount, userId: userId)
            }.value
            await identityGate.release()
            guard let image else { continue }
            addedIDs += await extractItems(from: image, userId: userId, userGender: userGender,
                                           wardrobeViewModel: wardrobeViewModel).added
        }

        let addedStrings = addedIDs.map(\.uuidString)
        updateProgress(forUser: userId) { p in
            p.totalItemsFound += addedIDs.count
            if p.activeJob != nil {
                p.activeJob?.addedItemIDs += addedStrings
            } else {
                p.lastScanAddedItemIDs = addedStrings
            }
        }
        flushProgress()
        return addedIDs.count
    }

    /// Loads the face crop shown in the review grid.
    func reviewThumbnail(for review: PendingFaceReview) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [review.assetId], options: nil).firstObject,
              let full = await loadFullImage(for: asset, maxDimension: 1200), let cg = full.cgImage else { return nil }
        return FaceMatchingService.shared.reviewFaceCrop(from: cg, faceBox: review.faceRect)
    }

    /// Throttle @Published updates to ~150ms intervals to avoid SwiftUI layout thrashing.
    private func throttleUIUpdate(scanned: Int, total: Int) {
        let now = ContinuousClock.now
        let isLast = scanned >= total
        if isLast || now - lastUIUpdate >= .milliseconds(150) {
            photosScanned = scanned
            lastUIUpdate = now
        }
    }

    // MARK: - Cancel / Dismiss

    /// Stops the scan. Its progress is kept: the unfinished part continues the
    /// next time the app opens (or overnight while charging).
    func cancelScan() {
        flushProgress()
        scanGeneration += 1
        isRunning = false
        scanState = .idle
        isPaused = false
        systemPauseReason = nil
        timeRemainingText = nil
        currentPhase = ""
        print("[StyleMate] Auto-scan cancelled")
    }

    func dismissCompleted() {
        scanState = .idle
        itemsFound = 0
        photosScanned = 0
        totalPhotosToScan = 0
        currentPhase = ""
    }

    func retryScan(wardrobeViewModel: WardrobeViewModel) async {
        if let context = lastScanContext {
            await startScan(
                forUser: context.userId,
                dateRange: context.dateRange,
                userGender: context.userGender,
                wardrobeViewModel: wardrobeViewModel
            )
        } else if !wardrobeViewModel.currentUserEmail.isEmpty {
            scanState = .idle
            await continueScanning(forUser: wardrobeViewModel.currentUserEmail, userGender: nil,
                                   wardrobeViewModel: wardrobeViewModel)
        }
    }

    // MARK: - Persisted Scan Item IDs

    func loadLastScanItemIDs(forUser userId: String) -> [UUID] {
        let progress = loadProgress(forUser: userId)
        return progress.lastScanAddedItemIDs.compactMap { UUID(uuidString: $0) }
    }

    func removeFromLastScanIDs(_ itemId: UUID, forUser userId: String) {
        updateProgress(forUser: userId) { p in
            p.lastScanAddedItemIDs.removeAll { $0 == itemId.uuidString }
            p.activeJob?.addedItemIDs.removeAll { $0 == itemId.uuidString }
        }
        flushProgress()
    }

    func clearLastScanIDs(forUser userId: String) {
        updateProgress(forUser: userId) { $0.lastScanAddedItemIDs = [] }
        flushProgress()
    }

    /// Resets scan progress so the next scan re-processes every photo. Pending
    /// "Is this you?" questions and the scanned range are kept.
    func resetProgress(forUser userId: String) {
        let old = loadProgress(forUser: userId)
        var fresh = ScanProgress.fresh()
        fresh.pendingReviews = old.pendingReviews
        fresh.coverageStart = old.coverageStart
        fresh.totalItemsFound = old.totalItemsFound
        saveProgress(fresh, forUser: userId)
        print("[StyleMate] Scan progress reset for user \(userId)")
    }

    /// Deletes the user's scan progress entirely (profile deletion).
    func forgetProgress(forUser userId: String) {
        if isRunning { cancelScan() }
        progressCache.removeValue(forKey: userId)
        dirtyProgressUsers.remove(userId)
        let url = Self.progressFileURL(forUser: userId)
        // Through the writer queue, so a checkpoint still in flight can't recreate it.
        Self.progressWriter.async { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removeObject(forKey: "scanProgress_\(userId)")
        pendingReviewCount = 0
    }

    /// The profile is being reset or deleted: stop everything and forget every
    /// cached checkpoint, so nothing found for the old profile can land in the
    /// new one (`extractItems` also checks the user id before adding).
    func resetForProfileChange() {
        if isRunning { cancelScan() }
        flushProgress()
        progressCache.removeAll()
        dirtyProgressUsers.removeAll()
        lastScanContext = nil
        scanAddedItemIDs = []
        pendingReviewCount = 0
        photosExamined = 0
        isRankingFirstLook = false
        dismissCompleted()
        NotificationCenter.default.post(name: .styleMateProfileWillReset, object: nil)
    }

    // MARK: - First run: best outfit photos first

    /// Measures the thumbnails of the newest units inside the last 90 days
    /// (bounded by count and time) and returns the scan order: the best ~40
    /// outfit-like moments first (`FirstLook.order`), then the rest as before.
    private func rankFirstLook(_ units: [[ScanAssetInfo]], assets: [String: PHAsset],
                               generation: Int) async -> (order: [Int], priorityCount: Int) {
        let now = Date()
        let window = units.indices.filter { FirstLook.inWindow(units[$0].first?.creationDate, now: now) }
            .prefix(FirstLook.maxRankedUnits)
        guard !window.isEmpty else { return (Array(units.indices), 0) }
        isRankingFirstLook = true
        currentPhase = "Picking your best outfit photos…"
        defer { isRankingFirstLook = false }

        let deadline = now.addingTimeInterval(FirstLook.rankingBudget)
        var scores: [Int: Double] = [:]
        let manager = thumbnailManager
        let batchSize = 12
        var start = window.startIndex
        while start < window.endIndex, Date() < deadline, isCurrent(generation) {
            let end = min(start + batchSize, window.endIndex)
            let batch = Array(window[start..<end])
            start = end
            // The middle frame of a burst stands for the moment.
            let picks: [(Int, PHAsset)] = batch.compactMap { idx in
                let unit = units[idx]
                guard let asset = assets[unit[unit.count / 2].id] else { return nil }
                return (idx, asset)
            }
            let measured: [(Int, Double?)] = await withTaskGroup(of: (Int, Double?).self) { group in
                for (idx, asset) in picks {
                    group.addTask {
                        guard let cg = await Self.rankingThumbnail(asset, manager: manager) else { return (idx, nil) }
                        return (idx, FirstLook.score(ThumbnailAnalyzer.firstLookSignals(for: cg)))
                    }
                }
                var out: [(Int, Double?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (idx, score) in measured { if let score { scores[idx] = score } }
        }
        let result = FirstLook.order(unitCount: units.count, scores: scores)
        print("[StyleMate] Auto-scan: first look ranked \(scores.count) outfit photos in the last \(FirstLook.windowDays) days, " +
              "\(result.priorityCount) go first")
        return result
    }

    /// A small (~320 px) local thumbnail for ranking. No network: an iCloud-only
    /// photo without a local preview just isn't ranked (it's still scanned later).
    private nonisolated static func rankingThumbnail(_ asset: PHAsset, manager: PHImageManager) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let gate = ResumeGate()
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: CGSize(width: 320, height: 320),
                                 contentMode: .aspectFit, options: options) { image, _ in
                guard gate.claim() else { return }
                continuation.resume(returning: image.flatMap { Self.bakeOrientation($0, pixelScale: true).cgImage })
            }
        }
    }

    // MARK: - Sample photos

    /// "Try with sample photos": runs the normal on-device extraction on the
    /// bundled CC0 street-style photos (strangers, so no identity step) and
    /// shows it through the same counters and banner as a library scan. The
    /// items are tagged as samples (`SampleLibrary`) and removable in one tap.
    func runSampleImport(images: [UIImage], userId: String, wardrobeViewModel: WardrobeViewModel) async {
        guard !isRunning, !images.isEmpty else { return }
        isRunning = true
        scanGeneration += 1
        let generation = scanGeneration
        scanState = .scanning
        isPaused = false
        systemPauseReason = nil
        scanAddedItemIDs = []
        itemsFound = 0
        photosScanned = 0
        photosExamined = 0
        totalPhotosToScan = images.count
        currentPhase = "Finding clothes in the sample photos…"
        timeRemainingText = nil
        for image in images {
            guard isCurrent(generation) else { return }
            let outcome = await extractItems(from: image, userId: userId, userGender: nil, holdUncertain: false,
                                             gated: false, wardrobeViewModel: wardrobeViewModel)
            guard isCurrent(generation) else {
                // Removed / cancelled while this photo was being analysed: drop what it found.
                SampleLibrary.deleteItems(Set(outcome.added), from: wardrobeViewModel)
                return
            }
            SampleLibrary.recordSampleItems(outcome.added, forUser: userId)
            wardrobeViewModel.markSamples(outcome.added)   // synced: other devices don't count them either
            photosScanned += 1
            photosExamined += 1
        }
        guard isCurrent(generation) else { return }
        isRunning = false
        scanState = .completed
        currentPhase = scanAddedItemIDs.isEmpty ? "No clothes found in the samples" : "Sample closet ready"
        print("[StyleMate] Sample import: \(scanAddedItemIDs.count) items from \(images.count) photos")
    }

    // MARK: - Photo Count Estimation

    nonisolated func estimatePhotoCount(for dateRange: ScanDateRange) -> Int {
        let b = dateRange.bounds()
        return PHAsset.fetchAssets(with: .image, options: Self.fetchOptions(start: b.start, end: b.end)).count
    }

    // MARK: - Photo Library Helpers

    private struct FetchedLibrary: @unchecked Sendable {
        let assets: [PHAsset]
        let infos: [ScanAssetInfo]
    }

    private nonisolated static func fetchOptions(start: Date?, end: Date?) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var predicates: [NSPredicate] = []
        if let start, start > .distantPast { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
        if let end { predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate)) }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        return options
    }

    /// Photos in the range plus `extraIDs`, newest first.
    private nonisolated static func fetchAssets(start: Date?, end: Date?, extraIDs: [String]) -> FetchedLibrary {
        var assets: [PHAsset] = []
        var seen = Set<String>()
        PHAsset.fetchAssets(with: .image, options: fetchOptions(start: start, end: end)).enumerateObjects { asset, _, _ in
            assets.append(asset)
            seen.insert(asset.localIdentifier)
        }
        if !extraIDs.isEmpty {
            var extras: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: extraIDs, options: nil).enumerateObjects { asset, _, _ in
                if asset.mediaType == .image, !seen.contains(asset.localIdentifier) { extras.append(asset) }
            }
            if !extras.isEmpty {
                assets += extras
                assets.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            }
        }
        let infos = assets.map { a in
            ScanAssetInfo(id: a.localIdentifier, creationDate: a.creationDate,
                          pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight,
                          isScreenshot: a.mediaSubtypes.contains(.photoScreenshot),
                          burstIdentifier: a.burstIdentifier)
        }
        return FetchedLibrary(assets: assets, infos: infos)
    }

    private static let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        // iCloud-only photos still have a small local preview, but allow the
        // network so a missing one is fetched instead of the photo being lost.
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }()

    private func loadThumbnails(for assets: [PHAsset]) async -> [UIImage?] {
        let manager = thumbnailManager
        let options = Self.thumbnailOptions
        let targetSize = Self.thumbnailSize
        return await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, asset) in assets.enumerated() {
                group.addTask { @Sendable in
                    await withCheckedContinuation { continuation in
                        let gate = ResumeGate()
                        manager.requestImage(
                            for: asset, targetSize: targetSize,
                            contentMode: .aspectFit, options: options
                        ) { image, _ in
                            guard gate.claim() else { return }
                            let normalized = image.flatMap { Self.bakeOrientation($0, pixelScale: true) }   // 1x: no 3x screen-scale copies
                            continuation.resume(returning: (index, normalized))
                        }
                    }
                }
            }

            var results = [UIImage?](repeating: nil, count: assets.count)
            for await (index, image) in group {
                results[index] = image
            }
            return results
        }
    }

    /// Loads the photo at up to 2048px with EXIF orientation baked into the pixels.
    /// 2048 (not 1024): face recognition + person isolation need faces large enough
    /// to embed reliably. At 1024 the faces in multi-person photos are too small and
    /// the wrong person can outscore the user.
    ///
    /// Network access is ON: with iCloud Photos' "Optimize iPhone Storage" (the
    /// default for most people) the full-size original of almost every photo
    /// older than a few weeks lives only in iCloud. With network access off, every
    /// one of those came back nil and was silently skipped — the main reason the
    /// scan "couldn't find me" in a real library. A timeout keeps one slow
    /// download from stalling the whole scan.
    private func loadFullImage(for asset: PHAsset, maxDimension: CGFloat = 2048) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isSynchronous = false

        let longSide = CGFloat(max(asset.pixelWidth, asset.pixelHeight))
        let scale = longSide > 0 ? min(maxDimension / longSide, 1.0) : 1.0
        let target = longSide > 0
            ? CGSize(width: (CGFloat(asset.pixelWidth) * scale).rounded(),
                     height: (CGFloat(asset.pixelHeight) * scale).rounded())
            : CGSize(width: maxDimension, height: maxDimension)

        let manager = PHImageManager.default()
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let requestID = manager.requestImage(for: asset, targetSize: target,
                                                 contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                let baked: UIImage? = autoreleasepool { image.map { Self.bakeOrientation($0, pixelScale: true) } }
                if gate.claim() { continuation.resume(returning: baked) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if gate.claim() {
                    manager.cancelImageRequest(requestID)
                    print("[StyleMate] Auto-scan: full image timed out (iCloud download?) for \(asset.localIdentifier)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Resumes a continuation exactly once across a completion handler and a timeout.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Orientation Normalization

    /// Renders any UIImage into a new bitmap with .up orientation,
    /// baking EXIF rotation/mirroring into the actual pixel data so
    /// that .cgImage returns correctly-oriented pixels for Vision.
    /// `pixelScale`: render at scale 1 so the output's point size IS its pixel size
    /// (otherwise the renderer uses the screen's 3x scale and the image balloons,
    /// and faces embed differently from the gallery faces).
    private nonisolated static func bakeOrientation(_ image: UIImage, pixelScale: Bool = false) -> UIImage {
        guard image.imageOrientation != .up || (pixelScale && image.scale != 1),
              image.cgImage != nil else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        if pixelScale { format.scale = 1 }
        let size = pixelScale
            ? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            : image.size
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension Notification.Name {
    /// Posted when the local profile is reset or deleted, after the scan has
    /// stopped. Long-running work for the old profile (e.g. a studio render
    /// queue) should cancel on it.
    static let styleMateProfileWillReset = Notification.Name("StyleMate.profileWillReset")
}
