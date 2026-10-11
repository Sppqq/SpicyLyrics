import SwiftUI

/// Settings laid out like iOS Settings: a short list of clearly named categories, each opening
/// its own page.
struct SettingsView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(PerformanceMonitor.self) private var performance
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Вид текста")) {
                    category(String(localized: "Текст"), "textformat.size", .purple,
                             value: "\(Int(settings.fontSize)) pt") { TextLookSettings() }
                    category(String(localized: "Эффекты"), "sparkles", .pink,
                             value: settings.simpleLyricsMode ? "Simple" : nil) { EffectsSettings() }
                    category(String(localized: "Фон"), "photo.fill", .indigo,
                             value: settings.dynamicBackground ? nil : String(localized: "Выкл.")) { BackgroundSettings() }
                    category(String(localized: "Перевод и романизация"), "character.bubble.fill", .blue,
                             value: translationSummary) { LanguageSettings() }
                }

                Section(String(localized: "Экран плеера")) {
                    category(String(localized: "Интерфейс"), "rectangle.bottomhalf.inset.filled", .orange) { InterfaceSettings() }
                    category(String(localized: "Горизонтальный режим"), "rectangle.landscape.rotate", .teal,
                             value: settings.landscapeLyricsOnly ? String(localized: "Только текст") : nil) { LandscapeSettings() }
                    category(String(localized: "Жесты"), "hand.draw.fill", .red,
                             value: settings.gesturesEnabled ? String(localized: "Вкл.") : String(localized: "Выкл.")) { GestureSettings() }
                    category(String(localized: "Экран блокировки"), "lock.iphone", .purple,
                             value: settings.liveActivity ? String(localized: "Вкл.") : nil) { LiveActivitySettings() }
                    category(String(localized: "Картинка в картинке"), "pip.fill", .green,
                             value: settings.autoPictureInPicture ? String(localized: "Авто") : nil) { PictureInPictureSettings() }
                }

                Section(String(localized: "Работа")) {
                    category(String(localized: "Синхронизация"), "timer", .cyan,
                             value: settings.timingOffsetMs == 0 ? nil : String(localized: "\(Int(settings.timingOffsetMs)) мс")) { SyncSettings() }
                    category(String(localized: "Батарея и нагрев"), "bolt.fill", .yellow,
                             value: settings.powerSaving ? String(localized: "Экономия") : (performance.constrained ? String(localized: "Авто-экономия") : nil)) {
                        PerformanceSettings()
                    }
                    category(String(localized: "Журнал"), "list.bullet.rectangle.fill", .gray,
                             value: settings.syncLogEnabled ? nil : String(localized: "Выкл.")) { SyncLogView() }
                    category(String(localized: "Источники текстов"), "doc.text.fill", .brown) { SourceSettings() }
                    category("Spotify", "music.note", Color(red: 0.12, green: 0.84, blue: 0.38),
                             value: settings.hasValidClientID ? "…" + String(settings.spotifyClientID.suffix(4)) : String(localized: "Не настроен")) { SpotifySettings() }
                }

                Section {
                    category(String(localized: "О приложении"), "info.circle.fill", .gray, value: AppVersion.display) { AboutSettings() }
                }
            }
            .navigationTitle(String(localized: "Настройки"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Готово")) { dismiss() }
                }
            }
        }
    }

    private var translationSummary: String? {
        switch (settings.translateLyrics, settings.showRomanization) {
        case (true, true): return String(localized: "Оба")
        case (true, false): return String(localized: "Перевод")
        case (false, true): return String(localized: "Романизация")
        case (false, false): return nil
        }
    }

    private func category<Destination: View>(_ title: String, _ icon: String, _ color: Color, value: String? = nil,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Building blocks

/// A slider with its title and current value on one line above it.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    /// How the value is shown; percent of 1 by default.
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// A "back to defaults" button at the bottom of a page.
private struct ResetSection: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Section {
            Button(title, role: .destructive) {
                withAnimation { action() }
            }
        }
    }
}

// MARK: - Pages

