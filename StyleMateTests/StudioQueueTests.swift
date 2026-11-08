import Foundation
import Testing
import UIKit
@testable import StyleMate

/// When the studio queue renders. Build 115 waited for the whole photo scan (hours on a 4,000-photo
/// library) and for 60% battery off the charger, so a real Duo never got a single product photo.
@Suite(.serialized)
@MainActor
struct StudioQueueTests {
    @Test func scanningNoLongerHoldsRendersOnAPhone() {
        var c = StudioQueue.Conditions(scanning: true, rendersDuringScan: true, freeMemory: 2_000_000_000)
        #expect(StudioQueue.holdReason(c) == nil, "a phone takes turns with the scan instead of waiting for it")
        c.firstLook = true
        #expect(StudioQueue.holdReason(c) != nil, "the first run's best photos are scanned first")
        c.firstLook = false
        c.rendersDuringScan = false
        #expect(StudioQueue.holdReason(c) != nil, "the simulator (and try-on) still wait for the scan")
    }

    @Test func halfABatteryIsEnough() {
        var c = StudioQueue.Conditions(powered: false, battery: 0.5)
        #expect(StudioQueue.holdReason(c) == nil, "50% off the charger used to hold any batch over 8 pieces")
        c.battery = 0.15
        #expect(StudioQueue.holdReason(c)?.contains("15%") == true)
        c.powered = true
        #expect(StudioQueue.holdReason(c) == nil)
    }

    @Test func memoryIsCheckedWithTheScanParked() {
        let c = StudioQueue.Conditions(freeMemory: 900_000_000)
        #expect(StudioQueue.holdReason(c) != nil)
        #expect(StudioQueue.holdReason(c, checkMemory: false) == nil)
        #expect(StudioQueue.holdReason(.init(thermal: .serious)) != nil)
        #expect(StudioQueue.holdReason(.init(lowPower: true)) != nil)
    }

    @Test func aRejectedPieceGetsOneMoreRoundWithNewSeeds() {
        let id = UUID()
        let item = WardrobeItem(id: id, category: .tops, product: "T-Shirts", colors: ["Blue"], brand: "",
                                pattern: .solid, imagePath: "tee-cutout.png")
        let store = StudioStore.shared
        defer { store.remove([id]) }
        store.set(.init(studioPath: "", cutoutPath: "tee-cutout.png", version: StudioStore.version, rejections: 1), for: id)
        #expect(store.needsRender(item))
        store.set(.init(studioPath: "", cutoutPath: "tee-cutout.png", version: StudioStore.version,
                        rejections: StudioStore.maxRejections), for: id)
        #expect(!store.needsRender(item))
        // Files written before the retry existed count as one round.
        store.set(.init(studioPath: "", cutoutPath: "tee-cutout.png", version: StudioStore.version), for: id)
        #expect(store.needsRender(item) == (1 < StudioStore.maxRejections))
    }

