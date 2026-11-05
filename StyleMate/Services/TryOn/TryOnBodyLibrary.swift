import Foundation
import Photos
import UIKit
import Vision

/// Which body the try-on dresses, and how good a photo is for it.
///
/// Default: the user's own best full-length, front-facing, standing photo among the photos the scan
/// already matched to them (face recognition, `PhotoScanService` → `noteUserPhoto`). The user can pick
/// another photo or take one. Without one (or if they prefer), a neutral model body that matches their
/// profile gender is generated once on the device and cached. The chosen image is copied to
/// `Application Support/TryOn/Body/` (local only, never synced or uploaded).
@MainActor
final class TryOnBodyLibrary: ObservableObject {
    static let shared = TryOnBodyLibrary()

    enum Source: String, Codable { case library, picked, camera, model, sample }

    struct BodyPhoto: Codable, Equatable {
        /// Stable id (part of every render's cache key).
        let id: String
        let source: Source
        /// File name under `TryOn/Body/`.
        let file: String
        let score: Float
        let assetId: String?
        let date: Date
    }

    enum Status: Equatable {
        case missing         // nothing chosen yet
        case searching       // looking through the user's photos
        case generating      // making the neutral model body
        case ready(BodyPhoto)
        case off             // the user turned try-on off
    }

    @Published private(set) var status: Status = .missing
    private var model: TryOnBodyModel?
    private var modelFor: String?

    private var dir: URL { LocalStore.directory("TryOn/Body") }
    private var stateURL: URL { LocalStore.directory("TryOn").appendingPathComponent("body.json") }
    private var candidatesURL: URL { LocalStore.directory("TryOn").appendingPathComponent("candidates.json") }

