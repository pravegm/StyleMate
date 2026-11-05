import CloudKit
import CoreData
import Foundation
import Testing
import UIKit
@testable import StyleMate

/// Data-safety and resource rules from the pre-launch reliability review: the cloud merge
/// never deletes from a diff, the sync ledger, the face gallery's caps, the extraction gate,
/// image sizing, protected storage and outfit-history snapshots.
struct ReliabilityTests {

    private func item(_ id: UUID = UUID(), product: String = "T-Shirts", colors: [String] = ["Black"],
                      image: String = "img.png", thumb: String? = nil) -> WardrobeItem {
        WardrobeItem(id: id, category: StyleMate.Category.tops, product: product, colors: colors,
                     brand: "", pattern: .solid, imagePath: image, croppedImagePath: image,
                     thumbnailPath: thumb)
    }

    // MARK: - Cloud merge (#1)

    @Test func fullFetchNeverDeletesLocalOnlyItems() {
        let localOnly = item(product: "Jeans")          // e.g. its upload failed
        let both = item()
        var changes = CloudKitService.CloudChanges()
        changes.modified = [both]
        changes.isFullFetch = true
        let out = CloudMerge.apply(changes, to: [localOnly, both], ledger: SyncLedger(), fileExists: { _ in true })
        #expect(out.items.map(\.id).contains(localOnly.id))
        #expect(out.removed.isEmpty)
    }

    @Test func onlyServerDeletionsRemoveItems_andNeverPendingOnes() {
        let gone = item()
        let editedHere = item()
        var ledger = SyncLedger()
        ledger.markPending(editedHere.id)
        var changes = CloudKitService.CloudChanges()
        changes.deleted = [gone.id, editedHere.id]
        let out = CloudMerge.apply(changes, to: [gone, editedHere], ledger: ledger, fileExists: { _ in true })
        #expect(out.removed.map(\.id) == [gone.id])
        #expect(out.items.map(\.id) == [editedHere.id])
    }

    @Test func localEditsWinOverCloud() {
        let id = UUID()
        let mine = item(id, colors: ["Red"])
        var ledger = SyncLedger()
        ledger.markPending(id)
        var changes = CloudKitService.CloudChanges()
        changes.modified = [item(id, colors: ["Blue"])]
        let out = CloudMerge.apply(changes, to: [mine], ledger: ledger, fileExists: { _ in true })
        #expect(out.items.first?.colors == ["Red"])
        #expect(!out.changed)
    }

    @Test func cloudEditsApplyWhenNothingIsPending_keepingLocalFiles() {
        let id = UUID()
        let mine = item(id, colors: ["Red"], image: "local.png", thumb: "thumb_local.png")
        var changes = CloudKitService.CloudChanges()
        changes.modified = [item(id, colors: ["Blue"], image: "cloud.png")]
        let out = CloudMerge.apply(changes, to: [mine], ledger: SyncLedger(), fileExists: { _ in true })
        #expect(out.items.first?.colors == ["Blue"])
        #expect(out.items.first?.imagePath == "local.png")
        #expect(out.items.first?.thumbnailPath == "thumb_local.png")
    }

    @Test func firstReconcileKeepsThePhonesCopy() {
        let id = UUID()
        let mine = item(id, colors: ["Red"])
        var changes = CloudKitService.CloudChanges()
        changes.modified = [item(id, colors: ["Blue"])]
        changes.isFullFetch = true
        let out = CloudMerge.apply(changes, to: [mine], ledger: SyncLedger(), preferLocal: true,
                                   fileExists: { _ in true })
        #expect(out.items.first?.colors == ["Red"])
        #expect(out.uploadLocal == [id])
    }

