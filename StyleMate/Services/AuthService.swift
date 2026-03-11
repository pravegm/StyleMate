import Foundation

@MainActor
class AuthService: ObservableObject {
    @Published var user: User?  
    @Published var isAuthenticated = false
    
    static private let usersKey = "users"
    static private let currentUserKey = "currentUserEmail"
    static private let currentUserObjectKey = "currentUserObject"
    static private let userProfilesKey = "userProfiles"
    static var users: [String: (password: String, name: String)] = loadUsers()
    
    init() {
        if let userData = UserDefaults.standard.data(forKey: Self.currentUserObjectKey),
           let decodedUser = try? JSONDecoder().decode(User.self, from: userData) {
            self.user = decodedUser
            self.isAuthenticated = true
        } else if let email = UserDefaults.standard.string(forKey: Self.currentUserKey),
                  let (_password, name) = AuthService.users[email] {
            // Restore user session (legacy)
            let restoredUser = User(
                id: email,
                email: email,
                name: name,
                preferredStyles: [
                    .everyday, .formal, .date, .sports, .party, .business
                ],
                notificationsEnabled: true,
                dateCreated: Date() // You may want to persist this too
            )
            self.user = restoredUser
            self.isAuthenticated = true
        }
    }
    
    // Load users from UserDefaults
    static func loadUsers() -> [String: (password: String, name: String)] {
        guard let data = UserDefaults.standard.dictionary(forKey: usersKey) as? [String: [String: String]] else {
            return [:]
        }
        var result: [String: (password: String, name: String)] = [:]
        for (email, dict) in data {
            if let password = dict["password"], let name = dict["name"] {
                result[email] = (password, name)
            }
        }
        return result
    }
    
    // Save users to UserDefaults
    static func saveUsers() {
        let dict = users.mapValues { ["password": $0.password, "name": $0.name] }
        UserDefaults.standard.set(dict, forKey: usersKey)
    }
    
    // Load all user profiles from UserDefaults
    static func loadUserProfiles() -> [String: User] {
        guard let data = UserDefaults.standard.data(forKey: userProfilesKey),
              let dict = try? JSONDecoder().decode([String: User].self, from: data) else {
            return [:]
        }
        return dict
    }
    
    // Save all user profiles to UserDefaults
    static func saveUserProfiles(_ profiles: [String: User]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: userProfilesKey)
        }
    }
    
    // Save the current user to the profiles dictionary
    func saveCurrentUser() {
        if let user = self.user {
            var profiles = Self.loadUserProfiles()
            profiles[user.email] = user
            Self.saveUserProfiles(profiles)
            if let data = try? JSONEncoder().encode(user) {
                UserDefaults.standard.set(data, forKey: Self.currentUserObjectKey)
            }
        }
    }
    
    // Email/password sign up
    func signUpWithEmail(email: String, password: String, name: String, gender: String, age: Int?) async -> String? {
        guard !email.isEmpty, !password.isEmpty, !name.isEmpty else {
            return "All fields are required."
        }
        // Overwrite any existing user for this email
        AuthService.users[email] = (password, name)
        AuthService.saveUsers()
        let newUser = User(
            id: email,
            email: email,
            name: name,
            preferredStyles: [
                .everyday, .formal, .date, .sports, .party, .business
            ],
            notificationsEnabled: true,
            dateCreated: Date(),
            gender: gender.isEmpty ? nil : gender,
            age: age
        )
        self.user = newUser
        self.isAuthenticated = true
        UserDefaults.standard.set(email, forKey: Self.currentUserKey)
        saveCurrentUser() // This will update the profiles dictionary
        return nil
    }
    
    // Email/password sign in
    func signInWithEmail(email: String, password: String) async -> String? {
        guard !email.isEmpty, !password.isEmpty else {
            return "Email and password are required."
        }
        guard let (storedPassword, name) = AuthService.users[email] else {
            return "User not found."
        }
        if storedPassword != password {
            return "Incorrect password."
        }
        // Try to load the user profile from the profiles dictionary
        let profiles = Self.loadUserProfiles()
        if let profile = profiles[email] {
            self.user = profile
        } else if let userData = UserDefaults.standard.data(forKey: Self.currentUserObjectKey),
                  let decodedUser = try? JSONDecoder().decode(User.self, from: userData),
                  decodedUser.email == email {
            self.user = decodedUser
        } else {
            // Fallback to legacy construction if not found
            let newUser = User(
                id: email,
                email: email,
                name: name,
                preferredStyles: [
                    .everyday, .formal, .date, .sports, .party, .business
                ],
                notificationsEnabled: true,
                dateCreated: Date()
            )
            self.user = newUser
        }
        self.isAuthenticated = true
        UserDefaults.standard.set(email, forKey: Self.currentUserKey)
        saveCurrentUser()
        return nil
    }
    
    func signOut() {
        self.user = nil
        self.isAuthenticated = false
        UserDefaults.standard.removeObject(forKey: Self.currentUserKey)
        UserDefaults.standard.removeObject(forKey: Self.currentUserObjectKey)
        // Do not clear users for persistence
    }
} 