private struct TextLookSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(String(localized: "Шрифт"), selection: $settings.lyricsFont) {
                    ForEach(LyricsFont.allCases) { font in
                        Text(font.title).tag(font.rawValue)
                    }
                }
                Picker(String(localized: "Насыщенность шрифта"), selection: $settings.lyricsWeight) {
                    ForEach(LyricsWeight.allCases) { weight in
                        Text(weight.title).tag(weight.rawValue)
                    }
                }
                SliderRow(title: String(localized: "Размер"), value: $settings.fontSize,
                          range: Double(AppSettings.fontRange.lowerBound)...Double(AppSettings.fontRange.upperBound),
                          step: 1, format: { "\(Int($0)) pt" })
                Toggle(String(localized: "По центру"), isOn: $settings.centerLyrics)
            } footer: {
                Text(String(localized: "Размер можно менять и щипком двумя пальцами прямо по тексту. После этого на пару секунд появится кнопка «Сбросить размер»."))
            }

            Section(String(localized: "Расстояния")) {
                SliderRow(title: String(localized: "Между строками"), value: $settings.lineSpacingScale, range: 0...4, step: 0.25)
            }

            Section {
                SliderRow(title: String(localized: "Положение активной строки"), value: $settings.activeLinePosition,
                          range: 0.2...0.8, step: 0.05, format: Self.positionLabel)
                SliderRow(title: String(localized: "Скорость прокрутки"), value: $settings.scrollSpeed, range: 0.5...3, step: 0.25)
            } header: {
                Text(String(localized: "Прокрутка"))
            } footer: {
                Text(String(localized: "Где держится строка, которую поют, и как быстро текст доезжает до следующей."))
            }

            ResetSection(title: String(localized: "Вернуть как было")) { settings.resetLyricsLook() }
        }
    }

    private static func positionLabel(_ value: Double) -> String {
        if abs(value - 0.5) < 0.01 { return String(localized: "По центру") }
        return value < 0.5 ? String(localized: "Выше на \(Int(((0.5 - value) * 100).rounded()))%")
                           : String(localized: "Ниже на \(Int(((value - 0.5) * 100).rounded()))%")
    }
}

private struct EffectsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Simple Lyrics Mode", isOn: $settings.simpleLyricsMode)
            } footer: {
                Text(String(localized: "Спокойная анимация из оригинального расширения: слова не подпрыгивают и не светятся, заливка мягче."))
            }

            Section {
                Toggle(String(localized: "Размывать неактивные строки"), isOn: $settings.blurInactiveLines)
                if settings.blurInactiveLines {
                    SliderRow(title: String(localized: "Сила размытия"), value: $settings.blurStrength, range: 0.25...2.5)
                }
            } header: {
                Text(String(localized: "Размытие"))
            } footer: {
                Text(String(localized: "Строки размываются тем сильнее, чем дальше они от текущей."))
            }

            Section {
                SliderRow(title: String(localized: "Свечение слов"), value: $settings.glowStrength, range: 0...2)
                    .disabled(settings.simpleLyricsMode)
                SliderRow(title: String(localized: "Яркость остальных строк"), value: $settings.inactiveBrightness, range: 0.5...1.5)
            } header: {
                Text(String(localized: "Свет"))
            } footer: {
                Text(settings.simpleLyricsMode
                     ? String(localized: "В Simple Lyrics Mode слова не светятся.")
                     : String(localized: "Свечение — мягкий ореол вокруг спетых слов."))
            }

            ResetSection(title: String(localized: "Вернуть эффекты по умолчанию")) { settings.resetEffects() }
        }
    }
}

private struct BackgroundSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PerformanceMonitor.self) private var performance

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Обложка на фоне"), isOn: $settings.dynamicBackground)
            } footer: {
                if settings.powerSaving || performance.constrained {
                    Text(String(localized: "Сейчас включена экономия батареи, поэтому фон не двигается."))
                } else {
                    Text(String(localized: "Размытая обложка трека, которая медленно плавает за текстом."))
                }
            }

            if settings.dynamicBackground {
                Section(String(localized: "Обложка")) {
                    SliderRow(title: String(localized: "Скорость движения"), value: $settings.backgroundSpeed, range: 0.25...3)
                    SliderRow(title: String(localized: "Размытие"), value: $settings.backgroundBlur, range: 0.3...3)
                    SliderRow(title: String(localized: "Насыщенность цвета"), value: $settings.backgroundSaturation, range: 0...2)
                }
            }

            Section {
                SliderRow(title: String(localized: "Затемнение"), value: $settings.backgroundDim, range: 0...0.7, step: 0.02)
            } footer: {
                Text(String(localized: "Чем темнее фон, тем лучше читается белый текст на светлых обложках."))
            }

            ResetSection(title: String(localized: "Вернуть фон по умолчанию")) { settings.resetBackground() }
        }
    }
}

