import BackgroundTasks
import Photos
import UIKit

/// Keeps the library scan going outside the foreground, like Google Photos:
///
/// - **Brief background**: when the app leaves the screen mid-scan it asks for
///   background time (`beginBackgroundTask`) to finish the photo in hand, and
///   checkpoints + parks the scan cleanly before that time runs out.
/// - **Overnight**: a `BGProcessingTask` (external power required) continues an
///   unfinished scan, or picks up new photos, while the phone charges.
/// - **New photos**: whenever the app becomes active, photos added since the
///   last check are scanned, so the wardrobe keeps growing on its own.
///
/// Scan state itself lives in `PhotoScanService` (checkpointed in
/// `ScanProgress`), so all three paths resume exactly where the last one stopped.
@MainActor
final class BackgroundScanCoordinator {
    static let shared = BackgroundScanCoordinator()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    nonisolated static let processingTaskID = "com.stylemates.StyleMate.photoscan"

    private weak var auth: AuthService?
    private weak var wardrobe: WardrobeViewModel?
    private var registered = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastActiveCheck: Date?
    /// Don't re-check the library on every quick app switch.
    private let activeCheckInterval: TimeInterval = 60

    private init() {}

    private var scanner: PhotoScanService { PhotoScanService.shared }

    // MARK: - Setup

    /// Called once from `StyleMateApp.init` (task handlers must be registered
    /// before the app finishes launching).
    func configure(auth: AuthService, wardrobe: WardrobeViewModel) {
        self.auth = auth
        self.wardrobe = wardrobe
        guard !registered else { return }
        registered = true
        // Launch handler on the main queue: the scan service is main-actor bound.
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskID,
                                                 using: DispatchQueue.main) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { BackgroundScanCoordinator.shared.handle(task) }
        }
        if !ok { print("[StyleMate] BG scan: task registration failed (identifier missing from Info.plist?)") }
    }

    // MARK: - App lifecycle

    /// App on screen: continue a parked scan, resume an unfinished one, or look
    /// for new photos.
    func appBecameActive() {
        endBackgroundTime()
        scanner.runContext = .foreground
        scanner.endSuspension()
        guard !scanner.isWorking, let ctx = scanContext() else { return }
        let unfinished = scanner.hasUnfinishedScan(forUser: ctx.userId)
        if !unfinished, let last = lastActiveCheck, Date().timeIntervalSince(last) < activeCheckInterval { return }
        lastActiveCheck = Date()
        Task {
            await scanner.continueScanning(forUser: ctx.userId, userGender: ctx.gender,
                                           wardrobeViewModel: ctx.wardrobe)
        }
    }

    /// App left the screen: keep scanning for the grace period, then park.
    /// Either way, schedule the overnight task if there's work left.
    func appDidEnterBackground() {
        scanner.flushProgress()
        if scanner.isWorking {
            scanner.runContext = .briefBackground
            if backgroundTaskID == .invalid {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StyleMate photo scan") {
                    // Called on the main thread shortly before the time is up.
                    MainActor.assumeIsolated {
                        BackgroundScanCoordinator.shared.backgroundTimeExpired()
                    }
                }
            }
        }
        scheduleProcessingTask()
    }

    private func backgroundTimeExpired() {
        scanner.suspend(reason: "Paused in the background")
        print("[StyleMate] BG scan: background time used up — parked, will continue later")
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Overnight processing task

    /// Asks iOS for a run while charging. Safe to call repeatedly: a pending
    /// request with the same identifier is replaced.
    func scheduleProcessingTask() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan,
              let ctx = scanContext(), hasWork(forUser: ctx.userId) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresExternalPower = true
        // iCloud originals download when there's a network, but a local-only
        // library can be scanned without one.
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[StyleMate] BG scan: overnight task scheduled")
        } catch {
            // Simulator, or Background App Refresh turned off.
            print("[StyleMate] BG scan: couldn't schedule (\(error.localizedDescription))")
        }
    }

    /// An unfinished scan, or a scanned range that new photos may have joined.
    private func hasWork(forUser userId: String) -> Bool {
        let progress = scanner.loadProgress(forUser: userId)
        return progress.activeJob != nil || progress.coverageStart != nil
    }

    /// Completes a background task exactly once (expiry and normal finish race). Also used
    /// by the morning-look refresh.
    final class TaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var done = false
        init(_ task: BGTask) { self.task = task }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func complete(success: Bool) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { task.setTaskCompleted(success: success) }
        }
    }

    private func handle(_ task: BGProcessingTask) {
        // Chain the next run first, so the scan keeps going on later nights.
        scheduleProcessingTask()
        let completion = TaskCompletion(task)
        task.expirationHandler = {
            Task { @MainActor in
                PhotoScanService.shared.suspend(reason: "Paused in the background")
                print("[StyleMate] BG scan: processing task expired — checkpointed")
                completion.complete(success: false)
            }
        }
        guard let ctx = scanContext() else { completion.complete(success: true); return }

        scanner.runContext = .processingTask
        scanner.endSuspension()
        print("[StyleMate] BG scan: overnight run started")
        Task {
            if !scanner.isWorking {
                await scanner.continueScanning(forUser: ctx.userId, userGender: ctx.gender,
                                               wardrobeViewModel: ctx.wardrobe)
            }
            // A scan that was parked by the brief-background expiry continues by
            // itself now; wait for it to finish (or for the task to expire).
            while scanner.isWorking && !completion.isDone {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            print("[StyleMate] BG scan: overnight run finished")
            completion.complete(success: true)
        }
    }

    // MARK: - Who to scan for

    private struct Context {
        let userId: String
        let gender: String?
        let wardrobe: WardrobeViewModel
    }

    /// The signed-in user, if they've finished onboarding and granted Photos
    /// access. Loads their wardrobe if the app was launched in the background.
    private func scanContext() -> Context? {
        guard let auth, let wardrobe, auth.isAuthenticated, let user = auth.user, !user.id.isEmpty,
              UserDefaults.standard.bool(forKey: "hasCompletedOnboarding_\(user.id)"),
              PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan else { return nil }
        if wardrobe.currentUserEmail != user.id { wardrobe.load(forUser: user.id) }
        return Context(userId: user.id, gender: user.gender, wardrobe: wardrobe)
    }
}

extension PHAuthorizationStatus {
    /// Full or limited access: the scan works on whatever photos it can see.
    var allowsScan: Bool { self == .authorized || self == .limited }
}
