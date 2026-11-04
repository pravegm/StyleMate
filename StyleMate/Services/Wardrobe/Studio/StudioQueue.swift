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
    }

    /// Bump to re-render every item after a pipeline change.
    /// 2: stricter render gate, new prompts, UUID seeds (Nov 2026).
    static let version = 2

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
        if e.studioPath.isEmpty { return e.cutoutPath != item.imagePath }   // failed before; retry only on a new cutout
        return e.studioPath != item.imagePath
    }
}

/// Works through the wardrobe in the background, replacing each item's cutout
/// with a lifelike on-device studio render (see `StudioPipeline`). Items show
/// their clean cutout immediately; the studio image swaps in when it's ready.
///
/// Renders are heavy (~1 GB UNet on the Neural Engine), so the queue waits
/// while a photo scan is running (its models are resident), while the phone is
/// hot, in Low Power Mode, low on battery (big batches need power), or short of
/// memory; it cancels and unloads when the app goes to the background and picks
/// up again when it returns.
@MainActor
final class StudioQueue: ObservableObject {
    static let shared = StudioQueue()

    @Published private(set) var isRunning = false
    @Published private(set) var remaining = 0

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
                guard await self.waitForGoodConditions(batchSize: self.remaining) else { break }
                // The item may have been edited / deleted while we waited.
                guard let current = wardrobe.items.first(where: { $0.id == item.id }),
                      StudioStore.shared.needsRender(current) else { self.remaining -= 1; continue }
                await self.render(current, wardrobe: wardrobe)
                self.remaining -= 1
            }
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
        StudioPipeline.generator?.cancelRenders()
        StudioPipeline.generator?.unload()
    }

    /// Below this much free memory (bytes) a render could get the app killed.
    static let minFreeMemory: UInt64 = 1_300_000_000

    /// Holds until rendering is reasonable; false = give up this batch (cancelled).
    private func waitForGoodConditions(batchSize: Int) async -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var unloaded = false
        while !Task.isCancelled {
            if let reason = Self.holdReason(batchSize: batchSize, scanning: PhotoScanService.shared.isWorking) {
                if !unloaded {
                    print("[Studio] holding: \(reason)")
                    StudioPipeline.generator?.unload()
                    unloaded = true
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                continue
            }
            return true
        }
        return false
    }

    /// Why rendering should wait right now (nil = go).
    static func holdReason(batchSize: Int, scanning: Bool) -> String? {
        if scanning { return "a photo scan is running" }
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return "device is hot" }
        if info.isLowPowerModeEnabled { return "Low Power Mode" }
        let device = UIDevice.current
        let powered = device.batteryState == .charging || device.batteryState == .full
        let level = device.batteryLevel   // -1 when unknown (simulator)
        if !powered && level >= 0 {
            let needed: Float = batchSize > 8 ? 0.6 : 0.3
            if level < needed { return "battery \(Int(level * 100))% and not charging" }
        }
        #if !targetEnvironment(simulator)
        let free = UInt64(os_proc_available_memory())
        if free < minFreeMemory { return "low memory (\(free / 1_000_000) MB free)" }
        #endif
        return nil
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
                                   embedding: embeddingStore.embedding(for: item.id))
        let embedding: [Float]? = embeddingStore.embedding(for: item.id)
        let seed = Self.seed(for: item.id)
        let outcome: StudioPipeline.Outcome = await Task.detached(priority: .utility) {
            let emb = embedding ?? cutout.cgImage.flatMap { FashionClassifier.onWhite($0, side: 224) }.flatMap { WardrobeML.shared.embed($0) }
            guard let emb else { return StudioPipeline.Outcome.failed }
            return StudioPipeline.studioOutcome(cutout: cutout, embedding: emb, plan: plan, seedBase: seed)
        }.value

        switch outcome {
        case .failed:
            if !Task.isCancelled { transientFailures[item.id, default: 0] += 1 }
        case .rejected:
            // No convincing render: the clean cutout is the item's image (an
            // older pipeline's render, if any, goes).
            if showsStudio {
                apply(imagePath: sourcePath, thumbnail: WardrobeImageFileHelper.saveThumbnail(cutout),
                      to: item.id, expecting: startPath, cutoutPath: sourcePath, wardrobe: wardrobe)
            }
            store.set(.init(studioPath: "", cutoutPath: sourcePath, version: StudioStore.version), for: item.id)
        case .rendered(let result):
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
    static func kind(for item: WardrobeItem) -> GarmentKind? {
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