private struct LanguageSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player

    private var providerNote: String {
        switch settings.provider {
        case .apple:
            return String(localized: "Apple переводит прямо на телефоне (iOS 18 и новее), без интернета. Строки, которые уже на выбранном языке, не переводятся. При первом использовании iOS предложит скачать языковую модель.")
        case .google, .yandex:
            return String(localized: "Строки текста отправляются в онлайн-переводчик. Нужен интернет; переводы запоминаются до перезапуска приложения. Строки, которые уже на выбранном языке, не переводятся.")
        case .deepl:
            return String(localized: "DeepL переводит лучше всех, но нужен свой ключ API: бесплатного тарифа (500 000 символов в месяц) хватает с запасом. Ключ хранится в связке ключей iOS.")
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Романизация"), isOn: $settings.showRomanization)
            } footer: {
                Text(String(localized: "Латиница вместо японского, китайского, корейского, кириллицы и греческого. Делается прямо на телефоне."))
            }

            Section {
                Toggle(String(localized: "Переводить текст"), isOn: $settings.translateLyrics)
                if settings.translateLyrics {
                    Picker(String(localized: "Переводчик"), selection: $settings.translationProvider) {
                        ForEach(TranslationProvider.allCases.filter(\.isAvailable)) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    if settings.provider == .deepl {
                        SecureField(String(localized: "Ключ DeepL API"), text: $settings.deeplKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Link(String(localized: "Получить бесплатный ключ DeepL"),
                             destination: URL(string: "https://www.deepl.com/your-account/keys")!)
                    }
                    Picker(String(localized: "Язык перевода"), selection: $settings.translationLanguage) {
                        ForEach(LyricsTranslation.languages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    Picker(String(localized: "Показывать"), selection: $settings.translationReplaces) {
                        Text(String(localized: "Под строкой")).tag(false)
                        Text(String(localized: "Вместо строки")).tag(true)
                    }
                    if !settings.translationReplaces {
                        SliderRow(title: String(localized: "Размер перевода"), value: $settings.translationScale, range: 0.6...1.6)
                        SliderRow(title: String(localized: "Яркость перевода"), value: $settings.translationBrightness, range: 0.5...1.6)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = player.translationError, settings.translateLyrics {
                        Text(String(localized: "Последняя ошибка: \(error)"))
                            .foregroundStyle(.orange)
                    }
                    if settings.translateLyrics && settings.translationReplaces {
                        Text(String(localized: "Перевод заменяет оригинал, а слова подсвечиваются по ритму исходной строки: время каждой строки делится между новыми словами по их длине."))
                    }
                    Text(providerNote)
                }
            }
        }
    }
}

private struct InterfaceSettings: View {
    @Environment(AppSettings.self) private var settings
    /// The language the app runs in now, to tell when a restart is needed.
    @State private var launchLanguage = Bundle.main.preferredLocalizations.first ?? "en"

    private var pendingRestart: Bool {
        switch settings.appLanguage {
        case "en", "ru": return settings.appLanguage != launchLanguage
        default:
            let system = Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                       forPreferences: Locale.preferredLanguages).first ?? "en"
            return system != launchLanguage
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(String(localized: "Язык"), selection: $settings.appLanguage) {
                    Text(String(localized: "Как на телефоне")).tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
            } header: {
                Text(String(localized: "Язык приложения"))
            } footer: {
                if pendingRestart {
                    Text(String(localized: "Язык сменится после перезапуска приложения: закройте его в переключателе приложений и откройте снова."))
                }
            }

            Section {
                Toggle(String(localized: "Прятать кнопки во время песни"), isOn: $settings.autoHideControls)
                if settings.autoHideControls {
                    SliderRow(title: String(localized: "Через"), value: $settings.autoHideDelay, range: 2...12, step: 1,
                              format: { String(localized: "\(Int($0)) с") })
                }
            } footer: {
                Text(String(localized: "Как в Apple Music: кнопки исчезают, пока играет песня. Касание внизу экрана возвращает их."))
            }

            Section {
                Toggle(String(localized: "Строка текста под обложкой"), isOn: $settings.artworkLyricLine)
            } header: {
                Text(String(localized: "Большая обложка"))
            } footer: {
                Text(String(localized: "Кнопка с цитатой внизу слева переключает текст и большую обложку. Под обложкой — строка, которую поют, с теми же анимациями, что и в тексте."))
            }

            Section {
                Toggle(String(localized: "Полоска громкости"), isOn: $settings.showVolumeSlider)
                Toggle(String(localized: "Не гасить экран"), isOn: $settings.keepScreenOn)
            }
        }
    }
}

private struct LandscapeSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Только текст"), isOn: $settings.landscapeLyricsOnly)
            } footer: {
                Text(String(localized: "Прячет весь интерфейс: текст занимает весь экран, а кнопки появляются по касанию на несколько секунд."))
            }

            Section {
                Toggle(String(localized: "Обложка"), isOn: $settings.landscapeArtwork)
                Toggle(String(localized: "Название и исполнитель"), isOn: $settings.landscapeTitle)
            } header: {
                Text(String(localized: "Слева от текста"))
            } footer: {
                Text(String(localized: "Если выключить и то и другое, текст сдвинется к центру, когда кнопки спрячутся."))
            }
            .disabled(settings.landscapeLyricsOnly)
        }
    }
}

