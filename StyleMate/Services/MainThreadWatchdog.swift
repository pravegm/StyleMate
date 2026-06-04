import Foundation
import QuartzCore

/// DEBUG-only diagnostic: detects when the main thread is blocked (UI frozen /
/// taps not registering) and logs how long it was stuck. A CADisplayLink fires
/// on the main run loop every frame; if the main thread hangs, the gap between
/// consecutive ticks reveals the stall duration. Correlate the logged timestamp
/// with the surrounding [StyleMate] logs to find the culprit.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private var link: CADisplayLink?
    private var last = CFAbsoluteTimeGetCurrent()
    private let threshold: CFTimeInterval = 0.35

    private init() {}

    func start() {
        #if DEBUG
        guard link == nil else { return }
        last = CFAbsoluteTimeGetCurrent()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        print("[Watchdog] Main-thread hang detector started (threshold \(Int(threshold * 1000))ms)")
        #endif
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        let now = CFAbsoluteTimeGetCurrent()
        let delta = now - last
        last = now
        if delta > threshold {
            print(String(format: "[Watchdog] ⚠️ Main thread blocked %.0fms", delta * 1000))
        }
    }
}