    private init() {
        if !TryOnAvailability.userEnabled { status = .off }
        else if let d = try? Data(contentsOf: stateURL), let b = try? JSONDecoder().decode(BodyPhoto.self, from: d),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent(b.file).path) {
            status = .ready(b)
        }
    }

    var current: BodyPhoto? { if case .ready(let b) = status { return b }; return nil }

    // MARK: - Scan hook

    /// A photo the scan confidently matched to the user (called from `PhotoScanService`). Kept as a
    /// candidate for the try-on body; nothing is analysed until a body is needed.
    nonisolated static func noteUserPhoto(_ assetId: String, date: Date?) {
        Task { @MainActor in shared.addCandidate(assetId, date: date ?? Date()) }
    }

    private struct Candidate: Codable { let id: String; let date: Date }

    private func loadCandidates() -> [Candidate] {
        (try? Data(contentsOf: candidatesURL)).flatMap { try? JSONDecoder().decode([Candidate].self, from: $0) } ?? []
    }

    private func addCandidate(_ id: String, date: Date) {
        var c = loadCandidates().filter { $0.id != id }
        c.append(Candidate(id: id, date: date))
        c.sort { $0.date > $1.date }
        if let d = try? JSONEncoder().encode(Array(c.prefix(300))) { _ = LocalStore.write(d, to: candidatesURL) }
    }

    // MARK: - Choosing a body

    /// The analysed current body (cached in memory; re-analysed after a relaunch, ~1-2 s).
    func bodyModel() async -> TryOnBodyModel? {
        guard let b = current else { return nil }
        if let model, modelFor == b.id { return model }
        guard let img = UIImage(contentsOfFile: dir.appendingPathComponent(b.file).path)?.cgImage else { return nil }
        let result = await Task.detached(priority: .utility) { TryOnBodyAnalyzer.analyze(img) }.value
        guard case .success(let m) = result else { return nil }
        model = m; modelFor = b.id
        return m
    }

    /// Picks the best photo of the user from the scan's matches (newest first, up to 60 looked at).
    /// Falls back to the neutral model when none is good enough.
    func findBestPhoto(userId: String, gender: String?) async {
        guard status != .searching, status != .generating else { return }
        status = .searching
        var ids = loadCandidates().prefix(60).map(\.id)
        if ids.isEmpty {
            // Scanned before try-on existed: look at the newest photos instead (face check below).
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 150
            let recent = PHAsset.fetchAssets(with: .image, options: opts)
            recent.enumerateObjects { a, _, _ in
                if !a.mediaSubtypes.contains(.photoScreenshot) { ids.append(a.localIdentifier) }
            }
        }
        var best: (UIImage, Float, String)?
        if !ids.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            var list: [PHAsset] = []
            assets.enumerateObjects { a, _, _ in list.append(a) }
            let manager = PHImageManager.default()
            for asset in list {
                guard asset.pixelHeight >= 900 || asset.pixelWidth >= 900 else { continue }
                guard let thumb = await LibraryFaceScanner.loadImage(asset, manager: manager, side: 640, network: false, timeout: 10),
                      let cg = thumb.cgImage else { continue }
                let quick = await Task.detached(priority: .utility) { Self.quickScore(cg) }.value
                guard let q = quick, q > (best?.1 ?? 0.55) else { continue }
                guard let full = await LibraryFaceScanner.loadImage(asset, manager: manager, side: 2048, network: true, timeout: 30),
                      let fcg = full.cgImage else { continue }
                // Still the user (the candidate list is from the scan, but check again on this exact frame).
                let identity = await Task.detached(priority: .utility) {
                    FaceMatchingService.shared.resolveIdentityForScan(in: fcg, fullImage: full, userId: userId)
                }.value
                guard case .analyze = identity else { continue }
                // Prefer fitted clothes: a long wide coat leaves a lot to invent under a tee and jeans.
                let bulk = await Task.detached(priority: .utility) { () -> Float in
                    guard let up = Self.upright(full, maxSide: 2048),
                          case .success(let m) = TryOnBodyAnalyzer.analyze(up) else { return 1 }
                    return Self.clothingBulk(m)
                }.value
                let score = q - 0.6 * bulk
                guard score > (best?.1 ?? 0.4) else { continue }
                best = (full, score, asset.localIdentifier)
            }
        }
        if let b = best, await use(b.0, source: .library, score: b.1, assetId: b.2) { return }
        await useModelBody(gender: gender)
    }

    /// Uses a photo the user picked or took. False (and nothing changes) if it isn't a usable
    /// full-length, front-facing photo of one person.
    @discardableResult
    func use(_ image: UIImage, source: Source, score: Float? = nil, assetId: String? = nil) async -> Bool {
        guard let cg = Self.upright(image, maxSide: 2048) else { return false }
        let s: Float?
        if let score { s = score } else { s = await Task.detached(priority: .userInitiated) { Self.quickScore(cg) }.value }
        guard let s, s >= 0.5 || source == .model || source == .sample else {
            if status == .searching { status = current.map { Status.ready($0) } ?? Status.missing }
            return false
        }
        let result = await Task.detached(priority: .userInitiated) { TryOnBodyAnalyzer.analyze(cg) }.value
        guard case .success(let m) = result else {
            if status == .searching { status = current.map { Status.ready($0) } ?? Status.missing }
            return false
        }
        let id = UUID().uuidString
        let file = "body_\(id).jpg"
        guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92),
              LocalStore.write(data, to: dir.appendingPathComponent(file)) else { return false }
        if let old = current { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old.file)) }
        let photo = BodyPhoto(id: id, source: source, file: file, score: s, assetId: assetId, date: Date())
        if let d = try? JSONEncoder().encode(photo) { _ = LocalStore.write(d, to: stateURL) }
        model = m; modelFor = id
        TryOnStore.shared.removeAll()
        status = .ready(photo)
        TryOnQueue.shared.bodyChanged()
        return true
    }

    /// Generates (once) a neutral model body on the device: the studio's diffusion model draws a
    /// person in plain fitted grey clothes on a white sweep; the head is cropped away (a neck-down
    /// catalogue shot), so no face is invented.
    func useModelBody(gender: String?) async {
        status = .generating
        let g = (gender ?? "").lowercased()
        let who = g.hasPrefix("f") || g.contains("woman") ? "woman" : (g.hasPrefix("m") && !g.contains("non") ? "man" : "person")
        let prompt = "full body fashion catalog photo of a slim \(who) standing straight, front view, arms relaxed at the sides, " +
            "wearing a plain light grey fitted t-shirt and light grey leggings, white sneakers, plain white studio background, soft even light"
        let negative = "multiple people, cropped, cut off feet, sitting, side view, back view, text, watermark, deformed, extra limbs"
        for k in 0..<3 {
            guard let img = await StudioRenderer.shared.render(startingImage: nil, prompt: prompt, negativePrompt: negative,
                                                                 strength: 1, steps: Self.modelSteps, guidance: 7,
                                                                 seed: 4242 + UInt32(k)) else { break }
            // Kept whole for the pose; the finished try-on is cropped under the chin (`cropBelowChin`).
            if await use(UIImage(cgImage: img), source: .model, score: 0.6) { return }
        }
        StudioRenderer.shared.unload()
        status = current.map { Status.ready($0) } ?? Status.missing
    }

    static var modelSteps = 20

    private var autoAttempted = false

    /// The first time a look wants a body and none is chosen: pick the user's best photo (or the model)
    /// without asking. Once per launch.
    func chooseAutomaticallyIfNeeded(userId: String, gender: String?) {
        guard !autoAttempted, status == .missing, TryOnAvailability.isAvailable else { return }
        #if DEBUG
        if TryOnDebugSeed.isActive { return }
        #endif
        autoAttempted = true
        Task { await findBestPhoto(userId: userId, gender: gender) }
    }

    func turnOff() {
        TryOnAvailability.userEnabled = false
        status = .off
    }

    func turnOn() {
        TryOnAvailability.userEnabled = true
        status = current.map { Status.ready($0) } ?? Status.missing
        if case .missing = status,
           let d = try? Data(contentsOf: stateURL), let b = try? JSONDecoder().decode(BodyPhoto.self, from: d) { status = .ready(b) }
    }

    /// "Delete everything": the body photo, the candidates and every render.
    func removeAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: candidatesURL)
        TryOnStore.shared.removeAll()
        model = nil; modelFor = nil
        status = TryOnAvailability.userEnabled ? .missing : .off
    }

    #if DEBUG
    /// UI tests / CI: use a bundled or fixture photo as the body without the quality bar.
    func debugUse(_ image: UIImage) async { _ = await use(image, source: .sample, score: 1) }
    #endif

    // MARK: - Scoring

    /// 0...1: how good a photo is for try-on — one person, whole body in view (shoulders to ankles),
    /// upright, facing the camera, big enough, arms not across the torso. nil = unusable.
    nonisolated static func quickScore(_ image: CGImage) -> Float? {
        guard let raw = TryOnBodyAnalyzer.detectPose(image), raw.personCount == 1 else { return nil }
        let pose = TryOnBodyAnalyzer.arrange(raw, source: "vision")
        guard pose.minConfidence >= 0.3, pose.faceVisible else { return nil }
        let sho = TOGeo.mid(pose.sL, pose.sR), hip = TOGeo.mid(pose.hL, pose.hR)
        let torso = TOGeo.dist(sho, hip)
        guard torso > 1 else { return nil }
        // Upright: torso axis within ~20 degrees of vertical.
        let tilt = abs(atan2(hip.x - sho.x, hip.y - sho.y))
        guard tilt < 0.35 else { return nil }
        // Facing the camera: shoulders wide relative to the torso (a side view is narrow).
        let frontal = TOGeo.dist(pose.sL, pose.sR) / torso
        guard frontal > 0.45 else { return nil }
        let ankle = max(pose.aL.y, pose.aR.y)
        let height = ankle - pose.nose.y
        let sizeScore = min(1, Float(height / CGFloat(image.height)) / 0.7)
        // Arms by the sides score higher than arms across the body (they hide the garment).
        let armsOut = [pose.wL, pose.wR].filter { w in w.x < pose.sL.x + torso * 0.1 || w.x > pose.sR.x - torso * 0.1 }.count
        let conf = min(1, pose.minConfidence / 0.6)
        // A hand raised above the shoulders (a wave, a hand on a hat) leaves its sleeve floating.
        let top = min(pose.sL.y, pose.sR.y)
        let raised: Float = (pose.wL.y < top || pose.wR.y < top) ? 0.25 : 0
        let base = 0.35 * sizeScore + 0.25 * Float(min(1, frontal / 0.7)) + 0.2 * conf
        return base + 0.2 * Float(armsOut) / 2 - raised
    }

    /// Share of the person that is clothing outside a close body envelope (torso band + limb capsules):
    /// ~0 for fitted clothes, 0.15-0.3 for a long open coat or a wide skirt.
    nonisolated static func clothingBulk(_ m: TryOnBodyModel) -> Float {
        let limbs = TryOnCompositor.limbMask(m)
        let half = 0.55 * max(m.shoulderW, m.hipW)
        let u = m.u, v = m.v, T = m.torsoLen
        var person = 0, outside = 0
        for y in 0..<m.height {
            for x in 0..<m.width {
                let i = y * m.width + x
                let l = m.labels[i]
                guard l != TryOnLabel.background else { continue }
                person += 1
                guard TryOnLabel.clothing.contains(l), !limbs[i] else { continue }
                let d = CGVector(dx: CGFloat(x) - m.shoMid.x, dy: CGFloat(y) - m.shoMid.y)
                let across = abs(TOGeo.dot(d, u)), along = TOGeo.dot(d, v)
                if across > half || along < -0.2 * T || along > T + 0.3 * m.thigh { outside += 1 }
            }
        }
        return person > 0 ? Float(outside) / Float(person) : 1
    }

    /// A try-on of the generated model, cropped just under the chin (a neck-down catalogue shot, so
    /// no invented face is ever shown).
    nonisolated static func cropBelowChin(_ image: CGImage, pose: TryOnPose) -> CGImage? {
        let sho = TOGeo.mid(pose.sL, pose.sR)
        let chin = pose.nose.y + (sho.y - pose.nose.y) * 0.45
        let y = max(0, min(image.height / 3, Int(chin)))
        return image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: image.height - y))
    }

    /// An upright (orientation applied) CGImage no larger than `maxSide`.
    nonisolated static func upright(_ image: UIImage, maxSide: CGFloat) -> CGImage? {
        let size = image.size
        let k = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        if image.imageOrientation == .up, k >= 1, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
