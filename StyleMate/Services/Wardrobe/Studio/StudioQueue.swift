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
    static let version = 1

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("studio.json")
    }

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
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }

    /// The original cutout for an item that has been studio-rendered.
    func originalCutout(for item: WardrobeItem) -> String? {
        guard let e = entry(for: item.id), !e.studioPath.isEmpty, e.studioPath == item.imagePath,
              e.cutoutPath != item.imagePath else { return nil }
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
@MainActor
final class StudioQueue: ObservableObject {
    static let shared = StudioQueue()
    private init() {}

    @Published private(set) var isRunning = false
    @Published private(set) var remaining = 0

    private var task: Task<Void, Never>?

    /// Starts (or continues) rendering every item that needs it.
    func enqueueMissing(_ wardrobe: WardrobeViewModel) {
        guard task == nil, StudioPipeline.generator?.isAvailable == true else { return }
        let todo = wardrobe.items.filter { StudioStore.shared.needsRender($0) && Self.kind(for: $0) != nil }
        guard !todo.isEmpty else { return }
        remaining = todo.count
        isRunning = true
        task = Task { [weak self] in
            for item in todo {
                if Task.isCancelled { break }
                await self?.waitForGoodConditions()
                await self?.render(item, wardrobe: wardrobe)
                self?.remaining -= 1
            }
            StudioPipeline.generator?.unload()
            self?.isRunning = false
            self?.task = nil
            // Items that arrived during the batch.
            if !Task.isCancelled { self?.enqueueMissing(wardrobe) }
        }
    }

    func cancel() { task?.cancel() }

    /// Renders are heavy: hold off while the phone is hot or in Low Power Mode.
    private func waitForGoodConditions() async {
        while ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
                || ProcessInfo.processInfo.isLowPowerModeEnabled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if Task.isCancelled { return }
        }
    }

    private func render(_ item: WardrobeItem, wardrobe: WardrobeViewModel) async {
        // Any failure is recorded, so the item isn't retried on every batch.
        func markFailed() {
            StudioStore.shared.set(.init(studioPath: "", cutoutPath: item.imagePath, version: StudioStore.version), for: item.id)
        }
        guard let kind = Self.kind(for: item),
              let cutout = WardrobeImageFileHelper.loadImage(at: item.imagePath) else { markFailed(); return }
        let embeddingStore = ItemEmbeddingStore.shared
        let plan = StudioPlan.make(product: item.product, category: item.category, colors: item.colors,
                                   pattern: item.pattern, material: item.material, sleeve: item.sleeveLength,
                                   neckline: item.neckline, details: item.details, kind: kind,
                                   truncated: embeddingStore.truncated(for: item.id) ?? false)
        let embedding: [Float]? = embeddingStore.embedding(for: item.id)
        let seed = UInt32(truncatingIfNeeded: item.id.hashValue)
        let cutoutPath = item.imagePath
        let result: StudioPipeline.Result? = await Task.detached(priority: .utility) {
            let emb = embedding ?? cutout.cgImage.flatMap { FashionClassifier.onWhite($0, side: 224) }.flatMap { WardrobeML.shared.embed($0) }
            guard let emb else { return nil }
            return StudioPipeline.studioImage(cutout: cutout, embedding: emb, plan: plan, seedBase: seed)
        }.value

        guard let result, let path = WardrobeImageFileHelper.saveImageAsPNG(result.image) else {
            markFailed()
            return
        }
        let thumb = WardrobeImageFileHelper.saveThumbnail(result.image)
        // The item may have changed (edited, deleted, upgraded) while rendering.
        guard let idx = wardrobe.items.firstIndex(where: { $0.id == item.id }),
              wardrobe.items[idx].imagePath == cutoutPath else {
            WardrobeImageFileHelper.deleteImage(at: path); WardrobeImageFileHelper.deleteImage(at: thumb)
            return
        }
        let current = wardrobe.items[idx]
        if current.thumbnailPath != nil { WardrobeImageFileHelper.deleteImage(at: current.thumbnailPath) }
        if let c = current.croppedImagePath, c != current.imagePath { WardrobeImageFileHelper.deleteImage(at: c) }
        let updated = current.withImages(imagePath: path, croppedImagePath: path, thumbnailPath: thumb)
        StudioStore.shared.set(.init(studioPath: path, cutoutPath: cutoutPath, version: StudioStore.version), for: item.id)
        wardrobe.items[idx] = updated
        wardrobe.syncItemToCloud(updated)
        print("[Studio] \(item.product): studio image ready (score \(String(format: "%.3f", result.score)))")
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
