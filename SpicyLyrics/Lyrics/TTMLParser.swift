import Foundation

/// Parses Apple-style TTML lyrics (what Spicy Lyrics' "Local DB" accepts) into a `LyricsDocument`.
/// Follows the extension's `utils/Lyrics/ttml/parser.ts`: `itunes:timing` picks the type (inferred
/// from the markup when missing), agents `v2`/`v2000` are the opposite side of a duet,
/// `ttm:role="x-bg"` spans are background vocals (parentheses stripped), and a syllable joins
/// the next one when their tags touch with no whitespace between them.
enum TTMLParser {
    enum ParseError: LocalizedError {
        case notXML
        case notTTML
        case noLyrics

        var errorDescription: String? {
            switch self {
            case .notXML: return String(localized: "Файл не похож на TTML: это не XML.")
            case .notTTML: return String(localized: "В файле нет TTML (<tt>…</tt>).")
            case .noLyrics: return String(localized: "В TTML не нашлось строк с текстом.")
            }
        }
    }

    static func parse(_ text: String, sourceName: String) throws -> LyricsDocument {
        guard let root = XMLTree.parse(Data(text.utf8)) else { throw ParseError.notXML }
        guard let tt = root.name == "tt" ? root : root.first(named: "tt") else { throw ParseError.notTTML }

        let songwriters = tt.all(named: "songwriter").map { $0.text.trimmed }.filter { !$0.isEmpty }
        let oppositeAgents = Set(
            tt.all(named: "ttm:agent")
                .compactMap { $0.attributes["xml:id"] }
                .filter { $0 == "v2" || $0 == "v2000" }
        )

        guard let body = tt.first(named: "body") else { throw ParseError.noLyrics }
        let paragraphs = body.paragraphsWithAgents(inherited: body.attributes["ttm:agent"])

        let kind: LyricsKind
        switch tt.attributes["itunes:timing"] {
        case "Word": kind = .syllable
        case "Line": kind = .line
        case "None": kind = .static
        default: kind = inferKind(paragraphs.map(\.p))
        }

        var lines: [LyricLine] = []
        for (p, agent) in paragraphs {
            let opposite = agent.map(oppositeAgents.contains) ?? false
            let begin = p.attributes["begin"].flatMap(seconds)
            let end = p.attributes["end"].flatMap(seconds)

            switch kind {
            case .syllable:
                let lead = syllables(in: p.children, stripParentheses: false)
                let backgroundGroups = p.children.compactMap(\.element)
                    .filter { $0.name == "span" && $0.attributes["ttm:role"] == "x-bg" }
                    .map { syllables(in: $0.children, stripParentheses: true) }
                    .filter { !$0.isEmpty }
                let background = backgroundGroups.flatMap { $0 }
                if lead.isEmpty && background.isEmpty { continue }
                let all = lead + background
                let start = min(begin ?? .infinity, all.map(\.start).min() ?? .infinity)
                let finish = max(end ?? 0, all.map(\.end).max() ?? 0)
                lines.append(LyricLine(start: start.isFinite ? start : 0, end: finish, oppositeAligned: opposite,
                                       text: lead.map(\.text).joined(separator: " "), romanizedText: nil,
                                       lead: lead, background: background, backgroundGroups: backgroundGroups))
            case .line:
                let text = p.vocalText
                guard !text.isEmpty, let begin else { continue }
                lines.append(LyricLine(start: begin, end: max(end ?? begin, begin), oppositeAligned: opposite,
                                       text: text, romanizedText: nil, lead: [], background: []))
            case .static:
                let text = p.vocalText
                guard !text.isEmpty else { continue }
                lines.append(LyricLine(start: 0, end: 0, oppositeAligned: opposite,
                                       text: text, romanizedText: nil, lead: [], background: []))
            }
        }
        guard !lines.isEmpty else { throw ParseError.noLyrics }
        if kind != .static { lines.sort { $0.start < $1.start } }
        return LyricsDocument(kind: kind, lines: lines, songwriters: songwriters, sourceName: sourceName,
                              credits: LyricsCredits(providedBy: sourceName))
    }

    // MARK: Lines

    /// `inferLyricsType`: several timed spans in a line make it word-synced.
    private static func inferKind(_ paragraphs: [XMLTree]) -> LyricsKind {
        var sawTiming = false
        for p in paragraphs {
            let timedSpans = p.children.compactMap(\.element)
                .filter { isVocalSpan($0) && $0.attributes["begin"] != nil }
            if timedSpans.count > 1 { return .syllable }
            if timedSpans.count == 1 || p.attributes["begin"] != nil { sawTiming = true }
        }
        return sawTiming ? .line : .static
    }

