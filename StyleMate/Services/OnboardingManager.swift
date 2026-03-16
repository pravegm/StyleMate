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
