import Foundation
import os
import UIKit

/// Schedules try-on renders and publishes their state per look.
///
/// - **User requests** (the look on screen) go first. They run the deterministic composite at once
///   and the diffusion pass when the device allows it.
/// - **Background requests** (the morning look, the next options) follow the studio queue's rules:
///   only while no photo scan or studio render runs, the phone is cool, not in Low Power Mode, with
///   battery to spare (`StudioQueue.holdReason`) — ideally charging.
/// - Results are cached by (body photo, item ids, item image versions) in `TryOnStore`; swapping a
///   piece changes the key, so that look renders again.
/// - Everything stops (and the models unload) when the app goes to the background.
@MainActor
final class TryOnQueue: ObservableObject {
    static let shared = TryOnQueue()

    enum State: Equatable {
        /// Try-on is off, or the look has nothing to put on a body.
        case unavailable
        /// No body photo chosen yet.
        case needsBody
        case queued
        case rendering
        case ready(URL)
        /// The gate rejected it: show the pieces.
        case rejected
    }

    enum Priority: Int { case background = 0, user = 1 }

    @Published private(set) var states: [String: State] = [:]
    /// Bumps whenever any state changes (cheap observation for views).
    @Published private(set) var revision = 0

    private struct Job { let key: String; let items: [WardrobeItem]; var priority: Priority }
    private var jobs: [Job] = []
    /// Composite-only results per look this session (re-queued for the diffusion pass).
    private var attempts: [String: Int] = [:]
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.stylemates.StyleMate", category: "TryOn")

