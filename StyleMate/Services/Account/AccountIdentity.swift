import Foundation
import CryptoKit
import Security
import AuthenticationServices

/// A StyleMate account: the person's Sign in with Apple identity.
///
/// - `appleUserID` is Apple's stable, app-scoped user identifier (`ASAuthorizationAppleIDCredential.user`),
///   kept in the Keychain. StyleMate asks for no email; the name is requested once, to greet the person.
/// - `uuid` is derived from it deterministically, so every device computes the same value without a
///   server. It is the StoreKit `appAccountToken` (the subscription belongs to the account) and names the
///   account's CloudKit zone (two Apple IDs on one iCloud never mix wardrobes).
/// - `profileID` keys everything stored on this phone (wardrobe, outfits, calendar, face data, scan state).
///   For an account that adopted an earlier on-device profile (TestFlight testers before sign-in existed)
///   it is that profile's id, so nothing has to be re-keyed; otherwise it is `uuid.uuidString`.
struct Account: Codable, Equatable {
    var appleUserID: String
    var profileID: String
    /// DEBUG UI-test accounts skip Apple's credential check.
    var isTestAccount = false

    var uuid: UUID { Self.uuid(forAppleUserID: appleUserID) }
    var cloudZoneName: String { Self.zoneName(forAppleUserID: appleUserID) }

    /// A name-based (SHA-256, RFC 4122 version 5 layout) UUID for an Apple user id.
    static func uuid(forAppleUserID id: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("com.stylemates.StyleMate.account:\(id)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The account's CloudKit zone in the private database.
    static func zoneName(forAppleUserID id: String) -> String {
        "Wardrobe-" + uuid(forAppleUserID: id).uuidString.lowercased()
    }
}

// MARK: - Keychain

/// Where the signed-in account is remembered. The Keychain survives a reinstall (so does the person's
/// CloudKit zone), and is never synced (`ThisDeviceOnly`).
protocol AccountStoring {
    func read() -> Account?
    func write(_ account: Account)
    func clear()
}

struct KeychainAccountStore: AccountStoring {
    var service = "com.stylemates.StyleMate.account"
    var key = "signedInAccount"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func read() -> Account? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    func write(_ account: Account) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory store (unit tests).
final class MemoryAccountStore: AccountStoring {
    var account: Account?
    init(_ account: Account? = nil) { self.account = account }
    func read() -> Account? { account }
    func write(_ account: Account) { self.account = account }
    func clear() { account = nil }
}

// MARK: - Apple credential state

enum AppleCredentialState: Equatable {
    case authorized, revoked, notFound, transferred
    /// Couldn't ask (offline, no Apple ID on the device): keep the session.
    case unknown

    /// Revoked in Settings, or the Apple ID no longer knows this app: sign out.
    var endsSession: Bool { self == .revoked || self == .notFound }
}

protocol AppleCredentialChecking {
    func state(forUserID id: String) async -> AppleCredentialState
}

struct AppleIDCredentialChecker: AppleCredentialChecking {
    func state(forUserID id: String) async -> AppleCredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { state, error in
                guard error == nil else { continuation.resume(returning: .unknown); return }
                switch state {
                case .authorized: continuation.resume(returning: .authorized)
                case .revoked: continuation.resume(returning: .revoked)
                case .notFound: continuation.resume(returning: .notFound)
                case .transferred: continuation.resume(returning: .transferred)
                @unknown default: continuation.resume(returning: .unknown)
                }
            }
        }
    }
}

/// A fixed answer (unit tests).
struct FixedCredentialChecker: AppleCredentialChecking {
    var answer: AppleCredentialState
    func state(forUserID id: String) async -> AppleCredentialState { answer }
}
