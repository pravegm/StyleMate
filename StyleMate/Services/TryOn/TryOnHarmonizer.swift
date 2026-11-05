import CoreGraphics
import CoreML
import Foundation
import os

/// The light diffusion pass over a try-on composite: **differential diffusion** with the studio's own
/// on-device Stable Diffusion 1.5 model (dreamshaper-8, `StudioModels.bundle`; no new weights).
///
/// Every latent pixel has its own strength (0 = frozen, 1 = fully regenerated). A pixel joins the
/// denoising only once the schedule has come down to its strength; until then it is reset each step
/// to the original latent noised to the current timestep (training-free, Levin & Fried 2024). So the
/// garments get a gentle relight (~0.3), uncovered skin / background is repainted (~0.75), and the
/// face, hands and background stay exactly the photo's (0).
///
/// Mirrors `tryon-lab/harmonize.py`. Runs on its own serial queue; callers make sure the studio
/// renderer isn't holding its ~1 GB UNet at the same time (`TryOnQueue` waits for `StudioQueue`).
final class TryOnHarmonizer: @unchecked Sendable {
    static let shared = TryOnHarmonizer()

    static let side = 512
    static let latentSide = 64

    private let log = Logger(subsystem: "com.stylemates.StyleMate", category: "TryOnHarmonizer")
    private let queue = DispatchQueue(label: "com.stylemates.StyleMate.tryon-harmonize", qos: .utility)
    private let resourcesURL: URL?
    private var pipeline: StableDiffusionPipeline?   // on `queue`
    private let lock = NSLock()
    private var cancelled = false
    private(set) var lastSeconds: Double = 0
    private(set) var lastSteps = 0

    /// `.cpuAndNeuralEngine` like the studio renderer (no GPU in the background).
    var computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    init(resourcesURL: URL? = Bundle.main.url(forResource: StudioRenderer.bundleName, withExtension: "bundle")) {
        self.resourcesURL = resourcesURL
    }

    var isAvailable: Bool {
        guard let url = resourcesURL else { return false }
        return StudioRenderer.requiredResources.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Frees the models (call when a batch is done).
    func unload() {
        queue.async {
            self.pipeline?.unloadResources()
            self.pipeline = nil
        }
    }

    /// - Parameters:
    ///   - image: 512x512 opaque composite.
    ///   - strength: 64x64 per-latent-pixel strength, row-major.
    /// - Returns: the 512x512 result, or nil (models missing, cancelled, error).
    func harmonize(image: CGImage, strength: [Float], prompt: String, negativePrompt: String,
                   steps: Int = 20, guidance: Float = 5, seed: UInt32 = 1) async -> CGImage? {
        guard isAvailable else { return nil }
        lock.withLock { cancelled = false }
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            queue.async {
                cont.resume(returning: autoreleasepool {
                    self.run(image: image, strength: strength, prompt: prompt, negativePrompt: negativePrompt,
                             steps: steps, guidance: guidance, seed: seed)
                })
            }
        }
    }