    /// Diffusion pass on by default; tests and the Diagnostics benchmark can turn it off.
    var harmonizeEnabled = true

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TryOnQueue.shared.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TryOnQueue.shared.startWorker() }
        })
    }

    /// Pieces that go on a body (tops, bottoms, one-pieces, layers, shoes).
    static func wearsOnBody(_ items: [WardrobeItem]) -> Bool {
        items.contains { [.top, .bottom, .onePiece, .outer].contains(TryOnRole.of($0)) }
    }

    func key(for items: [WardrobeItem]) -> String? {
        guard let body = TryOnBodyLibrary.shared.current else { return nil }
        return TryOnStore.key(bodyID: body.id, items: items)
    }

    func state(for items: [WardrobeItem]) -> State {
        guard TryOnAvailability.isAvailable, Self.wearsOnBody(items) else { return .unavailable }
        guard let key = key(for: items) else { return .needsBody }
        if let s = states[key] { return s }
        if let url = TryOnStore.shared.imageURL(key) { return .ready(url) }
        if TryOnStore.shared.entry(key)?.rejection != nil { return .rejected }
        return .queued
    }

    /// Asks for a look's try-on (no-op when cached, rejected, or already queued; a user request jumps
    /// the queue).
    func request(_ items: [WardrobeItem], priority: Priority) {
        guard TryOnAvailability.isAvailable, Self.wearsOnBody(items), let key = key(for: items) else { return }
        if TryOnStore.shared.entry(key) != nil { return }
        if let i = jobs.firstIndex(where: { $0.key == key }) {
            if priority.rawValue > jobs[i].priority.rawValue { jobs[i].priority = priority }
        } else {
            jobs.append(Job(key: key, items: items, priority: priority))
            if states[key] == nil { set(key, .queued) }
        }
        startWorker()
    }

    /// Background pre-render of the looks the user is likely to see next.
    func prerender(_ looks: [[WardrobeItem]]) {
        for look in looks { request(look, priority: .background) }
    }

    /// A new body photo: every cached render is gone, start over.
    func bodyChanged() {
        jobs.removeAll()
        states.removeAll()
        revision += 1
        TryOnHarmonizer.shared.cancel()
    }

    func pause() {
        worker?.cancel()
        worker = nil
        TryOnHarmonizer.shared.cancel()
        TryOnHarmonizer.shared.unload()
        for j in jobs where states[j.key] == .rendering { set(j.key, .queued) }
    }

    private func set(_ key: String, _ s: State) {
        states[key] = s
        revision += 1
    }

    private func startWorker() {
        guard worker == nil, !jobs.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        while !Task.isCancelled, let idx = nextJobIndex() {
            let job = jobs.remove(at: idx)
            if job.priority == .background {
                // Wait for good conditions (checked every 20 s); a user request can overtake meanwhile.
                var waited = false
                while !Task.isCancelled, let reason = Self.holdReason() {
                    if !waited { log.info("Try-on holding: \(reason, privacy: .public)"); waited = true }
                    TryOnHarmonizer.shared.unload()
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if jobs.contains(where: { $0.priority == .user }) { break }
                }
                if jobs.contains(where: { $0.priority == .user }) { jobs.append(job); continue }
            }
            guard !Task.isCancelled else { jobs.insert(job, at: 0); break }
            await render(job)
        }
        TryOnHarmonizer.shared.unload()
    }

    private func nextJobIndex() -> Int? {
        if let u = jobs.firstIndex(where: { $0.priority == .user }) { return u }
        return jobs.isEmpty ? nil : 0
    }

    /// Why background work should wait (nil = go). The studio queue's rules, plus: never alongside a
    /// studio render (two ~1 GB UNets), and never during a photo scan (only the studio takes turns with it).
    static func holdReason() -> String? {
        if StudioQueue.shared.isRunning { return "a studio render is running" }
        return StudioQueue.holdReason(StudioQueue.currentConditions(scanning: PhotoScanService.shared.isWorking,
                                                                    rendersDuringScan: false))
    }

    /// Whether the diffusion pass may run right now (a user request runs the composite regardless).
    private func mayHarmonize() -> Bool {
        guard harmonizeEnabled, TryOnHarmonizer.shared.isAvailable else { return false }
        if StudioQueue.shared.isRunning { return false }
        let t = ProcessInfo.processInfo.thermalState
        if t == .serious || t == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        #if !targetEnvironment(simulator)
        if UInt64(os_proc_available_memory()) < StudioQueue.minFreeMemory { return false }
        #endif
        return true
    }

    private func render(_ job: Job) async {
        guard let photo = TryOnBodyLibrary.shared.current, let body = await TryOnBodyLibrary.shared.bodyModel(),
              TryOnStore.key(bodyID: photo.id, items: job.items) == job.key else { return }
        set(job.key, .rendering)
        let perf = PerfLog.begin(.tryOn)
        let garments: [TryOnGarmentSpec] = await Task.detached(priority: .utility) {
            job.items.compactMap { item in
                guard TryOnRole.of(item).isWorn, let img = WardrobeImageFileHelper.loadImage(at: item.imagePath)?.cgImage else { return nil }
                return TryOnGarmentSpec(item: item, image: img)
            }
        }.value
        let harmonize = mayHarmonize()
        let outcome = await Task.detached(priority: .utility) {
            await TryOnRenderer.render(body: body, garments: garments, harmonize: harmonize, seed: Self.seed(job.key))
        }.value
        switch outcome {
        case .ready(let r) where !r.harmonized && harmonizeEnabled && TryOnHarmonizer.shared.isAvailable:
            // Only finished (harmonised) try-ons are shown: a raw composite's fills read as glitches.
            // Render again with the diffusion pass when the device allows it (twice at most).
            attempts[job.key, default: 0] += 1
            if attempts[job.key, default: 0] <= 2 {
                set(job.key, .queued)
                if !jobs.contains(where: { $0.key == job.key }) {
                    jobs.append(Job(key: job.key, items: job.items, priority: .background))
                }
            } else {
                TryOnStore.shared.storeRejected(job.key, reason: "the diffusion pass didn't run", harmonized: false)
                set(job.key, .rejected)
            }
            perf.end(outcome: .rejected)
        case .ready(let r):
            var image = r.image
            if photo.source == .model, let c = TryOnBodyLibrary.cropBelowChin(image, pose: body.pose) { image = c }
            if let url = TryOnStore.shared.storeReady(job.key, image: image, harmonized: r.harmonized, seconds: r.seconds) {
                set(job.key, .ready(url))
                perf.end(count: garments.count, outcome: .ok)
            } else {
                set(job.key, .rejected); perf.end(outcome: .failed)
            }
        case .rejected(let report, let composite):
            #if DEBUG
            if debugKeepRejected, let composite,
               let url = TryOnStore.shared.storeReady(job.key, image: composite, harmonized: false, seconds: 0) {
                set(job.key, .ready(url)); perf.end(outcome: .rejected); return
            }
            #endif
            // Without the diffusion pass a body with bulky old clothes fails on "invented" area: retry
            // later with it rather than giving up.
            if job.priority == .user, !report.harmonized, harmonizeEnabled, TryOnHarmonizer.shared.isAvailable,
               report.rejection?.contains("invented") == true {
                set(job.key, .queued)
                jobs.append(Job(key: job.key, items: job.items, priority: .background))
                perf.end(outcome: .rejected)
            } else {
                TryOnStore.shared.storeRejected(job.key, reason: report.rejection ?? "", harmonized: report.harmonized)
                set(job.key, .rejected)
                perf.end(outcome: .rejected)
            }
        case .failed(let why):
            log.error("Try-on failed: \(why, privacy: .public)")
            set(job.key, .rejected)
            perf.end(outcome: .failed)
        }
    }

    nonisolated static func seed(_ key: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    #if DEBUG
    /// UI tests: show the composite even when the gate would fall back to the pieces.
    var debugKeepRejected = false

    /// UI tests: marks a look as rendered with the given image, without running the pipeline.
    func debugSeed(_ items: [WardrobeItem], image: UIImage) {
        guard let key = key(for: items), let cg = image.cgImage,
              let url = TryOnStore.shared.storeReady(key, image: cg, harmonized: false, seconds: 0) else { return }
        set(key, .ready(url))
    }
    #endif
}
