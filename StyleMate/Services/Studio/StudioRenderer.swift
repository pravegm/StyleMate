import CoreGraphics
import CoreML
import Foundation
import os

/// On-device "studio render" of a wardrobe item with a Stable Diffusion 1.5-class model
/// (Lykon/dreamshaper-8, Core ML, 6-bit palettized, SPLIT_EINSUM_V2 attention). Two modes:
/// - **img2img** (`startingImage` = the garment cutout on white, strength ~0.5): keeps the item's exact
///   shape, best for bottoms / shoes / bags;
/// - **text-to-image** (`startingImage` = nil, a flat-lay prompt built from the attributes, ~20 steps):
///   best for tops / jackets / dresses. The VAE encoder is never loaded in this mode.
/// Fully on-device; nothing leaves the phone.
///
/// - Models: `StudioModels.bundle` in the app bundle (built by `scripts/build_studio_models.sh`,
///   git-ignored). If it's missing, `isAvailable` is false and `render` returns nil, so callers keep
///   the plain cutout.
/// - Runtime: Apple's ml-stable-diffusion Swift pipeline, vendored in `Vendor/StableDiffusion/`.
/// - Memory: always `reduceMemory` mode (each model is loaded only while it's used; the peak is the
///   UNet alone). A multi-seed render (`seeds:`) is ONE `generateImages` call with `imageCount` =
///   seeds.count, so every model is loaded once for the whole batch. Call `unload()` after a batch to
///   drop the pipeline too.
/// - Cancellation: `cancelRenders()` stops the in-flight render at its next denoising step (and any
///   render already queued behind it); the call then returns nils.
/// - Threading: renders are serialized on a private queue (one at a time). The synchronous overloads
///   block their caller for seconds to minutes, so never call them on the main thread; use the `async`
///   overloads from UI code.
final class StudioRenderer: @unchecked Sendable {
    static let shared = StudioRenderer()

    /// Output (and img2img input) edge in pixels; the models are converted for a 64x64 latent.
    static let imageSize = 512
    static let bundleName = "StudioModels"
    static let requiredResources = ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEEncoder.mlmodelc",
                                    "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

    struct RenderStats: Sendable {
        /// Pipeline construction + first model loads (the first render after launch / `unload()` also
        /// pays Core ML's on-device compilation for the Neural Engine).
        var setupSeconds: Double
        /// Wall time for the whole call (all seeds).
        var totalSeconds: Double
        /// Denoising steps run per image (img2img skips the first `steps * (1 - strength)`).
        var denoisingSteps: Int
        var imageCount: Int
        var textToImage: Bool
    }

    private let log = Logger(subsystem: "com.stylemates.StyleMate", category: "StudioRenderer")
    private let queue = DispatchQueue(label: "com.stylemates.StyleMate.studio-render", qos: .userInitiated)
    private let resourcesURL: URL?
    private let stateLock = NSLock()

    // Touched only on `queue`.
    private var pipeline: StableDiffusionPipeline?
    private var pipelineComputeUnits: MLComputeUnits?

    // Guarded by `stateLock`.
    private var _computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    private var _lastStats: RenderStats?
    private var _requests: UInt64 = 0
    private var _cancelledThrough: UInt64 = 0

    /// `.cpuAndNeuralEngine` (default; the models are converted for the ANE, and iOS forbids GPU work in
    /// the background). Changing it rebuilds the pipeline on the next render.
    var computeUnits: MLComputeUnits {
        get { stateLock.withLock { _computeUnits } }
        set { stateLock.withLock { _computeUnits = newValue } }
    }

    /// Timing of the most recent successful render call.
    var lastStats: RenderStats? { stateLock.withLock { _lastStats } }

    /// Stops the in-flight render at its next step, and renders queued before this call.
    func cancelRenders() { stateLock.withLock { _cancelledThrough = _requests } }
    private func isCancelled(_ request: UInt64) -> Bool { stateLock.withLock { request <= _cancelledThrough } }
    /// Numbers each request when it is made (not when it starts), so a cancel issued while it waits in
    /// the queue still applies to it, and a later request is unaffected.
    private func beginRequest() -> UInt64 { stateLock.withLock { () -> UInt64 in _requests += 1; return _requests } }