private struct PictureInPictureSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Открывать при сворачивании"), isOn: $settings.autoPictureInPicture)
            } footer: {
                Text(String(localized: "Текст поверх других приложений. Вручную окно открывается из меню «•••» в плеере."))
            }

            Section {
                Picker(String(localized: "Форма окна"), selection: $settings.pipFormat) {
                    ForEach(PiPFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                Toggle(String(localized: "Анимированный фон"), isOn: $settings.pipAnimatedBackground)
                Toggle(String(localized: "Название песни"), isOn: $settings.pipShowTitle)
            } header: {
                Text(String(localized: "Окно"))
            } footer: {
                Text(String(localized: "Широкое окно показывает одну-две строки, вертикальное — больше строк, как в плеере. Анимированный фон — плавающая обложка, как в приложении. На слабых устройствах выключите его; в режиме экономии он и так неподвижен."))
            }

            Section {
                SliderRow(title: String(localized: "Размер текста"), value: $settings.pipTextScale, range: 0.7...1.4)
                SliderRow(title: String(localized: "Затемнение фона"), value: $settings.pipBackgroundDim, range: 0.1...0.8)
                Picker(String(localized: "Частота кадров"), selection: $settings.pipFrameRate) {
                    Text("15").tag(15.0)
                    Text("24").tag(24.0)
                    Text("30").tag(30.0)
                    Text("60").tag(60.0)
                }
                Toggle(String(localized: "Размытие соседних строк"), isOn: $settings.pipBlurLines)
                Toggle(String(localized: "Перевод в окне"), isOn: $settings.pipShowTranslation)
                Toggle(String(localized: "Показывать FPS"), isOn: $settings.pipShowFPS)
            } header: {
                Text(String(localized: "Текст в окне"))
            } footer: {
                Text(String(localized: "Меньше кадров — меньше нагрузка и нагрев. Размытие строк работает, только если оно включено и в «Эффектах»."))
            }

            ResetSection(title: String(localized: "Сбросить вид окна")) {
                settings.pipFormat = PiPFormat.wide.rawValue
                settings.pipTextScale = 1
                settings.pipBackgroundDim = 0.42
                settings.pipFrameRate = 30
                settings.pipBlurLines = true
                settings.pipShowTranslation = true
                settings.pipShowFPS = false
            }
        }
    }
}

private struct LiveActivitySettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LiveLyricsActivity.self) private var liveActivity

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Текст на экране блокировки"), isOn: $settings.liveActivity)
                if let error = liveActivity.lastError, settings.liveActivity, !liveActivity.isRunning {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(String(localized: "Текущая строка на экране блокировки и в Dynamic Island (Live Activity). Пока она включена, приложение работает в фоне и следит за Spotify (играет беззвучный звук, который не мешает музыке), поэтому батарея тратится чуть быстрее. Если смахнуть её с экрана блокировки, она вернётся при следующем открытии приложения."))
            }

            Section {
                Toggle(String(localized: "Следующая строка"), isOn: $settings.liveActivityNextLine)
                Toggle(String(localized: "Перевод"), isOn: $settings.liveActivityTranslation)
                    .disabled(!settings.translateLyrics || settings.translationReplaces)
            } header: {
                Text(String(localized: "Что показывать"))
            }
            .disabled(!settings.liveActivity)
        }
    }
}

