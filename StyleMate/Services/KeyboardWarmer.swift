import UIKit

/// One-time keyboard pre-warm.
///
/// The very first time any text field becomes first responder, UIKit has to load
/// the keyboard subsystem (UIKeyboardImpl, input views, predictive bar) from cold —
/// a one-off ~1-2s main-thread cost that lands on whichever field you tap first. In
/// StyleMate that's the onboarding "About you" name field, so the first tap felt
/// like a hang.
///
/// We warm it ahead of time by briefly making an offscreen UITextField the first
/// responder and resigning it in the SAME run-loop turn. UIKit loads the keyboard
/// machinery but never actually presents it (the responder is already gone before
/// the show animation would run), so there's no visible flash.
enum KeyboardWarmer {
    private static var warmed = false

    @MainActor
    static func warm() {
        guard !warmed else { return }
        warmed = true

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return }

        let field = UITextField()
        field.alpha = 0                 // invisible; alpha-0 can still become first responder
        window.addSubview(field)
        field.becomeFirstResponder()
        field.resignFirstResponder()
        field.removeFromSuperview()
    }
}
