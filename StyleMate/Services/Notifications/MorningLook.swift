import BackgroundTasks
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Retention loop A — a reason to open the app every morning.
///
/// A local notification at 7:30 (editable in Profile): "9° and cloudy — your
/// camel coat look is ready", with a picture of the look. Everything is local:
/// the look is precomputed on the device by `OutfitEngine` (when the app last
/// ran, and again in a `BGAppRefreshTask` shortly before the alarm with a fresh
/// forecast), stored in `MorningLookStore`, and scheduled with a
/// `UNCalendarNotificationTrigger`. Tapping it opens Today's Outfit with exactly
/// that look (`NotificationRouter` → `HomeViewModel.openLookInDeck`).
///
/// Permission is asked only after the user has saved their first outfit.
@MainActor
final class MorningLookScheduler: ObservableObject {
    static let shared = MorningLookScheduler()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    nonisolated static let refreshTaskID = "com.stylemates.StyleMate.morninglook"
    nonisolated static let category = "MORNING_LOOK"
    private static let idPrefix = "morningLook."
    /// Days ahead scheduled; days without a precomputed look get a plain reminder.
    static let daysAhead = 7

    private enum Key {
        static let enabled = "morningLook.enabled"
        static let hour = "morningLook.hour"
        static let minute = "morningLook.minute"
        static let offered = "morningLook.offered"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var hour: Int
    @Published private(set) var minute: Int
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private weak var auth: AuthService?
    private weak var wardrobe: WardrobeViewModel?
    private var registered = false