    /// A batch cancelled by an earlier test ends at its next step; wait for it so a new one can start.
    @MainActor
    static func waitUntilIdle(_ queue: StudioQueue) async {
        let deadline = Date().addingTimeInterval(30)
        while queue.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Counts renders; each one waits a moment so the test sees the scan parked meanwhile.
    final class SlowFake: StudioImageGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        var isAvailable: Bool { true }
        func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                    strength: Float, steps: Int, guidance: Float, seed: UInt32) -> CGImage? {
            lock.withLock { _calls += 1 }
            Thread.sleep(forTimeInterval: 0.3)
            return startingImage ?? StudioPipelineTests.square(r: 40, g: 70, b: 140)
        }
        func unload() {}
    }

    /// The queue renders while a scan is running: it parks the scan, renders, then lets it go.
    @MainActor
    @Test func rendersWhileAScanRuns() async throws {
        let fake = SlowFake()
        let previous = StudioPipeline.generator
        let queue = StudioQueue.shared
        let saved = (queue.scanIsWorking, queue.scanIsParked, queue.scanInFirstLook, queue.rendersDuringScan)
        StudioPipeline.generator = fake
        var parkedWhileRendering = false
        queue.scanIsWorking = { true }
        queue.scanIsParked = { queue.holdsScan }   // the scan parks as soon as it's asked
        queue.scanInFirstLook = { false }
        queue.rendersDuringScan = true
        let wardrobe = WardrobeViewModel()
        let cutout = UIImage(cgImage: StudioPipelineTests.square(r: 40, g: 70, b: 140))
        let path = try #require(WardrobeImageFileHelper.saveImageAsPNG(cutout))
        let item = WardrobeItem(category: .tops, product: "T-Shirts", colors: ["Blue"], brand: "",
                                pattern: .solid, imagePath: path)
        defer {
            queue.cancel()
            StudioPipeline.generator = previous
            (queue.scanIsWorking, queue.scanIsParked, queue.scanInFirstLook, queue.rendersDuringScan) = saved
            StudioStore.shared.remove([item.id])
            WardrobeImageFileHelper.deleteImage(at: path)
        }
        wardrobe.items = [item]
        await Self.waitUntilIdle(queue)
        queue.enqueueMissing(wardrobe)
        #expect(queue.isRunning)
        let deadline = Date().addingTimeInterval(60)
        while StudioStore.shared.entry(for: item.id) == nil, Date() < deadline {
            if fake.calls > 0, queue.holdsScan { parkedWhileRendering = true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.calls > 0, "the studio never rendered while the scan was running: \(queue.holdReason ?? "-")")
        #expect(parkedWhileRendering, "the scan should be parked while a piece renders")
        #expect(StudioStore.shared.entry(for: item.id) != nil, "the piece should have had its studio round")
        #expect(!queue.holdsScan, "the scan is let go after the render")
    }

    /// The real thing, in CI's studio job (shard 0): a denim jacket extracted from a street photo goes
    /// into the closet during a scan, and the app's own queue replaces its cutout with a product photo
    /// drawn by the bundled diffusion model (simulator CPU, so ~8 min a round). The before/after images
    /// land in $REPORT_DIR/studio_queue.
    @MainActor
    @Test(.timeLimit(.minutes(60)))
    func realModelGivesAPieceItsProductPhotoDuringAScan() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STUDIO_SHARD"] == "0" else { return }   // CI's studio job only
        try #require(WardrobeExtractor.isAvailable, "needs the bundled wardrobe models")
        try #require(StudioRenderer.shared.isAvailable, "studio models not bundled")
        let out = FixtureExtraction.reportRoot.appendingPathComponent("studio_queue")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let extracted = try FixtureExtraction.run("casual_denim_jacket_hat.jpg").items
        let jacket = try #require(extracted.first { $0.kind == .outerLayer }, "no jacket extracted")
        let a = jacket.attributes
        let path = try #require(WardrobeImageFileHelper.saveImageAsPNG(jacket.cutout))
        // A fixed id: the seed (and so the render) is the same every run.
        let item = WardrobeItem(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, category: a.category,
                                product: a.product, colors: a.colors, brand: "", pattern: a.pattern, imagePath: path)
        ItemEmbeddingStore.shared.set(a.embedding, quality: 1, truncated: jacket.truncated, for: item.id)
        try? jacket.cutout.pngData()?.write(to: out.appendingPathComponent("before_cutout.png"))

        let queue = StudioQueue.shared
        let saved = (queue.scanIsWorking, queue.scanIsParked, queue.scanInFirstLook, queue.rendersDuringScan)
        queue.scanIsWorking = { true }
        queue.scanIsParked = { queue.holdsScan }
        queue.scanInFirstLook = { false }
        queue.rendersDuringScan = true
        StudioStore.shared.remove([item.id])
        let wardrobe = WardrobeViewModel()
        defer {
            queue.cancel()
            (queue.scanIsWorking, queue.scanIsParked, queue.scanInFirstLook, queue.rendersDuringScan) = saved
            StudioStore.shared.remove([item.id])
        }
        wardrobe.items = [item]
        await Self.waitUntilIdle(queue)
        let start = Date()
        queue.enqueueMissing(wardrobe)
        // Up to two rounds (a rejected first round is retried with new seeds).
        while Date().timeIntervalSince(start) < 50 * 60 {
            if let e = StudioStore.shared.entry(for: item.id), !e.studioPath.isEmpty { break }
            if let e = StudioStore.shared.entry(for: item.id), (e.rejections ?? 0) >= StudioStore.maxRejections { break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let after = try #require(wardrobe.items.first)
        let entry = StudioStore.shared.entry(for: item.id)
        print("[Report] studio queue: \(a.product) after \(Int(Date().timeIntervalSince(start))) s: "
              + "\(queue.renderedCount) made, \(queue.rejectedCount) not convincing, \(queue.failedCount) failed; "
              + queue.describe(items: wardrobe.items).joined(separator: " | "))
        #expect(entry?.studioPath.isEmpty == false, "the jacket kept its cutout: \(queue.describe(items: wardrobe.items))")
        #expect(after.imagePath != path, "the closet should now show the product photo, not the cutout")
        #expect(StudioStore.shared.originalCutout(for: after) == path, "the cutout stays as \"From your photo\"")
        if let studio = WardrobeImageFileHelper.loadImage(at: after.imagePath) {
            try? studio.pngData()?.write(to: out.appendingPathComponent("after_product_photo.png"))
        }
    }
}
