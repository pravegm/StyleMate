import Foundation
import AuthenticationServices

/// The signed-in StyleMate account. **Sign in with Apple is the only way in** (founder decision,
/// 5 Nov 2026): the subscription and the 50 free wardrobe pieces belong to the account, on every
/// device, so there is no guest mode.
///
/// - At launch the account is read from the Keychain (`Account`), so the app (and a background
///   scan with no UI) is signed in at once; Apple's credential state is then checked
///   (`verifyCredential`). Revoked or not found means signed out, back to the sign-in screen. The
///   app also listens for `credentialRevokedNotification`.
/// - Everything on the phone stays keyed by `user.id`, which is the account's `profileID`.
/// - Migration: the first sign-in on a phone that has an earlier on-device profile (builds without
///   sign-in, TestFlight) adopts that profile, so the closet, outfits, calendar and face data stay.
/// - Sign out keeps the data on the phone (signing back in shows it again). Delete account removes it
///   (Profile: local data + the account's CloudKit zone, then `deleteAccount()`).
@MainActor
class AuthService: ObservableObject {
    @Published var user: User?
    @Published var isAuthenticated = false
    @Published private(set) var account: Account?
    /// Why the last session ended on its own ("Sign in again…"); nil after a normal sign-out.
    @Published var signOutReason: String?

    nonisolated static let currentUserObjectKey = "currentUserObject"
    nonisolated static let userProfilesKey = "userProfiles"
    /// The on-device profile of builds without sign-in (adopted by the first account that signs in).
    nonisolated static let localProfileIDKey = "localProfileID"
    // Legacy Apple / Google session keys (very old builds; folded into `localProfileIDKey`).
    nonisolated static let legacyAuthUserIDKey = "authUserID"
    nonisolated static let legacyAuthProviderKey = "authProvider"
    /// Which account adopted the on-device profile (only one ever does).
    nonisolated static let legacyProfileAdoptedByKey = "localProfileAdoptedBy"
    nonisolated static func profileKey(for account: UUID) -> String { "accountProfile_\(account.uuidString)" }
    /// The account took over the old on-device profile, whose wardrobe lived in the shared legacy
    /// CloudKit zone: re-upload it to the account's zone once.
    nonisolated static func adoptedLegacyKey(for account: UUID) -> String { "accountAdoptedLegacy_\(account.uuidString)" }

    nonisolated static let defaultStyles: [OutfitType] = [.everyday, .formal, .date, .sports, .party, .business]

    private let store: AccountStoring
    private let checker: AppleCredentialChecking
    private let defaults: UserDefaults
    private var revokeObserver: NSObjectProtocol?

