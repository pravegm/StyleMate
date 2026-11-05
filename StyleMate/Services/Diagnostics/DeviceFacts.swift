import CoreML
import Foundation
import os
import UIKit

/// The phone facts the Diagnostics screen and report show. A plain value so the report can be built
/// (and tested) without a device.
struct DeviceFacts: Codable, Equatable {
    var modelIdentifier: String
    var isSimulator: Bool
    var systemVersion: String
    var appVersion: String
    var appBuild: String
    /// "TestFlight", "App Store" or "Debug build".
    var distribution: String
    /// ProcessInfo.ThermalState as a word: nominal / fair / serious / critical.
    var thermalState: String
    var lowPowerMode: Bool
    /// 0...1, nil when unknown (simulator).
    var batteryLevel: Double?
    /// unplugged / charging / full / unknown.
    var batteryState: String
    var physicalMemoryBytes: UInt64
    /// What the app may still allocate before iOS ends it (`os_proc_available_memory`); nil on the simulator.
    var appAvailableMemoryBytes: UInt64?
    /// The app's own memory footprint (`phys_footprint`).
    var appFootprintBytes: UInt64
    var freeDiskBytes: Int64?
    /// e.g. ["CPU", "GPU", "Neural Engine (16 cores)"].
    var computeDevices: [String]
    var hasNeuralEngine: Bool

    var isCharging: Bool { batteryState == "charging" || batteryState == "full" }

    /// Reads everything now (main actor: UIDevice).
    @MainActor
    static func current() -> DeviceFacts {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main.infoDictionary
        let level = device.batteryLevel
        let devices = ComputeDevices.describe()
        return DeviceFacts(
            modelIdentifier: Self.modelIdentifier,
            isSimulator: Self.isSimulator,
            systemVersion: "\(device.systemName) \(device.systemVersion)",
            appVersion: bundle?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: bundle?["CFBundleVersion"] as? String ?? "?",
            distribution: Self.distribution,
            thermalState: Self.word(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            batteryLevel: level >= 0 ? Double(level) : nil,
            batteryState: Self.word(device.batteryState),
            physicalMemoryBytes: info.physicalMemory,
            appAvailableMemoryBytes: MemoryProbe.availableToApp,
            appFootprintBytes: MemoryProbe.footprint,
            freeDiskBytes: Self.freeDisk,
            computeDevices: devices.names,
            hasNeuralEngine: devices.hasNeuralEngine)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// "iPhone18,2" on a device; the simulated model on the simulator.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var distribution: String {
        #if DEBUG
        return "Debug build"
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "TestFlight" : "App Store"
        #endif
    }

    static var freeDisk: Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func word(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func word(_ s: UIDevice.BatteryState) -> String {
        switch s {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        default: return "unknown"
        }
    }

    // MARK: Plain-language values (screen + report)

    var thermalText: String {
        switch thermalState {
        case "nominal": return "Normal"
        case "fair": return "Warm"
        case "serious": return "Hot (work slows down)"
        case "critical": return "Very hot (work stops)"
        default: return "Unknown"
        }
    }

    var batteryText: String {
        let pct = batteryLevel.map { "\(Int(($0 * 100).rounded()))%" }
        switch batteryState {
        case "charging": return [pct, "charging"].compactMap { $0 }.joined(separator: ", ")
        case "full": return "Full, plugged in"
        case "unplugged": return [pct, "not charging"].compactMap { $0 }.joined(separator: ", ")
        default: return pct ?? "Unknown"
        }
    }

    var modelText: String { isSimulator ? "\(modelIdentifier) (Simulator)" : modelIdentifier }
}

// MARK: - Compute devices

enum ComputeDevices {
    /// The Core ML compute devices this phone has (`MLComputeDevice.allComputeDevices`).
    static func describe() -> (names: [String], hasNeuralEngine: Bool) {
        var names: [String] = []
        var ane = false
        for device in MLComputeDevice.allComputeDevices {
            switch device {
            case .cpu: names.append("CPU")
            case .gpu: names.append("GPU")
            case .neuralEngine(let ne):
                ane = true
                names.append("Neural Engine (\(ne.totalCoreCount) cores)")
            @unknown default: names.append("Other")
            }
        }
        return (names, ane)
    }

    static func name(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .neuralEngine: return "Neural Engine"
        @unknown default: return "Other"
        }
    }
}

// MARK: - Memory

enum MemoryProbe {
    /// The app's physical footprint in bytes (what iOS counts against the app's memory limit).
    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Memory the app can still allocate; nil on the simulator (no limit there).
    static var availableToApp: UInt64? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return UInt64(os_proc_available_memory())
        #endif
    }
}

/// Samples the app's footprint every `interval` on a background queue and keeps the maximum.
final class PeakMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?

    var peakBytes: UInt64 { lock.withLock { peak } }

    func start(interval: TimeInterval = 0.1) {
        stop()
        lock.withLock { peak = MemoryProbe.footprint }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.stylemates.StyleMate.memsampler", qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            let now = MemoryProbe.footprint
            guard let self else { return }
            self.lock.withLock { self.peak = max(self.peak, now) }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }
}

// MARK: - Formatting

enum DiagFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func bytes(_ b: UInt64?) -> String {
        guard let b else { return "n/a" }
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", locale: posix, gb) }
        return String(format: "%.0f MB", locale: posix, Double(b) / 1_048_576)
    }

    static func bytes(_ b: Int64?) -> String { bytes(b.map { UInt64(max(0, $0)) }) }

    /// "0.42 s", "4.1 s", "1 min 12 s".
    static func seconds(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "n/a" }
        if s < 1 { return String(format: "%.2f s", locale: posix, s) }
        if s < 60 { return String(format: "%.1f s", locale: posix, s) }
        let m = Int(s) / 60, r = Int(s.rounded()) - m * 60
        return "\(m) min \(r) s"
    }

    static func percent(_ f: Double) -> String { String(format: "%.0f%%", locale: posix, f * 100) }

    static func degrees(_ d: Double?) -> String {
        guard let d else { return "n/a" }
        return String(format: "%.0f°", locale: posix, d)
    }

    static func rect(_ r: CGRect?) -> String {
        guard let r else { return "none" }
        return String(format: "x %.0f, y %.0f, %.0f × %.0f pt", locale: posix, r.minX, r.minY, r.width, r.height)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd HH:mm ZZZZZ"
        return f.string(from: d)
    }
}