    @Test func locallyDeletedItemsDontComeBack() {
        let id = UUID()
        var ledger = SyncLedger()
        ledger.markDeleted(id)
        var changes = CloudKitService.CloudChanges()
        changes.modified = [item(id)]
        let out = CloudMerge.apply(changes, to: [], ledger: ledger, fileExists: { _ in true })
        #expect(out.items.isEmpty)

        var deletion = CloudKitService.CloudChanges()
        deletion.deleted = [id]
        let confirmed = CloudMerge.apply(deletion, to: [], ledger: ledger, fileExists: { _ in true })
        #expect(confirmed.confirmedDeletions == [id])
    }

    @Test func newCloudItemsAreAddedAndQueuedForAssets() {
        let fresh = item(image: "missing.png", thumb: "thumb_missing.png")
        var changes = CloudKitService.CloudChanges()
        changes.modified = [fresh]
        let out = CloudMerge.apply(changes, to: [], ledger: SyncLedger(), fileExists: { _ in false })
        #expect(out.items.map(\.id) == [fresh.id])
        #expect(out.items.first?.thumbnailPath == nil)   // the cloud's thumbnail name isn't on this phone
        #expect(out.needAssets.map(\.id) == [fresh.id])
    }

    // MARK: - Fresh install / new iPhone (per-install profile ids)

