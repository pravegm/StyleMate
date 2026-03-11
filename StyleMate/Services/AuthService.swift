import Foundation
import AuthenticationServices
import GoogleSignIn

enum AuthProvider: String {
    case apple
    case google
}

@MainActor
class AuthService: ObservableObject {
    @Published var user: User?
    @Published var isAuthenticated = false

    static private let currentUserObjectKey = "currentUserObject"
    static private let userProfilesKey = "userProfiles"
    static private let authUserIDKey = "authUserID"
    static private let authProviderKey = "authProvider"

    init() {
        restoreSession()
    }

    // MARK: - Session Restoration

    private func restoreSession() {
        guard let providerRaw = UserDefaults.standard.string(forKey: Self.authProviderKey),
              let _ = AuthProvider(rawValue: providerRaw),
              let userID = UserDefaults.standard.string(forKey: Self.authUserIDKey) else {
            return
        }

        if let userData = UserDefaults.standard.data(forKey: Self.currentUserObjectKey),
           let decodedUser = try? JSONDecoder().decode(User.self, from: userData),
           decodedUser.id == userID {
            self.user = decodedUser
            self.isAuthenticated = true
        } else {
            let profiles = Self.loadUserProfiles()
            if let profile = profiles[userID] {
                self.user = profile
                self.isAuthenticated = true
            }
        }
    }

    // MARK: - Sign in with Apple

    func handleAppleSignIn(result: Result<ASAuthorization, Error>) -> String? {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                return "Unexpected credential type."
            }
            return processAppleCredential(credential)

        case .failure(let error):
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                return nil
            }
            return error.localizedDescription
        }
    }

    private func processAppleCredential(_ credential: ASAuthorizationAppleIDCredential) -> String? {
        let userID = credential.user

        let profiles = Self.loadUserProfiles()
        if let existingUser = profiles[userID] {
            var updatedUser = existingUser
            if let givenName = credential.fullName?.givenName,
               let familyName = credential.fullName?.familyName,
               !givenName.isEmpty {
                updatedUser.name = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
            }
            if let email = credential.email, !email.isEmpty {
                updatedUser.email = email
            }
            self.user = updatedUser
        } else {
            var name = "User"
            if let givenName = credential.fullName?.givenName {
                name = givenName
                if let familyName = credential.fullName?.familyName {
                    name += " \(familyName)"
                }
                name = name.trimmingCharacters(in: .whitespaces)
            }

            let newUser = User(
                id: userID,
                email: credential.email,
                name: name.isEmpty ? "User" : name,
                preferredStyles: [.everyday, .formal, .date, .sports, .party, .business],
                notificationsEnabled: true,
                dateCreated: Date()
            )
            self.user = newUser
        }

        self.isAuthenticated = true
        persistAuthSession(provider: .apple, userID: userID)
        saveCurrentUser()
        return nil
    }

    // MARK: - Sign in with Google

    func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }

        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let error = error {
                    let nsError = error as NSError
                    if nsError.code == GIDSignInError.canceled.rawValue {
                        return
                    }
                    return
                }

                guard let googleUser = result?.user,
                      let userID = googleUser.userID else {
                    return
                }

                self.processGoogleUser(googleUser, userID: userID)
            }
        }
    }

    private func processGoogleUser(_ googleUser: GIDGoogleUser, userID: String) {
        let profiles = Self.loadUserProfiles()
        if let existingUser = profiles[userID] {
            var updatedUser = existingUser
            if let name = googleUser.profile?.name, !name.isEmpty {
                updatedUser.name = name
            }
            if let email = googleUser.profile?.email, !email.isEmpty {
                updatedUser.email = email
            }
            self.user = updatedUser
        } else {
            let newUser = User(
                id: userID,
                email: googleUser.profile?.email,
                name: googleUser.profile?.name ?? "User",
                preferredStyles: [.everyday, .formal, .date, .sports, .party, .business],
                notificationsEnabled: true,
                dateCreated: Date()
            )
            self.user = newUser
        }

        self.isAuthenticated = true
        persistAuthSession(provider: .google, userID: userID)
        saveCurrentUser()
    }

    // MARK: - Credential State Checks

    func checkCredentialState() {
        guard let providerRaw = UserDefaults.standard.string(forKey: Self.authProviderKey),
              let provider = AuthProvider(rawValue: providerRaw) else {
            return
        }

        switch provider {
        case .apple:
            checkAppleCredentialState()
        case .google:
            checkGoogleCredentialState()
        }
    }

    private func checkAppleCredentialState() {
        guard let userID = UserDefaults.standard.string(forKey: Self.authUserIDKey) else { return }

        let provider = ASAuthorizationAppleIDProvider()
        provider.getCredentialState(forUserID: userID) { state, _ in
            Task { @MainActor in
                switch state {
                case .revoked, .notFound:
                    self.signOut()
                case .authorized:
                    break
                default:
                    break
                }
            }
        }
    }

    private func checkGoogleCredentialState() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
            Task { @MainActor in
                if error != nil || user == nil {
                    self.signOut()
                }
            }
        }
    }

    // MARK: - Sign Out

    func signOut() {
        let providerRaw = UserDefaults.standard.string(forKey: Self.authProviderKey)
        if providerRaw == AuthProvider.google.rawValue {
            GIDSignIn.sharedInstance.signOut()
        }

        self.user = nil
        self.isAuthenticated = false
        UserDefaults.standard.removeObject(forKey: Self.authUserIDKey)
        UserDefaults.standard.removeObject(forKey: Self.authProviderKey)
        UserDefaults.standard.removeObject(forKey: Self.currentUserObjectKey)
    }

    // MARK: - Persistence Helpers

    private func persistAuthSession(provider: AuthProvider, userID: String) {
        UserDefaults.standard.set(provider.rawValue, forKey: Self.authProviderKey)
        UserDefaults.standard.set(userID, forKey: Self.authUserIDKey)
    }

    func saveCurrentUser() {
        guard let user = self.user else { return }
        var profiles = Self.loadUserProfiles()
        profiles[user.id] = user
        Self.saveUserProfiles(profiles)
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.currentUserObjectKey)
        }
    }

    static func loadUserProfiles() -> [String: User] {
        guard let data = UserDefaults.standard.data(forKey: userProfilesKey),
              let dict = try? JSONDecoder().decode([String: User].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func saveUserProfiles(_ profiles: [String: User]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: userProfilesKey)
        }
    }
}