private struct GestureSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Жесты"), isOn: $settings.gesturesEnabled)
            } footer: {
                Text(String(localized: "Свайпы и щипок работают на iOS 18 и новее."))
            }

            Section {
                row("hand.draw", String(localized: "Свайп влево / вправо по тексту"), String(localized: "следующий / предыдущий трек"))
                row("arrow.up.left.and.arrow.down.right", String(localized: "Щипок двумя пальцами"), String(localized: "размер текста"))
                row("hand.tap", String(localized: "Долгое нажатие на строку"), String(localized: "перемотать, скопировать, поделиться"))
                row("hand.point.up.left", String(localized: "Касание строки"), String(localized: "перемотать к ней"))
                row("chevron.up", String(localized: "Свайп вверх внизу экрана"), String(localized: "показать кнопки"))
                row("chevron.down", String(localized: "Свайп вниз по заголовку"), String(localized: "спрятать кнопки"))
            } header: {
                Text(String(localized: "Что умеют"))
            } footer: {
                Text(String(localized: "На iPad с клавиатурой: пробел — пауза, ⌘← / ⌘→ — треки."))
            }
        }
    }

    private func row(_ icon: String, _ gesture: String, _ effect: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture)
                Text(effect).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

private struct SyncSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(SpotifyAppRemote.self) private var appRemote
    @EnvironmentObject private var auth: SpotifyAuth

    @State private var bundleCopied = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Точное время из приложения Spotify"), isOn: $settings.useAppRemote)
                if settings.useAppRemote {
                    LabeledContent(String(localized: "Состояние"), value: appRemote.statusText)
                    Toggle(String(localized: "Будить Spotify самому"), isOn: $settings.autoWakeSpotify)
                    if let error = appRemote.lastError, appRemote.status != .connected {
                        Text(error)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if appRemote.status == .needsLogin {
                        Button(String(localized: "Войти заново")) {
                            Task {
                                try? await auth.logIn()
                                appRemote.refresh()
                            }
                        }
                    } else if appRemote.status == .unavailable || appRemote.status == .connecting {
                        Button(String(localized: "Открыть Spotify и подключиться")) { appRemote.wakeSpotify() }
                    }
                }
            } footer: {
                Text(String(localized: "Когда Spotify играет на этом iPhone, позиция берётся прямо из его приложения, без задержек интернета. Иначе время берётся из Spotify Web API."))
            }

            if settings.useAppRemote {
                Section {
                    Button {
                        UIPasteboard.general.string = Bundle.main.bundleIdentifier
                        bundleCopied = true
                    } label: {
                        LabeledContent("Bundle ID") {
                            Text(bundleCopied ? String(localized: "Скопировано") : (Bundle.main.bundleIdentifier ?? "—"))
                                .font(.footnote.monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .foregroundStyle(.primary)
                    LabeledContent("Redirect URI") {
                        Text(SpotifyAuth.redirectURI).font(.footnote.monospaced())
                    }
                } header: {
                    Text(String(localized: "Если не подключается"))
                } footer: {
                    Text(String(localized: "1. Spotify должен играть на этом iPhone. 2. В developer.spotify.com → ваше приложение → Settings отметьте «iOS» и добавьте этот Bundle ID (AltStore меняет его при установке) и Redirect URI. 3. Нажмите «Открыть Spotify и подключиться» (или включите «Будить Spotify самому»: если Spotify дважды откажет, приложение один раз откроет его и вернётся). Если состояние «Нужно войти заново» — войдите заново: старый вход был без доступа к приложению Spotify."))
                }
            }

            Section {
                VStack(alignment: .leading) {
                    Text(String(localized: "Сдвиг текста: \(Int(settings.timingOffsetMs)) мс"))
                    Slider(value: $settings.timingOffsetMs, in: -1500...1500, step: 50)
                }
                Button(String(localized: "Сбросить сдвиг")) { settings.timingOffsetMs = 0 }
                    .disabled(settings.timingOffsetMs == 0)
            } footer: {
                Text(String(localized: "Положительный сдвиг показывает слова раньше."))
            }

            Section {
                SliderRow(title: String(localized: "Опрос Spotify Web API"), value: $settings.webPollInterval, range: 1...5,
                          step: 0.5, format: { String(format: "%.1f", $0) + " " + String(localized: "с") })
                SliderRow(title: String(localized: "Сверка с приложением Spotify"), value: $settings.remoteQueryInterval,
                          range: 0.5...5, step: 0.5, format: { String(format: "%.1f", $0) + " " + String(localized: "с") })
                Toggle(String(localized: "Индикатор синхронизации"), isOn: $settings.showSyncIndicator)
                NavigationLink(String(localized: "Журнал")) {
                    SyncLogView().navigationTitle(String(localized: "Журнал"))
                }
            } header: {
                Text(String(localized: "Как часто сверять время"))
            } footer: {
                Text(String(localized: "Индикатор над текстом показывает, откуда пришло время (App Remote или Web API), насколько часы расходились и как давно была сверка. Частый опрос Web API тратит общий лимит запросов вашего Client ID."))
            }

            Section {
                Toggle(String(localized: "Учитывать задержку наушников"), isOn: $settings.compensateOutputLatency)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent(AudioRoute.outputName,
                                   value: String(localized: "\(Int((player.appliedOutputLatency * 1000).rounded())) мс"))
                }
            } footer: {
                Text(String(localized: "Когда Spotify играет на этом iPhone, задержка Bluetooth-наушников вычитается автоматически."))
            }
        }
    }
}