    private func preparedPipeline() throws -> StableDiffusionPipeline {
        if let pipeline { return pipeline }
        guard let url = resourcesURL else { throw CocoaError(.fileNoSuchFile) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        let p = try StableDiffusionPipeline(resourcesAt: url, controlNet: [], configuration: cfg,
                                            disableSafety: true, reduceMemory: true)
        pipeline = p
        return p
    }

    private func run(image: CGImage, strength: [Float], prompt: String, negativePrompt: String,
                     steps: Int, guidance: Float, seed: UInt32) -> CGImage? {
        let start = CFAbsoluteTimeGetCurrent()
        let n = Self.latentSide * Self.latentSide
        guard strength.count == n, let smax = strength.max(), smax > 0.01 else { return image }
        do {
            let pipe = try preparedPipeline()
            // Text.
            let cond = try pipe.textEncoder.encode(prompt)
            let uncond = try pipe.textEncoder.encode(negativePrompt)
            let hidden = pipe.toHiddenStates(MLShapedArray<Float32>(concatenating: [uncond, cond], alongAxis: 0))
            pipe.textEncoder.unloadResources()
            // Image latent + noise from one seeded torch-compatible source.
            var random: RandomSource = TorchRandomSource(seed: seed)
            guard let encoder = pipe.encoder else { return nil }
            let x0 = try encoder.encode(image, scaleFactor: 0.18215, random: &random)
            encoder.unloadResources()
            var shape = pipe.unet.latentSampleShape
            shape[0] = 1
            let noise = MLShapedArray<Float32>(converting: random.normalShapedArray(shape, mean: 0, stdev: 1))
            let scheduler = DPMSolverMultistepScheduler(stepCount: steps, timeStepSpacing: .karras)
            let ts = scheduler.timeSteps
            let i0 = max(0, steps - Int(Float(steps) * min(0.99, smax)))
            func noised(_ i: Int) -> MLShapedArray<Float32> {
                let a = scheduler.alphasCumProd[ts[i]]
                return scheduler.weightedSum([Double(sqrt(a)), Double(sqrt(1 - a))], [x0, noise])
            }
            var lat = noised(i0)
            var ran = 0
            for i in i0..<steps {
                if isCancelled { pipe.unloadResources(); return nil }
                let t = ts[i]
                if i > i0 {
                    // Pixels whose strength is below this point of the schedule follow the original.
                    let thr = 1 - Float(i) / Float(steps)
                    let orig = noised(i)
                    lat = blend(lat, orig, strength: strength, keepBelow: thr)
                }
                var eps: MLShapedArray<Float32>
                if pipe.unet.latentSampleShape[0] >= 2 {
                    let both = MLShapedArray<Float32>(concatenating: [lat, lat], alongAxis: 0)
                    eps = try pipe.unet.predictNoise(latents: [both], timeStep: t, hiddenStates: hidden)[0]
                } else {
                    var h0 = MLShapedArray<Float32>(converting: hidden[0]); h0 = MLShapedArray(scalars: h0.scalars, shape: [1] + h0.shape)
                    var h1 = MLShapedArray<Float32>(converting: hidden[1]); h1 = MLShapedArray(scalars: h1.scalars, shape: [1] + h1.shape)
                    let u = try pipe.unet.predictNoise(latents: [lat], timeStep: t, hiddenStates: h0)[0]
                    let c = try pipe.unet.predictNoise(latents: [lat], timeStep: t, hiddenStates: h1)[0]
                    eps = MLShapedArray<Float32>(concatenating: [u, c], alongAxis: 0)
                }
                eps = pipe.performGuidance(eps, guidance)
                lat = scheduler.step(output: eps, timeStep: t, sample: lat)
                ran += 1
            }
            pipe.unet.unloadResources()
            // Frozen pixels end exactly on the original latent.
            lat = blend(lat, x0, strength: strength, keepBelow: 0.0001)
            let out = try pipe.decoder.decode([lat], scaleFactor: 0.18215).first
            pipe.decoder.unloadResources()
            lastSeconds = CFAbsoluteTimeGetCurrent() - start
            lastSteps = ran
            log.info("Try-on harmonise: \(ran) steps in \(self.lastSeconds, format: .fixed(precision: 1))s")
            return out
        } catch {
            log.error("Try-on harmonise failed: \(String(describing: error), privacy: .public)")
            pipeline?.unloadResources()
            pipeline = nil
            return nil
        }
    }

    /// Where `strength < keepBelow`, takes `orig`; elsewhere keeps `cur`. Latents are [1, 4, 64, 64].
    private func blend(_ cur: MLShapedArray<Float32>, _ orig: MLShapedArray<Float32>, strength: [Float],
                       keepBelow thr: Float) -> MLShapedArray<Float32> {
        let n = Self.latentSide * Self.latentSide
        var s = cur.scalars
        let o = orig.scalars
        let channels = s.count / n
        for p in 0..<n where strength[p] < thr {
            for c in 0..<channels { s[c * n + p] = o[c * n + p] }
        }
        return MLShapedArray(scalars: s, shape: cur.shape)
    }
}
