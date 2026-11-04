import Foundation
import Testing
import UIKit
@testable import StyleMate

/// First run + daily loop logic: the local profile (no login) and its migration, the
/// "First 40" ranking and hand-off, item trust, auto-log suggestions, the morning look's
/// schedule and copy, and the bundled sample photos.
struct FirstRunTests {

    // MARK: Local profile

    private static func defaults() -> UserDefaults {
        let name = "FirstRunTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private static func user(_ id: String, created: TimeInterval = 0) -> User {
        User(id: id, email: nil, name: "N", preferredStyles: [.everyday], notificationsEnabled: false,
             dateCreated: Date(timeIntervalSince1970: created))
    }

    @Test func freshInstallCreatesAStableLocalProfile() {
        let d = Self.defaults()
        let first = AuthService.resolveLocalProfile(defaults: d)
        #expect(UUID(uuidString: first.id) != nil)
        #expect(d.string(forKey: AuthService.localProfileIDKey) == first.id)
        let again = AuthService.resolveLocalProfile(defaults: d)
        #expect(again.id == first.id)
    }

    @Test func appleOrGoogleUserKeepsTheirIdAndWardrobe() throws {
        let d = Self.defaults()
        let legacy = Self.user("001234.abcd.5678")
        d.set("001234.abcd.5678", forKey: AuthService.legacyAuthUserIDKey)
        d.set("apple", forKey: AuthService.legacyAuthProviderKey)
        d.set(try JSONEncoder().encode(legacy), forKey: AuthService.currentUserObjectKey)
        let resolved = AuthService.resolveLocalProfile(defaults: d)
        #expect(resolved.id == "001234.abcd.5678")
        #expect(d.string(forKey: AuthService.legacyAuthProviderKey) == nil)
        #expect(AuthService.resolveLocalProfile(defaults: d).id == "001234.abcd.5678")
    }

    @Test func signedOutUserWithAWardrobeIsAdopted() {
        let d = Self.defaults()
        AuthService.saveUserProfiles(["old": Self.user("old", created: 10), "a.b@c": Self.user("a.b@c", created: 5)], defaults: d)
        d.set(Data([1]), forKey: "wardrobe_a_b_c")   // WardrobeViewModel's key for "a.b@c"
        #expect(AuthService.resolveLocalProfile(defaults: d).id == "a.b@c")
    }

    @Test func resetNeverReadoptsAnOldProfile() {
        let d = Self.defaults()
        AuthService.saveUserProfiles(["old": Self.user("old")], defaults: d)
        let fresh = AuthService.resolveLocalProfile(defaults: d, adoptExisting: false)
        #expect(fresh.id != "old")
    }

    // MARK: First 40

    @Test func outfitScoreWantsOneWholePersonWithAFace() {
        let full = FirstLook.score(FirstLookSignals(personCount: 1, bodyHeight: 0.85, faceArea: 0.006))!
        let crowd = FirstLook.score(FirstLookSignals(personCount: 4, bodyHeight: 0.85, faceArea: 0.006))!
        let faceless = FirstLook.score(FirstLookSignals(personCount: 1, bodyHeight: 0.85, faceArea: 0))!
        #expect(full > crowd)
        #expect(full > faceless)
        #expect(FirstLook.score(.none) == nil)                                                   // nobody: food, documents
        #expect(FirstLook.score(FirstLookSignals(personCount: 1, bodyHeight: 0.2, faceArea: 0.01)) == nil)  // a sliver
    }

    @Test func orderPutsTheBestFortyFirstThenTheRestNewestFirst() {
        var scores: [Int: Double] = [:]
        for i in 0..<100 where i % 2 == 1 { scores[i] = Double(i) / 100 }   // odd units are outfit photos
        let (order, n) = FirstLook.order(unitCount: 120, scores: scores, limit: 40)
        #expect(n == 40)
        #expect(order.count == 120 && Set(order).count == 120)
        #expect(order.first == 99)                                    // best score first
        #expect(Array(order.prefix(40)).allSatisfy { $0 % 2 == 1 })
        let rest = Array(order.dropFirst(40))
        #expect(rest == rest.sorted())                                // untouched order
    }

