import CoreML
import Foundation

/// Where Core ML will actually run each bundled model on this phone: the compute plan's preferred device for
/// every operation (`MLComputePlan`, iOS 17.4+), weighted by Core ML's own cost estimate. Answers "is the
/// Neural Engine really used?" without Instruments.
///
/// Generic: it finds every compiled model (`.mlmodelc`) in the app bundle, including inside resource bundles
/// (StudioModels.bundle), so a model swap needs no change here.
struct ModelPlacement: Codable, Equatable {
    /// File name without `.mlmodelc` (e.g. "GarmentNet", "StudioModels/Unet").
    var model: String
    /// Share of the estimated cost per device name ("Neural Engine", "CPU", "GPU"), 0...1.
    var shares: [String: Double]
    var operationCount: Int
    /// Why there is no plan (load failed, unsupported format).
    var error: String?

    /// "Neural Engine 97%, CPU 3%", largest first.
    var summary: String {
        if let error { return "unknown (\(error))" }
        guard !shares.isEmpty else { return "no operations" }
        return shares.sorted { $0.value > $1.value }
            .map { "\($0.key) \(DiagFormat.percent($0.value))" }
            .joined(separator: ", ")
    }

    /// Share of the work on the Neural Engine.
    var neuralEngineShare: Double { shares["Neural Engine"] ?? 0 }
}

enum ModelPlacementProbe {
    /// Every compiled model in `bundle` (and its nested `.bundle`s), sorted by name.
    static func bundledModels(in bundle: Bundle = .main) -> [(name: String, url: URL)] {
        guard let root = bundle.resourceURL else { return [] }
        var out: [(name: String, url: URL)] = []
        let fm = FileManager.default
        func scan(_ dir: URL, prefix: String, depth: Int) {
            guard depth < 3, let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for url in entries {
                let ext = url.pathExtension
                if ext == "mlmodelc" {
                    out.append((name: prefix + url.deletingPathExtension().lastPathComponent, url: url))
                } else if ext == "bundle" {
                    scan(url, prefix: prefix + url.deletingPathExtension().lastPathComponent + "/", depth: depth + 1)
                }
            }
        }
        scan(root, prefix: "", depth: 0)
        return out.sorted { $0.name < $1.name }
    }

    /// The plan for one model with the units the app uses (`.cpuAndNeuralEngine`: iOS forbids the GPU in the
    /// background, and every model is loaded that way).
    static func placement(name: String, url: URL,
                          computeUnits: MLComputeUnits = .cpuAndNeuralEngine) async -> ModelPlacement {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        do {
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: config)
            var tally = Tally()
            collect(plan.modelStructure, plan: plan, tally: &tally)
            let ops = tally.ops
            // Weighted by Core ML's cost estimate; by operation count when it gives none.
            let weights = tally.costs.values.reduce(0, +) > 0 ? tally.costs : tally.counts
            let total = weights.values.reduce(0, +)
            let shares = total > 0 ? weights.mapValues { $0 / total } : [:]
            return ModelPlacement(model: name, shares: shares, operationCount: ops,
                                  error: ops == 0 ? "no operations in the plan" : nil)
        } catch {
            return ModelPlacement(model: name, shares: [:], operationCount: 0,
                                  error: String(describing: error).prefix(120).description)
        }
    }

    private struct Tally {
        var costs: [String: Double] = [:]
        var counts: [String: Double] = [:]
        var ops = 0
        mutating func add(_ device: String, cost: Double) {
            ops += 1
            counts[device, default: 0] += 1
            costs[device, default: 0] += max(cost, 0)
        }
    }

    private static func collect(_ structure: MLModelStructure, plan: MLComputePlan, tally: inout Tally) {
        switch structure {
        case .program(let program):
            for function in program.functions.values {
                collect(function.block, plan: plan, tally: &tally)
            }
        case .neuralNetwork(let network):
            for layer in network.layers {
                guard let usage = plan.deviceUsage(for: layer) else { continue }
                tally.add(ComputeDevices.name(usage.preferred), cost: 0)   // no cost estimate for layers
            }
        case .pipeline(let pipeline):
            for sub in pipeline.subModels { collect(sub, plan: plan, tally: &tally) }
        case .unsupported:
            break
        @unknown default:
            break
        }
    }

    private static func collect(_ block: MLModelStructure.Program.Block, plan: MLComputePlan,
                                tally: inout Tally) {
        for op in block.operations {
            for inner in op.blocks { collect(inner, plan: plan, tally: &tally) }
            // Constants and other free ops have no device usage.
            guard let usage = plan.deviceUsage(for: op) else { continue }
            tally.add(ComputeDevices.name(usage.preferred), cost: plan.estimatedCost(of: op)?.weight ?? 0)
        }
    }
}
