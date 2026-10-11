import Foundation

/// On-device romanization, like Spicy Lyrics' `ProcessLyrics.ts`: the song's script is decided
/// once, then every syllable / line is converted. Japanese goes through the system tokenizer
/// (kanji get their Japanese readings, as kuroshiro gives the extension); Chinese becomes
/// pinyin; Korean and Greek use the standard transliterations, Cyrillic an everyday one.
enum Romanizer {
    enum Script {
        case japanese, chinese, korean, cyrillic, greek
    }

    /// The script to romanize for a whole song, nil when it is already Latin.
    static func script(of document: LyricsDocument) -> Script? {
        var kana = 0, han = 0, hangul = 0, cyrillic = 0, greek = 0
        for line in document.lines {
            let text = line.lead.isEmpty ? line.text : line.lead.map(\.text).joined()
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: kana += 1
                case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
                case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
                case 0x0400...0x052F: cyrillic += 1
                case 0x0370...0x03FF, 0x1F00...0x1FFF: greek += 1
                default: break
                }
            }
        }
        // Any kana makes Han characters Japanese kanji rather than Chinese hanzi.
        if kana > 0 { return .japanese }
        if hangul > 0 { return .korean }
        if han > 0 { return .chinese }
        if cyrillic >= 2 { return .cyrillic }
        if greek > 0 { return .greek }
        return nil
    }

    static func romanize(_ text: String, script: Script) -> String {
        let result: String?
        switch script {
        case .japanese:
            result = japanese(text)
        case .chinese:
            result = text.applyingTransform(.mandarinToLatin, reverse: false)
        case .cyrillic:
            result = cyrillic(text)
        case .korean, .greek:
            result = text.applyingTransform(.toLatin, reverse: false)
        }
        guard let result, !result.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
        return result
    }

    /// Everyday transliteration ("Vremya shest utra"), not the system's scholarly ISO 9
    /// ("Vremâ šestʹ utra") that nobody can sing along to. Letters outside the table (Serbian,
    /// Kazakh…) still go through the system transform.
    private static func cyrillic(_ text: String) -> String? {
        var output = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let lower = Character(character.lowercased())
            guard let latin = cyrillicTable[lower] else {
                output.append(character)
                continue
            }
            guard character != lower, !latin.isEmpty else {
                output += latin
                continue
            }
            // Capital letter: "Zh" in a word, "ZH" in a word written in capitals.
            let neighbour = index + 1 < characters.count ? characters[index + 1]
                : (index > 0 ? characters[index - 1] : character)
            let shouting = neighbour.isLetter && neighbour.isUppercase
            output += shouting ? latin.uppercased() : latin.prefix(1).uppercased() + latin.dropFirst()
        }
        return output.applyingTransform(.toLatin, reverse: false) ?? output
    }

    private static let cyrillicTable: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh",
        "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        // Ukrainian and Belarusian.
        "є": "ye", "і": "i", "ї": "yi", "ґ": "g", "ў": "w",
    ]

    /// Japanese → romaji through CFStringTokenizer's Latin transcription, word by word.
    private static func japanese(_ text: String) -> String? {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRangeMake(0, string.length),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        )
        var pieces: [String] = []
        var cursor = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > cursor {
                // Whatever the tokenizer skipped (spaces, punctuation) stays as it is.
                pieces.append(string.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            let token = string.substring(with: NSRange(location: range.location, length: range.length))
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            pieces.append(latin ?? token)
            cursor = range.location + range.length
        }
        if cursor < string.length { pieces.append(string.substring(from: cursor)) }
        return pieces.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