    @Test func handOffAtEightItemsOrNinetySeconds() {
        #expect(!FirstLook.shouldHandOff(itemsFound: 7, elapsed: 30, scanFinished: false))
        #expect(FirstLook.shouldHandOff(itemsFound: 8, elapsed: 30, scanFinished: false))
        #expect(FirstLook.shouldHandOff(itemsFound: 0, elapsed: 90, scanFinished: false))
        #expect(FirstLook.shouldHandOff(itemsFound: 2, elapsed: 10, scanFinished: true))
        #expect(FirstLook.counterText(items: 11, photos: 23) == "11 items found in 23 photos")
        #expect(FirstLook.counterText(items: 1, photos: 1) == "1 item found in 1 photo")
    }

    @Test func windowIsTheLastNinetyDays() {
        let now = Date()
        #expect(FirstLook.inWindow(now.addingTimeInterval(-86_400 * 30), now: now))
        #expect(!FirstLook.inWindow(now.addingTimeInterval(-86_400 * 120), now: now))
        #expect(!FirstLook.inWindow(nil, now: now))
    }

    @Test func firstLookFlagSurvivesACheckpoint() throws {
        var job = ScanJob(rangeStart: nil, rangeEnd: nil, extraAssetIDs: nil, isAutomatic: false, createdAt: Date(), firstLook: true)
        job.photosDone = 3
        let decoded = try JSONDecoder().decode(ScanJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.firstLook == true)
        // Checkpoints written before the field existed still decode.
        let old = #"{"isAutomatic":false,"createdAt":0,"addedItemIDs":[],"photosDone":0}"#
        #expect(try JSONDecoder().decode(ScanJob.self, from: Data(old.utf8)).firstLook == nil)
    }

    // MARK: Trust

    @Test func trustRules() {
        #expect(ItemTrust.doubt(category: .tops, product: "T-Shirts", quality: 0.7, pieces: 1) == nil)
        #expect(ItemTrust.doubt(category: .tops, product: "T-Shirts", quality: 0.3, pieces: 1) == .lowQuality)
        #expect(ItemTrust.doubt(category: .accessories, product: "Ties", quality: 0.8, pieces: 3) == .fragmented)
        #expect(ItemTrust.doubt(category: .accessories, product: "Ties", quality: 0.5, pieces: 1) == .unsureAccessory)
        #expect(ItemTrust.doubt(category: .accessories, product: "Rings", quality: 0.5, pieces: 1) == .tinyJewelry)
        #expect(ItemTrust.doubt(category: .accessories, product: "Hats", quality: 0.7, pieces: 2) == .fragmented)
        // Things that come in two are fine in two pieces.
        #expect(ItemTrust.doubt(category: .footwear, product: "Boots", quality: 0.7, pieces: 2) == nil)
        #expect(ItemTrust.doubt(category: .accessories, product: "Sunglasses", quality: 0.7, pieces: 2) == nil)
        #expect(ItemTrust.doubt(category: .outerwear, product: "Coats", quality: 0.7, pieces: 2) == nil)
    }

    @Test func pieceCountIgnoresSpecks() {
        // 20x10: two 6x6 blocks and a 1-pixel speck.
        let w = 20, h = 10
        var a = [UInt8](repeating: 0, count: w * h)
        for y in 2..<8 { for x in 1..<7 { a[y * w + x] = 255 }; for x in 12..<18 { a[y * w + x] = 255 } }
        a[0] = 255
        #expect(ItemTrust.pieceCount(alpha: a, width: w, height: h) == 2)
        #expect(ItemTrust.pieceCount(alpha: [UInt8](repeating: 0, count: w * h), width: w, height: h) == 0)
    }

