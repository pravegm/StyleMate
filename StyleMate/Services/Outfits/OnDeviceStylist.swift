import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional polish from Apple's on-device foundation model (Apple Intelligence).
///
/// Two jobs, both strictly best-effort:
///   1. Read the free-text request into structured `StyleHints` (refines the
///      keyword parser — e.g. "not too dressy, meeting his parents").
///   2. Rewrite each look's deterministic note in a warm stylist voice.
///
/// Only `SystemLanguageModel` is used — it runs entirely on the device; nothing
/// is ever sent to a server. Every call is raced against a timeout and any
/// failure (model unavailable, guardrail, timeout, odd output) returns nil so
/// callers silently keep the deterministic result. Nothing here blocks the UI.
enum OnDeviceStylist {

    /// True when the on-device model can be used right now (supported device,
    /// Apple Intelligence on, model downloaded).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Structured reading of the request, or nil (fall back to the keyword parser).
    static func interpret(_ text: String, timeout: Double = 2.5) async -> StyleHints? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await withTimeout(timeout) { await ModelBridge.interpret(trimmed) }
        }
        #endif
        return nil
    }

    /// A warmer rewrite of `note.draft`, or nil (keep the deterministic text).
    static func polish(_ note: StylistNote, timeout: Double = 4) async -> String? {
        guard isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await withTimeout(timeout) { await ModelBridge.polish(note) }
        }
        #endif
        return nil
    }

    // MARK: - Timeout

    /// Resumes exactly once, from whichever finishes first: the work or the clock.
    /// (A task group would wait for a model call that ignores cancellation.)
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    static func withTimeout<T>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = ResumeOnce<T>(continuation)
            let work = Task {
                let value = await operation()
                gate.resume(value)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                work.cancel()
                gate.resume(nil)
            }
        }
    }

    // MARK: - Output hygiene

    /// Accept a rewrite only if it reads like a short stylist note.
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        text = text.replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        guard text.count >= 12, text.count <= 240 else { return nil }
        let lowered = text.lowercased()
        let tells = ["as an ai", "i'm sorry", "i cannot", "i can't", "language model", "here's", "here is",
                     "rewrite", "#", "*", "http"]
        guard !tells.contains(where: { lowered.contains($0) }) else { return nil }
        return text
    }
}

/// What the model needs to rewrite one look's note — facts only, so it can't
/// invent pieces.
struct StylistNote {
    let draft: String
    let pieces: [String]        // "camel coat", "navy knit", …
    let occasion: String?
    let mood: String?

    init(outfit: Outfit, context: StylingContext) {
        draft = outfit.explanation
        pieces = outfit.items.map { StyleVocabulary.describe($0) }
        occasion = context.occasionWasStated ? context.resolvedOccasion.rawValue : nil
        mood = context.moods.first?.label
    }
}

#if canImport(FoundationModels)

/// Structured reading of a styling request, generated on-device.
@available(iOS 26.0, *)
@Generable
struct GeneratedStyleIntent {
    @Guide(description: "The occasion. Exactly one of: everyday, formal, date, sports, party, business, loungewear, vacation, ethnic, streetwear, none.")
    var occasion: String

    @Guide(description: "Up to two moods from: confident, cozy, relaxed, playful, polished, bold, minimal, romantic. Empty if none are implied.")
    var moods: [String]

    @Guide(description: "Simple colour names the person wants to wear, like blue or black. Empty if none.")
    var wantedColors: [String]

    @Guide(description: "Simple colour names the person wants to avoid. Empty if none.")
    var avoidedColors: [String]

    @Guide(description: "Garment types the person asked for, like dress, jeans, sneakers, blazer. Empty if none.")
    var wantedGarments: [String]

    @Guide(description: "Garment types the person wants to avoid. Empty if none.")
    var avoidedGarments: [String]

    @Guide(description: "How dressy the plans are: -2 very casual, -1 casual, 0 not stated, 1 smart, 2 very dressy.")
    var dressiness: Int

    @Guide(description: "True if the plans are in the evening or at night.")
    var isEvening: Bool

    @Guide(description: "True if the person mentions rain or wet weather.")
    var expectsRain: Bool
}

@available(iOS 26.0, *)
private enum ModelBridge {

    static func interpret(_ text: String) async -> StyleHints? {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            You read short requests people type into a wardrobe app ("what should I wear…") and \
            extract structured styling hints. Only use words from the allowed lists. If something \
            isn't mentioned, leave it empty, use none, or use 0.
            """
        )
        do {
            let response = try await session.respond(to: "Request: \(text)", generating: GeneratedStyleIntent.self)
            return hints(from: response.content)
        } catch {
            print("[OnDeviceStylist] interpret failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func polish(_ note: StylistNote) async -> String? {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            You are a warm, sharp personal stylist talking to a friend. Rewrite the stylist note \
            you are given in one or two short sentences (under 30 words total), speaking to "you". \
            Keep every fact: the temperature, the weather, and the exact pieces and colours. Never \
            mention a piece that isn't listed. No emojis, no hashtags, no quotation marks, no lists. \
            Avoid clichés like "effortlessly chic", "elevate your look" or "make a statement".
            """
        )
        var prompt = "Pieces: \(note.pieces.joined(separator: ", ")).\n"
        if let occasion = note.occasion { prompt += "Occasion: \(occasion).\n" }
        if let mood = note.mood { prompt += "Mood: \(mood).\n" }
        prompt += "Note to rewrite: \(note.draft)"
        do {
            let response = try await session.respond(to: prompt)
            return OnDeviceStylist.sanitize(response.content)
        } catch {
            print("[OnDeviceStylist] polish failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func hints(from g: GeneratedStyleIntent) -> StyleHints {
        var h = StyleHints()
        let occasions: [String: OutfitType] = [
            "everyday": .everyday, "formal": .formal, "date": .date, "sports": .sports, "party": .party,
            "business": .business, "loungewear": .loungewear, "vacation": .vacation, "ethnic": .ethnic,
            "streetwear": .streetwear
        ]
        h.occasion = occasions[g.occasion.lowercased().trimmingCharacters(in: .whitespaces)]
        h.moods = Array(g.moods.compactMap { OutfitMood(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) }.prefix(2))
        h.preferredColors = g.wantedColors.compactMap { StylePalette.swatch(for: $0)?.name }
        h.avoidedColors = g.avoidedColors.compactMap { StylePalette.swatch(for: $0)?.name }
        h.preferredProducts = g.wantedGarments.flatMap { StyleIntentParser.products(for: $0) }
        h.avoidedProducts = g.avoidedGarments.flatMap { StyleIntentParser.products(for: $0) }
        h.formalityBias = Double(max(-2, min(2, g.dressiness))) * 0.35
        h.isEvening = g.isEvening
        h.expectsRain = g.expectsRain
        h.wantsEthnic = h.occasion == .ethnic
        h.wantsActive = h.occasion == .sports
        return h
    }
}

#endif
