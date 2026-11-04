import Foundation

/// A FIFO counting semaphore for async code: at most `permits` holders at once, held
/// across suspension points (an actor alone is re-entrant at every `await`).
actor AsyncSemaphore {
    private let permits: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func acquire() async {
        if inUse < permits { inUse += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        // The releaser handed its permit straight to us; `inUse` is unchanged.
    }

    /// Hands the permit to the next waiter (arrival order), or frees it.
    func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// For tests / diagnostics.
    var holders: Int { inUse }
    var waiting: Int { waiters.count }
}

/// The one gate every garment extraction goes through — manual add (photo picker /
/// camera) AND the library scan. Each extraction holds ~100–200 MB (five Core ML models'
/// activations, labeler logits, full-res cutouts), so running many at once is what gets
/// the app jetsammed. Sharing a single gate means a manual add interleaves with the scan
/// instead of stacking on top of it.
///
/// Two permits on devices with plenty of RAM (≥ 6 GB: iPhone 15 Pro and later), one
/// otherwise.
///
/// Adoption: `PhotoScanService` should use `ExtractionGate.shared` instead of its private
/// `extractionGate` (same `acquire()` / `release()` API).
enum ExtractionGate {
    static let permits: Int = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024 ? 2 : 1
    static let shared = AsyncSemaphore(permits: permits)
}