    private func record(id: UUID, uploadedBy profileID: String, product: String = "Jeans") -> CKRecord {
        let rid = CKRecord.ID(recordName: id.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitService.zoneName))
        let r = CKRecord(recordType: CloudKitService.recordType, recordID: rid)
        r["userID"] = profileID
        r["category"] = StyleMate.Category.bottoms.rawValue
        r["product"] = product
        r["colors"] = ["Blue"]
        r["brand"] = ""
        r["pattern"] = Pattern.solid.rawValue
        r["imagePath"] = "\(id.uuidString).png"
        r["croppedImagePath"] = "\(id.uuidString).png"
        return r
    }

    @Test func freshInstallAdoptsTheWardrobeAnOldProfileIdUploaded() throws {
        // The reinstall got a new local profile UUID; the zone's records carry the old one.
        let oldProfile = UUID().uuidString
        let ids = [UUID(), UUID(), UUID()]
        let pulled = ids.compactMap { CloudKitService.restoredItem(from: record(id: $0, uploadedBy: oldProfile)) }
        #expect(pulled.map(\.id) == ids)

        var changes = CloudKitService.CloudChanges()
        changes.modified = pulled
        changes.isFullFetch = true
        let out = CloudMerge.apply(changes, to: [], ledger: SyncLedger(), preferLocal: true,
                                   fileExists: { _ in false })
        #expect(Set(out.items.map(\.id)) == Set(ids))
        #expect(Set(out.needAssets.map(\.id)) == Set(ids))          // images come down next
        #expect(out.items.allSatisfy { $0.product == "Jeans" && $0.category == .bottoms })
    }

    @Test func schemaAndAccountErrorsStopSyncForTheSession_networkErrorsDont() {
        // A Production container without the deployed schema rejects writes
        // (serverRejectedRequest / invalidArguments): latch, don't retry in a loop.
        #expect(CloudKitService.isPermanent(CKError(.serverRejectedRequest)))
        #expect(CloudKitService.isPermanent(CKError(.invalidArguments)))
        #expect(CloudKitService.isPermanent(CKError(.notAuthenticated)))
        #expect(!CloudKitService.isPermanent(CKError(.networkUnavailable)))
        #expect(!CloudKitService.isPermanent(CKError(.requestRateLimited)))
    }

    @Test func otherRecordTypesAreNotRestored() {
        let r = CKRecord(recordType: "SomethingElse",
                         recordID: CKRecord.ID(recordName: UUID().uuidString,
                                               zoneID: CKRecordZone.ID(zoneName: CloudKitService.zoneName)))
        #expect(CloudKitService.restoredItem(from: r) == nil)
    }

    @Test func aPendingWipeBlocksPullsForEveryProfile() throws {
        // "Delete Everything" starts a new profile; until the zone deletion is confirmed the
        // new profile must not pull the deleted wardrobe back.
        let suite = "reltest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!WardrobeViewModel.mustWipeZoneBeforePull(ledger: SyncLedger(), defaults: defaults))
        defaults.set(true, forKey: WardrobeViewModel.pendingZoneWipeKey)
        #expect(WardrobeViewModel.mustWipeZoneBeforePull(ledger: SyncLedger(), defaults: defaults))
    }

    // MARK: - Sync ledger

    @Test func uploadConfirmationOnlyClearsTheChangeItCarried() {
        let id = UUID()
        var ledger = SyncLedger()
        let first = ledger.markPending(id)
        _ = ledger.markPending(id)                   // edited again while the upload was in flight
        ledger.confirmUpload(id, generation: first)
        #expect(ledger.isPending(id))
        ledger.confirmUpload(id, generation: ledger.pending[id.uuidString])
        #expect(!ledger.isPending(id))
    }

    @Test func ledgerSurvivesARoundTrip() throws {
        var ledger = SyncLedger()
        ledger.markPending(UUID())
        ledger.markDeleted(UUID())
        ledger.pendingZoneWipe = true
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(SyncLedger.self, from: data) == ledger)
    }

    @Test func deleteEverythingUsesTheRealWardrobeKey() {
        // Apple ids / emails contain dots: the raw id is not the key.
        #expect(WardrobeViewModel.storageKey(for: "a.b@icloud.com") == "wardrobe_a_b_icloud_com")
    }

    // MARK: - Face gallery caps (#12)

    private func entry(_ source: FaceMatchingService.GallerySource, _ t: TimeInterval) -> FaceMatchingService.GalleryEntry {
        FaceMatchingService.GalleryEntry(embedding: [Float(t)], source: source, addedAt: Date(timeIntervalSince1970: t))
    }

    @Test func learnedFacesAreCappedAndEvictedOldestFirst() {
        var g = [entry(.selfie, 0), entry(.selfie, 1)] + (2..<8).map { entry(.learned, TimeInterval($0)) }
        FaceMatchingService.enforceCaps(&g)
        #expect(g.filter { $0.source == .selfie }.count == 2)
        #expect(g.filter { $0.source == .learned }.map(\.addedAt.timeIntervalSince1970) == [6, 7])
    }

    @Test func selfieAndConfirmedFacesAreNeverEvicted() {
        let cap = FaceMatchingService.galleryCap
        var g = [entry(.selfie, 0), entry(.selfie, 1)]
            + (2..<cap).map { entry(.confirmed, TimeInterval($0)) }
            + (0..<10).map { entry(.learned, TimeInterval(1000 + $0)) }
        FaceMatchingService.enforceCaps(&g)
        #expect(g.count == cap)
        #expect(g.filter { $0.source == .learned }.isEmpty)
        #expect(g.filter { $0.source != .learned }.count == cap)
    }

    // MARK: - Extraction gate (#2)

    @Test func extractionGateBoundsConcurrency() async {
        let gate = AsyncSemaphore(permits: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        #expect(await counter.maxConcurrent <= 2)
        #expect(await counter.total == 12)
        #expect(await gate.holders == 0)
    }

    private actor Counter {
        var current = 0, maxConcurrent = 0, total = 0
        func enter() { current += 1; total += 1; maxConcurrent = max(maxConcurrent, current) }
        func leave() { current -= 1 }
    }

    // MARK: - Image sizing (#2, #3)

    private func photo(width: Int, height: Int, alpha: Bool = false) -> UIImage {
        ImageDownsampler.render(size: CGSize(width: width, height: height), opaque: !alpha) { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
    }

    @Test func rendererIsPinnedToScaleOne() {
        let img = photo(width: 300, height: 200)
        #expect(img.cgImage?.width == 300)
        #expect(img.cgImage?.height == 200)
    }

    @Test func pickedPhotosAreDownsampledTo2048() throws {
        let big = photo(width: 4032, height: 3024)
        let data = try #require(big.jpegData(compressionQuality: 0.8))
        let small = try #require(ImageDownsampler.downsample(data: data))
        let longSide = max(small.cgImage!.width, small.cgImage!.height)
        #expect(longSide <= 2048 && longSide >= 2000)
        let redrawn = ImageDownsampler.downsample(image: big)
        #expect(max(redrawn.cgImage!.width, redrawn.cgImage!.height) == 2048)
    }

    @Test func thumbnailsAreReally480Pixels() throws {
        let cutout = photo(width: 1024, height: 900, alpha: true)
        let name = try #require(WardrobeImageFileHelper.saveThumbnail(cutout))
        defer { WardrobeImageFileHelper.deleteImage(at: name) }
        let size = try #require(ImageDownsampler.pixelSize(ofFile: WardrobeImageFileHelper.fileURL(for: name)))
        #expect(max(size.width, size.height) == 480)
        #expect(name.hasSuffix(".png"))   // transparent cutouts stay PNG
        #expect(!WardrobeImageFileHelper.thumbnailNeedsRegeneration(name))
    }

    // MARK: - Protected storage (#20)

    @Test func wardrobeImagesLiveInApplicationSupportExcludedFromBackup() throws {
        let folder = WardrobeImageFileHelper.folderURL
        #expect(folder.path.contains("Library/Application Support"))
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func legacyDocumentsFolderIsMigrated() throws {
        let fm = FileManager.default
        let legacyName = "reltest_legacy_\(UUID().uuidString)"
        let legacy = LocalStore.documents.appendingPathComponent(legacyName, isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacy.appendingPathComponent("a.png"))
        let dest = LocalStore.directory(legacyName)
        defer { try? fm.removeItem(at: dest) }
        LocalStore.migrateLegacyDirectory(named: legacyName, into: dest)
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("a.png").path))
        #expect(!fm.fileExists(atPath: legacy.path))
    }

    @Test func legacySelfieMovesOutOfDocuments() throws {
        let fm = FileManager.default
        let user = "reltest-\(UUID().uuidString)"
        let legacy = LocalStore.documents.appendingPathComponent(LocalStore.selfieFileName(user))
        try Data("jpeg".utf8).write(to: legacy)
        UserDefaults.standard.set(legacy.path, forKey: LocalStore.selfieKey(user))
        defer { LocalStore.deleteSelfie(userId: user) }
        let resolved = try #require(LocalStore.resolveSelfiePath(legacy.path, userId: user))
        #expect(resolved.contains("Application Support/Selfie"))
        #expect(!fm.fileExists(atPath: legacy.path))
        #expect(UserDefaults.standard.string(forKey: LocalStore.selfieKey(user)) == resolved)
    }

    @Test func deletingTheSelfieRemovesTheHeadTurnFramesToo() throws {
        let user = "reltest-\(UUID().uuidString)"
        let frame = ImageDownsampler.render(size: CGSize(width: 40, height: 40)) { _ in }
        SelfieReferenceStore.saveTurnFrames([frame, frame], userId: user)
        let names = try #require(UserDefaults.standard.stringArray(forKey: SelfieReferenceStore.turnFramesKey(user)))
        #expect(names.count == 2)
        #expect(FileManager.default.fileExists(atPath: LocalStore.selfieDirectory.appendingPathComponent(names[0]).path))
        LocalStore.deleteSelfie(userId: user)
        #expect(UserDefaults.standard.stringArray(forKey: SelfieReferenceStore.turnFramesKey(user)) == nil)
        #expect(!FileManager.default.fileExists(atPath: LocalStore.selfieDirectory.appendingPathComponent(names[0]).path))
    }

    // MARK: - Outfit history (#18)

    @Test func outfitSnapshotsOutliveTheItemsFiles() throws {
        let cutout = photo(width: 800, height: 800, alpha: true)
        let image = try #require(WardrobeImageFileHelper.saveImageAsPNG(cutout))
        let thumb = try #require(WardrobeImageFileHelper.saveThumbnail(cutout))
        let snap = try #require(WardrobeImageFileHelper.makeOutfitSnapshot(thumbnailPath: thumb, imagePath: image))
        defer { WardrobeImageFileHelper.deleteImage(at: snap) }
        #expect(WardrobeImageFileHelper.isOutfitSnapshot(snap))
        WardrobeImageFileHelper.deleteImage(at: image)        // item deleted / upgraded
        WardrobeImageFileHelper.deleteImage(at: thumb)
        #expect(WardrobeImageFileHelper.loadImage(at: snap) != nil)
    }

    @MainActor
    @Test func outfitHistoryIsScopedPerUserAndDeletable() throws {
        let context = PersistenceController.shared.container.viewContext
        let a = "reltest-a-\(UUID().uuidString)", b = "reltest-b-\(UUID().uuidString)"
        let vmA = MyOutfitsViewModel(context: context)
        vmA.setUser(a)
        vmA.addOutfit(date: Date(), items: [item()], source: MyOutfitsViewModel.Source.manual)
        #expect(vmA.outfitsByDate.values.flatMap { $0 }.contains { $0.userID == a })

        let vmB = MyOutfitsViewModel(context: context)
        vmB.setUser(b)
        #expect(!vmB.outfitsByDate.values.flatMap { $0 }.contains { $0.userID == a })

        MyOutfitsViewModel.deleteOutfits(forUser: a, in: context)
        vmA.fetchAllOutfits()
        #expect(!vmA.outfitsByDate.values.flatMap { $0 }.contains { $0.userID == a })
    }

    @Test func coreDataRecoveryOnlyResetsDamagedStores() {
        #expect(PersistenceController.isUnrecoverable(NSError(domain: NSCocoaErrorDomain,
                                                              code: NSPersistentStoreIncompatibleVersionHashError)))
        #expect(PersistenceController.isUnrecoverable(NSError(domain: NSSQLiteErrorDomain, code: 11)))
        // Disk full (SQLITE_FULL = 13) must NOT reset the history.
        #expect(!PersistenceController.isUnrecoverable(NSError(domain: NSSQLiteErrorDomain, code: 13)))
    }
}

