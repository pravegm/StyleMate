import Foundation
import UIKit
import UserNotifications

/// "Your closet is ready: 25 pieces": a local notification at 10, 25 and 50 pieces while the very
/// first library scan runs and StyleMate isn't on screen, so someone who left during the scan comes
/// back to a full closet. Only when notifications are already allowed. This never asks for
/// permission: that ask belongs to the morning look, after the first saved outfit.
/// Each milestone fires at most once per profile.
@MainActor
final class ClosetReadyNotifier {
    static let shared = ClosetReadyNotifier()

    static let milestones = [10, 25, 50]

    private init() {}

    private static func firedKey(_ userId: String) -> String { "closetReadyMilestones_\(userId)" }

    /// The milestone a count newly reaches, given the ones already fired (pure, unit tested).
    static func milestone(reachedBy count: Int, fired: Set<Int>) -> Int? {
        milestones.filter { count >= $0 && !fired.contains($0) }.max()
    }

    static func title(for pieces: Int) -> String { "Your closet is ready: \(pieces) pieces" }

    /// Called as the scan adds pieces. `counted` is the closet's own (non-sample) pieces.
    func closetGrew(to counted: Int, userId: String) {
        guard !userId.isEmpty,
              !UserDefaults.standard.bool(forKey: "hasCompletedInitialScan_\(userId)") else { return }
        var fired = Set(UserDefaults.standard.array(forKey: Self.firedKey(userId)) as? [Int] ?? [])
        guard let milestone = Self.milestone(reachedBy: counted, fired: fired) else { return }
        // Every smaller milestone counts as passed too (one notification, not three).
        for m in Self.milestones where m <= milestone { fired.insert(m) }
        UserDefaults.standard.set(Array(fired).sorted(), forKey: Self.firedKey(userId))
        // On screen, the closet filling up is the news; no banner needed.
        guard UIApplication.shared.applicationState != .active else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = Self.title(for: counted)
            content.body = "StyleMate found them in your photos. Tap to see your closet and today's outfit."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "closetReady.\(milestone)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    func forget(userId: String) {
        UserDefaults.standard.removeObject(forKey: Self.firedKey(userId))
    }
}