private struct PerformanceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PerformanceMonitor.self) private var performance

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Экономия батареи"), isOn: $settings.powerSaving)
            } footer: {
                Text(String(localized: "30 кадров в секунду, без размытия строк, неподвижный фон в приложении и в PiP."))
            }

            Section {
                Picker(String(localized: "Частота кадров текста"), selection: $settings.lyricsFrameRate) {
                    Text("24").tag(24.0)
                    Text("30").tag(30.0)
                    Text("45").tag(45.0)
                    Text("60").tag(60.0)
                    if UIScreen.main.maximumFramesPerSecond > 60 {
                        Text("120").tag(120.0)
                    }
                }
                Toggle(String(localized: "Показывать FPS в плеере"), isOn: $settings.showLyricsFPS)
                Toggle(String(localized: "Показывать FPS в PiP"), isOn: $settings.pipShowFPS)
            } header: {
                Text(String(localized: "Кадры"))
            } footer: {
                Text(String(localized: "Меньше кадров — меньше нагрев. На паузе текст рисуется 15 раз в секунду, в режиме экономии — не больше 30. Счётчик показывает реальные кадры / цель. Частота PiP настраивается в «Картинке в картинке»."))
            }

            Section {
                LabeledContent(String(localized: "Сейчас"), value: settings.powerSaving
                               ? String(localized: "Экономия включена")
                               : (performance.constrained ? String(localized: "Экономия (авто)") : String(localized: "Полная плавность")))
            } footer: {
                Text(String(localized: "Экономия включается сама в режиме энергосбережения iOS и когда телефон сильно нагревается."))
            }
        }
    }
}

