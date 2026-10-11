import SwiftUI

@main
@MainActor
struct SpicyLyricsApp: App {
    @State private var settings: AppSettings
    @StateObject private var auth: SpotifyAuth
    @State private var player: PlayerModel
    @State private var performance = PerformanceMonitor()
    @State private var pip = LyricsPictureInPicture()
    @State private var appRemote: SpotifyAppRemote
    @State private var liveActivity = LiveLyricsActivity()

    init() {
        AudioRoute.prepare()
        let settings = AppSettings()
        SyncLog.shared.enabled = settings.syncLogEnabled
        let auth = SpotifyAuth(settings: settings)
        let api = SpotifyAPI(auth: auth)
        let localLyrics = LocalLyricsStore()
        let lyrics = LyricsService(settings: settings, auth: auth, local: localLyrics)
        _settings = State(initialValue: settings)
        _auth = StateObject(wrappedValue: auth)
        _appRemote = State(initialValue: SpotifyAppRemote(auth: auth, settings: settings))
        _player = State(initialValue: PlayerModel(api: api, lyrics: lyrics, settings: settings, localLyrics: localLyrics))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(player)
                .environment(performance)
                .environment(pip)
                .environment(appRemote)
                .environment(liveActivity)
                .environmentObject(auth)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LyricsPictureInPicture.self) private var pip
    @Environment(SpotifyAppRemote.self) private var appRemote
    @Environment(LiveLyricsActivity.self) private var liveActivity
    /// Letting go of Spotify after the app went to the background, unless the floating window
    /// turns up meanwhile.
    @State private var stopTask: Task<Void, Never>?

    var body: some View {
        Group {
            if auth.isLoggedIn || isDemo {
                NowPlayingView()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase, initial: true) { old, phase in
            updateActivity(phase)
            // Back in the app: the lyrics on screen were last drawn a while ago.
            if phase == .active, old != .active {
                player.resync("app active")
                liveActivity.refresh()
            }
        }
        .onChange(of: liveActivity.keepsAppRunning) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.liveActivity) { _, _ in liveActivity.refresh() }
        .onChange(of: player.track?.uri) { _, _ in liveActivity.refresh() }
        .task { liveActivity.configure(player: player, settings: settings) }
        .onChange(of: auth.isLoggedIn) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.keepScreenOn) { _, _ in updateActivity(scenePhase) }
        .onChange(of: pip.keepsAppRunning) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.useAppRemote) { _, _ in appRemote.refresh() }
        .onChange(of: settings.syncLogEnabled) { _, enabled in SyncLog.shared.enabled = enabled }
        .onOpenURL { url in appRemote.handle(url) }
        #if DEBUG
        .task {
            if let demo = DemoTrack.current { player.startDemo(demo) }
        }
        #endif
    }

    private var isDemo: Bool {
        #if DEBUG
        return DemoTrack.current != nil
        #else
        return false
        #endif
    }

    /// Following Spotify is wanted: the app is on screen (Control Center or the app switcher
    /// over it count), or the floating window is up or on its way.
    private func wantsToFollow(_ phase: ScenePhase) -> Bool {
        auth.isLoggedIn && (phase != .background || pip.keepsAppRunning || liveActivity.keepsAppRunning)
    }

    private func updateActivity(_ phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active && auth.isLoggedIn && settings.keepScreenOn
        if wantsToFollow(phase) {
            stopTask?.cancel()
            stopTask = nil
            player.startPolling()
            if settings.useAppRemote { appRemote.start(player: player) }
            return
        }
        guard auth.isLoggedIn else {
            stopFollowing()
            return
        }
        // Leaving the app: the floating window may still be opening (iOS only says so after its
        // animation). Dropping App Remote right then and reconnecting a moment later was what
        // threw the timing off: wait a little and look again.
        guard stopTask == nil else { return }
        stopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            stopTask = nil
            let phase: ScenePhase = UIApplication.shared.applicationState == .background ? .background : .active
            if !wantsToFollow(phase) { stopFollowing() }
        }
    }

    private func stopFollowing() {
        stopTask?.cancel()
        stopTask = nil
        player.stopPolling()
        appRemote.stop()
    }
}