    private init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Key.enabled)
        hour = d.object(forKey: Key.hour) as? Int ?? 7
        minute = d.object(forKey: Key.minute) as? Int ?? 30
    }

    /// "7:30 AM"
    var timeText: String {
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    var time: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    // MARK: Setup

    /// From `StyleMateApp.init` (BG handlers must be registered before launch ends).
    func configure(auth: AuthService, wardrobe: WardrobeViewModel) {
        self.auth = auth
        self.wardrobe = wardrobe
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        guard !registered else { return }
        registered = true
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: DispatchQueue.main) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { MorningLookScheduler.shared.handle(task) }
        }
        if !ok { print("[StyleMate] Morning look: refresh task registration failed") }
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if isEnabled, authorization == .denied { setEnabled(false) }
    }

    // MARK: Asking (after the first saved outfit)

    /// Show the "Get tomorrow's look at 7:30?" card: an outfit has been saved,
    /// the user hasn't answered yet, and the system hasn't been asked.
    var shouldOffer: Bool {
        !isEnabled && !UserDefaults.standard.bool(forKey: Key.offered) && authorization == .notDetermined
    }

    func markOffered() {
        UserDefaults.standard.set(true, forKey: Key.offered)
        objectWillChange.send()
    }

    /// Asks iOS for permission (only alerts + sound, nothing else) and turns
    /// the morning look on if granted.
    @discardableResult
    func requestAndEnable() async -> Bool {
        markOffered()
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        setEnabled(granted)
        return granted
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        if on { Task { await reschedule() } } else { cancelAll() }
    }

    func setTime(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        hour = c.hour ?? 7
        minute = c.minute ?? 30
        UserDefaults.standard.set(hour, forKey: Key.hour)
        UserDefaults.standard.set(minute, forKey: Key.minute)
        if isEnabled { Task { await reschedule() } }
    }

    // MARK: Scheduling

    /// The next `daysAhead` alarms, the first one with a precomputed look.
    /// Called when the app goes to the background, from Profile, and from the
    /// refresh task. Cheap: one OutfitEngine pass.
    func reschedule(now: Date = Date()) async {
        guard isEnabled else { return }
        await refreshAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }
        let center = UNUserNotificationCenter.current()
        let fires = Self.fireDates(after: now, hour: hour, minute: minute, count: Self.daysAhead)
        guard let first = fires.first else { return }

        var requests: [UNNotificationRequest] = []
        if let look = await precompute(for: first) {
            requests.append(request(for: first, look: look))
        } else {
            requests.append(request(for: first, look: nil))
        }
        for date in fires.dropFirst() { requests.append(request(for: date, look: nil)) }

        cancelAll()
        for r in requests { try? await center.add(r) }
        scheduleRefreshTask(before: first)
        print("[StyleMate] Morning look: scheduled \(requests.count) (next \(first))")
    }

    private func cancelAll() {
        let center = UNUserNotificationCenter.current()
        let ids = (0..<(Self.daysAhead + 2)).map { "\(Self.idPrefix)\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func request(for date: Date, look: MorningLookStore.Look?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.category
        content.sound = .default
        content.userInfo = ["dayKey": MorningLookStore.dayKey(date)]
        if let look {
            content.title = "Today's outfit"
            content.body = look.headline
            if let url = look.thumbnailURL,
               let copy = Self.attachmentCopy(of: url),
               let attachment = try? UNNotificationAttachment(identifier: "look", url: copy, options: nil) {
                content.attachments = [attachment]
            }
        } else {
            content.title = "Today's outfit"
            content.body = "Your look for today is ready. Tap to see it."
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let index = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                            to: Calendar.current.startOfDay(for: date)).day ?? 0)
        return UNNotificationRequest(identifier: "\(Self.idPrefix)\(index)",
                                     content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }

    /// iOS moves an attachment file into its own store, so hand it a copy.
    private static func attachmentCopy(of url: URL) -> URL? {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("morning-\(UUID().uuidString).jpg")
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
    }

    /// Pure: the next `count` alarm times strictly after `now`.
    nonisolated static func fireDates(after now: Date, hour: Int, minute: Int, count: Int,
                                      calendar: Calendar = .current) -> [Date] {
        guard count > 0, var day = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return [] }
        if day <= now { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
    }

    // MARK: Precompute

    /// Styles the look for `date` from the wardrobe and that morning's forecast
    /// (falls back to the last reading). Stored so Home shows the same look.
    func precompute(for date: Date) async -> MorningLookStore.Look? {
        guard let auth, let wardrobe, let user = auth.user, !user.id.isEmpty else { return nil }
        if wardrobe.currentUserEmail != user.id { wardrobe.load(forUser: user.id) }
        let items = wardrobe.items
        guard items.count >= 4 else { return nil }
        if let existing = MorningLookStore.look(for: date, userId: user.id),
           existing.itemIDs.allSatisfy({ id in items.contains { $0.id == id } }) {
            return existing
        }
        let forecast = await MorningForecast.fetch(for: date)
        let weather = forecast ?? MorningForecast.cachedWeather()
        let log = MyOutfitsViewModel()
        log.setUser(user.id)
        let lastWorn = log.lastWornDates()
        var context = StylingContext(weather: weather, occasion: user.preferredStyles.first ?? .everyday, mood: nil,
                                     hints: StyleHints(), user: user, lastWorn: lastWorn, now: date,
                                     useFahrenheit: MorningForecast.prefersFahrenheit)
        context.taste = TasteStore.shared.profile(forUser: user.id, now: date)
        let seed = UInt64(bitPattern: Int64(MorningLookStore.dayKey(date)))
        let engine = OutfitEngine()
        let result = await Task.detached(priority: .utility) {
            engine.suggest(from: items, context: context, count: 1, seed: seed)
        }.value
        guard case .success(let looks) = result,
              let look = OutfitValidator.validateAndRepair(looks, wardrobe: items).first else { return nil }
        let headline = MorningLookStore.headline(for: look.items, weather: weather,
                                                  fahrenheit: MorningForecast.prefersFahrenheit)
        let thumb = await MorningLookStore.renderThumbnail(look.items, dayKey: MorningLookStore.dayKey(date))
        let stored = MorningLookStore.Look(dayKey: MorningLookStore.dayKey(date), userId: user.id,
                                           itemIDs: look.items.map(\.id), explanation: look.explanation,
                                           headline: headline, thumbnailFile: thumb)
        MorningLookStore.save(stored)
        return stored
    }

    // MARK: Background refresh

    private func scheduleRefreshTask(before fire: Date) {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // ~2 h before the alarm: late enough for a real forecast.
        request.earliestBeginDate = max(Date().addingTimeInterval(15 * 60), fire.addingTimeInterval(-2 * 3600))
        do { try BGTaskScheduler.shared.submit(request) }
        catch { print("[StyleMate] Morning look: couldn't schedule refresh (\(error.localizedDescription))") }
    }

    private func handle(_ task: BGAppRefreshTask) {
        let completion = BackgroundScanCoordinator.TaskCompletion(task)
        let work = Task { @MainActor in
            // Recompute the next look with a fresh forecast.
            if let first = Self.fireDates(after: Date(), hour: hour, minute: minute, count: 1).first {
                MorningLookStore.remove(dayKey: MorningLookStore.dayKey(first))
            }
            await reschedule()
            completion.complete(success: !Task.isCancelled)
        }
        // Out of time: stop and tell iOS now. An expired task that is never completed counts
        // against the app, and iOS then runs its refreshes less often.
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }
}

