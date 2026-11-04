import Foundation

/// Per-item visual data kept beside the wardrobe (not in the item JSON, which
/// lives in UserDefaults and syncs to CloudKit): the FashionSigLIP embedding of
/// the item's cutout, and the quality score of the photo it came from. The
/// embedding drives duplicate detection; the quality lets a later, better photo
/// of the same garment replace the image.
final class ItemEmbeddingStore {
    static let shared = ItemEmbeddingStore()

    private struct Entry: Codable {
        var embedding: [Float]
        var quality: Float
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WardrobeEmbeddings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("items.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
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

    func set(_ embedding: [Float], quality: Float, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        entries[id.uuidString] = Entry(embedding: embedding, quality: quality)
        persist()
    }

    func remove(_ id: UUID) {
        remove([id])
    }

    /// Batch removal: one file write however many items (bulk delete).
    func remove(_ ids: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        for id in ids { entries[id.uuidString] = nil }
        persist()
    }
}
