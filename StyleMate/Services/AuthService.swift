import Foundation

/// The app has no server and no account. On first launch it creates a **local,
/// on-device profile** with a stable UUID; every per-user key (wardrobe, scan
/// progress, face gallery, onboarding) hangs off that id. iCloud sync uses the
/// device's own iCloud account through CloudKit's private database, so no
/// sign-in is needed for it either.
///
/// Migration: people who installed an earlier build signed in with Apple or
/// Google. Their persisted user id is kept as the local profile id, so their
/// wardrobe, outfits and face reference stay exactly where they are.
///
/// (The type keeps its old name and `isAuthenticated` so the rest of the app,
/// the background scan and the UI-test hooks don't need to change.)
@MainActor
class AuthService: ObservableObject {
    @Published var user: User?
    /// Always true once the local profile exists (immediately after init).
    @Published var isAuthenticated = false

    nonisolated static let currentUserObjectKey = "currentUserObject"
    nonisolated static let userProfilesKey = "userProfiles"
    /// The local profile's id.
    nonisolated static let localProfileIDKey = "localProfileID"
    // Legacy Apple / Google session keys (read once, for migration).
    nonisolated static let legacyAuthUserIDKey = "authUserID"
    nonisolated static let legacyAuthProviderKey = "authProvider"

    nonisolated static let defaultStyles: [OutfitType] = [.everyday, .formal, .date, .sports, .party, .business]

    init() {
        #if DEBUG
        // UI-test launch arguments (StyleMate/Debug/DebugLaunchSupport.swift): use a fixed demo
        // profile instead of the device's local one.
        if let demoUser = DebugLaunchSupport.applyIfNeeded() {
            self.user = demoUser
            self.isAuthenticated = true
            return
        }
        #endif
        self.user = Self.resolveLocalProfile(defaults: .standard)
        self.isAuthenticated = true
        saveCurrentUser()
    }

    // MARK: - Local profile

    /// The profile to use on this device: the one already in use, an earlier
    /// Apple/Google user (migration), or a brand-new one. Only touches
    /// `defaults`, so it's unit-tested.
    nonisolated static func resolveLocalProfile(defaults: UserDefaults, now: Date = Date(),
                                                adoptExisting: Bool = true) -> User {
        let profiles = loadUserProfiles(defaults: defaults)

        // 1. This device's local profile.
        if let id = defaults.string(forKey: localProfileIDKey), !id.isEmpty {
            return profiles[id] ?? decodedCurrentUser(defaults: defaults, id: id) ?? newUser(id: id, now: now)
        }

        // 2. Migration: a persisted Apple / Google session. Keep its id.
        var adopted: User?
        if let legacyID = defaults.string(forKey: legacyAuthUserIDKey), !legacyID.isEmpty {
            adopted = decodedCurrentUser(defaults: defaults, id: legacyID) ?? profiles[legacyID]
                ?? newUser(id: legacyID, now: now)
        } else if adoptExisting, let current = decodedCurrentUser(defaults: defaults, id: nil) {
            adopted = current
        } else if adoptExisting, !profiles.isEmpty {
            // Signed out of an earlier build but the data is still here: prefer
            // the profile that has a wardrobe, most recently created first.
            let ranked = profiles.values.sorted { $0.dateCreated > $1.dateCreated }
            adopted = ranked.first { hasWardrobe(defaults: defaults, userId: $0.id) } ?? ranked.first
        }

        let user = adopted ?? newUser(id: UUID().uuidString, now: now)
        defaults.set(user.id, forKey: localProfileIDKey)
        defaults.removeObject(forKey: legacyAuthUserIDKey)
        defaults.removeObject(forKey: legacyAuthProviderKey)
        dlog("[StyleMate] Local profile: \(adopted != nil ? "kept existing user" : "created") \(user.id)")
        return user
    }

    nonisolated private static func newUser(id: String, now: Date) -> User {
        User(id: id, email: nil, name: "", preferredStyles: defaultStyles,
             notificationsEnabled: false, dateCreated: now)
    }

    nonisolated private static func decodedCurrentUser(defaults: UserDefaults, id: String?) -> User? {
        guard let data = defaults.data(forKey: currentUserObjectKey),
              let user = try? JSONDecoder().decode(User.self, from: data), !user.id.isEmpty else { return nil }
        if let id, user.id != id { return nil }
        return user
    }

    /// Same key scheme as `WardrobeViewModel.storageKey(for:)`.
    nonisolated private static func hasWardrobe(defaults: UserDefaults, userId: String) -> Bool {
        let key = "wardrobe_\(userId.replacingOccurrences(of: "@", with: "_").replacingOccurrences(of: ".", with: "_"))"
        return defaults.data(forKey: key) != nil
    }

    /// "Delete Profile & All Data": forget this profile and start a fresh one
    /// (the app goes back to onboarding).
    func resetLocalProfile() {
        if let id = user?.id {
            var profiles = Self.loadUserProfiles()
            profiles.removeValue(forKey: id)
            Self.saveUserProfiles(profiles)
        }
        UserDefaults.standard.removeObject(forKey: Self.currentUserObjectKey)
        UserDefaults.standard.removeObject(forKey: Self.localProfileIDKey)
        // A brand-new id: never re-adopt another profile left on the phone here.
        user = Self.resolveLocalProfile(defaults: .standard, adoptExisting: false)
        isAuthenticated = true
        saveCurrentUser()
    }

    // MARK: - Persistence Helpers

    func saveCurrentUser() {
        guard let user = self.user else { return }
        var profiles = Self.loadUserProfiles()
        profiles[user.id] = user
        Self.saveUserProfiles(profiles)
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.currentUserObjectKey)
        }
    }

    nonisolated static func loadUserProfiles(defaults: UserDefaults = .standard) -> [String: User] {
        guard let data = defaults.data(forKey: userProfilesKey),
              let dict = try? JSONDecoder().decode([String: User].self, from: data) else {
            return [:]
        }
        return dict
    }

    nonisolated static func saveUserProfiles(_ profiles: [String: User], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: userProfilesKey)
        }
    }
}
