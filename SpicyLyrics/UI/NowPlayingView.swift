import SwiftUI

/// The main screen, laid out like Apple Music's lyrics view: header and controls float over
/// full-height lyrics and fade away while a song plays. Landscape puts artwork and controls on
/// the left, lyrics on the right.
struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(PerformanceMonitor.self) private var performance
    @Environment(LyricsPictureInPicture.self) private var pip
    @State private var showSettings = false
    @State private var showPicker = false
    @State private var showSetupGuide = false
    @State private var showOwnLyrics = false
    /// Big ⏭/⏮ flash after a swipe changes the track.
    @State private var skipFeedback: SkipDirection?
    @State private var skipCount = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var chromeVisible = true
    /// Bumped on every touch; restarts the auto-hide countdown.
    @State private var interactionTick = 0
    @State private var headerSwipe: CGFloat = 0
    @State private var headerHeight: CGFloat = 76
    @State private var controlsHeight: CGFloat = 250
    @State private var landscapeControlsHeight: CGFloat = 150
    @State private var isLandscape = false

    private static let chromeAnimation = Animation.easeInOut(duration: 0.45)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Side by side in landscape, and on iPad in any orientation (wide enough for both).
            let landscape = (size.width > size.height && size.width > 560) || size.width >= 700
            ZStack {
                // The PiP layer has to be in the window; it sits behind everything.
                PictureInPictureHost(pip: pip)
                    .frame(width: 80, height: 40)
                    .allowsHitTesting(false)

                DynamicBackground(
                    image: settings.dynamicBackground ? player.backgroundArtwork : nil,
                    imageID: player.artworkID,
                    animated: settings.dynamicBackground && !reduced,
                    dim: settings.backgroundDim,
                    speed: settings.backgroundSpeed,
                    blur: settings.backgroundBlur,
                    saturation: settings.backgroundSaturation
                )

                if landscape {
                    landscapeLayout(geometry.size)
                } else {
                    portraitLayout(geometry.size)
                }

                Color.clear
                    .allowsHitTesting(false)
                    .onChange(of: landscape, initial: true) { _, value in isLandscape = value }

                if let skipFeedback {
                    Image(systemName: skipFeedback == .next ? "forward.fill" : "backward.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                        .padding(30)
                        .background(.ultraThinMaterial, in: Circle())
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
        .background { keyboardShortcuts }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .task(id: AutoHideKey(tick: interactionTick, eligible: canAutoHide)) {
            guard canAutoHide else { return }
            try? await Task.sleep(for: .seconds(lyricsOnly ? 4 : settings.autoHideDelay))
            guard !Task.isCancelled, canAutoHide else { return }
            withAnimation(Self.chromeAnimation) { chromeVisible = false }
        }
        .onChange(of: player.isPlaying) { _, playing in
            // Pausing brings the controls back, like Apple Music (not in lyrics-only mode).
            if !playing && !lyricsOnly { showChrome() }
        }
        .onChange(of: lyricsOnly) { _, value in
            if value { hideChrome() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(settings)
                .environment(player)
                .environment(performance)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showSetupGuide) {
            NavigationStack {
                SpotifySetupGuideView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Закрыть")) { showSetupGuide = false }
                        }
                    }
            }
            .environment(settings)
            .environmentObject(auth)
        }
        .sheet(isPresented: $showOwnLyrics) {
            OwnLyricsView()
                .environment(player)
        }
        .sheet(isPresented: $showPicker) {
            TrackPickerView()
                .environment(player)
                .environmentObject(auth)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: settings.showRomanization) { _, _ in player.settingsChanged() }
        .onChange(of: settings.simpleLyricsMode) { _, _ in player.settingsChanged() }
        .onChange(of: settings.translationReplaces) { _, _ in player.settingsChanged() }
        .onChange(of: settings.translateLyrics) { _, _ in player.settingsChanged() }
        .modifier(LyricsTranslation(player: player, settings: settings))
        .task { pip.configure(player: player, settings: settings, performance: performance) }
        .onChange(of: settings.autoPictureInPicture) { _, enabled in pip.setAutomaticStart(enabled) }
        .alert(String(localized: "Картинка в картинке"), isPresented: Binding(
            get: { pip.lastError != nil && !pip.isActive },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pip.lastError ?? "")
        }
        .alert("Spotify", isPresented: Binding(
            get: { player.transientError != nil },
            set: { if !$0 { player.transientError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.transientError ?? "")
        }
    }

    // MARK: Chrome visibility

    private struct AutoHideKey: Hashable {
        var tick: Int
        var eligible: Bool
    }

    /// Low Power Mode, a hot phone, or the battery saver setting.
    private var reduced: Bool { settings.powerSaving || performance.constrained }

    private var lyricsLoaded: Bool {
        if case .loaded = player.lyricsState { return true }
        return false
    }

    /// Landscape with "Только текст": the controls only show up for a moment after a tap.
    private var lyricsOnly: Bool { isLandscape && settings.landscapeLyricsOnly }

    private var canAutoHide: Bool {
        guard chromeVisible, !showSettings, !showPicker, !showSetupGuide, !showOwnLyrics else { return false }
        return lyricsOnly || (settings.autoHideControls && player.isPlaying && lyricsLoaded)
    }

    private func showChrome() {
        interactionTick += 1
        guard !chromeVisible else { return }
        withAnimation(Self.chromeAnimation) { chromeVisible = true }
    }

    private func toggleChrome() {
        interactionTick += 1
        withAnimation(Self.chromeAnimation) { chromeVisible.toggle() }
    }

    private func hideChrome() {
        withAnimation(Self.chromeAnimation) { chromeVisible = false }
    }

    // MARK: Gestures & keyboard

    private enum SkipDirection { case next, previous }

    /// Swipe across the lyrics: next / previous track with a flash and a light tap.
    private func skip(_ direction: SkipDirection) {
        if direction == .next { player.next() } else { player.previous() }
        skipCount += 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { skipFeedback = direction }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard skipFeedback == direction else { return }
            withAnimation(.easeOut(duration: 0.25)) { skipFeedback = nil }
        }
    }

    /// Hardware keyboard (iPad): space plays/pauses, ⌘← / ⌘→ change tracks.
    private var keyboardShortcuts: some View {
        ZStack {
            Button(String(localized: "Пауза / воспроизведение")) { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button(String(localized: "Следующий трек")) { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button(String(localized: "Предыдущий трек")) { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Portrait

    private func portraitLayout(_ size: CGSize) -> some View {
        ZStack {
            lyricsArea(
                topInset: chromeVisible ? headerHeight : 0,
                bottomInset: chromeVisible ? controlsHeight : 0,
                horizontalPadding: 28
            )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : -24)

                Spacer(minLength: 0)

                controls()
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : 40)
            }
            .allowsHitTesting(chromeVisible)

            // Like Apple Music: while the controls are hidden, where they live is not part of the
            // lyrics. A tap there brings them back instead of seeking to a line.
            if !chromeVisible {
                VStack(spacing: 0) {
                    wakeZone.frame(height: headerHeight + 24)
                    Spacer(minLength: 0)
                    wakeZone.frame(height: controlsHeight + 24)
                }
            }
        }
    }

    /// Invisible area that shows the controls on tap.
    private var wakeZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { showChrome() }
            .verticalSwipe(.up) { showChrome() }
            .accessibilityLabel(String(localized: "Показать элементы управления"))
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Landscape

    private func landscapeLayout(_ size: CGSize) -> some View {
        let lyricsOnly = settings.landscapeLyricsOnly
        let showTitle = settings.landscapeTitle && !lyricsOnly
        let column = min(size.width * 0.4, 420)
        let blockWidth = column - 40
        // The artwork gets whatever height the title and controls leave free.
        let reserved = (chromeVisible ? landscapeControlsHeight + 18 : 0) + (showTitle ? 62 : 0) + 24
        let artworkSide = min(blockWidth, size.height * 0.62, size.height - reserved)
        let showArtwork = settings.landscapeArtwork && !lyricsOnly && artworkSide >= 72
        let infoWidth = showArtwork ? artworkSide : min(blockWidth, 320)
        // With artwork and title switched off the column is empty once the controls hide:
        // slide the lyrics to the middle instead of leaving a gap (no re-wrapping).
        let columnEmpty = !showArtwork && !showTitle && !chromeVisible

        return HStack(spacing: 0) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                if showArtwork {
                    artwork(side: artworkSide, cornerRadius: 12)
                        .scaleEffect(player.isPlaying ? 1 : 0.86)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
                        .onTapGesture { toggleChrome() }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if showTitle {
                    titleBlock
                        .frame(width: infoWidth)
                }

                if chromeVisible {
                    controls(compact: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { landscapeControlsHeight = $0 }
                        .frame(width: max(infoWidth, 280))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: column)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // Empty space in the column toggles the controls (the buttons keep their own taps).
            .onTapGesture { toggleChrome() }
            // "•••" in the column's corner, out of the title's way.
            .overlay(alignment: .topTrailing) {
                if chromeVisible && !lyricsOnly {
                    moreMenu
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .opacity(columnEmpty ? 0 : 1)

            lyricsArea(topInset: 0, bottomInset: 0, horizontalPadding: 24)
                .frame(width: max(0, size.width - column - 12))
        }
        .frame(width: size.width, alignment: .leading)
        .offset(x: columnEmpty ? -(column + 12) / 2 : 0)
        .overlay(alignment: .bottom) {
            if !chromeVisible {
                wakeZone.frame(height: size.height * 0.2)
            }
        }
        .animation(Self.chromeAnimation, value: showArtwork)
        .animation(Self.chromeAnimation, value: showTitle)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            trackInfo
            moreMenu
        }
        .foregroundStyle(.white)
        // Swipe the header down to tuck the controls away.
        .verticalSwipe(.down) { hideChrome() }
    }

    /// Small artwork and title. Tap to pick a track, swipe sideways to skip.
    private var trackInfo: some View {
        HStack(spacing: 12) {
            artwork(side: 54, cornerRadius: 6)
            titleBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .offset(x: headerSwipe)
        .opacity(1 - min(Double(abs(headerSwipe)) / 160, 0.6))
        .onTapGesture {
            showChrome()
            showPicker = true
        }
        .gesture(
            DragGesture(minimumDistance: 28)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    headerSwipe = value.translation.width * 0.5
                }
                .onEnded { value in
                    let width = value.translation.width
                    // A deliberate, mostly horizontal swipe: a sloppy tap near "•••" must not skip.
                    if abs(width) > 110, abs(width) > abs(value.translation.height) * 2 {
                        if width < 0 { player.next() } else { player.previous() }
                    }
                    showChrome()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { headerSwipe = 0 }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Выбрать трек. Смахните влево или вправо, чтобы переключить трек."))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Too long to fit: rides sideways, like in Apple Music.
            MarqueeText(text: title, font: .system(size: 17, weight: .semibold), active: chromeVisible || isLandscape)
            MarqueeText(text: subtitle, font: .system(size: 17), active: chromeVisible || isLandscape)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(side: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let artwork = player.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.35))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Apple Music's "•••" button.
    private var moreMenu: some View {
        Menu {
            Button {
                showPicker = true
            } label: {
                Label(String(localized: "Выбрать трек"), systemImage: "music.note.list")
            }
            if let url = spotifyURL {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label(String(localized: "Открыть в Spotify"), systemImage: "arrow.up.forward.app")
                }
            }
            Button {
                player.loadLyrics(force: true)
            } label: {
                Label(String(localized: "Перезагрузить текст"), systemImage: "arrow.clockwise")
            }
            Button {
                showOwnLyrics = true
            } label: {
                Label(String(localized: "Свой текст (TTML)"), systemImage: "doc.text")
            }
            if #available(iOS 18.0, *) {
                Button {
                    settings.translateLyrics.toggle()
                } label: {
                    Label(settings.translateLyrics ? String(localized: "Выключить перевод") : String(localized: "Включить перевод"),
                          systemImage: "character.bubble")
                }
            }
            if LyricsPictureInPicture.isSupported {
                Button {
                    pip.isActive ? pip.stop() : pip.start()
                } label: {
                    Label(pip.isActive ? String(localized: "Закрыть окно с текстом") : String(localized: "Текст поверх приложений"),
                          systemImage: "pip.enter")
                }
            }
            Divider()
            Button {
                showSettings = true
            } label: {
                Label(String(localized: "Настройки"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.18), in: Circle())
                // 48 pt touch target around the 30 pt circle.
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .simultaneousGesture(TapGesture().onEnded { showChrome() })
    }

    private var spotifyURL: URL? {
        guard let track = player.track else { return URL(string: "spotify:") }
        return URL(string: track.uri) ?? URL(string: "spotify:")
    }

    private func controls(compact: Bool = false) -> some View {
        PlaybackBar(
            onInteraction: { showChrome() },
            onShowQueue: { showPicker = true },
            onHideControls: { hideChrome() },
            isVisible: chromeVisible,
            compact: compact
        )
        .foregroundStyle(.white)
    }

    private var title: String {
        switch player.content {
        case .track(let track): return track.title
        case .episode(let title, _, _): return title
        case .ad: return String(localized: "Реклама")
        case .unknown: return String(localized: "Неизвестный трек")
        case .none: return "Spicy Lyrics"
        }
    }

    private var subtitle: String {
        switch player.content {
        case .track(let track): return track.artistLine
        case .episode(_, let show, _): return show
        default: return player.statusMessage ?? String(localized: "Ожидание Spotify…")
        }
    }

    // MARK: Lyrics

    private func lyricsArea(topInset: CGFloat, bottomInset: CGFloat, horizontalPadding: CGFloat) -> some View {
        lyricsContent(topInset: topInset, bottomInset: bottomInset, horizontalPadding: horizontalPadding)
            // Until Spotify confirms what is playing, the lyrics on screen may be stale.
            .opacity(player.isResyncing ? 0.3 : 1)
            .overlay(alignment: .top) {
                if player.isResyncing {
                    Label(String(localized: "Синхронизация со Spotify…"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, topInset + 8)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: player.isResyncing)
            .trackSwipes(enabled: settings.gesturesEnabled && player.track != nil,
                         onNext: { skip(.next) }, onPrevious: { skip(.previous) })
    }

    /// iPad: the extension sizes lyrics at 7% of the container width, so wide screens get more.
    private var lyricFontScale: CGFloat { sizeClass == .regular ? 1.35 : 1 }

    @ViewBuilder
    private func lyricsContent(topInset: CGFloat, bottomInset: CGFloat, horizontalPadding: CGFloat) -> some View {
        switch player.lyricsState {
        case .loaded(let lyrics):
            LyricsView(
                lyrics: lyrics, player: player, settings: settings,
                topInset: topInset, bottomInset: bottomInset,
                horizontalPadding: horizontalPadding, reduced: reduced, fontScale: lyricFontScale,
                onInteraction: { showChrome() },
                onBackgroundTap: { toggleChrome() },
                tapSeeks: chromeVisible || lyricsOnly
            )
            .id(player.lyricsRevision)
            .overlay(alignment: .topTrailing) {
                if settings.showSyncIndicator {
                    SyncIndicator()
                        .padding(.top, topInset + 6)
                        .padding(.trailing, horizontalPadding)
                }
            }
            .transition(.opacity)
        case .loading:
            LyricsSkeleton()
                .padding(.top, topInset)
                .frame(maxHeight: .infinity, alignment: .top)
        case .notFound:
            message(icon: "text.badge.xmark", title: String(localized: "Текст не найден"),
                    detail: String(localized: "Для этого трека пока нет текста ни в Spicy Lyrics, ни в LRCLIB."),
                    retry: true)
        case .failed(let reason):
            message(icon: "wifi.exclamationmark", title: String(localized: "Не удалось загрузить текст"), detail: reason, retry: true)
        case .unavailable(let reason):
            message(icon: "music.note", title: reason, detail: nil, retry: false)
        case .idle:
            idleState
        }
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 44))
            Text(player.statusMessage ?? String(localized: "Включите музыку в Spotify"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if player.accessProblem != nil {
                Button {
                    showSetupGuide = true
                } label: {
                    Label(String(localized: "Подключить свой Client ID"), systemImage: "key.horizontal")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.12, green: 0.84, blue: 0.38), in: Capsule())
                        .foregroundStyle(.black)
                }
            } else {
                Button {
                    if let url = URL(string: "spotify:") { UIApplication.shared.open(url) }
                } label: {
                    Label(String(localized: "Открыть Spotify"), systemImage: "arrow.up.forward.app")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(icon: String, title: String, detail: String?, retry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            if retry {
                Button(String(localized: "Повторить")) { player.loadLyrics(force: true) }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Placeholder bars while lyrics load (the extension's LyricsSkeleton).
private struct LyricsSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(pulse ? 0.16 : 0.08))
                    .frame(width: [260, 200, 300, 170, 240, 210][i], height: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