    @Test func pieceCountOnARealCutout() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 10, y: 10, width: 60, height: 80))
            ctx.fill(CGRect(x: 120, y: 10, width: 60, height: 80))
        }
        #expect(ItemTrust.pieceCount(of: image) == 2)
    }

    // MARK: Auto-log

    private static func item(_ cat: Category, _ product: String, _ color: String) -> WardrobeItem {
        WardrobeItem(category: cat, product: product, colors: [color], brand: "", pattern: .solid, imagePath: "x.png")
    }

    @Test func wearLogAsksAboutWholeRecentOutfits() {
        let now = Date()
        let coat = Self.item(.outerwear, "Coats", "Camel")
        let cardigan = Self.item(.midLayers, "Cardigans", "Navy")
        let watch = Self.item(.accessories, "Watches", "Silver")
        #expect(WearLogSuggestions.isWorthAsking(items: [coat, cardigan], date: now.addingTimeInterval(-86_400 * 2), now: now))
        #expect(!WearLogSuggestions.isWorthAsking(items: [coat], date: now, now: now))                       // one piece
        #expect(!WearLogSuggestions.isWorthAsking(items: [coat, cardigan], date: now.addingTimeInterval(-86_400 * 20), now: now))
        #expect(!WearLogSuggestions.isWorthAsking(items: [watch, Self.item(.accessories, "Belts", "Black")], date: now, now: now))
        #expect(WearLogSuggestions.summary(of: [cardigan, watch, coat]) == "Camel coat + navy cardigan")
    }

    @Test func wearLogQuestionNamesTheDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_793_600)        // Wed 2026-11-04 12:00 UTC
        #expect(WearLogSuggestions.question(for: now, now: now, calendar: cal) == "Wore this today?")
        #expect(WearLogSuggestions.question(for: now.addingTimeInterval(-86_400), now: now, calendar: cal) == "Wore this yesterday?")
        #expect(WearLogSuggestions.question(for: now.addingTimeInterval(-86_400 * 1), now: now, calendar: cal) != "Wore this on Tue?")
        #expect(WearLogSuggestions.question(for: now.addingTimeInterval(-86_400 * 2), now: now, calendar: cal) == "Wore this on Mon?")
    }

    // MARK: Morning look

    @Test func morningAlarmsStartTomorrowOnceTodaysTimeHasPassed() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let afternoon = Date(timeIntervalSince1970: 1_793_793_600)  // 12:00 UTC
        let fires = MorningLookScheduler.fireDates(after: afternoon, hour: 7, minute: 30, count: 3, calendar: cal)
        #expect(fires.count == 3)
        #expect(fires[0] == afternoon.addingTimeInterval(19.5 * 3600))  // 07:30 next day
        #expect(fires[1].timeIntervalSince(fires[0]) == 86_400)
        let early = afternoon.addingTimeInterval(-6 * 3600)            // 06:00
        #expect(MorningLookScheduler.fireDates(after: early, hour: 7, minute: 30, count: 1, calendar: cal)[0]
                == early.addingTimeInterval(1.5 * 3600))
    }

    @Test func morningHeadlineNamesWeatherAndTheHeroPiece() {
        let coat = Self.item(.outerwear, "Coats", "Camel")
        let tee = Self.item(.tops, "T-Shirts", "White")
        let weather = Weather(temperature2m: 9.2, weathercode: 3, isDay: 1, time: "", city: nil, conditionText: "Cloudy")
        #expect(MorningLookStore.headline(for: [tee, coat], weather: weather, fahrenheit: false)
                == "9° and cloudy — your camel coat look is ready")
        #expect(MorningLookStore.headline(for: [tee], weather: nil, fahrenheit: false) == "Your white t-shirt look is ready")
    }

    // MARK: Samples

    @Test func samplePhotosAreBundledAndCredited() {
        let urls = SampleLibrary.photoURLs()
        #expect(urls.count == SampleLibrary.credits.count, "Bundled sample photos: \(urls.map(\.lastPathComponent))")
        #expect(SampleLibrary.loadImages().count == urls.count)
        #expect(SampleLibrary.credits.allSatisfy { $0.source.hasPrefix("https://commons.wikimedia.org/") })
    }

    @Test func sampleIdsAreRemembered() {
        let d = Self.defaults()
        let a = UUID(), b = UUID()
        SampleLibrary.recordSampleItems([a], forUser: "u", defaults: d)
        SampleLibrary.recordSampleItems([b], forUser: "u", defaults: d)
        #expect(SampleLibrary.sampleItemIDs(forUser: "u", defaults: d) == [a, b])
        #expect(SampleLibrary.sampleItemIDs(forUser: "other", defaults: d).isEmpty)
    }
}
