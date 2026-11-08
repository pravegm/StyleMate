import os
import UIKit

/// Remembers which items have a studio image, and the original cutout each was
/// made from (shown as "From your photo" on the item page).
final class StudioStore {
    static let shared = StudioStore()

    struct Entry: Codable {
        /// The studio image file the item now points at ("" = no convincing render).
        var studioPath: String
        /// The cutout from the user's photo it was made from (kept on disk).
        var cutoutPath: String
        var version: Int
        /// Rounds that ended with no convincing render (nil in files from before Nov 2026 = 1).
        var rejections: Int? = nil
    }

    /// A rejected item gets this many rounds, each with fresh seeds, before its cutout stays.
    static let maxRejections = 2

    /// Bump to re-render every item after a pipeline change.
    /// 2: stricter render gate, new prompts, UUID seeds (Nov 2026).
    /// 3: product templates for shoes, hats and all trousers (Nov 2026).
    static let version = 3

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false

    /// `Application Support/Studio/studio.json` — excluded from backup and protected until
    /// first unlock (`LocalStore`). The studio images and the original cutouts themselves
    /// live with the other wardrobe images (`WardrobeImageFileHelper`, also `LocalStore`).
    private var url: URL { LocalStore.directory("Studio").appendingPathComponent("studio.json") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    func entry(for id: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        load()
        return entries[id.uuidString]
    }

    func set(_ entry: Entry, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        load()
        entries[id.uuidString] = entry
        save()
    }

    /// Caller holds `lock`.
    private func save() {
        if let d = try? JSONEncoder().encode(entries) { LocalStore.write(d, to: url) }
    }

    /// Forgets these items' renders and deletes the original cutouts kept for them (the
    /// item's current image is deleted by its owner).
    func remove(_ ids: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        load()
        for id in ids {
            if let e = entries.removeValue(forKey: id.uuidString), !e.cutoutPath.isEmpty, e.cutoutPath != e.studioPath {
                WardrobeImageFileHelper.deleteImage(at: e.cutoutPath)
            }
        }
        save()
    }

    /// "Delete everything": forgets every render and deletes the bookkeeping file.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        loaded = true
        try? FileManager.default.removeItem(at: url)
    }

    /// The original cutout for an item that has been studio-rendered.
    func originalCutout(for item: WardrobeItem) -> String? {
        guard let e = entry(for: item.id), !e.studioPath.isEmpty, e.studioPath == item.imagePath,
              !e.cutoutPath.isEmpty, e.cutoutPath != item.imagePath else { return nil }
        return e.cutoutPath
    }

    /// True when the item still needs a (re-)render: never rendered, rendered by
    /// an older pipeline, or its image was replaced by a better photo since.
    func needsRender(_ item: WardrobeItem) -> Bool {
        guard let e = entry(for: item.id) else { return true }
        if e.version < Self.version { return true }
        if e.studioPath.isEmpty {
            // Rejected before: retry with new seeds a limited number of times, or on a new cutout.
            return e.cutoutPath != item.imagePath || (e.rejections ?? 1) < Self.maxRejections
        }
        return e.studioPath != item.imagePath
    }

    /// Items still waiting for their first studio round (for the closet's progress line).
    func pendingCount(_ items: [WardrobeItem]) -> Int {
        items.filter { StudioQueue.kind(for: $0) != nil && entry(for: $0.id) == nil }.count
    }
}

/// Works through the wardrobe in the background, replacing each item's cutout
/// with a lifelike on-device studio render (see `StudioPipeline`). Items show
/// their clean cutout immediately; the studio image swaps in when it's ready.
///
/// Renders are heavy (~1 GB UNet on the Neural Engine). While a photo scan runs the
/// two take turns: the scan parks at its next photo (`holdsScan`), one item renders,
/// then the scan runs for at least as long before the next render. (Until build 115
/// the queue waited for the whole scan, so a 4,000-photo library stayed all cutouts
/// for hours on a real Duo.) The queue also waits while the phone is hot, in Low Power
/// Mode, below 20% battery off the charger, or short of memory; it cancels and
/// unloads when the app goes to the background and picks up again when it returns.
@MainActor
final class StudioQueue: ObservableObject {
    static let shared = StudioQueue()