// MARK: - Store

/// The precomputed look per day, so the notification, its picture and Home's
/// Today's Outfit all show the same thing. UserDefaults + a small JPEG in Caches.
enum MorningLookStore {
    struct Look: Codable, Equatable {
        let dayKey: Double
        let userId: String
        let itemIDs: [UUID]
        let explanation: String
        let headline: String
        let thumbnailFile: String?

        var thumbnailURL: URL? { thumbnailFile.map { MorningLookStore.folder.appendingPathComponent($0) } }
    }

    private static let key = "morningLooks"

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> Double {
        calendar.startOfDay(for: date).timeIntervalSinceReferenceDate
    }

    static var folder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MorningLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func all() -> [Look] {
        (UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Look].self, from: $0) }) ?? []
    }

    static func look(for date: Date, userId: String) -> Look? {
        let k = dayKey(date)
        return all().first { $0.dayKey == k && $0.userId == userId }
    }

    static func look(dayKey k: Double) -> Look? { all().first { $0.dayKey == k } }

    static func save(_ look: Look) {
        // Keep the last week only.
        let cutoff = dayKey(Date()) - 7 * 86_400
        var looks = all().filter { $0.dayKey != look.dayKey && $0.dayKey >= cutoff }
        looks.append(look)
        if let data = try? JSONEncoder().encode(looks) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func remove(dayKey k: Double) {
        let looks = all().filter { $0.dayKey != k }
        if let data = try? JSONEncoder().encode(looks) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: folder)
    }

    /// "9° and cloudy — your camel coat look is ready"
    static func headline(for items: [WardrobeItem], weather: Weather?, fahrenheit: Bool) -> String {
        let hero = heroPiece(items).map { WearLogSuggestions.shortName($0) }
        let lookText = hero.map { "your \($0) look is ready" } ?? "your look is ready"
        guard let weather else { return lookText.prefix(1).uppercased() + lookText.dropFirst() }
        let t = fahrenheit ? weather.temperature2m * 9 / 5 + 32 : weather.temperature2m
        let condition = weather.displayDescription.lowercased()
        return "\(Int(t.rounded()))° and \(condition) — \(lookText)"
    }

    /// The piece a look is "about": the coat if there is one, else the dress, the top…
    static func heroPiece(_ items: [WardrobeItem]) -> WardrobeItem? {
        let rank: [Category: Int] = [.outerwear: 0, .onePieces: 1, .ethnicWear: 1, .midLayers: 2, .tops: 3,
                                     .activewear: 3, .bottoms: 4, .footwear: 5, .accessories: 6, .innerwear: 7]
        return items.min { (rank[$0.category] ?? 9) < (rank[$1.category] ?? 9) }
    }

    /// A small flat-lay of the look's thumbnails (JPEG) for the notification.
    static func renderThumbnail(_ items: [WardrobeItem], dayKey: Double) async -> String? {
        let paths = items.prefix(4).compactMap { $0.thumbnailPath ?? $0.imagePath }
        guard !paths.isEmpty else { return nil }
        let name = "look-\(Int(dayKey)).jpg"
        let url = folder.appendingPathComponent(name)
        let ok: Bool = await Task.detached(priority: .utility) {
            let images = paths.compactMap { WardrobeImageFileHelper.loadImage(at: $0) }
            guard !images.isEmpty else { return false }
            let side: CGFloat = 400
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
                UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
                let cols = images.count == 1 ? 1 : 2
                let rows = images.count <= 2 ? 1 : 2
                let cw = side / CGFloat(cols), ch = side / CGFloat(rows)
                for (i, img) in images.enumerated() {
                    let cell = CGRect(x: CGFloat(i % cols) * cw, y: CGFloat(i / cols) * ch, width: cw, height: ch)
                        .insetBy(dx: 14, dy: 14)
                    let s = min(cell.width / max(img.size.width, 1), cell.height / max(img.size.height, 1))
                    let size = CGSize(width: img.size.width * s, height: img.size.height * s)
                    img.draw(in: CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2,
                                        width: size.width, height: size.height))
                }
            }
            guard let data = image.jpegData(compressionQuality: 0.8) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }.value
        return ok ? name : nil
    }
}

