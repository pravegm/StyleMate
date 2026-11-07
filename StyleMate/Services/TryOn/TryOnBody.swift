import CoreGraphics
import Foundation
import Vision

/// Human-parser classes the try-on reads (the app's garment parser, `GarmentSegmenter.P`).
enum TryOnLabel {
    static let background: UInt8 = GarmentSegmenter.P.background.rawValue
    static let face: UInt8 = GarmentSegmenter.P.face.rawValue
    static let hair: UInt8 = GarmentSegmenter.P.hair.rawValue
    static let clothing: Set<UInt8> = [GarmentSegmenter.P.top, .dress, .skirt, .pants, .belt, .scarf].reduce(into: []) { $0.insert($1.rawValue) }
    /// Kept byte-for-byte from the photo: face, hair, hands, glasses, hat, bag, jewelry.
    static let protected: Set<UInt8> = [GarmentSegmenter.P.face, .hair, .hands, .glasses, .hat, .bag, .jewelry].reduce(into: []) { $0.insert($1.rawValue) }
    static let skin: Set<UInt8> = [GarmentSegmenter.P.face, .hands, .arms, .legs, .torso].reduce(into: []) { $0.insert($1.rawValue) }
    static let feet: UInt8 = GarmentSegmenter.P.feet.rawValue
    static let upper: Set<UInt8> = [GarmentSegmenter.P.top, .dress, .torso].reduce(into: []) { $0.insert($1.rawValue) }
}

/// Body keypoints in working-image pixels (y down), arranged by IMAGE side (L = smaller x), the way
/// the compositor maps a front-view garment onto a front-view person.
struct TryOnPose: Codable, Equatable {
    var nose: CGPoint
    var sL: CGPoint, sR: CGPoint
    var eL: CGPoint, eR: CGPoint
    var wL: CGPoint, wR: CGPoint
    var hL: CGPoint, hR: CGPoint
    var kL: CGPoint, kR: CGPoint
    var aL: CGPoint, aR: CGPoint
    /// Lowest confidence over the joints that matter for a full-body try-on.
    var minConfidence: Float
    /// Face landmarks seen (eyes / nose): a front or three-quarter view.
    var faceVisible: Bool
    /// "vision" or "parse" (estimated from the parser where Vision isn't available).
    var source: String
}

/// Everything the compositor needs about one body photo, at working resolution.
struct TryOnBodyModel {
    /// The working image: the person crop, opaque.
    let image: TryOnRaster
    let pose: TryOnPose
    /// Parser label per working pixel.
    let labels: [UInt8]
    /// Face / hair / hands / accessories as a soft matte (the parser grid upsampled bilinearly and
    /// feathered ~1.5 px), so those edges blend instead of stair-stepping. 1 = copied byte for byte.
    let protectSoft: [Float]
    var width: Int { image.width }
    var height: Int { image.height }

    func label(_ x: Int, _ y: Int) -> UInt8 {
        labels[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))]
    }

    // Derived geometry (same names as tryon-lab/tryon.py).
    var shoMid: CGPoint { TOGeo.mid(pose.sL, pose.sR) }
    var hipMid: CGPoint { TOGeo.mid(pose.hL, pose.hR) }
    var torsoLen: CGFloat { TOGeo.dist(shoMid, hipMid) }
    /// Unit torso axis, shoulders -> hips.
    var v: CGVector { TOGeo.unit(CGVector(dx: hipMid.x - shoMid.x, dy: hipMid.y - shoMid.y)) }
    /// Unit vector across the body toward image-right.
    var u: CGVector { CGVector(dx: -v.dy, dy: v.dx).dx >= 0 ? CGVector(dx: -v.dy, dy: v.dx) : CGVector(dx: v.dy, dy: -v.dx) }
    var shoulderW: CGFloat { TOGeo.dist(pose.sL, pose.sR) * 1.30 }
    var hipW: CGFloat { max(TOGeo.dist(pose.hL, pose.hR) * 1.6, shoulderW * 0.72) }
    /// Chest width: the pose estimate, narrowed where a fitted top shows the body is slimmer.
    var chestW: CGFloat {
        let est = shoulderW * 0.80
        let y = Int(shoMid.y + 0.30 * torsoLen)
        guard y >= 0, y < height else { return est }
        let c = Int(shoMid.x)
        guard c >= 0, c < width, TryOnLabel.upper.contains(label(c, y)) else { return est }
        var l = c, r = c
        while l > 0, TryOnLabel.upper.contains(label(l - 1, y)) { l -= 1 }
        while r < width - 1, TryOnLabel.upper.contains(label(r + 1, y)) { r += 1 }
        return min(est, max(est * 0.85, CGFloat(r - l + 1)))
    }
    var thigh: CGFloat { (TOGeo.dist(pose.hL, pose.kL) + TOGeo.dist(pose.hR, pose.kR)) / 2 }
    var shin: CGFloat { (TOGeo.dist(pose.kL, pose.aL) + TOGeo.dist(pose.kR, pose.aR)) / 2 }

    func arm(_ left: Bool) -> (CGPoint, CGPoint, CGPoint) { left ? (pose.sL, pose.eL, pose.wL) : (pose.sR, pose.eR, pose.wR) }
    func leg(_ left: Bool) -> (CGPoint, CGPoint, CGPoint) { left ? (pose.hL, pose.kL, pose.aL) : (pose.hR, pose.kR, pose.aR) }
}

