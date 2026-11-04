#if DEBUG
import UIKit

/// DEBUG-only: `-uiTestOrientation portrait|landscape` keeps asking the window scene for that orientation.
///
/// The iPhone Duo simulator shows its inner display sideways (book pose) and `simctl` cannot rotate it, so the
/// Duo CI (`.github/workflows/duo.yml`, seated pass) launches with `-uiTestOrientation portrait` to get Apple's
/// seated / tabletop pose (669 × 951 pt, fold running side to side). It re-asks every 2 s because opening and
/// closing the phone moves the app between displays and the inner display does not keep the orientation.
/// Logs `[Duo] orientation <want> ok <W>x<H>` each time the window reaches the wanted shape.
enum DebugOrientation {
    @MainActor
    static func startIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "uiTestOrientation") else { return }
        let portrait = raw == "portrait"
        let mask: UIInterfaceOrientationMask = portrait ? .portrait : .landscape
        Task { @MainActor in
            var lastOK: CGSize? = nil
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                      let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { continue }
                let size = window.bounds.size
                if portrait == (size.height > size.width) {
                    if lastOK != size {
                        lastOK = size
                        NSLog("%@", "[Duo] orientation \(raw) ok \(Int(size.width))x\(Int(size.height))")
                    }
                    continue
                }
                lastOK = nil
                NSLog("%@", "[Duo] orientation \(raw) requested; window \(Int(size.width))x\(Int(size.height))")
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    NSLog("%@", "[Duo] orientation request error: \(error.localizedDescription)")
                }
            }
        }
    }
}
#endif
