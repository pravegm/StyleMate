#if DEBUG
import UIKit

/// DEBUG-only UI-test hook for "On you" (never compiled into Release):
///
/// - `-uiTestSeedTryOn`  use a bundled CC0 sample photo as the try-on body, render looks with the
///   deterministic composite only (no diffusion: the UI-test job has no studio models), and keep the
///   composite even when the gate would fall back to the pieces, so the screenshots always show the
///   On you state.
@MainActor
enum TryOnDebugSeed {
    static let argument = "-uiTestSeedTryOn"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// Called once at launch (from `StyleMateApp`).
    static func applyIfNeeded() {
        guard isActive else { return }
        TryOnQueue.shared.harmonizeEnabled = false
        TryOnQueue.shared.debugKeepRejected = true
        TryOnAvailability.userEnabled = true
        Task { @MainActor in
            let urls = SampleLibrary.photoURLs(bundle: .main)
            guard let url = urls.first(where: { $0.lastPathComponent.contains("pink_coat") }) ?? urls.first,
                  let img = UIImage(contentsOfFile: url.path) else {
                print("[UITest] try-on seed: no sample photo in the bundle")
                return
            }
            await TryOnBodyLibrary.shared.debugUse(img)
            print("[UITest] try-on seed: body ready = \(TryOnBodyLibrary.shared.current != nil)")
        }
    }
}
#endif