// MARK: - Forecast

/// That morning's weather for the notification. Approximate coordinates only
/// (2 decimals, ~1 km), from the last location iOS already has; nothing else
/// is sent. Falls back to the last reading Home cached.
enum MorningForecast {
    static var prefersFahrenheit: Bool { Locale.current.measurementSystem == .us }

    static func cachedWeather() -> Weather? {
        UserDefaults.standard.data(forKey: "cachedWeather").flatMap { try? JSONDecoder().decode(Weather.self, from: $0) }
    }

    private struct Hourly: Decodable {
        struct H: Decodable { let time: [String]; let temperature_2m: [Double]; let weather_code: [Int] }
        let hourly: H
    }

    static func fetch(for date: Date) async -> Weather? {
        guard let loc = CLLocationManager().location else { return nil }
        let lat = String(format: "%.2f", loc.coordinate.latitude)
        let lon = String(format: "%.2f", loc.coordinate.longitude)
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)" +
                            "&hourly=temperature_2m,weather_code&forecast_days=3&timezone=auto") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Hourly.self, from: result.0) else { return nil }
        // Open-Meteo local time strings: "2026-11-05T07:00".
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = .current
        let hourStart = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: date),
                                              minute: 0, second: 0, of: date) ?? date
        let target = f.string(from: hourStart)
        let h = decoded.hourly
        guard let i = h.time.firstIndex(of: target) ?? h.time.firstIndex(where: { $0 > target }),
              i < h.temperature_2m.count, i < h.weather_code.count else { return nil }
        let hour = Calendar.current.component(.hour, from: date)
        return Weather(temperature2m: h.temperature_2m[i], weathercode: h.weather_code[i],
                       isDay: (6..<19).contains(hour) ? 1 : 0, time: h.time[i], city: cachedWeather()?.city)
    }
}

// MARK: - Router

/// Shows the morning notification even when the app is open, and turns a tap
/// into "open Today's Outfit with that look" (observed by Home).
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = NotificationRouter()

    /// Day key of the look to open; Home consumes and clears it.
    @Published var pendingMorningLook: Double?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let day = info["dayKey"] as? Double ?? MorningLookStore.dayKey(Date())
        if response.notification.request.content.categoryIdentifier == MorningLookScheduler.category {
            Task { @MainActor in NotificationRouter.shared.pendingMorningLook = day }
        }
        completionHandler()
    }
}
