import Foundation
import UIKit

/// Per-item visual data kept beside the wardrobe (not in the item JSON, which
/// lives in UserDefaults and syncs to CloudKit): the FashionSigLIP embedding of
/// the item's cutout, and the quality score of the photo it came from. The
/// embedding drives duplicate detection; the quality lets a later, better photo
/// of the same garment replace the image.
///
/// Reads and writes are in memory. The file (`items.bin`, ~3 KB per item) is
/// written off the calling thread, debounced, so a scan adding hundreds of items
/// from the main actor never re-encodes the whole store per item; it is flushed
/// when the app goes to the background.
final class ItemEmbeddingStore {
    static let shared = ItemEmbeddingStore()

    private struct Entry: Codable {
        var embedding: [Float]
        var quality: Float
        /// The source view was cut off by the photo frame (optional: older files lack it).
        var truncated: Bool?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private var writeScheduled = false
    private let io = DispatchQueue(label: "com.stylemates.StyleMate.embeddings-io", qos: .utility)
    private let directoryOverride: URL?
    /// Coalesces bursts of `set` / `remove` into one write.
    var writeDelay: TimeInterval = 1.5

    init(directory: URL? = nil) {
        directoryOverride = directory
        let nc = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.flush() }
        }
    }

    /// `Application Support/WardrobeEmbeddings/`: excluded from backup, protected until first
    /// unlock (`LocalStore`), like every other personal file.
    private var directory: URL {
        guard let dir = directoryOverride else { return LocalStore.directory("WardrobeEmbeddings") }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            LocalStore.protect(dir)
        }
        return dir
    }
    private var fileURL: URL { directory.appendingPathComponent("items.bin") }
    /// The JSON file of earlier builds; migrated on first load, then deleted.
    private var legacyURL: URL { directory.appendingPathComponent("items.json") }

    /// Caller holds `lock`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), let decoded = Self.decode(data) {
            entries = decoded
        } else if let data = try? Data(contentsOf: legacyURL),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
            scheduleWrite()
        }
    }

    func embedding(for id: UUID) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries[id.uuidString]?.embedding
    }

    func quality(for id: UUID) -> Float? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries[id.uuidString]?.quality
    }

    func truncated(for id: UUID) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries[id.uuidString]?.truncated
    }

    func set(_ embedding: [Float], quality: Float, truncated: Bool = false, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        entries[id.uuidString] = Entry(embedding: embedding, quality: quality, truncated: truncated)
        scheduleWrite()
    }

    func remove(_ id: UUID) {
        remove([id])
    }

    /// Batch removal: one (deferred) file write however many items.
    func remove(_ ids: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        for id in ids { entries[id.uuidString] = nil }
        scheduleWrite()
    }

    /// Forgets every embedding and deletes the files ("Delete everything"). A write still
    /// pending finds nothing to do, so nothing is written back afterwards.
    func removeAll() {
        lock.lock()
        entries = [:]
        loaded = true
        dirty = false
        lock.unlock()
        io.sync {
            for url in [fileURL, legacyURL] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Writes pending changes now (blocks until written).
    func flush() {
        io.sync { writeNow() }
    }

    // MARK: - Persistence

    /// Caller holds `lock`.
    private func scheduleWrite() {
        dirty = true
        guard !writeScheduled else { return }
        writeScheduled = true
        io.asyncAfter(deadline: .now() + writeDelay) { [weak self] in self?.writeNow() }
    }

    /// On `io`.
    private func writeNow() {
        lock.lock()
        guard dirty else { writeScheduled = false; lock.unlock(); return }
        let snapshot = entries
        dirty = false
        writeScheduled = false
        lock.unlock()
        let data = Self.encode(snapshot)
        do {
            try data.write(to: fileURL, options: LocalStore.writeOptions)
            if FileManager.default.fileExists(atPath: legacyURL.path) { try? FileManager.default.removeItem(at: legacyURL) }
        } catch {
            print("[Wardrobe] embedding store write failed: \(error)")
            lock.lock(); dirty = true; lock.unlock()
        }
    }

    // Format: "SMEB", UInt32 version, UInt32 count, then per entry: 16-byte UUID,
    // Float32 quality, UInt8 flags (bit 0: truncated known, bit 1: truncated),
    // UInt32 dimension, Float32 x dimension. Little-endian.
    private static let magic: [UInt8] = Array("SMEB".utf8)

    private static func encode(_ entries: [String: Entry]) -> Data {
        var d = Data()
        d.reserveCapacity(12 + entries.count * (25 + 768 * 4))
        func put<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func putF(_ v: Float) { put(v.bitPattern) }
        d.append(contentsOf: magic)
        put(UInt32(1))
        let valid = entries.compactMap { k, e in UUID(uuidString: k).map { ($0, e) } }
        put(UInt32(valid.count))
        for (id, e) in valid {
            withUnsafeBytes(of: id.uuid) { d.append(contentsOf: $0) }
            putF(e.quality)
            put(UInt8((e.truncated != nil ? 1 : 0) | (e.truncated == true ? 2 : 0)))
            put(UInt32(e.embedding.count))
            for v in e.embedding { putF(v) }
        }
        return d
    }

    private static func decode(_ data: Data) -> [String: Entry]? {
        let bytes = [UInt8](data)
        var o = 0
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard o + n <= bytes.count else { return nil }
            defer { o += n }
            return bytes[o..<(o + n)]
        }
        func u32() -> UInt32? {
            guard let s = take(4) else { return nil }
            return s.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
        guard let m = take(4), Array(m) == magic, u32() == 1, let count = u32() else { return nil }
        var out: [String: Entry] = [:]
        for _ in 0..<count {
            guard let u = take(16), let q = f32(), let flags = take(1)?.first, let dim = u32(), dim <= 4096 else { return nil }
            let ub = Array(u)
            let id = UUID(uuid: (ub[0], ub[1], ub[2], ub[3], ub[4], ub[5], ub[6], ub[7],
                                 ub[8], ub[9], ub[10], ub[11], ub[12], ub[13], ub[14], ub[15]))
            var emb = [Float](repeating: 0, count: Int(dim))
            for i in 0..<Int(dim) { guard let v = f32() else { return nil }; emb[i] = v }
            out[id.uuidString] = Entry(embedding: emb, quality: q,
                                       truncated: flags & 1 != 0 ? flags & 2 != 0 : nil)
        }
        return out
    }
}
