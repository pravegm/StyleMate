import Foundation

/// Runs a synchronous call that might block for good (a Vision request: on the founder's iPhone Duo
/// one never returned and the scan stood still) on its own thread, and waits at most `seconds`.
/// Past that the caller gets nil and takes its fallback, and the call is skipped for the rest of the
/// launch, so at most one thread is ever stuck per kind. Diagnostics › Photo scan lists what timed out.
///
///     let mask = HangGuard.run("person mask", seconds: 15) { try? handler.perform([request]); ... }
enum HangGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stuck: Set<String> = []

    static func isStuck(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stuck.contains(key)
    }

    static func run<T>(_ key: String, seconds: Double, _ work: @escaping () -> T?) -> T? {
        guard !isStuck(key) else { return nil }
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.set(work())
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            lock.lock(); stuck.insert(key); lock.unlock()
            print("[HangGuard] \(key) didn't return in \(Int(seconds)) s; skipped from now on")
            ScanTrace.shared.setNote("Timed out", key)
            return nil
        }
        return box.value
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ v: T?) { lock.lock(); stored = v; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
