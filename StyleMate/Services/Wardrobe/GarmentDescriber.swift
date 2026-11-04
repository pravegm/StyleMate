import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional polish on Apple Intelligence devices (iOS 27+): Apple's on-device
/// foundation model looks at a new item's cutout and writes the short
/// "details" line (e.g. "zip front, ribbed cuffs") and a brand when a logo or
/// wordmark is clearly readable. Strictly `SystemLanguageModel` — on-device,
/// never Private Cloud Compute. Everywhere else (older phones, Apple
/// Intelligence off, the simulator) it quietly returns nil and the item keeps
/// its classifier attributes.
enum GarmentDescriber {
    struct Description {
        let details: String
        let brand: String
    }

    static func describe(_ cutout: UIImage, product: String, colors: [String]) async -> Description? {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return await withTimeout(seconds: 8) { await describeWithModel(cutout, product: product, colors: colors) }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 27.0, *)
    @Generable
    struct GarmentNotes {
        @Guide(description: "2 to 5 short comma-separated visual details that make this exact item recognisable, e.g. 'zip front, ribbed cuffs, chest pocket'. No colours, no item name.")
        var details: String
        @Guide(description: "The brand name only if a logo or wordmark is clearly readable on the item, otherwise an empty string. Never guess from style.")
        var brand: String
    }

    @available(iOS 27.0, *)
    private static func describeWithModel(_ cutout: UIImage, product: String, colors: [String]) async -> Description? {
        let model = SystemLanguageModel.default
        guard model.isAvailable, let cg = FashionClassifier.onWhite(cutout.cgImage!, side: 512) else { return nil }
        let session = LanguageModelSession(model: model) {
            "You are a precise fashion cataloguer. You describe one clothing item or accessory from a product photo."
        }
        do {
            let colorText = colors.joined(separator: ", ")
            let response = try await session.respond(generating: GarmentNotes.self) {
                "This is a \(colorText) \(product.lowercased()). List its distinctive visual details and any clearly visible brand."
                Attachment(cg)
            }
            let notes = response.content
            let details = notes.details.trimmingCharacters(in: .whitespacesAndNewlines)
            let brand = notes.brand.trimmingCharacters(in: .whitespacesAndNewlines)
            return Description(details: String(details.prefix(80)), brand: brand.count <= 24 ? brand : "")
        } catch {
            print("[Wardrobe] on-device describer unavailable: \(error)")
            return nil
        }
    }
    #endif

    private static func withTimeout<T>(seconds: Double, _ work: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
