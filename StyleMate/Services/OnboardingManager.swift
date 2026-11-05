import SwiftUI

@MainActor
class OnboardingManager: ObservableObject {
    @Published var hasCompletedOnboarding: Bool = false

    private func key(for userId: String) -> String {
        "hasCompletedOnboarding_\(userId)"
    }

    func check(forUser userId: String) {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: key(for: userId))
        print("[StyleMate] Onboarding check for \(userId): completed=\(hasCompletedOnboarding)")
    }

    func complete(forUser userId: String) {
        UserDefaults.standard.set(true, forKey: key(for: userId))
        // No coach-mark tour after onboarding: the first minutes belong to the
        // closet filling up. The tour stays one tap away (Profile → Replay app
        // tour); the short outfit-sheet tour still runs the first time it opens.
        UserDefaults.standard.set(true, forKey: "tour_home_\(userId)")
        withAnimation(.easeInOut(duration: 0.3)) {
            hasCompletedOnboarding = true
        }
        print("[StyleMate] Onboarding completed for \(userId)")
    }

    func reset(forUser userId: String) {
        UserDefaults.standard.set(false, forKey: key(for: userId))
        hasCompletedOnboarding = false
        print("[StyleMate] Onboarding reset for \(userId)")
    }
}

/// Public legal pages (GitHub Pages, from docs/ in the repo).
enum LegalLinks {
    static let privacyPolicy = URL(string: "https://pravegm.github.io/StyleMate/privacy.html")!
}
