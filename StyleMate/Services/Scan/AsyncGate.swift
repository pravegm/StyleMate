import Foundation

/// A FIFO async mutex: at most one holder at a time, across suspension points
/// (an actor alone doesn't do that — it's re-entrant at every `await`).
///
/// The scan prepares the next photos while the current one is extracted, so
/// two tasks can reach the same Core ML pipeline at once. Identity resolution
/// (`FaceMatchingService`, which also mutates the face gallery) and garment
/// extraction (`WardrobeExtractor`) each go through their own gate.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the next waiter (in arrival order), or frees it.
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