/// Small geometry helpers (named, not operators: global operator overloads on CoreGraphics types
/// would slow down type-checking of every `-` / `*` in the module).
enum TOGeo {
    static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    static func unit(_ v: CGVector) -> CGVector { let n = max(1e-6, hypot(v.dx, v.dy)); return CGVector(dx: v.dx / n, dy: v.dy / n) }
    static func add(_ a: CGPoint, _ v: CGVector, _ k: CGFloat = 1) -> CGPoint { CGPoint(x: a.x + v.dx * k, y: a.y + v.dy * k) }
    static func sub(_ a: CGPoint, _ b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
    static func scale(_ v: CGVector, _ k: CGFloat) -> CGVector { CGVector(dx: v.dx * k, dy: v.dy * k) }
    static func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }
    static func len(_ v: CGVector) -> CGFloat { hypot(v.dx, v.dy) }
}

/// Analyses a body photo: Vision body pose (Apple, on-device) + the app's garment parser, on a
/// person crop at working resolution.
enum TryOnBodyAnalyzer {
    /// Working height of the person crop (the try-on image's resolution).
    static var workingHeight = 1280

    enum Failure: Error, Equatable { case noPerson, notFullBody, parserUnavailable }

    static func analyze(_ photo: CGImage) -> Result<TryOnBodyModel, Failure> {
        // 1. Pose on the whole photo (downscaled for speed).
        let small = downscaled(photo, maxSide: 1024) ?? photo
        let visionPose = detectPose(small)
        // 2. Person crop: from the pose, or the parser on the whole frame when Vision has nothing.
        var crop: CGRect
        if let p = visionPose {
            let k = CGFloat(photo.width) / CGFloat(small.width)
            crop = personRect(p.map { CGPoint(x: $0.x * k, y: $0.y * k) }, imageSize: CGSize(width: photo.width, height: photo.height))
        } else {
            crop = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
        }
        crop = fit23(crop, in: CGSize(width: photo.width, height: photo.height))
        guard let cropped = photo.cropping(to: crop.integral) else { return .failure(.noPerson) }
        let H = min(workingHeight, max(256, cropped.height))
        let W = max(64, Int((CGFloat(H) * CGFloat(cropped.width) / CGFloat(cropped.height)).rounded()))
        guard var raster = TryOnRaster(cropped, width: W, height: H) else { return .failure(.noPerson) }
        for i in 0..<(W * H) { raster.px[i * 4 + 3] = 255 }
        // 3. Parse the crop on the parser's 384x576 grid, then up to working size (nearest).
        guard let gridImage = scaled(cropped, width: WardrobeML.gridW, height: WardrobeML.gridH),
              let parsed = WardrobeML.shared.parse(gridImage) else { return .failure(.parserUnavailable) }
        var labels = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            let gy = min(WardrobeML.gridH - 1, y * WardrobeML.gridH / H)
            for x in 0..<W {
                labels[y * W + x] = parsed.labels[gy * WardrobeML.gridW + min(WardrobeML.gridW - 1, x * WardrobeML.gridW / W)]
            }
        }
        guard labels.contains(where: { $0 != TryOnLabel.background }) else { return .failure(.noPerson) }
        let gridProtect = TryOnPlane(width: WardrobeML.gridW, height: WardrobeML.gridH,
                                     v: parsed.labels.map { TryOnLabel.protected.contains($0) ? 1 : 0 })
        let soft = gridProtect.resized(width: W, height: H).blurred(sigma: 1.5).v.map { min(1, max(0, ($0 - 0.15) / 0.7)) }
        // 4. Pose in working coordinates: Vision again on the crop (more pixels on the person), else the parser estimate.
        let pose: TryOnPose
        if let cg = raster.opaqueCGImage(), let p = detectPose(cg) { pose = arrange(p, source: "vision") }
        else if let p = poseFromParse(labels, width: W, height: H) { pose = p }
        else { return .failure(.notFullBody) }
        return .success(TryOnBodyModel(image: raster, pose: pose, labels: labels, protectSoft: soft))
    }

    // MARK: - Vision

    /// Raw Vision joints (y-down pixel coords) keyed like COCO plus confidences.
    struct RawPose {
        var points: [VNHumanBodyPoseObservation.JointName: (CGPoint, Float)]
        var personCount: Int
        func map(_ f: (CGPoint) -> CGPoint) -> RawPose {
            RawPose(points: points.mapValues { (f($0.0), $0.1) }, personCount: personCount)
        }
    }

    static func detectPose(_ image: CGImage) -> RawPose? {
        // Never longer than 15 s: a Vision request can block for good on a device (the Duo's did).
        HangGuard.run("body pose (Vision)", seconds: 15) { detectPoseUnguarded(image) }
    }

    private static func detectPoseUnguarded(_ image: CGImage) -> RawPose? {
        let req = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([req])) != nil, let results = req.results, !results.isEmpty else { return nil }
        // The biggest person.
        func spread(_ o: VNHumanBodyPoseObservation) -> CGFloat {
            guard let pts = try? o.recognizedPoints(.all) else { return 0 }
            let good = pts.values.filter { $0.confidence > 0.2 }
            guard let minY = good.map(\.location.y).min(), let maxY = good.map(\.location.y).max() else { return 0 }
            return maxY - minY
        }
        guard let best = results.max(by: { spread($0) < spread($1) }),
              let pts = try? best.recognizedPoints(.all) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var out: [VNHumanBodyPoseObservation.JointName: (CGPoint, Float)] = [:]
        for (k, p) in pts where p.confidence > 0 {
            out[k] = (CGPoint(x: p.location.x * w, y: (1 - p.location.y) * h), p.confidence)
        }
        let people = results.filter { spread($0) > 0.25 }.count
        return RawPose(points: out, personCount: max(1, people))
    }

    static let requiredJoints: [VNHumanBodyPoseObservation.JointName] = [
        .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]

    static func arrange(_ raw: RawPose, source: String) -> TryOnPose {
        func p(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? { raw.points[j].map { $0.0 } }
        func c(_ j: VNHumanBodyPoseObservation.JointName) -> Float { raw.points[j]?.1 ?? 0 }
        let ls = p(.leftShoulder) ?? .zero, rs = p(.rightShoulder) ?? .zero
        // Person-left chain vs person-right chain; image-left is the chain whose shoulder has smaller x.
        let leftIsImageLeft = ls.x < rs.x
        func chain(_ personLeft: Bool) -> [CGPoint] {
            let names: [VNHumanBodyPoseObservation.JointName] = personLeft
                ? [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle]
                : [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle]
            var pts = names.map { p($0) }
            // Missing elbow / wrist: hang the arm straight down from the shoulder.
            let sh = pts[0] ?? .zero, hip = pts[3] ?? CGPoint(x: sh.x, y: sh.y + 200)
            let armLen = abs(hip.y - sh.y) * 0.85
            if pts[1] == nil { pts[1] = CGPoint(x: sh.x, y: sh.y + armLen * 0.5) }
            if pts[2] == nil { pts[2] = CGPoint(x: pts[1]!.x, y: pts[1]!.y + armLen * 0.5) }
            return pts.map { $0 ?? .zero }
        }
        let a = chain(leftIsImageLeft), b = chain(!leftIsImageLeft)
        var minC = requiredJoints.map(c).min() ?? 0
        if a.contains(.zero) || b.contains(.zero) { minC = 0 }
        let face = c(.nose) > 0.2 && (c(.leftEye) > 0.2 || c(.rightEye) > 0.2)
        return TryOnPose(nose: p(.nose) ?? TOGeo.mid(a[0], b[0]),
                         sL: a[0], sR: b[0], eL: a[1], eR: b[1], wL: a[2], wR: b[2],
                         hL: a[3], hR: b[3], kL: a[4], kR: b[4], aL: a[5], aR: b[5],
                         minConfidence: minC, faceVisible: face, source: source)
    }

    /// A rough pose from the parser alone (the simulator has no Vision body pose): body proportions on
    /// the person's silhouette, leg centres from the leg / trouser columns.
    static func poseFromParse(_ labels: [UInt8], width w: Int, height h: Int) -> TryOnPose? {
        var top = h, bottom = 0, faceSumX = 0, faceSumY = 0, faceN = 0
        for y in 0..<h {
            for x in 0..<w where labels[y * w + x] != 0 {
                top = min(top, y); bottom = max(bottom, y)
                if labels[y * w + x] == TryOnLabel.face { faceSumX += x; faceSumY += y; faceN += 1 }
            }
        }
        guard bottom - top > h / 3 else { return nil }
        let ph = CGFloat(bottom - top)
        func rowSpan(_ y: Int, _ accept: (UInt8) -> Bool) -> (Int, Int)? {
            let yy = min(h - 1, max(0, y))
            var l = -1, r = -1
            for x in 0..<w where accept(labels[yy * w + x]) { if l < 0 { l = x }; r = x }
            return l < 0 ? nil : (l, r)
        }
        let body: (UInt8) -> Bool = { $0 != 0 && $0 != GarmentSegmenter.P.arms.rawValue && $0 != GarmentSegmenter.P.hands.rawValue && $0 != GarmentSegmenter.P.bag.rawValue }
        let yS = top + Int(0.19 * ph), yH = top + Int(0.50 * ph), yK = top + Int(0.73 * ph), yA = top + Int(0.94 * ph)
        guard let s = rowSpan(yS, body), let hp = rowSpan(yH, body) else { return nil }
        let cx = CGFloat(s.0 + s.1) / 2
        let sw = CGFloat(s.1 - s.0)
        func legCentres(_ y: Int) -> (CGFloat, CGFloat) {
            let yy = min(h - 1, max(0, y))
            var runs: [(Int, Int)] = []
            var start = -1
            for x in 0..<w {
                let on = body(labels[yy * w + x])
                if on && start < 0 { start = x }
                if (!on || x == w - 1) && start >= 0 { runs.append((start, on ? x : x - 1)); start = -1 }
            }
            let big = runs.sorted { ($0.1 - $0.0) > ($1.1 - $1.0) }.prefix(2).sorted { $0.0 < $1.0 }
            if big.count == 2 { return (CGFloat(big[0].0 + big[0].1) / 2, CGFloat(big[1].0 + big[1].1) / 2) }
            if let one = big.first { let c = CGFloat(one.0 + one.1) / 2, q = CGFloat(one.1 - one.0) / 4; return (c - q, c + q) }
            return (cx - sw * 0.2, cx + sw * 0.2)
        }
        let hipC = CGFloat(hp.0 + hp.1) / 2, hipQ = CGFloat(hp.1 - hp.0) * 0.22
        let (k1, k2) = legCentres(yK), (a1, a2) = legCentres(yA)
        let sL = CGPoint(x: cx - sw * 0.36, y: CGFloat(yS)), sR = CGPoint(x: cx + sw * 0.36, y: CGFloat(yS))
        let armDrop = 0.17 * ph
        let nose = faceN > 0 ? CGPoint(x: CGFloat(faceSumX) / CGFloat(faceN), y: CGFloat(faceSumY) / CGFloat(faceN))
                             : CGPoint(x: cx, y: CGFloat(top) + 0.07 * ph)
        return TryOnPose(nose: nose, sL: sL, sR: sR,
                         eL: CGPoint(x: sL.x - sw * 0.06, y: sL.y + armDrop), eR: CGPoint(x: sR.x + sw * 0.06, y: sR.y + armDrop),
                         wL: CGPoint(x: sL.x - sw * 0.08, y: sL.y + armDrop * 2), wR: CGPoint(x: sR.x + sw * 0.08, y: sR.y + armDrop * 2),
                         hL: CGPoint(x: hipC - hipQ, y: CGFloat(yH)), hR: CGPoint(x: hipC + hipQ, y: CGFloat(yH)),
                         kL: CGPoint(x: k1, y: CGFloat(yK)), kR: CGPoint(x: k2, y: CGFloat(yK)),
                         aL: CGPoint(x: a1, y: CGFloat(yA)), aR: CGPoint(x: a2, y: CGFloat(yA)),
                         minConfidence: 0.3, faceVisible: faceN > 30, source: "parse")
    }

    // MARK: - Geometry helpers

    static func personRect(_ raw: RawPose, imageSize: CGSize) -> CGRect {
        let pts = raw.points.values.filter { $0.1 > 0.1 }.map { $0.0 }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let hgt = maxY - minY
        return CGRect(x: minX - hgt * 0.22, y: minY - hgt * 0.16, width: (maxX - minX) + hgt * 0.44, height: hgt * 1.26)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Grows `r` toward a 2:3 portrait inside the image (the parser's aspect).
    static func fit23(_ r: CGRect, in size: CGSize) -> CGRect {
        var rect = r
        let targetW = rect.height * 2 / 3
        if rect.width < targetW {
            rect = rect.insetBy(dx: -(targetW - rect.width) / 2, dy: 0)
        } else {
            let targetH = rect.width * 1.5
            rect = rect.insetBy(dx: 0, dy: -(targetH - rect.height) / 2)
        }
        // Shift back inside, then clip.
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        if rect.maxX > size.width { rect.origin.x = max(0, size.width - rect.width) }
        if rect.maxY > size.height { rect.origin.y = max(0, size.height - rect.height) }
        return rect.intersection(CGRect(origin: .zero, size: size))
    }

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let s = CGFloat(maxSide) / CGFloat(max(image.width, image.height))
        guard s < 1 else { return image }
        return scaled(image, width: Int(CGFloat(image.width) * s), height: Int(CGFloat(image.height) * s))
    }

    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
