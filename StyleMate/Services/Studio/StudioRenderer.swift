import CoreGraphics
import CoreML
import Foundation
import os

/// On-device "studio render" of a wardrobe item: Stable Diffusion 1.5-class img2img
/// (Lykon/dreamshaper-8, Core ML, 6-bit palettized, SPLIT_EINSUM_V2 attention) that turns a garment
/// cutout composited on white into a lifelike product photo. Fully on-device; nothing leaves the phone.
///
/// - Models: `StudioModels.bundle` in the app bundle (built by `scripts/build_studio_models.sh`,
///   git-ignored). If it's missing, `isAvailable` is false and `render` returns nil, so callers keep
///   the plain cutout.
/// - Runtime: Apple's ml-stable-diffusion Swift pipeline, vendored in `Vendor/StableDiffusion/`.
/// - Memory: the pipeline runs in `reduceMemory` mode, loading each model only while it is used (peak is
///   the UNet, a few hundred MB on the Neural Engine). Call `unload()` after a batch to drop everything.
/// - Threading: renders are serialized on a private queue (one at a time). The synchronous `render`
///   blocks its caller for seconds to minutes, so never call it on the main thread; use the `async`
///   overload from UI code.
final class StudioRenderer: @unchecked Sendable {
    static let shared = StudioRenderer()

    /// Output (and model input) edge in pixels; the models are converted for a 64x64 latent.
    static let imageSize = 512
    static let bundleName = "StudioModels"
    static let requiredResources = ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEEncoder.mlmodelc",
                                    "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

    struct RenderStats: Sendable {
        /// Pipeline construction + model loads (first render after `unload()` includes Core ML compilation).
        var setupSeconds: Double
        var totalSeconds: Double
        /// Denoising steps actually run (img2img skips the first `steps * (1 - strength)`).
        var denoisingSteps: Int
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

    /// `.cpuAndNeuralEngine` (default; the models are converted for the ANE, and iOS forbids GPU work in
    /// the background). Changing it rebuilds the pipeline on the next render.
    var computeUnits: MLComputeUnits {
        get { stateLock.withLock { _computeUnits } }
        set { stateLock.withLock { _computeUnits = newValue } }
    }

    /// Timing of the most recent successful render.
    var lastStats: RenderStats? { stateLock.withLock { _lastStats } }

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

    /// Renders a lifelike product photo from a cutout composited on white.
    ///
    /// - Parameters:
    ///   - cutoutOnWhite: the garment on a white background, any size (letterboxed onto 512x512 white;
    ///     transparent pixels become white).
    ///   - strength: 0...1, how far img2img may move from the input (~0.45-0.6 keeps the garment's shape).
    ///   - steps: scheduler steps for strength 1; `steps * strength` are actually run.
    ///   - guidance: classifier-free guidance scale (~6.5).
    /// - Returns: a 512x512 opaque sRGB image, or nil if the models are missing or inference failed.
    func render(cutoutOnWhite: CGImage, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seed: UInt32) -> CGImage? {
        if Thread.isMainThread {
            log.fault("StudioRenderer.render called on the main thread; use the async overload")
            assertionFailure("StudioRenderer.render must not run on the main thread")
        }
        guard isAvailable else { return nil }
        return queue.sync {
            renderOnQueue(cutoutOnWhite: cutoutOnWhite, prompt: prompt, negativePrompt: negativePrompt,
                          strength: strength, steps: steps, guidance: guidance, seed: seed)
        }
    }

    /// Async version of `render` for UI code; waits its turn behind other renders without blocking a thread.
    func render(cutoutOnWhite: CGImage, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seed: UInt32) async -> CGImage? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            queue.async {
                cont.resume(returning: self.renderOnQueue(
                    cutoutOnWhite: cutoutOnWhite, prompt: prompt, negativePrompt: negativePrompt,
                    strength: strength, steps: steps, guidance: guidance, seed: seed))
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

    private func renderOnQueue(cutoutOnWhite: CGImage, prompt: String, negativePrompt: String,
                               strength: Float, steps: Int, guidance: Float, seed: UInt32) -> CGImage? {
        dispatchPrecondition(condition: .onQueue(queue))
        let start = CFAbsoluteTimeGetCurrent()
        do {
            guard let input = Self.flattenedOnWhite(cutoutOnWhite, size: Self.imageSize) else { return nil }
            let pipe = try preparedPipeline()
            let setup = CFAbsoluteTimeGetCurrent() - start

            var config = StableDiffusionPipeline.Configuration(prompt: prompt)
            config.negativePrompt = negativePrompt
            config.startingImage = input
            config.strength = min(max(strength, 0.01), 0.99)  // 1.0 would silently switch to text-to-image
            config.stepCount = max(1, steps)
            config.guidanceScale = guidance
            config.seed = seed
            config.imageCount = 1
            config.disableSafety = true
            config.schedulerType = .dpmSolverMultistepScheduler  // DPM-Solver++ (2nd order)
            config.schedulerTimestepSpacing = .karras
            config.rngType = .torchRNG  // same noise as torch.manual_seed(seed) on CPU in diffusers

            var ranSteps = 0
            let images = try pipe.generateImages(configuration: config) { progress in
                ranSteps = progress.step + 1
                return true
            }
            guard let image = images.first ?? nil else { return nil }
            let total = CFAbsoluteTimeGetCurrent() - start
            stateLock.withLock { _lastStats = RenderStats(setupSeconds: setup, totalSeconds: total, denoisingSteps: ranSteps) }
            log.info("Studio render: \(ranSteps) steps in \(total, format: .fixed(precision: 1))s (setup \(setup, format: .fixed(precision: 1))s)")
            return image
        } catch {
            log.error("Studio render failed: \(String(describing: error), privacy: .public)")
            return nil
        }
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
