import Foundation

/// The licence / attribution texts shown in Profile → About → Acknowledgements.
///
/// Every `ACK-<order>-<slug>.md` file in `StyleMate/Resources/Acknowledgements/` is listed, sorted by file
/// name; drop a file in to add a component, delete it when the component stops shipping (see
/// `ACKNOWLEDGEMENTS-HOWTO.txt` there). The `StyleMate` folder is a synchronized Xcode group, which copies
/// resources flat into the bundle, so the `ACK-` prefix is what finds them (a folder copy is accepted too).
///
/// File format: `# Title`, then optional `key: value` header lines (`licence`, `kind`, `source`), a blank
/// line, and a Markdown body.
struct Acknowledgement: Identifiable, Equatable {
    let id: String
    let title: String
    let licence: String?
    let kind: String?
    let source: URL?
    let body: String

    static let prefix = "ACK-"

    static func parse(id: String, text: String) -> Acknowledgement {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        var title = id
        if i < lines.count, lines[i].hasPrefix("# ") {
            title = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            i += 1
        }
        var meta: [String: String] = [:]
        while i < lines.count {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.isEmpty else { break }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter }) else { break }
            meta[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            i += 1
        }
        let body = lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Acknowledgement(id: id, title: title, licence: meta["licence"] ?? meta["license"],
                               kind: meta["kind"], source: meta["source"].flatMap(URL.init(string:)), body: body)
    }

    /// Every bundled acknowledgement, in file-name order.
    static func all(in bundle: Bundle = .main) -> [Acknowledgement] {
        var urls: [URL] = []
        for sub in [nil, "Acknowledgements"] as [String?] {
            urls += (bundle.urls(forResourcesWithExtension: "md", subdirectory: sub) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        var seen = Set<String>()
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { seen.insert($0.lastPathComponent).inserted }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parse(id: url.deletingPathExtension().lastPathComponent, text: text)
            }
    }
}

/// A small Markdown block parser for licence texts: headings, bullets, rules and paragraphs (hard-wrapped
/// lines are joined). Inline Markdown (bold, links) is left to `AttributedString`.
enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullet: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if let b = bullet { blocks.append(.bullet(b.joined(separator: " "))); bullet = nil }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(level)
                if rest.hasPrefix(" ") {
                    flush()
                    blocks.append(.heading(level: level, text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                bullet = [String(line.dropFirst(2))]
                continue
            }
            if bullet != nil { bullet?.append(line) } else { paragraph.append(line) }
        }
        flush()
        return blocks
    }
}