/// Face-gallery safety with the real models. Declared as an extension so it runs inside the
/// serialized `FaceMatchingTests` suite (they share `FaceMatchingService.shared`).
extension FaceMatchingTests {
    private static let reliabilityUser = "reliability@stylemate.test"

    private func relFixture(_ name: String) throws -> UIImage {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FIXTURES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("photos") }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/photos")
        return try #require(UIImage(data: try Data(contentsOf: dir.appendingPathComponent(name))))
    }

    private func relUseAsSelfie(_ image: UIImage) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reliability_selfie.jpg")
        try #require(image.jpegData(compressionQuality: 0.95)).write(to: url)
        UserDefaults.standard.set(url.path, forKey: "selfieReferencePath_\(Self.reliabilityUser)")
        FaceMatchingService.shared.clearReference(forUser: Self.reliabilityUser)
        #expect(FaceMatchingService.shared.loadReference(forUser: Self.reliabilityUser))
    }

    /// A unit vector at cosine `c` from `base` (deterministic per seed).
    private func near(_ base: [Float], cosine c: Float, seed: Int) -> [Float] {
        // SplitMix64: independent pseudo-random directions per seed (128-d or 512-d, so two of
        // them are nearly orthogonal and the generated views aren't near-duplicates).
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15 &+ 1
        func next() -> Float {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Float(Double(z) / Double(UInt64.max)) * 2 - 1
        }
        var r = base.map { _ in next() }
        let proj = zip(r, base).map { $0 * $1 }.reduce(0, +)
        r = zip(r, base).map { $0 - proj * $1 }                  // orthogonal to base
        let rn = sqrt(r.map { $0 * $0 }.reduce(0, +))
        r = r.map { $0 / rn }
        let s = sqrt(max(0, 1 - c * c))
        return zip(base, r).map { c * $0 + s * $1 }
    }

    /// Selfie anchors built from one front frame: upright + mirror, or one when the embedder is
    /// flip-averaged (mirror-invariant).
    private var selfieAnchorCount: Int { FaceModelProfile.active.flipAverage ? 1 : 2 }

    /// A "new view of the user": clears both learning bars (gallery and selfie) with room to spare.
    private var learnableCosine: Float {
        min(0.9, max(FaceMatchingService.autoLearnSelfieThreshold, FaceMatchingService.autoLearnThreshold) + 0.1)
    }

    @Test func learningIsGatedOnTheSelfieAndCapped() throws {
        let svc = FaceMatchingService.shared
        let user = Self.reliabilityUser
        let selfie = try relFixture("street_coat_cap.jpg")
        try relUseAsSelfie(selfie)
        let selfieCG = try #require(selfie.cgImage)
        let anchor = try #require(svc.evaluateFaceForReference(in: selfieCG)?.embedding)

        // A stranger can't be learned however high the (gallery) similarity claims to be.
        let strangerCG = try #require(try relFixture("street_coat_boots.jpg").cgImage)
        let stranger = try #require(svc.evaluateFaceForReference(in: strangerCG)?.embedding)
        #expect(!svc.learnFromScan(stranger, similarity: 0.97, userId: user))

        // New views of the user are learned, but never more than the selfie/confirmed share.
        var learned = 0
        let c = learnableCosine
        for seed in 1...5 where svc.learnFromScan(near(anchor, cosine: c, seed: seed), similarity: c, userId: user) {
            learned += 1
        }
        #expect(learned >= 1)
        let summary = svc.gallerySummary()
        #expect(summary.selfie == selfieAnchorCount)
        #expect(summary.learned <= summary.selfie + summary.confirmed)

        // An ambiguous group-photo pick (small margin) is not learned.
        #expect(!svc.learnFromScan(near(anchor, cosine: c, seed: 99), similarity: c,
                                   margin: FaceMatchingService.autoLearnMargin / 3, userId: user))
        svc.clearReference(forUser: user)
    }

    @Test func concurrentUseIsSafe() async throws {
        let svc = FaceMatchingService.shared
        let user = Self.reliabilityUser
        let selfie = try relFixture("street_coat_cap.jpg")
        try relUseAsSelfie(selfie)
        let cg = try #require(selfie.cgImage)
        let anchor = try #require(svc.evaluateFaceForReference(in: cg)?.embedding)
        let c = learnableCosine
        let views = (0..<8).map { near(anchor, cosine: c, seed: 200 + $0) }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    switch i % 4 {
                    case 0: _ = svc.findUserInPhoto(cg)
                    case 1: _ = svc.addReferenceEmbeddings([views[i % views.count]], forUser: user)
                    case 2: _ = svc.learnFromScan(views[(i + 3) % views.count], similarity: c, userId: user)
                    default:
                        _ = svc.referenceCount
                        _ = svc.loadReference(forUser: user)
                        if i == 7 { svc.clearReference(forUser: user) }
                    }
                }
            }
        }
        #expect(svc.loadReference(forUser: user))
        #expect(svc.gallerySummary().selfie == selfieAnchorCount)
        let match = svc.findUserInPhoto(cg)
        // The selfie photo still matches its own anchor (single best), and the gallery consensus
        // (mean of the two best entries: the anchor + a synthetic view at cosine c) still auto-adds.
        #expect((match.bestSingleSimilarity ?? 0) > 0.9)
        #expect((match.similarity ?? 0) >= FaceMatchingService.highConfidenceThreshold)
        svc.clearReference(forUser: user)
    }
}
