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
                Section("Вид текста") {
                    category("Текст", "textformat.size", .purple,
                             value: "\(Int(settings.fontSize)) pt") { TextLookSettings() }
                    category("Эффекты", "sparkles", .pink,
                             value: settings.simpleLyricsMode ? "Simple" : nil) { EffectsSettings() }
                    category("Фон", "photo.fill", .indigo,
                             value: settings.dynamicBackground ? nil : "Выкл.") { BackgroundSettings() }
                    category("Перевод и романизация", "character.bubble.fill", .blue,
                             value: translationSummary) { LanguageSettings() }
                }

                Section("Экран плеера") {
                    category("Интерфейс", "rectangle.bottomhalf.inset.filled", .orange) { InterfaceSettings() }
                    category("Горизонтальный режим", "rectangle.landscape.rotate", .teal,
                             value: settings.landscapeLyricsOnly ? "Только текст" : nil) { LandscapeSettings() }
                    category("Жесты", "hand.draw.fill", .red,
                             value: settings.gesturesEnabled ? "Вкл." : "Выкл.") { GestureSettings() }
                    category("Картинка в картинке", "pip.fill", .green,
                             value: settings.autoPictureInPicture ? "Авто" : nil) { PictureInPictureSettings() }
                }

                Section("Работа") {
                    category("Синхронизация", "timer", .cyan,
                             value: settings.timingOffsetMs == 0 ? nil : "\(Int(settings.timingOffsetMs)) мс") { SyncSettings() }
                    category("Батарея и нагрев", "bolt.fill", .yellow,
                             value: settings.powerSaving ? "Экономия" : (performance.constrained ? "Авто-экономия" : nil)) {
                        PerformanceSettings()
                    }
                    category("Источники текстов", "doc.text.fill", .brown) { SourceSettings() }
                    category("Spotify", "music.note", Color(red: 0.12, green: 0.84, blue: 0.38),
                             value: settings.usingBundledClientID ? "Встроенный" : "Свой Client ID") { SpotifySettings() }
                }

                Section {
                    category("О приложении", "info.circle.fill", .gray, value: AppVersion.display) { AboutSettings() }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var translationSummary: String? {
        switch (settings.translateLyrics, settings.showRomanization) {
        case (true, true): return "Оба"
        case (true, false): return "Перевод"
        case (false, true): return "Романизация"
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
                Picker("Шрифт", selection: $settings.lyricsFont) {
                    ForEach(LyricsFont.allCases) { font in
                        Text(font.title).tag(font.rawValue)
                    }
                }
                SliderRow(title: "Размер", value: $settings.fontSize,
                          range: Double(AppSettings.fontRange.lowerBound)...Double(AppSettings.fontRange.upperBound),
                          step: 1, format: { "\(Int($0)) pt" })
                Toggle("По центру", isOn: $settings.centerLyrics)
            } footer: {
                Text("Размер можно менять и щипком двумя пальцами прямо по тексту. После этого на пару секунд появится кнопка «Сбросить размер».")
            }

            Section("Расстояния") {
                SliderRow(title: "Между строками", value: $settings.lineSpacingScale, range: 0...4, step: 0.25)
            }

            ResetSection(title: "Вернуть как было") { settings.resetLyricsLook() }
        }
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
                Text("Спокойная анимация из оригинального расширения: слова не подпрыгивают и не светятся, заливка мягче.")
            }

            Section {
                Toggle("Размывать неактивные строки", isOn: $settings.blurInactiveLines)
                if settings.blurInactiveLines {
                    SliderRow(title: "Сила размытия", value: $settings.blurStrength, range: 0.25...2.5)
                }
            } header: {
                Text("Размытие")
            } footer: {
                Text("Строки размываются тем сильнее, чем дальше они от текущей.")
            }

            Section {
                SliderRow(title: "Свечение слов", value: $settings.glowStrength, range: 0...2)
                    .disabled(settings.simpleLyricsMode)
                SliderRow(title: "Яркость остальных строк", value: $settings.inactiveBrightness, range: 0.5...1.5)
            } header: {
                Text("Свет")
            } footer: {
                Text(settings.simpleLyricsMode
                     ? "В Simple Lyrics Mode слова не светятся."
                     : "Свечение — мягкий ореол вокруг спетых слов.")
            }

            ResetSection(title: "Вернуть эффекты по умолчанию") { settings.resetEffects() }
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
                Toggle("Обложка на фоне", isOn: $settings.dynamicBackground)
            } footer: {
                if settings.powerSaving || performance.constrained {
                    Text("Сейчас включена экономия батареи, поэтому фон не двигается.")
                } else {
                    Text("Размытая обложка трека, которая медленно плавает за текстом.")
                }
            }

            if settings.dynamicBackground {
                Section("Обложка") {
                    SliderRow(title: "Скорость движения", value: $settings.backgroundSpeed, range: 0.25...3)
                    SliderRow(title: "Размытие", value: $settings.backgroundBlur, range: 0.3...3)
                }
            }

            Section {
                SliderRow(title: "Затемнение", value: $settings.backgroundDim, range: 0...0.7, step: 0.02)
            } footer: {
                Text("Чем темнее фон, тем лучше читается белый текст на светлых обложках.")
            }

            ResetSection(title: "Вернуть фон по умолчанию") { settings.resetBackground() }
        }
    }
}

