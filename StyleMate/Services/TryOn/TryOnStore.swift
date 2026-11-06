import CryptoKit
import Foundation
import UIKit

/// The single switch for the try-on feature. Everyone has it today; making it a Premium perk is a
/// one-line change here (e.g. `&& SubscriptionStore.shared.isPremium`).
enum TryOnAvailability {
    static let enabledKey = "tryOn.enabled"

    /// The user hasn't turned "See outfits on you" off.
    static var userEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isAvailable: Bool { userEnabled }
}

/// Finished try-ons on disk, keyed by (body photo, item ids, item image versions, pipeline version):
/// `Application Support/TryOn/Renders/<key>.jpg` (+ a small index with the gate verdict, so a rejected
/// look isn't rendered again). Local only, excluded from backup, protected until first unlock
/// (`LocalStore`). Body images never leave the phone.
final class TryOnStore {
    static let shared = TryOnStore()

    /// Bump when the pipeline changes enough to re-render everything.
    static let pipelineVersion = 1

    struct Entry: Codable {
        var file: String?          // nil = rejected
        var rejection: String?
        var harmonized: Bool
        var date: Date
        var seconds: Double
    }

    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var loaded = false
    private var dir: URL { LocalStore.directory("TryOn/Renders") }
    private var indexURL: URL { LocalStore.directory("TryOn").appendingPathComponent("renders.json") }

    static func key(bodyID: String, items: [WardrobeItem]) -> String {
        let worn = items.filter { TryOnRole.of($0).isWorn }.sorted { $0.id.uuidString < $1.id.uuidString }
        let s = "v\(pipelineVersion)|\(bodyID)|" + worn.map { "\($0.id.uuidString):\($0.imagePath)" }.joined(separator: ",")
        return SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: indexURL), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { index = e }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(index) { _ = LocalStore.write(d, to: indexURL) }
    }

    func entry(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        load()
        return index[key]
    }

    func imageURL(_ key: String) -> URL? {
        guard let f = entry(key)?.file else { return nil }
        let url = dir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func image(_ key: String) -> UIImage? {
        imageURL(key).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    @discardableResult
    func storeReady(_ key: String, image: CGImage, harmonized: Bool, seconds: Double) -> URL? {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else { return nil }
        let name = key + ".jpg"
        let url = dir.appendingPathComponent(name)
        guard LocalStore.write(data, to: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        load()
        index[key] = Entry(file: name, rejection: nil, harmonized: harmonized, date: Date(), seconds: seconds)
        prune()
        save()
        return url
    }

    func storeRejected(_ key: String, reason: String, harmonized: Bool) {
        lock.lock(); defer { lock.unlock() }
        load()
        index[key] = Entry(file: nil, rejection: reason, harmonized: harmonized, date: Date(), seconds: 0)
        save()
    }

    /// Keeps the newest 80 renders.
    private func prune() {
        let ready = index.filter { $0.value.file != nil }.sorted { $0.value.date > $1.value.date }
        guard ready.count > 80 else { return }
        for (k, e) in ready.dropFirst(80) {
            if let f = e.file { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            index.removeValue(forKey: k)
        }
    }

    /// A new body photo (or "Delete everything"): drops every render.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        index = [:]
        loaded = true
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: indexURL)
    }
}