    @Published private(set) var isRunning = false
    @Published private(set) var remaining = 0
    /// Why the queue is waiting right now (nil = rendering or idle), for the closet and Diagnostics.
    @Published private(set) var holdReason: String?
    /// The item being drawn right now.
    @Published private(set) var currentProduct: String?
    /// True while a render has the phone to itself: the photo scan parks at its next photo.
    @Published private(set) var holdsScan = false
    /// This launch: renders accepted, items left as cutouts, renders that failed.
    @Published private(set) var renderedCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var lastRenderSeconds: Double?

    /// The scan the queue takes turns with; tests swap in their own.
    var scanIsWorking: () -> Bool = { PhotoScanService.shared.isWorking }
    var scanIsParked: () -> Bool = { PhotoScanService.shared.isParked }
    var scanInFirstLook: () -> Bool = { PhotoScanService.shared.isFirstLookPass }
    /// Renders take turns with a running scan. Off in the simulator, whose CPU render takes
    /// minutes and would stall the scan in the UI tests; tests turn it on.
    var rendersDuringScan: Bool = {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }()

    private var task: Task<Void, Never>?
    private weak var wardrobe: WardrobeViewModel?
    /// Renders that failed for a passing reason (cancelled, model error, low
    /// memory) this session; retried a few times, then left for the next launch.
    private var transientFailures: [UUID: Int] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StudioQueue.shared.cancel() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let q = StudioQueue.shared
                guard let w = q.wardrobe else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    q.enqueueMissing(w)
                }
            }
        })
    }

    /// Starts (or continues) rendering every item that needs it.
    func enqueueMissing(_ wardrobe: WardrobeViewModel) {
        self.wardrobe = wardrobe
        guard task == nil, StudioPipeline.generator?.isAvailable == true else { return }
        let todo = wardrobe.items.filter {
            StudioStore.shared.needsRender($0) && Self.kind(for: $0) != nil && (transientFailures[$0.id] ?? 0) < 3
        }
        guard !todo.isEmpty else { return }
        remaining = todo.count
        isRunning = true
        task = Task { [weak self] in
            for item in todo {
                guard let self, !Task.isCancelled else { break }
                // The item may have been edited / deleted while we waited.
                guard wardrobe.items.contains(where: { $0.id == item.id }) else { self.remaining -= 1; continue }
                guard await self.waitForTurn() else { break }
                let shared = self.holdsScan
                guard let current = wardrobe.items.first(where: { $0.id == item.id }),
                      StudioStore.shared.needsRender(current) else { self.holdsScan = false; self.remaining -= 1; continue }
                let start = Date()
                self.currentProduct = current.product
                await self.render(current, wardrobe: wardrobe)
                self.currentProduct = nil
                self.lastRenderSeconds = Date().timeIntervalSince(start)
                self.holdsScan = false
                self.remaining -= 1
                // Then the scan gets the phone for at least as long.
                if shared { await self.giveScanItsTurn(seconds: max(20, Date().timeIntervalSince(start))) }
            }
            self?.holdsScan = false
            self?.currentProduct = nil
            self?.holdReason = nil
            StudioPipeline.generator?.unload()
            self?.isRunning = false
            self?.task = nil
            // Items that arrived during the batch.
            if !Task.isCancelled { self?.enqueueMissing(wardrobe) }
        }
    }

    /// Stops the batch now: the in-flight render stops at its next step and the
    /// models are released. Called when the app goes to the background.
    func cancel() {
        task?.cancel()
        holdsScan = false
        StudioPipeline.generator?.cancelRenders()
        StudioPipeline.generator?.unload()
    }

    /// Below this much free memory (bytes) a render could get the app killed. Measured with the
    /// scan parked, its models still loaded.
    nonisolated static let minFreeMemory: UInt64 = 1_300_000_000
    /// Off the charger, renders wait below this battery level.
    nonisolated static let minBattery: Float = 0.2
    /// How long a render waits for the scan to finish its current photo and park.
    static let parkTimeout: TimeInterval = 120

    /// Holds until rendering is reasonable and, during a scan, the scan has parked (`holdsScan`
    /// stays true for the render). Free memory is measured with the scan parked; when it's short
    /// the scan is let go again while the queue waits. False = cancelled.
    private func waitForTurn() async -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var unloaded = false
        while !Task.isCancelled {
            var c = conditions()
            var reason = Self.holdReason(c, checkMemory: false)
            if reason == nil {
                if c.scanning { guard await parkScan() else { break } }
                c = conditions()
                reason = Self.holdReason(c)
            }
            guard let reason else { holdReason = nil; return true }
            holdsScan = false
            if holdReason != reason { print("[Studio] holding: \(reason)") }
            holdReason = reason
            if !unloaded {
                StudioPipeline.generator?.unload()
                unloaded = true
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        holdsScan = false
        return false
    }

    /// Asks the scan to park at its next photo and waits until it has (or the timeout: a photo that
    /// takes that long is stuck, and the memory check still guards the render); false = cancelled.
    private func parkScan() async -> Bool {
        holdsScan = true
        let deadline = Date().addingTimeInterval(Self.parkTimeout)
        while !Task.isCancelled, scanIsWorking(), !scanIsParked(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !Task.isCancelled
    }

    /// Lets the scan run (the next render waits) for `seconds`, or until it ends.
    private func giveScanItsTurn(seconds: TimeInterval) async {
        let until = Date().addingTimeInterval(seconds)
        while !Task.isCancelled, scanIsWorking(), Date() < until {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func conditions() -> Conditions {
        var c = Self.currentConditions(scanning: scanIsWorking(), rendersDuringScan: rendersDuringScan)
        c.firstLook = c.scanning && scanInFirstLook()
        return c
    }

    /// Everything `holdReason` looks at, measured now.
    struct Conditions: Sendable {
        var scanning = false
        var rendersDuringScan = true
        /// The first run is still on its best outfit photos (the closet fills first).
        var firstLook = false
        var thermal: ProcessInfo.ThermalState = .nominal
        var lowPower = false
        var powered = true
        /// 0...1, or -1 when unknown (simulator).
        var battery: Float = -1
        /// nil = not measured (simulator).
        var freeMemory: UInt64? = nil
    }

    static func currentConditions(scanning: Bool, rendersDuringScan: Bool) -> Conditions {
        let info = ProcessInfo.processInfo, device = UIDevice.current
        var c = Conditions(scanning: scanning, rendersDuringScan: rendersDuringScan, thermal: info.thermalState,
                           lowPower: info.isLowPowerModeEnabled,
                           powered: device.batteryState == .charging || device.batteryState == .full,
                           battery: device.batteryLevel)
        #if !targetEnvironment(simulator)
        c.freeMemory = UInt64(os_proc_available_memory())
        #endif
        return c
    }

    /// Why rendering should wait right now (nil = go), in words for the closet.
    nonisolated static func holdReason(_ c: Conditions, checkMemory: Bool = true) -> String? {
        if c.scanning && !c.rendersDuringScan { return "Waiting for the photo scan to finish" }
        if c.scanning && c.firstLook { return "Starting once your best photos are scanned" }
        if c.thermal == .serious || c.thermal == .critical { return "Paused while your iPhone cools down" }
        if c.lowPower { return "Paused for Low Power Mode" }
        if !c.powered && c.battery >= 0 && c.battery < minBattery {
            return "Paused at \(Int(c.battery * 100))% battery: plug in to continue"
        }
        if checkMemory, let free = c.freeMemory, free < minFreeMemory { return "Waiting for memory (\(free / 1_000_000) MB free)" }
        return nil
    }

    /// Plain-language state for Diagnostics and the shared report.
    func describe(items: [WardrobeItem]) -> [String] {
        guard StudioPipeline.generator?.isAvailable == true else { return ["The product-photo models are missing from this build."] }
        var out: [String] = []
        let store = StudioStore.shared
        let eligible = items.filter { Self.kind(for: $0) != nil }
        let done = eligible.filter { item in store.entry(for: item.id).map { !$0.studioPath.isEmpty && $0.studioPath == item.imagePath } ?? false }.count
        let kept = eligible.filter { store.entry(for: $0.id).map { $0.studioPath.isEmpty } ?? false }.count
        out.append("Product photos: \(done) of \(eligible.count) pieces; \(kept) kept their cutout; \(store.pendingCount(items)) not tried yet")
        if let p = currentProduct { out.append("Now: drawing \(p)") }
        else if let r = holdReason { out.append("Now: waiting. \(r)") }
        else { out.append(isRunning ? "Now: between pieces" : "Now: idle") }
        out.append("Since StyleMate opened: \(renderedCount) made, \(rejectedCount) not convincing, \(failedCount) failed")
        if let s = lastRenderSeconds { out.append("Last piece took \(DiagFormat.seconds(s))") }
        return out
    }

    /// A stable per-item seed (FNV-1a over the UUID's bytes). `hashValue` is
    /// randomised per launch, so re-renders weren't reproducible.
    nonisolated static func seed(for id: UUID) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt32(b)) &* 16_777_619 } }
        return h
    }

    private func render(_ item: WardrobeItem, wardrobe: WardrobeViewModel) async {
        guard let kind = Self.kind(for: item) else { return }
        let store = StudioStore.shared
        let entry = store.entry(for: item.id)
        let startPath = item.imagePath
        // Always render from the cutout of the user's photo, never from an
        // earlier studio image (a pipeline upgrade re-renders every item).
        let showsStudio = entry.map { !$0.studioPath.isEmpty && $0.studioPath == item.imagePath } ?? false
        let sourcePath = showsStudio ? (entry?.cutoutPath ?? "") : item.imagePath
        guard !sourcePath.isEmpty, !(showsStudio && sourcePath == item.imagePath),
              let cutout = WardrobeImageFileHelper.loadImage(at: sourcePath) else {
            if showsStudio {
                // The cutout is gone (e.g. a reinstall restored only the studio
                // image from iCloud): keep the studio image, don't loop.
                store.set(.init(studioPath: item.imagePath, cutoutPath: "", version: StudioStore.version), for: item.id)
            } else {
                transientFailures[item.id, default: 0] += 1
            }
            return
        }
        // A better photo replaced the cutout since the last render: the old cutout is unused now.
        if let e = entry, !e.cutoutPath.isEmpty, e.cutoutPath != sourcePath, e.cutoutPath != item.imagePath {
            WardrobeImageFileHelper.deleteImage(at: e.cutoutPath)
        }
        let embeddingStore = ItemEmbeddingStore.shared
        let plan = StudioPlan.make(product: item.product, category: item.category, colors: item.colors,
                                   pattern: item.pattern, material: item.material, sleeve: item.sleeveLength,
                                   neckline: item.neckline, details: item.details, kind: kind,
                                   truncated: embeddingStore.truncated(for: item.id) ?? false, cutout: cutout.cgImage,
                                   embedding: embeddingStore.embedding(for: item.id), fit: item.fit)
        let embedding: [Float]? = embeddingStore.embedding(for: item.id)
        // A retry after a rejected round draws new candidates.
        let rejections = entry.flatMap { $0.studioPath.isEmpty && $0.cutoutPath == sourcePath ? ($0.rejections ?? 1) : nil } ?? 0
        let seed = Self.seed(for: item.id) &+ UInt32(rejections) &* 104_729
        let perf = PerfLog.begin(.studioRender)
        // A render blocks its thread for 40–60 s (the renderer's queue.sync), so it runs on a
        // GCD thread, not a Swift-concurrency one: holding a cooperative-pool thread that long
        // starves every other task (the pool has one thread per core).
        let outcome: StudioPipeline.Outcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let emb = embedding ?? cutout.cgImage.flatMap { FashionClassifier.onWhite($0, side: 224) }.flatMap { WardrobeML.shared.embed($0) }
                guard let emb else { cont.resume(returning: StudioPipeline.Outcome.failed); return }
                cont.resume(returning: StudioPipeline.studioOutcome(cutout: cutout, embedding: emb, plan: plan, seedBase: seed))
            }
        }
        perf.end(outcome: PerfLog.Outcome(outcome))

        switch outcome {
        case .failed:
            if !Task.isCancelled { transientFailures[item.id, default: 0] += 1; failedCount += 1 }
        case .rejected:
            rejectedCount += 1
            // No convincing render: the clean cutout is the item's image (an
            // older pipeline's render, if any, goes).
            if showsStudio {
                apply(imagePath: sourcePath, thumbnail: WardrobeImageFileHelper.saveThumbnail(cutout),
                      to: item.id, expecting: startPath, cutoutPath: sourcePath, wardrobe: wardrobe)
            }
            store.set(.init(studioPath: "", cutoutPath: sourcePath, version: StudioStore.version, rejections: rejections + 1),
                      for: item.id)
        case .rendered(let result):
            renderedCount += 1
            guard let path = WardrobeImageFileHelper.saveImageAsPNG(result.image) else {
                transientFailures[item.id, default: 0] += 1
                return
            }
            let thumb = WardrobeImageFileHelper.saveThumbnail(result.image)
            if apply(imagePath: path, thumbnail: thumb, to: item.id, expecting: startPath, cutoutPath: sourcePath, wardrobe: wardrobe) {
                store.set(.init(studioPath: path, cutoutPath: sourcePath, version: StudioStore.version), for: item.id)
                print("[Studio] \(item.product): studio image ready (score \(String(format: "%.3f", result.score)))")
            } else {
                WardrobeImageFileHelper.deleteImage(at: path); WardrobeImageFileHelper.deleteImage(at: thumb)
            }
        }
    }

    /// Points the item at a new image, deleting the image files it replaces —
    /// never the cutout. False if the item changed meanwhile (edited, deleted,
    /// upgraded by a better photo).
    @discardableResult
    private func apply(imagePath: String, thumbnail: String?, to id: UUID, expecting startPath: String,
                       cutoutPath: String, wardrobe: WardrobeViewModel) -> Bool {
        guard let idx = wardrobe.items.firstIndex(where: { $0.id == id }),
              wardrobe.items[idx].imagePath == startPath else { return false }
        let current = wardrobe.items[idx]
        if let t = current.thumbnailPath, t != thumbnail { WardrobeImageFileHelper.deleteImage(at: t) }
        if current.imagePath != cutoutPath && current.imagePath != imagePath { WardrobeImageFileHelper.deleteImage(at: current.imagePath) }
        if let c = current.croppedImagePath, c != current.imagePath, c != cutoutPath, c != imagePath {
            WardrobeImageFileHelper.deleteImage(at: c)
        }
        let updated = current.withImages(imagePath: imagePath, croppedImagePath: imagePath, thumbnailPath: thumbnail)
        wardrobe.items[idx] = updated
        wardrobe.syncItemToCloud(updated)
        return true
    }

    /// The extraction kind for a stored item (nil = don't render, e.g. innerwear).
    nonisolated static func kind(for item: WardrobeItem) -> GarmentKind? {
        let p = item.product
        switch item.category {
        case .outerwear: return .outerLayer
        case .midLayers:
            return ["Cardigans", "Vests", "Gilets", "Fleece Jackets", "Shrugs", "Ponchos"].contains(p) ? .outerLayer : .innerTop
        case .tops: return .innerTop
        case .onePieces: return .onePiece
        case .bottoms: return .lower
        case .footwear: return .footwear
        case .innerwear: return nil
        case .activewear:
            if p.contains("Shorts") || p.contains("Pants") || p.contains("Leggings") { return .lower }
            if p.contains("Jacket") { return .outerLayer }
            if p.contains("Dress") || p == "Swimwear" { return .onePiece }
            return .innerTop
        case .ethnicWear:
            if ["Salwar", "Churidar", "Dhoti", "Lungis", "Mundu", "Patiala Pants", "Sharara", "Ghagra", "Lehenga"].contains(p) { return .lower }
            if ["Saree", "Anarkali", "Palazzo Suit", "Jodhpuri Suit", "Pathani Suit"].contains(p) { return .onePiece }
            if ["Nehru Jacket", "Sherwani", "Bandhgala"].contains(p) { return .outerLayer }
            if p == "Dupatta" { return .neckwear }
            return .innerTop
        case .accessories:
            if ["Sunglasses", "Eyeglasses", "Reading Glasses"].contains(p) { return .eyewear }
            if ["Handbags", "Tote Bags", "Crossbody Bags", "Backpacks", "Wallets", "Clutches", "Fanny Packs",
                "Briefcases", "Messenger Bags"].contains(p) { return .bag }
            if ["Scarves", "Ties", "Bowties"].contains(p) { return .neckwear }
            if ["Belts", "Suspenders"].contains(p) { return .belt }
            if ["Baseball Caps", "Beanies", "Fedoras", "Bucket Hats", "Sun Hats", "Visors", "Bandanas", "Turbans",
                "Headbands", "Berets", "Hair Accessories"].contains(p) { return .headwear }
            return .jewelry
        }
    }
}
