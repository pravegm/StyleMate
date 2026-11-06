// Builds the simulator photo library for StyleMateUITests/RealFirstRunE2ETests (CI's "Real first run" step).
//
//   xcrun swiftc -O -o make-ui-library scripts/ui_test_library.swift
//   ./make-ui-library StyleMateTests/Fixtures/photos <out-dir> [filler-count]
//   xcrun simctl addmedia <sim> <out-dir>/*.jpg
//
// What's in it (all derived from the CC0 fixtures in StyleMateTests/Fixtures/photos, see CREDITS.md, or
// drawn here, so the licences stay clean):
// - the user: 8 variants of kurta_dhoti_turban.jpg (crops, scales, a mirror, darker, recompressed),
//   the person whose face the DEBUG selfie hook (-uiTestSelfieFixture, StyleMate/Debug/DebugSelfieFeed.swift)
//   uses, so "Find yourself" has a group of his faces and the scan has his outfit to extract;
// - strangers: every other fixture photo once;
// - filler: photos with nobody in them (gradients and shapes), for volume.
// Every photo gets its own capture date (EXIF DateTimeOriginal, newest first, a few hours apart over the
// last weeks), so the scan sees separate moments and not one burst of a thousand frames imported at once.
// Names with `_stallthumb` / `_stallfull` are the photos the DEBUG fault hook (-uiTestStallSomePhotos,
// StyleMate/Debug/ScanFaultInjection.swift) turns into stuck iCloud downloads.
//
// Deterministic: the same inputs give the same files (fixed seed), dates relative to now.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: \(args[0]) <fixtures/photos> <out-dir> [filler-count]\n".data(using: .utf8)!)
    exit(2)
}
let fixtures = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let fillerCount = args.count > 3 ? Int(args[3]) ?? 240 : 240
let userFixture = "kurta_dhoti_turban.jpg"   // a near-frontal face (casual_denim_jacket_hat is a strong profile)

try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: - Random (SplitMix64, fixed seed)

var rngState: UInt64 = 0x5EED_57E1_E3A7_E001
func nextRandom() -> UInt64 {
    rngState &+= 0x9E37_79B9_7F4A_7C15
    var z = rngState
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}
func rand01() -> CGFloat { CGFloat(nextRandom() >> 11) / CGFloat(1 << 53) }
func rand(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * rand01() }
func randInt(_ lo: Int, _ hi: Int) -> Int { lo + Int(nextRandom() % UInt64(hi - lo + 1)) }

// MARK: - Images

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot read \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}

/// `crop` (fractions of the image, top-left origin), scaled by `scale`, optionally mirrored and darkened.
func variant(_ img: CGImage, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), scale: CGFloat = 1,
             mirror: Bool = false, darken: CGFloat = 0) -> CGImage {
    let W = CGFloat(img.width), H = CGFloat(img.height)
    let r = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H).integral
    let cropped = img.cropping(to: r)!
    let w = Int((CGFloat(cropped.width) * scale).rounded()), h = Int((CGFloat(cropped.height) * scale).rounded())
    let ctx = context(w, h)
    ctx.interpolationQuality = .high
    if mirror { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1) }
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
    if darken > 0 {
        if mirror { ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -CGFloat(w), y: 0) }
        ctx.setFillColor(CGColor(gray: 0, alpha: darken))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    return ctx.makeImage()!
}

func color() -> CGColor {
    CGColor(colorSpace: rgb, components: [rand01(), rand01(), rand01(), 1])!
}

/// A photo with nobody in it: a sky-to-ground gradient, some blocks and discs, a few lines.
func filler(portrait: Bool) -> CGImage {
    let w = portrait ? 960 : 1280, h = portrait ? 1280 : 960
    let ctx = context(w, h)
    let gradient = CGGradient(colorsSpace: rgb, colors: [color(), color(), color()] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: rand(0, CGFloat(w)), y: 0), options: [])
    for _ in 0..<randInt(5, 14) {
        ctx.setFillColor(color().copy(alpha: rand(0.35, 0.95))!)
        let rect = CGRect(x: rand(-100, CGFloat(w)), y: rand(-100, CGFloat(h)), width: rand(60, 520), height: rand(60, 520))
        if nextRandom() % 2 == 0 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
    }
    ctx.setLineWidth(rand(2, 12))
    for _ in 0..<randInt(2, 8) {
        ctx.setStrokeColor(color())
        ctx.move(to: CGPoint(x: rand(0, CGFloat(w)), y: rand(0, CGFloat(h))))
        ctx.addLine(to: CGPoint(x: rand(0, CGFloat(w)), y: rand(0, CGFloat(h))))
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

// MARK: - Writing (JPEG + capture date)

let exifFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f
}()
let offsetFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "xxx"   // +00:00
    return f
}()

