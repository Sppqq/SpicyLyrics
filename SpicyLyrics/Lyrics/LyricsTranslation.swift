import NaturalLanguage
import SwiftUI
import Translation

/// Translates the current lyrics on the device with Apple's Translation framework (iOS 18+) and
/// hands the result to the player; the lyrics show it under each line. The first use of a
/// language pair makes iOS offer to download its model.
struct LyricsTranslation: ViewModifier {
    let player: PlayerModel
    let settings: AppSettings

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(TranslationDriver(player: player, settings: settings))
        } else {
            content
        }
    }

    /// Languages offered in settings (Apple Translation supports these on device).
    static let languages: [(id: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("uk", "Українська"), ("de", "Deutsch"),
        ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"),
        ("pl", "Polski"), ("tr", "Türkçe"), ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "简体中文"),
    ]
}

@available(iOS 18.0, *)
@MainActor
private struct TranslationDriver: ViewModifier {
    let player: PlayerModel
    let settings: AppSettings
    @State private var configuration: TranslationSession.Configuration?

    /// Changes whenever there is something new to translate.
    private var key: String {
        "\(settings.translateLyrics)|\(settings.translationReplaces)|\(settings.translationLanguage)|\(player.documentRevision)"
    }

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                await translate(with: session)
            }
            .onChange(of: key, initial: true) { _, _ in reconfigure() }
    }

    private var targetCode: String {
        Locale.Language(identifier: settings.translationLanguage).languageCode?.identifier ?? settings.translationLanguage
    }

    /// Unique texts of the lead lines that are not already in the target language.
    private func pendingTexts() -> [String] {
        guard settings.translateLyrics, case .loaded(let lyrics) = player.lyricsState else { return [] }
        let texts = Set(lyrics.lines
            // Backing vocals are lines of their own and get translated too.
            .filter { !$0.isInterlude }
            .map(\.sourceText)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let code = targetCode
        return texts.filter { !Self.isWritten(in: code, $0) }
    }

    /// A line counts as already translated when the recognizer is fairly sure of the target language.
    private static func isWritten(in code: String, _ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let likely = recognizer.languageHypotheses(withMaximum: 3)
            .first { $0.key.rawValue.hasPrefix(code) }?.value ?? 0
        return likely > 0.5
    }

    /// Letters only, so "Hello!" and "hello" compare equal.
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.letters.contains).map(Character.init))
    }

    private func sourceLanguage(of texts: [String]) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        return recognizer.dominantLanguage
    }

    private func reconfigure() {
        let texts = pendingTexts()
        let target = Locale.Language(identifier: settings.translationLanguage)
        let source = sourceLanguage(of: texts)
        // A song already in the target language needs no translation; drop any left from before.
        if texts.isEmpty || source.map({ $0.rawValue.hasPrefix(targetCode) }) == true {
            if !player.translations.isEmpty { player.setTranslations([:], revision: player.documentRevision) }
            return
        }
        let sourceLanguage = source.map { Locale.Language(identifier: $0.rawValue) }
        if configuration?.source == sourceLanguage, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: sourceLanguage, target: target)
        }
    }

    private func translate(with session: TranslationSession) async {
        let texts = pendingTexts()
        guard !texts.isEmpty else { return }
        let revision = player.documentRevision
        let requests = texts.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
        do {
            var result: [String: String] = [:]
            for response in try await session.translations(from: requests) {
                // A "translation" that only repeats the line adds nothing under it.
                if let id = response.clientIdentifier, Self.normalized(response.targetText) != Self.normalized(id) {
                    result[id] = response.targetText
                }
            }
            player.setTranslations(result, revision: revision)
        } catch {
            // An unsupported language pair or a declined download: show the lyrics untranslated.
            SyncLog.shared.add("translate", "failed: \(error.localizedDescription)")
        }
    }
}
