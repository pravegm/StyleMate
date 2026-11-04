# StyleMate pre-launch engineering review
Scope: main @6c3f528, [studio] = feat/studio-pipeline, [identity] = feat/integrate-identity-launch. Lines are on main unless tagged. All items verified in code; (?) = unconfirmed.

## Top 20, ranked

1. **data-loss: cloud restore deletes local items the cloud lacks.** `Category.swift:178-187`, `CloudKitService.swift:197-209`.
   - Any item whose upload failed (offline, iCloud full) or is still in flight mid-scan is deleted with its images on the next foreground.
   - `fetchAll` returns a *partial* list on a mid-pagination error, so one flaky fetch can wipe most of the closet.
   - Cloud wins the merge: offline edits revert (`:130-170`), offline deletes come back.
   - Fix: never delete from a full-fetch diff; keep a pending-upload/tombstone set, persist the change token, apply only server deletions, return nil on error.

2. **jetsam: manual add runs up to 15 extractions in parallel, beside the scan.** `AddItemReviewView.swift:320-323` (one TaskGroup, bypasses `extractionGate`).
   - Picker photos stay full-res (`StyleMateApp.swift:95-103`; 24 MP ≈ 96 MB decoded).
   - Each extraction holds ~100-200 MB, including 24 MB of labeler logits (`WardrobeML.swift:90`).
   - Fix: share `extractionGate` (1-2 at a time), downsample to 2048 px via ImageIO on load, pause the scan meanwhile.

3. **jetsam/perf: renderers default to 3× screen scale, i.e. 9× the pixels.**
   - `WardrobeItem.swift:276`: "480 px" thumbnails are 1440 px, bigger than the ≤1024 px cutouts.
   - `PhotoScanService.swift:1029→1113-1118`: scan thumbnails are 1920×1440 (≈11 MB); 24 per group × 3 groups in flight ≈ 0.8 GB.
   - Same pattern: `FaceMatchingService.swift:1208`, [identity] `SelfieCameraService.swift:423`.
   - Fix: `format.scale = 1` everywhere; regenerate existing thumbnails.

4. **hang/battery/data: full CloudKit pull on every foreground, on the main actor.** `StyleMateApp.swift:201-208` → `CloudKitService.swift:179`.
   - `recordZoneChanges(since: nil)` downloads every record with its assets.
   - `wardrobeItem(from:)` (`:295,306,320`) reads every image via `loadImage` on @MainActor.
   - Fix: persist the change token, exclude assets via `desiredKeys`, fetch only missing assets off-main.

5. **crash: face-matching state is unsynchronized.** `FaceMatchingService.swift:91-93` (gallery, `mlModel`), `SCRFDDetector.swift:54-66` (lazy model).
   - Concurrent callers: scan (`PhotoScanService.swift:652-656`, gated only by `identityGate`), manual add (`AddItemFlowView.swift:63`), `isolateChosenPerson` on main (`:96`, also learns), reference builder (`FaceReferenceViewModel.swift:100`), `clearReference` (`:1243-1244`, `mlModel = nil`).
   - A racing append is a use-after-free crash; the persisted gallery keeps the last write. [identity] `IdentityWorker` doesn't cover the scan.
   - Fix: make it an `actor` and route every caller through it.

6. **privacy/corruption: sign-out doesn't stop the scan.** `StyleMateApp.swift:175-177`, `AuthService.swift:223-234`.
   - User A's scan keeps appending; after B signs in, A's garments are saved and uploaded as B's (`PhotoScanService.swift:767-768`).
   - Fix: cancel the scan and [studio] `StudioQueue` on sign-out, drop cached progress, guard `extractItems` on user id.

7. **main-thread/flash wear: whole-file rewrites on every change.**
   - `ItemEmbeddingStore.swift:54-59` rewrites ~9 MB at 1k items on each `set`, from the MainActor scan (`PhotoScanService.swift:764,798`): O(n²) bytes, 100 ms+ hitches.
   - `ClosetActions.swift:24-31` removes one id at a time despite the batch API.
   - `items.didSet` (`Category.swift:48-54,80-87`) re-encodes the wardrobe into UserDefaults per change.
   - Fix: debounced off-main writes in binary or SQLite, batch removal, wardrobe out of UserDefaults.

8. **jetsam: unbounded image caches, decodes in view bodies.**
   - `WardrobeItem.swift:236-240`: count limit 600, no cost limit. `ClosetImageLoader.swift:12-16`: 500 decoded (~8 MB each at 1440 px), images double-cached.
   - Main-thread decodes in `body`: `HomeView.swift:292,555`, `TodayOutfitSheet.swift:509,935`, `MyOutfitsView.swift:497-502`.
   - Fix: byte `totalCostLimit`, cache thumbnails only, use `AsyncItemTile` everywhere.