private struct SourceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCleared = false
    @State private var showOwnLyrics = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                if settings.hasBundledSpicyKey {
                    Label(String(localized: "Ключ Spicy Lyrics встроен в приложение"), systemImage: "checkmark.seal.fill")
                } else {
                    TextField("sl_pk_…", text: $settings.spicyLyricsKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if !settings.spicyLyricsKey.isEmpty && settings.validSpicyKey == nil {
                        Text(settings.spicyLyricsKey.hasPrefix("sl_sk_")
                             ? String(localized: "Это секретный ключ. Нужен клиентский ключ sl_pk_…")
                             : String(localized: "Ключ должен начинаться с sl_pk_"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Link(String(localized: "Получить ключ Spicy Lyrics"), destination: URL(string: "https://developers.spicylyrics.org")!)
                }
                Toggle(String(localized: "Запасной источник LRCLIB"), isOn: $settings.useLRCLibFallback)
            } header: {
                Text("Spicy Lyrics")
            } footer: {
                Text(String(localized: "С клиентским ключом используется публичный API /v1/lyrics. Без ключа приложение пробует токен Spotify, как расширение для Spicetify."))
            }

            Section {
                Picker(String(localized: "Пропускать песни"), selection: $settings.autoSkipMode) {
                    ForEach(AutoSkipMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } footer: {
                Text(String(localized: "Песня, у которой нет синхронизации в Spicy Lyrics (текст не найден, есть только в LRCLIB или без таймингов), пропускается сама. Свои TTML считаются. Не пропускаются песни, выбранные вручную или возвращённые кнопкой «назад»; после \(PlayerModel.autoSkipLimit) пропусков подряд пропуск встаёт на паузу."))
            }

            Section {
                Toggle(String(localized: "Скрывать «Текст не найден»"), isOn: $settings.hideNotFoundNotice)
                Toggle(String(localized: "Скрывать несинхронный текст"), isOn: $settings.hideStaticLyrics)
            } footer: {
                Text(String(localized: "Вместо сообщения или статичного текста остаётся только фон. В горизонтальном режиме кнопки тоже прячутся; касание возвращает их."))
            }

            if settings.hideNotFoundNotice || settings.hideStaticLyrics {
                Section {
                    Picker(String(localized: "Вместо текста"), selection: $settings.hiddenLyricsView) {
                        ForEach(HiddenLyricsView.allCases) { view in
                            Text(view.title).tag(view.rawValue)
                        }
                    }
                } footer: {
                    Text(String(localized: "Большая обложка — во весь экран поверх туманности в цветах обложки, как в Apple Music: становится больше, когда кнопки прячутся, и чуть уменьшается на паузе. Туманность течёт, пока песня играет, и почти замирает на паузе."))
                }
            }

            Section {
                Button(String(localized: "Свои тексты (TTML)")) { showOwnLyrics = true }
                Button(String(localized: "Перезагрузить текст")) { player.loadLyrics(force: true) }
                Button(cacheCleared ? String(localized: "Кэш очищен") : String(localized: "Очистить кэш текстов")) {
                    player.clearLyricsCache()
                    cacheCleared = true
                }
                .disabled(cacheCleared)
            }
        }
        .sheet(isPresented: $showOwnLyrics) {
            OwnLyricsView()
                .environment(player)
        }
    }
}

private struct SpotifySettings: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                LabeledContent("Client ID", value: settings.hasValidClientID
                               ? "…\(String(settings.spotifyClientID.suffix(4)))"
                               : String(localized: "Не настроен"))
                NavigationLink {
                    SpotifySetupGuideView()
                } label: {
                    Label(String(localized: "Сменить Client ID"), systemImage: "key.horizontal")
                }
            } footer: {
                Text(String(localized: "Приложение работает только через ваше собственное приложение Spotify. Друзей можно добавить в него через Settings → User Management в developer.spotify.com (до 5 человек)."))
            }

            Section {
                Button(String(localized: "Выйти из Spotify"), role: .destructive) { auth.logOut() }
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Версия"), value: AppVersion.display)
            }
            Section(String(localized: "Авторы")) {
                creditLink(String(localized: "Автор"), name: "sppq", url: "https://spicylyrics.org/sppq")
                creditLink("GitHub", name: "Sppqq", url: "https://github.com/Sppqq")
                creditLink(String(localized: "Тестер"), name: "nie4ick", url: "https://spicylyrics.org/nie4ick")
            }
            Section {
                Link(String(localized: "Spicy Lyrics (оригинал)"), destination: URL(string: "https://github.com/Spikerko/spicy-lyrics")!)
                Link("Spicy Lyrics Mobile (Android)", destination: URL(string: "https://github.com/spicylyrics/mobile")!)
                Link(String(localized: "Этот проект на GitHub"), destination: URL(string: "https://github.com/Sppqq/spicy-lyrics-ios")!)
                Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
            } footer: {
                Text(String(localized: "Неофициальный iOS-порт. Распространяется по лицензии AGPL-3.0, как и оригинал. Не связан со Spotify AB."))
            }
        }
    }

    private func creditLink(_ role: String, name: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            LabeledContent(role) {
                HStack(spacing: 4) {
                    Text(name)
                    Image(systemName: "arrow.up.right").font(.caption)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}
