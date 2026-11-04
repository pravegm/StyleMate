import Foundation

/// Where StyleMate keeps the user's private files on the phone.
///
/// Everything personal — wardrobe photos and cutouts, the selfie, face embeddings — lives
/// under `Application Support`, excluded from iCloud Backup (the app's promise is that
/// photos and faces never leave the phone; the user's own CloudKit sync of wardrobe items
/// is separate and opt-in by iCloud), with file protection
/// `completeUntilFirstUserAuthentication`: unreadable until the phone is unlocked once after
/// boot, but still usable by the overnight scan while the phone is locked afterwards.
///
/// Older builds wrote wardrobe images and the selfie into `Documents` (backed up). They
/// are moved here transparently on first access (`migrateLegacyDirectory`,
/// `resolveSelfiePath`).
enum LocalStore {
    static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `Application Support/<name>`, created if needed, excluded from backup and protected.
    /// Cheap to call repeatedly (one `fileExists` when the folder is already there).
    static func directory(_ name: String) -> URL {
        let dir = applicationSupport.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: fileProtection])
            protect(dir)
        }
        return dir
    }

    /// Marks a file or folder as excluded from backup and sets its protection class.
    /// (A folder's protection class becomes the default for files created inside it.)
    static func protect(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
    }

    /// Writes `data` atomically with the protection class applied.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: writeOptions)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Legacy migration

    /// Moves `Documents/<legacyName>` into `newDir` (already created). The common case is a
    /// single directory rename; if both exist, each file not yet in `newDir` is moved over.
    /// Files are never deleted unless an identical name already exists at the destination.
    static func migrateLegacyDirectory(named legacyName: String, into newDir: URL) {
        let fm = FileManager.default
        let legacy = documents.appendingPathComponent(legacyName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue else { return }

        let existing = (try? fm.contentsOfDirectory(atPath: newDir.path)) ?? []
        if existing.isEmpty {
            // Fast path: swap the (empty) new folder for the legacy one.
            try? fm.removeItem(at: newDir)
            if (try? fm.moveItem(at: legacy, to: newDir)) != nil {
                protect(newDir)
                protectContents(of: newDir)
                dlog("[LocalStore] Moved \(legacyName) to Application Support")
                return
            }
            // Rename failed (unlikely): recreate the folder and fall through to per-file moves.
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: fileProtection])
            protect(newDir)
        }

        let names = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
        var moved = 0
        for name in names {
            let src = legacy.appendingPathComponent(name)
            let dst = newDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: src)          // already migrated
            } else if (try? fm.moveItem(at: src, to: dst)) != nil {
                try? fm.setAttributes([.protectionKey: fileProtection], ofItemAtPath: dst.path)
                moved += 1
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
            try? fm.removeItem(at: legacy)
        }
        dlog("[LocalStore] Merged \(moved) legacy files from \(legacyName)")
    }

    private static func protectContents(of dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? fm.setAttributes([.protectionKey: fileProtection],
                                  ofItemAtPath: dir.appendingPathComponent(name).path)
        }
    }

    // MARK: - Selfie

    /// `Application Support/Selfie/` — the onboarding selfie frame(s).
    static var selfieDirectory: URL { directory("Selfie") }

    static func selfieKey(_ userId: String) -> String { "selfieReferencePath_\(userId)" }

    static func selfieFileName(_ userId: String) -> String { "selfie_reference_\(userId).jpg" }

    /// Saves the selfie frame and records its path under `selfieReferencePath_<userId>`
    /// (the contract `FaceMatchingService.selfieAnchors` reads).
    @discardableResult
    static func saveSelfie(_ data: Data, userId: String) -> URL? {
        let url = selfieDirectory.appendingPathComponent(selfieFileName(userId))
        guard write(data, to: url) else { return nil }
        UserDefaults.standard.set(url.path, forKey: selfieKey(userId))
        return url
    }

    /// Resolves a stored selfie path to a file that exists, migrating a legacy
    /// `Documents/` selfie into `Application Support/Selfie/` on the way (and updating the
    /// stored path). The app container's absolute path can change across reinstalls and
    /// restores, so a missing absolute path is retried by file name. Paths outside
    /// `Documents` (e.g. a test fixture in tmp) are used as they are.
    static func resolveSelfiePath(_ stored: String, userId: String?) -> String? {
        let fm = FileManager.default
        let name = URL(fileURLWithPath: stored).lastPathComponent
        let legacyURL = documents.appendingPathComponent(name)
        let docsPath = documents.resolvingSymlinksInPath().path
        let storedPath = URL(fileURLWithPath: stored).resolvingSymlinksInPath().path
        let isLegacy = storedPath.hasPrefix(docsPath)
            || (!fm.fileExists(atPath: stored) && fm.fileExists(atPath: legacyURL.path))

        if isLegacy, fm.fileExists(atPath: legacyURL.path) {
            let dst = selfieDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: legacyURL)
            } else if (try? fm.moveItem(at: legacyURL, to: dst)) == nil {
                return legacyURL.path                // couldn't move; still usable in place
            }
            try? fm.setAttributes([.protectionKey: fileProtection], ofItemAtPath: dst.path)
            if let userId { UserDefaults.standard.set(dst.path, forKey: selfieKey(userId)) }
            dlog("[LocalStore] Moved the selfie to Application Support")
            return dst.path
        }
        if fm.fileExists(atPath: stored) { return stored }
        let moved = selfieDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: moved.path) {
            if let userId { UserDefaults.standard.set(moved.path, forKey: selfieKey(userId)) }
            return moved.path
        }
        return nil
    }

    /// Deletes the user's selfie frames — front and head-turn — wherever they are (new and
    /// legacy locations), and both UserDefaults keys that point at them.
    static func deleteSelfie(userId: String) {
        let fm = FileManager.default
        if let stored = UserDefaults.standard.string(forKey: selfieKey(userId)) {
            try? fm.removeItem(atPath: stored)
        }
        let prefix = "selfie_reference_\(userId)"
        for dir in [selfieDirectory, documents] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        UserDefaults.standard.removeObject(forKey: selfieKey(userId))
        UserDefaults.standard.removeObject(forKey: "selfieTurnFrames_\(userId)")   // SelfieReferenceStore.turnFramesKey
    }
}