    init(resourcesURL: URL? = Bundle.main.url(forResource: StudioRenderer.bundleName, withExtension: "bundle")) {
        self.resourcesURL = resourcesURL
    }

    /// The studio models are bundled (all four models + tokenizer files).
    var isAvailable: Bool {
        guard let url = resourcesURL else { return false }
        return Self.requiredResources.allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - Rendering

    /// Renders one 512x512 product photo.
    ///
    /// - Parameters:
    ///   - startingImage: img2img source (the garment on white, any size: letterboxed onto 512x512 white,
    ///     transparent pixels become white), or nil for text-to-image.
    ///   - strength: img2img only, 0...1: how far the render may move from the input (~0.45-0.6 keeps the
    ///     garment's shape). Ignored for text-to-image.
    ///   - steps: scheduler steps (img2img actually runs `steps * strength` of them).
    ///   - guidance: classifier-free guidance scale (~6.5-7).
    /// - Returns: a 512x512 opaque sRGB image, or nil if the models are missing or inference failed.
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seed: UInt32) -> CGImage? {
        render(startingImage: startingImage, prompt: prompt, negativePrompt: negativePrompt,
               strength: strength, steps: steps, guidance: guidance, seeds: [seed]).first ?? nil
    }

    /// Renders one image per seed with a single model load (the models stay loaded across the seeds and
    /// are unloaded at the end). Results are in `seeds` order; an entry is nil if that render failed.
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seeds: [UInt32]) -> [CGImage?] {
        if Thread.isMainThread {
            log.fault("StudioRenderer.render called on the main thread; use the async overload")
            assertionFailure("StudioRenderer.render must not run on the main thread")
        }
        guard isAvailable else { return seeds.map { _ in nil } }
        let request = beginRequest()
        return queue.sync {
            renderOnQueue(request: request, startingImage: startingImage, prompt: prompt, negativePrompt: negativePrompt,
                          strength: strength, steps: steps, guidance: guidance, seeds: seeds)
        }
    }

    /// Async `render` for UI code; waits its turn behind other renders without blocking a thread.
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seed: UInt32) async -> CGImage? {
        await render(startingImage: startingImage, prompt: prompt, negativePrompt: negativePrompt,
                     strength: strength, steps: steps, guidance: guidance, seeds: [seed]).first ?? nil
    }

    /// Async multi-seed `render` (one model load for all seeds).
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seeds: [UInt32]) async -> [CGImage?] {
        guard isAvailable else { return seeds.map { _ in nil } }
        let request = beginRequest()
        return await withCheckedContinuation { (cont: CheckedContinuation<[CGImage?], Never>) in
            queue.async {
                cont.resume(returning: self.renderOnQueue(
                    request: request, startingImage: startingImage, prompt: prompt, negativePrompt: negativePrompt,
                    strength: strength, steps: steps, guidance: guidance, seeds: seeds))
            }
        }
    }

    /// Builds the pipeline and loads + unloads each model once, so Core ML's (slow, first-launch) model
    /// compilation for the Neural Engine is done before the first render. Runs in the background.
    func prewarm() {
        guard isAvailable else { return }
        queue.async {
            do {
                let start = CFAbsoluteTimeGetCurrent()
                try self.preparedPipeline().prewarmResources()
                self.log.info("Studio models prewarmed in \(CFAbsoluteTimeGetCurrent() - start, format: .fixed(precision: 1))s")
            } catch {
                self.log.error("Studio prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Drops the pipeline and every loaded model (call after a batch of renders). Waits for an in-flight
    /// render to finish first.
    func unload() {
        queue.async {
            self.pipeline?.unloadResources()
            self.pipeline = nil
            self.pipelineComputeUnits = nil
        }
    }

    // MARK: - Private (on `queue`)

    private func preparedPipeline() throws -> StableDiffusionPipeline {
        dispatchPrecondition(condition: .onQueue(queue))
        let units = computeUnits
        if let pipeline, pipelineComputeUnits == units { return pipeline }
        pipeline?.unloadResources()
        guard let url = resourcesURL else { throw CocoaError(.fileNoSuchFile) }
        let config = MLModelConfiguration()
        config.computeUnits = units
        let built = try StableDiffusionPipeline(resourcesAt: url, controlNet: [], configuration: config,
                                                disableSafety: true, reduceMemory: true)
        pipeline = built
        pipelineComputeUnits = units
        return built
    }

    private func renderOnQueue(request: UInt64, startingImage: CGImage?, prompt: String, negativePrompt: String,
                               strength: Float, steps: Int, guidance: Float, seeds: [UInt32]) -> [CGImage?] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !seeds.isEmpty else { return [] }
        guard !isCancelled(request) else { return seeds.map { _ in nil } }
        let start = CFAbsoluteTimeGetCurrent()
        var input: CGImage?
        if let startingImage {
            input = Self.flattenedOnWhite(startingImage, size: Self.imageSize)
            if input == nil { return seeds.map { _ in nil } }
        }
        var pipe: StableDiffusionPipeline
        do {
            pipe = try preparedPipeline()
        } catch {
            log.error("Studio pipeline setup failed: \(String(describing: error), privacy: .public)")
            return seeds.map { _ in nil }
        }
        let setup = CFAbsoluteTimeGetCurrent() - start
        // Reduced memory always: the scan's models may be resident too. All seeds run as one
        // `imageCount` batch, so each model is still loaded only once per call.
        pipe.reduceMemory = true

        var config = StableDiffusionPipeline.Configuration(prompt: prompt)
        config.negativePrompt = negativePrompt
        config.startingImage = input
        // < 1: strength 1.0 would silently switch an img2img request to text-to-image.
        config.strength = input == nil ? 1 : min(max(strength, 0.01), 0.99)
        config.stepCount = max(1, steps)
        config.guidanceScale = guidance
        config.imageCount = seeds.count
        // The batch's noise is drawn from the first seed (image k uses the k-th draw), so results stay
        // deterministic per seed list.
        config.seed = seeds[0]
        config.disableSafety = true
        config.schedulerType = .dpmSolverMultistepScheduler  // DPM-Solver++ (2nd order)
        config.schedulerTimestepSpacing = .karras
        config.rngType = .torchRNG  // same noise as torch.manual_seed(seed) on CPU in diffusers

        var ranSteps = 0
        var results: [CGImage?] = seeds.map { _ in nil }
        do {
            let images = try pipe.generateImages(configuration: config) { progress in
                ranSteps = progress.step + 1
                return !self.isCancelled(request)
            }
            for (i, im) in images.prefix(seeds.count).enumerated() { results[i] = im }
        } catch {
            log.error("Studio render (seed \(seeds[0]) x\(seeds.count)) failed: \(String(describing: error), privacy: .public)")
        }
        if isCancelled(request) {
            pipe.unloadResources()
            log.info("Studio render cancelled")
            return seeds.map { _ in nil }
        }
        let total = CFAbsoluteTimeGetCurrent() - start
        if results.contains(where: { $0 != nil }) {
            let stats = RenderStats(setupSeconds: setup, totalSeconds: total, denoisingSteps: ranSteps,
                                    imageCount: seeds.count, textToImage: input == nil)
            stateLock.withLock { _lastStats = stats }
        }
        log.info("Studio render (\(input == nil ? "text2img" : "img2img", privacy: .public)): \(seeds.count) image(s) x \(ranSteps) steps in \(total, format: .fixed(precision: 1))s")
        return results
    }

    /// Letterboxes `image` onto an opaque white `size`x`size` sRGB canvas (transparency becomes white).
    static func flattenedOnWhite(_ image: CGImage, size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let scale = min(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }
}
