import CoreImage
import UIKit

/// The Core Image contexts every renderer shares. iOS doesn't let a backgrounded app submit
/// GPU work, and the overnight scan runs in a BGProcessingTask: a GPU render there comes back
/// blank or nil. So whenever the app isn't active, renders use a software (CPU) context.
///
/// A render that still comes back empty is reported with `noteFailure()`; the scan compares
/// `failures` before and after a photo and retries that photo later instead of marking it done.
///
/// Thread-safe.
enum CoreImageContext {
    private static let gpu = CIContext(options: [.useSoftwareRenderer: false])
    private static let software = CIContext(options: [.useSoftwareRenderer: true])

    /// The context to render with right now.
    static var current: CIContext { AppActivity.isActive ? gpu : software }

    private static let lock = NSLock()
    private static var failureCount = 0

    /// How many renders have come back empty since launch.
    static var failures: Int {
        lock.lock(); defer { lock.unlock() }
        return failureCount
    }

    static func noteFailure(_ what: String) {
        lock.lock()
        failureCount += 1
        lock.unlock()
        dlog("[CoreImage] Render came back empty (\(what)), app active: \(AppActivity.isActive)")
    }
}

/// Whether the app is the active foreground app, readable from any thread (UIApplication's
/// `applicationState` is main-thread only). Starts false, so a launch straight into a
/// background task never assumes the GPU.
enum AppActivity {
    private static let lock = NSLock()
    private static var active = false

    private static let observers: [NSObjectProtocol] = {
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                AppActivity.set(true)
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
                AppActivity.set(false)
            },
        ]
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppActivity.set(UIApplication.shared.applicationState == .active) }
        }
        return tokens
    }()

    private static func set(_ value: Bool) {
        lock.lock(); active = value; lock.unlock()
    }

    /// Call once early on the main thread (it starts listening); reading works without it.
    static func start() { _ = observers }

    static var isActive: Bool {
        _ = observers
        lock.lock(); defer { lock.unlock() }
        return active
    }
}
