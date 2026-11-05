import Foundation
import Testing
@testable import StyleMate

/// Sign in with Apple accounts: the derived account UUID and zone, migration of an earlier
/// on-device profile, the credential check, sign-out / delete, and which StoreKit transactions
/// count for an account (`appAccountToken`).
struct AccountTests {

    private static func defaults() -> UserDefaults {
        let name = "AccountTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Identity

    @Test func accountUUIDAndZoneAreDeterministicPerAppleID() {
        let a = Account.uuid(forAppleUserID: "001234.abcdef.0001")
        #expect(a == Account.uuid(forAppleUserID: "001234.abcdef.0001"))   // every device agrees
        #expect(a != Account.uuid(forAppleUserID: "001234.abcdef.0002"))
        #expect(a.uuidString.dropFirst(14).first == "5")                    // version-5 layout
        let zone = Account.zoneName(forAppleUserID: "001234.abcdef.0001")
        #expect(zone == "Wardrobe-" + a.uuidString.lowercased())
        #expect(zone != CloudKitService.zoneName)                          // never the shared legacy zone
        #expect(zone != Account.zoneName(forAppleUserID: "001234.abcdef.0002"))
    }

    // MARK: Migration

    @Test func firstSignInAdoptsThePhonesEarlierProfileOnce() {
        let d = Self.defaults()
        d.set("LOCAL-UUID-1", forKey: AuthService.localProfileIDKey)
        // The first account on this phone takes over the old profile (closet, outfits, face data).
        let first = AuthService.resolveProfileID(appleUserID: "apple.alex", defaults: d)
        #expect(first == "LOCAL-UUID-1")
        let alex = Account.uuid(forAppleUserID: "apple.alex")
        #expect(d.bool(forKey: AuthService.adoptedLegacyKey(for: alex)))   // re-upload to its own zone
        #expect(AuthService.profileAdoptedLegacy("LOCAL-UUID-1", defaults: d))
        // Signing in again: the same profile.
        #expect(AuthService.resolveProfileID(appleUserID: "apple.alex", defaults: d) == "LOCAL-UUID-1")
        // Another Apple ID on the same phone gets its own, never the adopted one.
        let sam = AuthService.resolveProfileID(appleUserID: "apple.sam", defaults: d)
        #expect(sam == Account.uuid(forAppleUserID: "apple.sam").uuidString)
        #expect(!AuthService.profileAdoptedLegacy(sam, defaults: d))
    }

    @Test func aFreshInstallGetsAProfileNamedAfterTheAccount() {
        let d = Self.defaults()
        let id = AuthService.resolveProfileID(appleUserID: "apple.new", defaults: d)
        #expect(id == Account.uuid(forAppleUserID: "apple.new").uuidString)
        #expect(!d.bool(forKey: AuthService.adoptedLegacyKey(for: Account.uuid(forAppleUserID: "apple.new"))))
    }

    @Test func veryOldAppleOrGoogleSessionIsAdoptedToo() {
        let d = Self.defaults()
        d.set("001234.abcd.5678", forKey: AuthService.legacyAuthUserIDKey)
        #expect(AuthService.resolveProfileID(appleUserID: "001234.abcd.5678", defaults: d) == "001234.abcd.5678")
    }

    @Test func displayNameUsesOnlyWhatAppleSent() {
        #expect(AuthService.displayName(PersonNameComponents(givenName: "Alex", familyName: "Demo")) == "Alex Demo")
        #expect(AuthService.displayName(PersonNameComponents()) == nil)
        #expect(AuthService.displayName(nil) == nil)
    }

    // MARK: Session

    @MainActor
    @Test func signInPersistsAndRelaunchRestoresIt() {
        let d = Self.defaults()
        let store = MemoryAccountStore()
        let auth = AuthService(store: store, checker: FixedCredentialChecker(answer: .authorized), defaults: d)
        #expect(!auth.isAuthenticated)
        auth.completeSignIn(appleUserID: "apple.alex", fullName: PersonNameComponents(givenName: "Alex", familyName: nil))
        #expect(auth.isAuthenticated)
        #expect(auth.user?.name == "Alex")
        #expect(auth.user?.email == nil)                 // never asked for
        #expect(store.account?.appleUserID == "apple.alex")
        let relaunch = AuthService(store: store, checker: FixedCredentialChecker(answer: .authorized), defaults: d)
        #expect(relaunch.isAuthenticated)
        #expect(relaunch.user?.id == auth.user?.id)
        #expect(relaunch.user?.name == "Alex")
    }

    @MainActor
    @Test func revokedOrUnknownCredentialSignsOutButOfflineDoesNot() async {
        for (answer, staysSignedIn) in [(AppleCredentialState.revoked, false), (.notFound, false),
                                        (.authorized, true), (.unknown, true), (.transferred, true)] {
            let d = Self.defaults()
            let store = MemoryAccountStore(Account(appleUserID: "apple.alex", profileID: "P1"))
            let auth = AuthService(store: store, checker: FixedCredentialChecker(answer: answer), defaults: d)
            #expect(auth.isAuthenticated)
            await auth.verifyCredential()
            #expect(auth.isAuthenticated == staysSignedIn, "credential \(answer)")
            if !staysSignedIn {
                #expect(store.account == nil)
                #expect(auth.user == nil)
                #expect(auth.signOutReason != nil)
            }
        }
    }

    @MainActor
    @Test func signOutKeepsTheDataAndDeleteAccountForgetsIt() {
        let d = Self.defaults()
        d.set("LOCAL-UUID-9", forKey: AuthService.localProfileIDKey)
        let store = MemoryAccountStore()
        let auth = AuthService(store: store, checker: FixedCredentialChecker(answer: .authorized), defaults: d)
        auth.completeSignIn(appleUserID: "apple.alex", fullName: nil)
        let profile = auth.user?.id
        #expect(profile == "LOCAL-UUID-9")

        auth.signOut()
        #expect(!auth.isAuthenticated && store.account == nil)
        #expect(AuthService.loadUserProfiles(defaults: d)[profile!] != nil)   // data stays for the next sign-in
        auth.completeSignIn(appleUserID: "apple.alex", fullName: nil)
        #expect(auth.user?.id == profile)

        auth.deleteAccount()
        #expect(!auth.isAuthenticated && store.account == nil)
        #expect(AuthService.loadUserProfiles(defaults: d)[profile!] == nil)
        #expect(d.string(forKey: AuthService.profileKey(for: Account.uuid(forAppleUserID: "apple.alex"))) == nil)
        #expect(d.string(forKey: AuthService.localProfileIDKey) == nil)
        // Signing in again after deleting starts empty (a new profile, not the deleted one).
        auth.completeSignIn(appleUserID: "apple.alex", fullName: nil)
        #expect(auth.user?.id == Account.uuid(forAppleUserID: "apple.alex").uuidString)
    }

    @MainActor
    @Test func deleteAccountClearsTheWardrobeOnThisPhone() {
        let user = "test-delete-\(UUID().uuidString)"
        // Another wardrobe on the phone, so only this user's files go (not the shared folders
        // other tests running in parallel use).
        let keepAlive = "wardrobe_keepalive_\(UUID().uuidString)"
        UserDefaults.standard.set(Data([1]), forKey: keepAlive)
        defer { UserDefaults.standard.removeObject(forKey: keepAlive) }
        let vm = WardrobeViewModel()
        vm.load(forUser: user)
        vm.items = [WardrobeItem(category: .tops, product: "T-Shirts", colors: ["White"], brand: "",
                                 pattern: .solid, imagePath: "", croppedImagePath: nil, thumbnailPath: nil)]
        vm.addLocked(WardrobeItem(category: .bottoms, product: "Jeans", colors: ["Blue"], brand: "",
                                  pattern: .solid, imagePath: "", croppedImagePath: nil, thumbnailPath: nil))
        vm.deleteAllLocalData(forUser: user, includingCloud: false)
        #expect(vm.items.isEmpty && vm.lockedItems.isEmpty)
        #expect(UserDefaults.standard.data(forKey: WardrobeViewModel.storageKey(for: user)) == nil)
        #expect(UserDefaults.standard.data(forKey: WardrobeViewModel.lockedKey(for: user)) == nil)
        #expect(UserDefaults.standard.data(forKey: WardrobeViewModel.metaKey(for: user)) == nil)
        let relaunched = WardrobeViewModel()
        relaunched.load(forUser: user)
        #expect(relaunched.items.isEmpty && relaunched.lockedItems.isEmpty)
        for key in [WardrobeViewModel.storageKey(for: user), WardrobeViewModel.lockedKey(for: user),
                    WardrobeViewModel.metaKey(for: user)] { UserDefaults.standard.removeObject(forKey: key) }
    }

    @Test func pendingAccountZoneWipesBlockOnlyThatZone() {
        let d = Self.defaults()
        let zone = Account.zoneName(forAppleUserID: "apple.alex")
        let other = Account.zoneName(forAppleUserID: "apple.sam")
        WardrobeViewModel.setZoneWipe(zone, pending: true, defaults: d)
        #expect(WardrobeViewModel.mustWipeZoneBeforePull(ledger: SyncLedger(), zone: zone, defaults: d))
        #expect(!WardrobeViewModel.mustWipeZoneBeforePull(ledger: SyncLedger(), zone: other, defaults: d))
        WardrobeViewModel.setZoneWipe(zone, pending: false, defaults: d)
        #expect(!WardrobeViewModel.mustWipeZoneBeforePull(ledger: SyncLedger(), zone: zone, defaults: d))
    }

    // MARK: Subscription belongs to the account

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyThisAccountsTokenNilOrFamilySharingCount() {
        let mine = Account.uuid(forAppleUserID: "apple.alex")
        let theirs = Account.uuid(forAppleUserID: "apple.sam")
        #expect(PremiumStatus.belongs(token: mine, familyShared: false, to: mine))
        #expect(PremiumStatus.belongs(token: nil, familyShared: false, to: mine))      // offer codes, older builds
        #expect(PremiumStatus.belongs(token: theirs, familyShared: true, to: mine))    // Family Sharing
        #expect(!PremiumStatus.belongs(token: theirs, familyShared: false, to: mine))  // another account's

        func annual(_ token: UUID?) -> PremiumStatus.Entitlement {
            .init(productID: PremiumProducts.annual, expirationDate: now.addingTimeInterval(86_400 * 30), appAccountToken: token)
        }
        let ok = PremiumStatus.resolve(entitlements: [annual(mine)], renewal: nil, account: mine, now: now)
        #expect(ok.isPremium(at: now) && !ok.heldByOtherAccount)
        let other = PremiumStatus.resolve(entitlements: [annual(theirs)], renewal: nil, account: mine, now: now)
        #expect(!other.isPremium(at: now))
        #expect(other.heldByOtherAccount)
        let renewalForOther = PremiumStatus.Renewal(state: .subscribed, productID: PremiumProducts.annual,
                                                    expirationDate: now.addingTimeInterval(86_400), willAutoRenew: true,
                                                    appAccountToken: theirs)
        #expect(!PremiumStatus.resolve(entitlements: [annual(theirs)], renewal: renewalForOther, account: mine, now: now).isPremium(at: now))
        #expect(PremiumStatus.resolve(entitlements: [annual(nil)], renewal: nil, account: mine, now: now).isPremium(at: now))
    }

    @Test func premiumCacheIsPerAccount() throws {
        let name = "AccountTests.cache.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let alex = Account.uuid(forAppleUserID: "apple.alex")
        let sam = Account.uuid(forAppleUserID: "apple.sam")
        PremiumStatus(state: .active, productID: PremiumProducts.monthly, expiresAt: Date().addingTimeInterval(600),
                      willAutoRenew: true).save(to: d, account: alex)
        #expect(PremiumStatus.cached(in: d, account: alex).isPremium())
        #expect(!PremiumStatus.cached(in: d, account: sam).isPremium())
    }
}
