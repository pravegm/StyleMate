import Foundation
import Testing
import UIKit
@testable import StyleMate

/// Sanity checks for the on-device identity pipeline (SCRFD-10G detection +
/// 5-point alignment + AdaFace IR-101 embedding) with the real bundled models:
/// the same face survives a re-crop/rescale, and different people stay apart.
@Suite(.serialized)
struct FaceMatchingTests {
    private static let userId = "facetest@stylemate.test"

    private func fixture(_ name: String) throws -> UIImage {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FIXTURES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("photos") }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/photos")
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return try #require(UIImage(data: data))
    }

    /// Re-frames a photo the way a different shot of the same moment would:
    /// tighter crop, smaller, slightly darker.
    private func variant(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard let crop = cg.cropping(to: CGRect(x: w * 0.08, y: 0, width: w * 0.84, height: h * 0.7)) else { return nil }
        let size = CGSize(width: CGFloat(crop.width) * 0.75, height: CGFloat(crop.height) * 0.75)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            UIColor.black.withAlphaComponent(0.12).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage
    }

    private func useAsSelfie(_ image: UIImage) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facetest_selfie.jpg")
        try #require(image.jpegData(compressionQuality: 0.95)).write(to: url)
        UserDefaults.standard.set(url.path, forKey: "selfieReferencePath_\(Self.userId)")
        FaceMatchingService.shared.clearReference(forUser: Self.userId)
        #expect(FaceMatchingService.shared.loadReference(forUser: Self.userId), "could not build a reference from the selfie")
    }

    @Test func sameFaceMatchesAcrossReframing() throws {
        let photo = try fixture("street_coat_cap.jpg")
        try useAsSelfie(photo)
        let cg = try #require(variant(photo))
        let match = FaceMatchingService.shared.findUserInPhoto(cg)
        print("[Report] face self-match after reframe: sim=\(match.similarity ?? -1) faces=\(match.faceCount)")
        #expect(match.faceCount >= 1, "SCRFD found no face")
        #expect((match.similarity ?? 0) >= FaceMatchingService.highConfidenceThreshold,
                "same face scored \(match.similarity ?? -1)")
    }

    @Test func differentPeopleStayApart() throws {
        try useAsSelfie(try fixture("street_coat_cap.jpg"))
        for other in ["street_coat_boots.jpg", "street_coat_backpack.jpg", "street_coat_scarf.jpg"] {
            let cg = try #require(try fixture(other).cgImage)
            let match = FaceMatchingService.shared.findUserInPhoto(cg)
            print("[Report] face impostor \(other): sim=\(match.similarity ?? -1) faces=\(match.faceCount)")
            if let s = match.similarity {
                #expect(s < FaceMatchingService.highConfidenceThreshold, "\(other) would be auto-added as the user (sim \(s))")
            }
        }
    }

    @Test func scanQueuesBorderlineInsteadOfDropping() throws {
        // A gallery of only the selfie: a confident re-framed match is analyzed,
        // a stranger is skipped (never queued as "is this you?" spam).
        let photo = try fixture("street_coat_cap.jpg")
        try useAsSelfie(photo)
        let same = try #require(variant(photo))
        if case .skip = FaceMatchingService.shared.resolveIdentityForScan(in: same, fullImage: UIImage(cgImage: same), userId: Self.userId) {
            Issue.record("the user's own re-framed photo was skipped")
        }
        let stranger = try #require(try fixture("street_coat_boots.jpg").cgImage)
        if case .analyze = FaceMatchingService.shared.resolveIdentityForScan(in: stranger, fullImage: UIImage(cgImage: stranger), userId: Self.userId) {
            Issue.record("a stranger was auto-added")
        }
    }
}