private struct LanguageSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Романизация", isOn: $settings.showRomanization)
            } footer: {
                Text("Латиница вместо японского, китайского, корейского, кириллицы и греческого. Делается прямо на телефоне.")
            }

            Section {
                Toggle("Перевод под строками", isOn: $settings.translateLyrics)
                if settings.translateLyrics {
                    Picker("Язык перевода", selection: $settings.translationLanguage) {
                        ForEach(LyricsTranslation.languages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    SliderRow(title: "Размер перевода", value: $settings.translationScale, range: 0.6...1.6)
                }
            } footer: {
                Text("Перевод Apple на устройстве (iOS 18 и новее). Строки, которые уже на выбранном языке, не переводятся. При первом использовании iOS предложит скачать языковую модель.")
            }
        }
    }
}

private struct InterfaceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Прятать кнопки во время песни", isOn: $settings.autoHideControls)
                if settings.autoHideControls {
                    SliderRow(title: "Через", value: $settings.autoHideDelay, range: 2...12, step: 1,
                              format: { "\(Int($0)) с" })
                }
            } footer: {
                Text("Как в Apple Music: кнопки исчезают, пока играет песня. Касание внизу экрана возвращает их.")
            }

            Section {
                Toggle("Полоска громкости", isOn: $settings.showVolumeSlider)
                Toggle("Не гасить экран", isOn: $settings.keepScreenOn)
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
                Toggle("Только текст", isOn: $settings.landscapeLyricsOnly)
            } footer: {
                Text("Прячет весь интерфейс: текст занимает весь экран, а кнопки появляются по касанию на несколько секунд.")
            }

            Section {
                Toggle("Обложка", isOn: $settings.landscapeArtwork)
                Toggle("Название и исполнитель", isOn: $settings.landscapeTitle)
            } header: {
                Text("Слева от текста")
            } footer: {
                Text("Если выключить и то и другое, текст сдвинется к центру, когда кнопки спрячутся.")
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
                Toggle("Открывать при сворачивании", isOn: $settings.autoPictureInPicture)
            } footer: {
                Text("Текст поверх других приложений. Вручную окно открывается из меню «•••» в плеере.")
            }

            Section {
                Toggle("Анимированный фон", isOn: $settings.pipAnimatedBackground)
                Toggle("Название песни", isOn: $settings.pipShowTitle)
            } header: {
                Text("Окно")
            } footer: {
                Text("Анимированный фон — плавающая обложка, как в приложении. На слабых устройствах выключите его; в режиме экономии он и так неподвижен.")
            }
        }
    }
}

