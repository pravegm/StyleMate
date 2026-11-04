import CoreGraphics
import Foundation
import Testing
@testable import StyleMate

/// Pure logic of the photo-library scan engine (Services/Scan/ScanPlanner.swift,
/// ThumbnailAnalyzer's sharpness): asset filtering, burst grouping and frame
/// picking, throttling, time-remaining text, and resume bookkeeping.
struct ScanEngineTests {

    // MARK: Helpers

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-06-15 12:00 UTC + `offset` seconds.
    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_781_524_800 + offset)
    }

    private static func asset(_ id: String, at offset: TimeInterval?, w: Int = 3024, h: Int = 4032,
                              screenshot: Bool = false, burst: String? = nil) -> ScanAssetInfo {
        ScanAssetInfo(id: id, creationDate: offset.map(date), pixelWidth: w, pixelHeight: h,
                      isScreenshot: screenshot, burstIdentifier: burst)
    }

    // MARK: Asset filter

    @Test func filterSkipsScreenshots() {
        #expect(ScanAssetFilter.skipReason(for: Self.asset("s", at: 0, w: 1179, h: 2556, screenshot: true)) == .screenshot)
    }

    @Test func filterSkipsTinyImages() {
        #expect(ScanAssetFilter.skipReason(for: Self.asset("t", at: 0, w: 320, h: 480)) == .tooSmall)
        #expect(ScanAssetFilter.skipReason(for: Self.asset("t2", at: 0, w: 1200, h: 400)) == .tooSmall)
    }

    @Test func filterSkipsPanoramasAndStrips() {
        #expect(ScanAssetFilter.skipReason(for: Self.asset("p", at: 0, w: 12000, h: 3000)) == .extremeAspect)
        #expect(ScanAssetFilter.skipReason(for: Self.asset("strip", at: 0, w: 800, h: 4000)) == .extremeAspect)
    }

    @Test func filterKeepsNormalPhotos() {
        #expect(ScanAssetFilter.skipReason(for: Self.asset("camera", at: 0)) == nil)
        #expect(ScanAssetFilter.skipReason(for: Self.asset("16x9", at: 0, w: 1920, h: 1080)) == nil)
        #expect(ScanAssetFilter.skipReason(for: Self.asset("shared", at: 0, w: 1200, h: 1600)) == nil)
        // Unknown size: let the image load decide.
        #expect(ScanAssetFilter.skipReason(for: Self.asset("unknown", at: 0, w: 0, h: 0)) == nil)
    }

    // MARK: Burst grouping

    @Test func groupsShotsSecondsApart() {
        // Newest first, as the scan walks the library.
        let assets = [
            Self.asset("a", at: 100), Self.asset("b", at: 70), Self.asset("c", at: 40),   // one moment
            Self.asset("d", at: -600),                                                // 10 min earlier
            Self.asset("e", at: -3600), Self.asset("f", at: -3610),                   // another moment
        ]
        let groups = BurstGrouper.group(assets, calendar: Self.calendar).map { $0.map(\.id) }
        #expect(groups == [["a", "b", "c"], ["d"], ["e", "f"]])
    }

    @Test func groupsByBurstIdentifierEvenWithoutDates() {
        let assets = [Self.asset("x1", at: nil, burst: "B"), Self.asset("x2", at: nil, burst: "B"),
                      Self.asset("y", at: nil)]
        let groups = BurstGrouper.group(assets, calendar: Self.calendar).map { $0.map(\.id) }
        #expect(groups == [["x1", "x2"], ["y"]])
    }

    @Test func groupNeverSpansMoreThanFiveMinutes() {
        // One photo a minute for 10 minutes: every gap is small, but it isn't one moment.
        let assets = (0..<10).map { Self.asset("m\($0)", at: TimeInterval(-60 * $0)) }
        let groups = BurstGrouper.group(assets, calendar: Self.calendar)
        #expect(groups.count >= 2)
        for g in groups {
            let dates = g.compactMap(\.creationDate)
            let span = dates.max()!.timeIntervalSince(dates.min()!)
            #expect(span <= BurstGrouper.maxSpan)
        }
        #expect(groups.flatMap { $0 }.map(\.id) == assets.map(\.id))   // nothing lost, order kept
    }

    @Test func groupSplitsAcrossMidnight() {
        // 23:59:30 and 00:00:20 the next day: 50 s apart but different days.
        let midnight = Self.calendar.startOfDay(for: Self.date(86_400))
        let late = ScanAssetInfo(id: "late", creationDate: midnight.addingTimeInterval(-30), pixelWidth: 3000, pixelHeight: 4000)
        let early = ScanAssetInfo(id: "early", creationDate: midnight.addingTimeInterval(20), pixelWidth: 3000, pixelHeight: 4000)
        let groups = BurstGrouper.group([early, late], calendar: Self.calendar)
        #expect(groups.count == 2)
    }

    @Test func groupSizeIsCapped() {
        let assets = (0..<60).map { Self.asset("b\($0)", at: TimeInterval(-$0), burst: "BURST") }
        let groups = BurstGrouper.group(assets, calendar: Self.calendar)
        #expect(groups.allSatisfy { $0.count <= BurstGrouper.maxGroupSize })
        #expect(groups.reduce(0) { $0 + $1.count } == 60)
    }

    // MARK: Best frame

    @Test func picksFullBodySharpFrame() {
        let closeUp = ThumbnailSignals(hasPerson: true, bodyHeight: 0.35, faceArea: 0.20, sharpness: 0.9)
        let blurryFull = ThumbnailSignals(hasPerson: true, bodyHeight: 0.85, faceArea: 0.02, sharpness: 0.15)
        let sharpFull = ThumbnailSignals(hasPerson: true, bodyHeight: 0.85, faceArea: 0.02, sharpness: 0.9)
        let nobody = ThumbnailSignals(hasPerson: false)
        let ranked = BurstPicker.ranked([("close", closeUp), ("blurry", blurryFull),
                                         ("sharp", sharpFull), ("empty", nobody)])
        #expect(ranked.first == "sharp")
        #expect(!ranked.contains("empty"))
        #expect(ranked.count == 3)
    }

    @Test func rankingTiesKeepLibraryOrder() {
        let s = ThumbnailSignals(hasPerson: true, bodyHeight: 0.5, faceArea: 0.01, sharpness: 0.5)
        #expect(BurstPicker.ranked([("first", s), ("second", s), ("third", s)]) == ["first", "second", "third"])
    }

    @Test func faceSizeStopsCountingPastEnough() {
        let enough = ThumbnailSignals(hasPerson: true, bodyHeight: 0.6, faceArea: 0.04, sharpness: 0.5)
        let huge = ThumbnailSignals(hasPerson: true, bodyHeight: 0.6, faceArea: 0.40, sharpness: 0.5)
        #expect(BurstPicker.score(enough) == BurstPicker.score(huge))
        #expect(BurstPicker.score(ThumbnailSignals(hasPerson: false)) < 0)
    }

    // MARK: Sharpness

    @Test func laplacianVarianceSeparatesSharpFromFlat() {
        let w = 32, h = 32
        let flat = [UInt8](repeating: 128, count: w * h)
        var checker = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where (x + y) % 2 == 0 { checker[y * w + x] = 255 } }
        #expect(ThumbnailAnalyzer.laplacianVariance(flat, width: w, height: h) == 0)
        #expect(ThumbnailAnalyzer.laplacianVariance(checker, width: w, height: h) > 10_000)
        #expect(ThumbnailAnalyzer.laplacianVariance([1, 2], width: 1, height: 2) == 0)
    }

    @Test func sharpnessOfRenderedImages() throws {
        func image(_ fill: (Int, Int) -> UInt8) throws -> CGImage {
            let w = 128, h = 128
            var px = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { px[y * w + x] = fill(x, y) } }
            let provider = try #require(CGDataProvider(data: Data(px) as CFData))
            return try #require(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let stripes = try image { x, _ in (x / 2) % 2 == 0 ? 255 : 0 }
        let gradient = try image { x, _ in UInt8(x * 2) }
        let sharp = ThumbnailAnalyzer.sharpness(of: stripes)
        let soft = ThumbnailAnalyzer.sharpness(of: gradient)
        #expect(sharp > 0.8)
        #expect(soft < 0.1)
        #expect((0...1).contains(sharp) && (0...1).contains(soft))
    }

    // MARK: Throttle

    @Test func throttleFollowsThermalState() {
        let nominal = ScanThrottle.policy(thermal: .nominal, lowPowerMode: false, context: .foreground)
        #expect(nominal.pauseReason == nil && nominal.prefetchDepth == 2 && nominal.delayBetweenPhotos == 0)
        let serious = ScanThrottle.policy(thermal: .serious, lowPowerMode: false, context: .foreground)
        #expect(serious.prefetchDepth == 0 && serious.delayBetweenPhotos > 0 && serious.pauseReason == nil)
        let critical = ScanThrottle.policy(thermal: .critical, lowPowerMode: false, context: .processingTask)
        #expect(critical.pauseReason != nil)
    }

    @Test func throttleRespectsLowPowerMode() {
        let fg = ScanThrottle.policy(thermal: .nominal, lowPowerMode: true, context: .foreground)
        #expect(fg.pauseReason == nil && fg.prefetchDepth <= 1 && fg.delayBetweenPhotos >= 0.5)
        #expect(ScanThrottle.policy(thermal: .nominal, lowPowerMode: true, context: .processingTask).pauseReason != nil)
        #expect(ScanThrottle.policy(thermal: .nominal, lowPowerMode: true, context: .briefBackground).pauseReason != nil)
    }

    @Test func briefBackgroundDoesNotStartNewDownloads() {
        #expect(ScanThrottle.policy(thermal: .nominal, lowPowerMode: false, context: .briefBackground).prefetchDepth == 0)
    }

    // MARK: Time remaining

    @Test func etaNeedsSamplesThenSmooths() {
        var eta = ScanETA()
        eta.record(seconds: 1)
        eta.record(seconds: 1)
        #expect(eta.secondsRemaining(units: 100) == nil)
        eta.record(seconds: 1)
        #expect(eta.secondsRemaining(units: 100) == 100)
        eta.record(seconds: 11)           // one slow iCloud download moves it a little, not 10x
        let after = try! #require(eta.secondsRemaining(units: 100))
        #expect(after > 100 && after < 400)
        #expect(eta.secondsRemaining(units: 0) == 0)
        eta.record(seconds: -5)           // ignored
        eta.record(seconds: .nan)         // ignored
        #expect(eta.samples == 4)
    }

    @Test func etaText() {
        #expect(ScanETA.describe(secondsLeft: 20) == "Less than a minute left")
        #expect(ScanETA.describe(secondsLeft: 4 * 60 + 10) == "About 4 min left")
        #expect(ScanETA.describe(secondsLeft: 2 * 3600 + 9 * 60) == "About 2 hr 10 min left")
        #expect(ScanETA.describe(secondsLeft: 3600 + 58 * 60) == "About 2 hr left")
        #expect(ScanETA.describeDuration(3 * 3600) == "about 3 hr")
        #expect(ScanETA.describeDuration(.infinity) == "less than a minute")
    }

    // MARK: Date ranges

    @Test func dateRangeBounds() {
        let now = Self.date(0)
        let year = ScanDateRange.lastYear.bounds(now: now, calendar: Self.calendar)
        #expect(year.end == nil)
        #expect(year.start == Self.calendar.date(byAdding: .year, value: -1, to: now))
        #expect(ScanDateRange.all.bounds(now: now).start == nil)
        let past = ScanDateRange.custom(from: Self.date(-90 * 86_400), to: Self.date(-30 * 86_400))
            .bounds(now: now, calendar: Self.calendar)
        #expect(past.end == Self.date(-30 * 86_400))
        let toToday = ScanDateRange.custom(from: Self.date(-90 * 86_400), to: now).bounds(now: now, calendar: Self.calendar)
        #expect(toToday.end == nil)   // open-ended: includes photos taken during the scan
    }

    // MARK: Resume bookkeeping

    private static func job(start: Date? = nil, automatic: Bool = false) -> ScanJob {
        ScanJob(rangeStart: start, rangeEnd: nil, extraAssetIDs: nil, isAutomatic: automatic, createdAt: date(0))
    }

    @Test func pendingKeepsOrderAndSkipsDone() {
        var p = ScanProgress.fresh()
        p.markDone(["b", "d"])
        #expect(p.pending(["a", "b", "c", "d", "e"]) == ["a", "c", "e"])
        #expect(p.isDone("b") && !p.isDone("a"))
    }

    @Test func loadFailuresRetryThenGiveUp() {
        var p = ScanProgress.fresh()
        let first = p.recordLoadFailure("icloud")
        #expect(first == false)
        #expect(!p.isDone("icloud"))
        let second = p.recordLoadFailure("icloud")
        #expect(second == false)
        let third = p.recordLoadFailure("icloud")
        #expect(third == true)     // third strike
        #expect(p.isDone("icloud"))
        #expect(p.failedAttempts == nil)
    }

    @Test func successAfterFailureClearsTheCounter() {
        var p = ScanProgress.fresh()
        p.recordLoadFailure("x")
        p.markDone(["x"])
        #expect(p.failedAttempts == nil)
        #expect(p.isDone("x"))
    }

    @Test func restartingSameRangeResumesTheJob() {
        var p = ScanProgress.fresh()
        let start = Self.date(-365 * 86_400)
        p.begin(Self.job(start: start))
        p.recordPhotosDone(40)
        p.recordAdded(UUID())
        let resumed = p.begin(Self.job(start: start))
        #expect(resumed.photosDone == 40)
        #expect(resumed.addedItemIDs.count == 1)
        #expect(p.totalItemsFound == 1)
    }

    @Test func automaticResumeOfUserJobStaysUserJob() {
        var p = ScanProgress.fresh()
        p.begin(Self.job(start: nil, automatic: false))
        let merged = p.begin(Self.job(start: nil, automatic: true))
        #expect(merged.isAutomatic == false)
    }

    @Test func differentRangeStartsANewJob() {
        var p = ScanProgress.fresh()
        p.begin(Self.job(start: Self.date(-30 * 86_400)))
        p.recordPhotosDone(10)
        let all = p.begin(Self.job(start: nil))
        #expect(all.photosDone == 0)
        #expect(p.activeJob?.rangeStart == nil)
    }

    @Test func extraIDsMergeIntoResumedJob() {
        var p = ScanProgress.fresh()
        var j = Self.job(start: nil, automatic: true)
        j.extraAssetIDs = ["old-import"]
        p.begin(j)
        var again = Self.job(start: nil, automatic: true)
        again.extraAssetIDs = ["airdrop"]
        let merged = p.begin(again)
        #expect(Set(merged.extraAssetIDs ?? []) == ["old-import", "airdrop"])
    }

    @Test func finishingAUserJobReplacesLastScanItems() {
        var p = ScanProgress.fresh()
        p.lastScanAddedItemIDs = ["older"]
        p.begin(Self.job())
        let id = UUID()
        p.recordAdded(id)
        p.finishJob(at: Self.date(10))
        #expect(p.activeJob == nil)
        #expect(p.lastScanAddedItemIDs == [id.uuidString])
        #expect(p.lastScanDate == Self.date(10))
    }

    @Test func finishingAnAutomaticJobAppendsLastScanItems() {
        var p = ScanProgress.fresh()
        p.lastScanAddedItemIDs = ["older"]
        p.begin(Self.job(automatic: true))
        let id = UUID()
        p.recordAdded(id)
        p.finishJob()
        #expect(p.lastScanAddedItemIDs == ["older", id.uuidString])
    }

    @Test func coverageOnlyGrowsBackwardsAndIgnoresFixedRanges() {
        var p = ScanProgress.fresh()
        p.extendCoverage(start: Self.date(-30 * 86_400), end: nil)
        p.extendCoverage(start: Self.date(-10 * 86_400), end: nil)    // narrower: no change
        #expect(p.coverageStart == Self.date(-30 * 86_400))
        p.extendCoverage(start: Self.date(-900 * 86_400), end: Self.date(-800 * 86_400))  // fixed past range
        #expect(p.coverageStart == Self.date(-30 * 86_400))
        p.extendCoverage(start: nil, end: nil)                        // all photos
        #expect(p.coverageStart == .distantPast)
    }

    @Test func oldPipelineProgressIsRescanned() {
        var old = ScanProgress(scannedAssetIDs: ["a", "b"], totalItemsFound: 7)
        old.pendingReviews = []
        old.activeJob = Self.job()
        let migrated = old.migratePipelineIfNeeded()
        #expect(migrated)
        #expect(old.scannedAssetIDs.isEmpty)
        #expect(old.activeJob == nil)
        #expect(old.totalItemsFound == 7)
        #expect(old.pendingReviews != nil)
        let again = old.migratePipelineIfNeeded()
        #expect(!again)    // only once
        var current = ScanProgress.fresh()
        current.markDone(["z"])
        let currentMigrated = current.migratePipelineIfNeeded()
        #expect(!currentMigrated)
        #expect(current.isDone("z"))
    }

    @Test func progressRoundTripsThroughJSON() throws {
        var p = ScanProgress.fresh()
        p.markDone(["a"])
        p.recordLoadFailure("b")
        p.begin(Self.job(start: Self.date(-100)))
        p.recordPhotosDone(3)
        p.extendCoverage(start: Self.date(-100), end: nil)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(ScanProgress.self, from: data)
        #expect(back.scannedAssetIDs == ["a"])
        #expect(back.failedAttempts == ["b": 1])
        #expect(back.activeJob == p.activeJob)
        #expect(back.coverageStart == p.coverageStart)
        #expect(back.pipelineVersion == ScanProgress.currentPipelineVersion)
    }

    @Test func legacyProgressFileStillDecodes() throws {
        // Written before jobs / versions / failures existed.
        let json = #"{"scannedAssetIDs":["x"],"totalItemsFound":3,"lastScanAddedItemIDs":[]}"#
        var p = try JSONDecoder().decode(ScanProgress.self, from: Data(json.utf8))
        #expect(p.pipelineVersion == nil && p.activeJob == nil)
        let legacyMigrated = p.migratePipelineIfNeeded()
        #expect(legacyMigrated)
    }
}