    init(store: AccountStoring = KeychainAccountStore(),
         checker: AppleCredentialChecking = AppleIDCredentialChecker(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.checker = checker
        self.defaults = defaults
        #if DEBUG
        // UI-test launch arguments (StyleMate/Debug/DebugLaunchSupport.swift): a fake signed-in account.
        if store is KeychainAccountStore, let demo = DebugLaunchSupport.applyIfNeeded() {
            self.user = demo.user
            self.account = demo.account
            self.isAuthenticated = true
            return
        }
        #endif
        if let saved = store.read() {
            activate(saved, freshName: nil)
        }
        revokeObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.verifyCredential() }
        }
    }

    // MARK: - Sign in

    /// The result of `SignInWithAppleButton`. Returns an error message to show (nil = signed in, or
    /// the person cancelled).
    func handleAppleSignIn(result: Result<ASAuthorization, Error>) -> String? {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                return "Sign in with Apple returned an unexpected credential. Please try again."
            }
            completeSignIn(appleUserID: credential.user, fullName: credential.fullName)
            return nil
        case .failure(let error):
            let code = (error as NSError).code
            if code == ASAuthorizationError.canceled.rawValue { return nil }
            return "Sign in with Apple didn't finish. Check you're signed in to your Apple Account in Settings, then try again."
        }
    }

    /// Signs in (or back in) as `appleUserID`. `fullName` is only sent by Apple the first time.
    func completeSignIn(appleUserID: String, fullName: PersonNameComponents?, isTestAccount: Bool = false) {
        let profileID = Self.resolveProfileID(appleUserID: appleUserID, defaults: defaults)
        let account = Account(appleUserID: appleUserID, profileID: profileID, isTestAccount: isTestAccount)
        if !isTestAccount { store.write(account) }
        signOutReason = nil
        activate(account, freshName: Self.displayName(fullName))
        dlog("[Account] Signed in (profile \(profileID == account.uuid.uuidString ? "new" : "adopted"))")
    }

    private func activate(_ account: Account, freshName: String?) {
        var profiles = Self.loadUserProfiles(defaults: defaults)
        var user = profiles[account.profileID]
            ?? Self.decodedCurrentUser(defaults: defaults, id: account.profileID)
            ?? User(id: account.profileID, email: nil, name: "", preferredStyles: Self.defaultStyles,
                    notificationsEnabled: false, dateCreated: Date())
        if let freshName, user.name.isEmpty { user.name = freshName }
        user.email = nil   // never asked for; drop what very old builds stored
        profiles[user.id] = user
        Self.saveUserProfiles(profiles, defaults: defaults)
        self.account = account
        self.user = user
        self.isAuthenticated = true
        saveCurrentUser()
    }

    /// Which on-phone profile an account uses: the one it already has here, else the earlier
    /// on-device profile if no other account adopted it (migration), else a new one named after the
    /// account. Only touches `defaults`, so it's unit-tested.
    nonisolated static func resolveProfileID(appleUserID: String, defaults: UserDefaults) -> String {
        let uuid = Account.uuid(forAppleUserID: appleUserID)
        if let existing = defaults.string(forKey: profileKey(for: uuid)), !existing.isEmpty { return existing }

        var profileID = uuid.uuidString
        let legacy = legacyLocalProfileID(defaults: defaults)
        if let legacy, defaults.string(forKey: legacyProfileAdoptedByKey) == nil {
            profileID = legacy
            defaults.set(legacy, forKey: localProfileIDKey)   // pin it (it may have come from an older key)
            defaults.set(uuid.uuidString, forKey: legacyProfileAdoptedByKey)
            defaults.set(true, forKey: adoptedLegacyKey(for: uuid))
        }
        defaults.set(profileID, forKey: profileKey(for: uuid))
        return profileID
    }

    /// The on-device profile of a build without sign-in, if this phone has one.
    nonisolated static func legacyLocalProfileID(defaults: UserDefaults) -> String? {
        if let id = defaults.string(forKey: localProfileIDKey), !id.isEmpty { return id }
        if let id = defaults.string(forKey: legacyAuthUserIDKey), !id.isEmpty { return id }
        return decodedCurrentUser(defaults: defaults, id: nil)?.id
    }

    /// This profile is the phone's old on-device profile that an account adopted (its wardrobe was
    /// backed up to the shared legacy zone).
    nonisolated static func profileAdoptedLegacy(_ profileID: String, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: legacyProfileAdoptedByKey) != nil else { return false }
        return legacyLocalProfileID(defaults: defaults) == profileID
    }

    nonisolated static func displayName(_ name: PersonNameComponents?) -> String? {
        guard let name else { return nil }
        let parts = [name.givenName, name.familyName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Session checks

    /// Asks Apple whether the account is still signed in to StyleMate (launch + foreground). Revoked
    /// (Settings › Sign in with Apple › Stop Using) or not found signs out; offline keeps the session.
    func verifyCredential() async {
        guard let account, !account.isTestAccount else { return }
        let state = await checker.state(forUserID: account.appleUserID)
        guard state.endsSession, self.account?.appleUserID == account.appleUserID else { return }
        signOut(reason: "Sign in with Apple was turned off for StyleMate. Sign in again to see your closet.")
    }

    // MARK: - Sign out / delete

    /// Signs out. Nothing is deleted: signing back in with the same Apple ID shows the same closet.
    func signOut(reason: String? = nil) {
        store.clear()
        account = nil
        user = nil
        isAuthenticated = false
        signOutReason = reason
        defaults.removeObject(forKey: Self.currentUserObjectKey)
        dlog("[Account] Signed out\(reason == nil ? "" : " (credential)")")
    }

    /// Forgets the account on this phone (after Profile deleted its data and its iCloud zone).
    func deleteAccount() {
        if let account {
            var profiles = Self.loadUserProfiles(defaults: defaults)
            profiles.removeValue(forKey: account.profileID)
            Self.saveUserProfiles(profiles, defaults: defaults)
            defaults.removeObject(forKey: Self.profileKey(for: account.uuid))
            defaults.removeObject(forKey: Self.adoptedLegacyKey(for: account.uuid))
            if defaults.string(forKey: Self.localProfileIDKey) == account.profileID {
                defaults.removeObject(forKey: Self.localProfileIDKey)
            }
            if defaults.string(forKey: Self.legacyProfileAdoptedByKey) == account.uuid.uuidString {
                defaults.removeObject(forKey: Self.legacyProfileAdoptedByKey)
            }
        }
        signOut()
    }

    // MARK: - Persistence Helpers

    func saveCurrentUser() {
        guard let user = self.user else { return }
        var profiles = Self.loadUserProfiles(defaults: defaults)
        profiles[user.id] = user
        Self.saveUserProfiles(profiles, defaults: defaults)
        if let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: Self.currentUserObjectKey)
        }
    }

    nonisolated private static func decodedCurrentUser(defaults: UserDefaults, id: String?) -> User? {
        guard let data = defaults.data(forKey: currentUserObjectKey),
              let user = try? JSONDecoder().decode(User.self, from: data), !user.id.isEmpty else { return nil }
        if let id, user.id != id { return nil }
        return user
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