private struct GestureSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Жесты", isOn: $settings.gesturesEnabled)
            } footer: {
                Text("Свайпы и щипок работают на iOS 18 и новее.")
            }

            Section {
                row("hand.draw", "Свайп влево / вправо по тексту", "следующий / предыдущий трек")
                row("arrow.up.left.and.arrow.down.right", "Щипок двумя пальцами", "размер текста")
                row("hand.tap", "Долгое нажатие на строку", "перемотать, скопировать, поделиться")
                row("hand.point.up.left", "Касание строки", "перемотать к ней")
                row("chevron.up", "Свайп вверх внизу экрана", "показать кнопки")
                row("chevron.down", "Свайп вниз по заголовку", "спрятать кнопки")
            } header: {
                Text("Что умеют")
            } footer: {
                Text("На iPad с клавиатурой: пробел — пауза, ⌘← / ⌘→ — треки.")
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

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Сдвиг текста: \(Int(settings.timingOffsetMs)) мс")
                    Slider(value: $settings.timingOffsetMs, in: -1500...1500, step: 50)
                }
                Button("Сбросить сдвиг") { settings.timingOffsetMs = 0 }
                    .disabled(settings.timingOffsetMs == 0)
            } footer: {
                Text("Положительный сдвиг показывает слова раньше.")
            }

            Section {
                Toggle("Учитывать задержку наушников", isOn: $settings.compensateOutputLatency)
            } footer: {
                Text("Когда Spotify играет на этом iPhone, задержка Bluetooth-наушников вычитается автоматически.")
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
                Toggle("Экономия батареи", isOn: $settings.powerSaving)
            } footer: {
                Text("30 кадров в секунду, без размытия строк, неподвижный фон в приложении и в PiP.")
            }

            Section {
                LabeledContent("Сейчас", value: settings.powerSaving
                               ? "Экономия включена"
                               : (performance.constrained ? "Экономия (авто)" : "Полная плавность"))
            } footer: {
                Text("Экономия включается сама в режиме энергосбережения iOS и когда телефон сильно нагревается.")
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
                    Label("Ключ Spicy Lyrics встроен в приложение", systemImage: "checkmark.seal.fill")
                } else {
                    TextField("sl_pk_…", text: $settings.spicyLyricsKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if !settings.spicyLyricsKey.isEmpty && settings.validSpicyKey == nil {
                        Text(settings.spicyLyricsKey.hasPrefix("sl_sk_")
                             ? "Это секретный ключ. Нужен клиентский ключ sl_pk_…"
                             : "Ключ должен начинаться с sl_pk_")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Link("Получить ключ Spicy Lyrics", destination: URL(string: "https://developers.spicylyrics.org")!)
                }
                Toggle("Запасной источник LRCLIB", isOn: $settings.useLRCLibFallback)
            } header: {
                Text("Spicy Lyrics")
            } footer: {
                Text("С клиентским ключом используется публичный API /v1/lyrics. Без ключа приложение пробует токен Spotify, как расширение для Spicetify.")
            }

            Section {
                Button("Свои тексты (TTML)") { showOwnLyrics = true }
                Button("Перезагрузить текст") { player.loadLyrics(force: true) }
                Button(cacheCleared ? "Кэш очищен" : "Очистить кэш текстов") {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Доступ", value: settings.usingBundledClientID
                               ? "Встроенный"
                               : "Свой Client ID …\(String(settings.spotifyClientID.suffix(4)))")
                NavigationLink {
                    SpotifySetupGuideView()
                } label: {
                    Label(settings.usingBundledClientID ? "Подключить свой Client ID" : "Сменить Client ID",
                          systemImage: "key.horizontal")
                }
                if settings.bundledSpotifyClientID != nil, settings.useOwnClientID {
                    Button("Вернуться к встроенному доступу") {
                        // The session belongs to the user's own Client ID: sign in again.
                        settings.useOwnClientID = false
                        auth.logOut()
                    }
                }
            } footer: {
                Text("Встроенный доступ Spotify — максимум на 5 человек. Со своим Client ID ограничение снимается (нужен Spotify Premium).")
            }

            Section {
                Button("Выйти из Spotify", role: .destructive) { auth.logOut() }
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Версия", value: AppVersion.display)
            }
            Section {
                Link("Spicy Lyrics (оригинал)", destination: URL(string: "https://github.com/Spikerko/spicy-lyrics")!)
                Link("Spicy Lyrics Mobile (Android)", destination: URL(string: "https://github.com/spicylyrics/mobile")!)
                Link("Этот проект на GitHub", destination: URL(string: "https://github.com/Sppqq/SpicyLyrics")!)
                Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
            } footer: {
                Text("Неофициальный iOS-порт. Распространяется по лицензии AGPL-3.0, как и оригинал. Не связан со Spotify AB.")
            }
        }
    }
}