    private static func isVocalSpan(_ node: XMLTree) -> Bool {
        guard node.name == "span" else { return false }
        switch node.attributes["ttm:role"] {
        case "x-bg", "x-translation", "x-roman": return false
        default: return true
        }
    }

    /// `buildSyllables`: one syllable per timed vocal span among `siblings`.
    private static func syllables(in siblings: [XMLTree.Child], stripParentheses: Bool) -> [LyricSyllable] {
        var result: [LyricSyllable] = []
        for (index, child) in siblings.enumerated() {
            guard let span = child.element, isVocalSpan(span) else { continue }
            let raw = span.text
            var text = raw.trimmed
            if stripParentheses { text = text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "").trimmed }
            guard !text.isEmpty,
                  let start = span.attributes["begin"].flatMap(seconds),
                  let end = span.attributes["end"].flatMap(seconds)
            else { continue }

            // Joined only when the next node is a vocal span right against this one.
            var joins = false
            if index + 1 < siblings.count, let next = siblings[index + 1].element, isVocalSpan(next) {
                let nextText = next.text
                joins = !(nextText.first?.isWhitespace ?? false)
                    && !(raw.last?.isWhitespace ?? false)
                    && !raw.trimmed.hasSuffix(",")
            }
            result.append(LyricSyllable(text: text, romanized: nil, start: start, end: max(end, start), joinsNext: joins))
        }
        return result
    }

    // MARK: Time

    /// `convertTimeToSeconds`: clock time `[hh:]mm:ss[.fff]` or offset time `12.5s` / `300ms` / `2m` / `1.5h`.
    static func seconds(_ raw: String) -> Double? {
        let value = raw.trimmed
        guard !value.isEmpty else { return nil }
        if value.contains(":") {
            var parts = value.split(separator: ":").map(String.init)
            guard (2...4).contains(parts.count) else { return nil }
            if parts.count == 4 { parts.removeLast() } // SMPTE frames need a frame rate: dropped
            var total = 0.0
            for part in parts {
                guard let number = Double(part) else { return nil }
                total = total * 60 + number
            }
            return total
        }
        let units: [(String, Double)] = [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1)]
        for (suffix, factor) in units where value.hasSuffix(suffix) {
            return Double(value.dropLast(suffix.count)).map { $0 * factor }
        }
        return Double(value)
    }
}

// MARK: - A tiny XML tree

/// Just enough DOM for TTML: element names and attributes keep their prefixes (`ttm:agent`),
/// and text nodes keep their whitespace, which decides where words break.
final class XMLTree {
    enum Child {
        case element(XMLTree)
        case text(String)

        var element: XMLTree? {
            if case .element(let node) = self { return node }
            return nil
        }
    }

    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [Child] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    /// All text inside, in document order.
    var text: String {
        children.map { child in
            switch child {
            case .text(let string): return string
            case .element(let node): return node.text
            }
        }.joined()
    }

    /// Text of a line without background vocals or translations, whitespace collapsed.
    var vocalText: String {
        let parts = children.map { child -> String in
            switch child {
            case .text(let string): return string
            case .element(let node):
                if node.name == "span", let role = node.attributes["ttm:role"],
                   ["x-bg", "x-translation", "x-roman"].contains(role) { return " " }
                return node.vocalText
            }
        }
        return parts.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func first(named name: String) -> XMLTree? {
        for child in children {
            guard let node = child.element else { continue }
            if node.name == name { return node }
            if let found = node.first(named: name) { return found }
        }
        return nil
    }

    func all(named name: String) -> [XMLTree] {
        children.compactMap(\.element).flatMap { node in
            (node.name == name ? [node] : []) + node.all(named: name)
        }
    }

    /// Every `<p>` below this node with the `ttm:agent` it inherits from its `<div>`s.
    func paragraphsWithAgents(inherited: String?) -> [(p: XMLTree, agent: String?)] {
        children.compactMap(\.element).flatMap { node -> [(p: XMLTree, agent: String?)] in
            let agent = node.attributes["ttm:agent"] ?? inherited
            if node.name == "p" { return [(node, agent)] }
            return node.paragraphsWithAgents(inherited: agent)
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        private var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLTree(name: qName ?? elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(.element(node))
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.children.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data: CDATABlock, encoding: .utf8) { stack.last?.children.append(.text(string)) }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