func write(_ img: CGImage, name: String, date: Date, quality: CGFloat) {
    let url = out.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    let stamp = exifFormat.string(from: date)
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
            kCGImagePropertyExifOffsetTimeOriginal: offsetFormat.string(from: date),
        ] as [CFString: Any],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: stamp] as [CFString: Any],
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("cannot encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    // The file dates too, in case an importer ignores EXIF.
    try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
}

// MARK: - The library

struct Entry {
    let name: String
    let quality: CGFloat
    let make: () -> CGImage
}

var entries: [Entry] = []

// The user: 8 views of one outfit moment's person. Two are stuck in iCloud (see ScanFaultInjection).
let user = load(fixtures.appendingPathComponent(userFixture))
let userViews: [(String, CGFloat, () -> CGImage)] = [
    ("user_01", 0.92, { variant(user) }),
    ("user_02", 0.90, { variant(user, crop: CGRect(x: 0.06, y: 0, width: 0.88, height: 0.9)) }),
    ("user_03_stallthumb", 0.90, { variant(user, mirror: true) }),
    ("user_04", 0.85, { variant(user, scale: 0.8) }),
    ("user_05", 0.70, { variant(user, crop: CGRect(x: 0.1, y: 0.04, width: 0.8, height: 0.92)) }),
    ("user_06_stallfull", 0.80, { variant(user, crop: CGRect(x: 0, y: 0, width: 0.92, height: 0.94), mirror: true) }),
    ("user_07", 0.88, { variant(user, darken: 0.12) }),
    ("user_08", 0.80, { variant(user, crop: CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.96), scale: 1.2) }),
]
for (name, q, make) in userViews { entries.append(Entry(name: "\(name).jpg", quality: q, make: make)) }

// Strangers: every other fixture photo.
let fixtureNames = (try FileManager.default.contentsOfDirectory(atPath: fixtures.path))
    .filter { $0.lowercased().hasSuffix(".jpg") && $0 != userFixture }
    .sorted()
for name in fixtureNames {
    let url = fixtures.appendingPathComponent(name)
    entries.append(Entry(name: "stranger_\(name)", quality: 0.9, make: { variant(load(url)) }))
}

// Nobody in them. A few are stuck in iCloud too.
let stuckFillers: Set<Int> = [12, 77, 150]
for i in 0..<fillerCount {
    let portrait = i % 3 == 0
    let name = String(format: "filler_%03d", i) + (stuckFillers.contains(i) ? "_stallthumb" : "")
    entries.append(Entry(name: "\(name).jpg", quality: rand(0.7, 0.92), make: { filler(portrait: portrait) }))
}

// Shuffle (fixed seed) so the user's photos are spread through the library, then date them newest first,
// 2.5 h apart, starting an hour ago: all inside the scan's 12 months and the first run's 90-day window.
for i in stride(from: entries.count - 1, to: 0, by: -1) {
    entries.swapAt(i, Int(nextRandom() % UInt64(i + 1)))
}
let now = Date()
var manifest: [String] = []
for (i, e) in entries.enumerated() {
    let date = now.addingTimeInterval(-3600 - Double(i) * 9000)
    write(e.make(), name: e.name, date: date, quality: e.quality)
    manifest.append("\(exifFormat.string(from: date))  \(e.name)")
}
try manifest.joined(separator: "\n").appending("\n")
    .write(to: out.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
print("Wrote \(entries.count) photos to \(out.path): \(userViews.count) of the user, \(fixtureNames.count) strangers, \(fillerCount) with nobody")