9. **jetsam/battery [studio]: Stable Diffusion runs during the scan with memory reduction off.**
   - `StudioRenderer.swift:196` sets `reduceMemory = false` for 2+ seeds (every plan), keeping ~1-1.2 GB resident.
   - `.task(id: items.count)` in `StyleMateApp` enqueues renders 3 s after each scanned item, while the 5 scan models are loaded.
   - `cancel()` (`StudioQueue.swift:101`) is never called; the progress handler always returns `true` (`:219`); no charging requirement.
   - Fix: one `generateImages(imageCount:)` with `reduceMemory = true`; skip while scanning; unload on background; require power; check `os_proc_available_memory()`.

10. **data-loss [studio]: re-renders start from the AI image; original cutout never backed up.**
    - `StudioQueue.swift:118,126` renders from `imagePath`, which holds the studio image after the first render; the cutout never syncs, so a reinstall renders AI from AI.
    - `markFailed` (`:133-135`) makes transient errors permanent.
    - Fix: render from `StudioStore.cutoutPath`, sync the cutout, record errors apart from rejections.

11. **privacy/App Store 5.1.1(v): "Delete Everything" misses data.**
    - `ProfileView.swift:464` removes `wardrobe_<id>`, but the real key replaces `.`/`@` (`Category.swift:58-60`); Apple IDs contain dots, so the wardrobe survives.
    - Also kept: `WardrobeEmbeddings/items.json` and the Core Data outfit log, which has no user attribute and is shared across accounts. Cloud delete is fire-and-forget (`:478-480`).
    - Fix: use `storageKey(for:)`, delete embeddings and outfits, scope outfits by user, retry the cloud delete.

12. **bug (USP): self-learning can drift the gallery onto someone else.** `FaceMatchingService.swift:366-372`.
    - It learns any face whose max over the gallery is ≥ 0.62; one impostor face in, and their photos match it at ~0.9 and keep being learned.
    - FIFO trim (`:347-352`) evicts the oldest learned faces ([identity]: the head-turn anchors).
    - Fix: gate learning on similarity to the selfie anchors, cap the learned share, track provenance, protect selfie entries.

13. **battery: faceless photos get a second, larger SCRFD pass.** `SCRFDDetector.swift:74-89` re-detects on a 1.8× padded copy (~3700×2760, ~40 MB). Fix: no-retry option for library/scan passes.

14. **perf: per-pixel Swift loops in GarmentCutout.**
    - Per item: two full-crop renders to RGBA plus loops (`GarmentCutout.swift:103-114`, 1.57 M px), two float pyramid fills (`:61-62`), copy-on-write copies (`:150,179`).
    - Estimate ~60-80 MB transient and ~100-200 M ops per item: ~0.2-0.5 s on A19 Release (?), 10-30× slower in Debug.
    - Fix: item box region only, threshold in Core Image, vImage for the pyramid.

15. **hang: heavy work on the main thread.**
    - `AddItemFlowView.swift:96` runs Vision + AdaFace on tap.
    - PNG/thumbnail encodes on the MainActor (`PhotoScanService.swift:737-742,789-791`).
    - Progress JSON (asset IDs + pending-review embeddings) written every 5 s (`:283-288,313-315`).
    - Fix: move all three to detached tasks.

16. **crash/data-loss: legacy migrations race the live wardrobe.** `Category.swift:204-357`.
    - They read `items` off-main and write back by stale index: index-out-of-range crashes or the wrong item overwritten mid-scan or mid-delete.
    - Two run at once (`StyleMateApp.swift:165-166`), one deleting files the other writes back; BG-removal turns transparent PNG cutouts into JPEGs on white.
    - Fix: delete them, or update by id on main.

17. **bug: being offline signs Google users out.** `AuthService.swift:212-216` signs out on any `restorePreviousSignIn` error, network included. Fix: only on revocation or invalid-grant.

18. **crash/bug: Core Data.**
    - `PersistenceController.swift:14-18`: `fatalError` on store load; a full disk means a crash loop.
    - Outfit snapshots keep `imagePath` (`MyOutfitsViewModel.swift:113-114`); upgrade, replace and studio delete those files (`PhotoScanService.swift:792-794`), so history goes blank.
    - Fix: recover/reset the store; keep referenced files or snapshot a thumbnail.

19. **release risk: the shipped configuration is never compiled.**
    - CI builds Debug only (`ci.yml:113,224`), Swift 5 with no concurrency checking, so the compiler can't flag #5-#7.
    - `GarmentDescriber.withTimeout` (`:61-72`) doesn't enforce its timeout (the task group awaits its children).
    - Fix: Release archive job, `SWIFT_STRICT_CONCURRENCY=complete`, one Thread Sanitizer run.

20. **privacy: selfie and wardrobe photos go into iCloud Backup.**
    - `SelfieCameraService.swift:149-152` and `WardrobeItem.swift:202` write to Documents, contradicting "never leaves the phone".
    - Face embeddings use default file protection; `print` logs user and asset IDs in Release.
    - Fix: Application Support, backup excluded, explicit file protection; `#if DEBUG` logs.

**Checked and OK:** Debug code fully `#if DEBUG` (caller too); Core ML on CPU + Neural Engine only (background-safe); scan checkpointing and BG task completion sound; OutfitEngine search bounded; [identity] privacy manifest and removed entitlements fine.
