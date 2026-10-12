import Foundation
import Observation
import QuartzCore
import SpotifyiOS
import UIKit

/// Reads the playback position straight from the Spotify app on this phone (App Remote).
///
/// The Web API answers over the internet, so its position is only as exact as half a round
/// trip and some devices only refresh it on play / pause / seek. App Remote talks to the local
/// Spotify app: every play, pause, seek and new track arrives as an event carrying the exact
/// position, and a quick local query between events keeps the clock honest. The Web API stays
/// in charge of everything else (and of the clock whenever App Remote is not connected).
@MainActor
@Observable
final class SpotifyAppRemote: NSObject {
    enum Status: Equatable {
        /// Switched off, or the app is not following Spotify right now.
        case off
        /// The login predates the `app-remote-control` scope.
        case needsLogin
        case connecting
        case connected
        /// Spotify is not running (or refused): the Web API keeps the clock.
        case unavailable
    }

    private(set) var status: Status = .off
    /// Why the last attempt failed, as Spotify put it (shown in settings and on the sync badge).
    private(set) var lastError: String?

    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private var remote: SPTAppRemote?
    @ObservationIgnored private var remoteClientID: String?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    /// Gives up on a connection attempt Spotify never answers.
    @ObservationIgnored private var connectTimeout: Task<Void, Never>?
    /// Token handed back by Spotify after "wake Spotify", used for the next connection.
    @ObservationIgnored private var wakeToken: String?
    @ObservationIgnored private var coverURI: String?
    /// Failed attempts in a row: retries back off from 8 s to a minute.
    @ObservationIgnored private var failures = 0
    /// Automatic wake-ups this launch, and when the last one was: Spotify closes the connection when it
    /// is sent to the background again, so one wake is not always enough, but never in a loop.
    @ObservationIgnored private var wakes = 0
    @ObservationIgnored private var lastWake = Date.distantPast
    private static let maxWakes = 4
    private static let wakeCooldown: TimeInterval = 12

    static let scope = "app-remote-control"

    init(auth: SpotifyAuth, settings: AppSettings) {
        self.auth = auth
        self.settings = settings
    }

    /// Starts following the Spotify app (while the app follows Spotify at all).
    func start(player: PlayerModel) {
        self.player = player
        player.onRemoteStale = { [weak self] in self?.reconnect() }
        player.onRemoteQueryNow = { [weak self] in self?.query() }
        wanted = true
        // Called on every scene change; a second `connect()` mid-attempt cancels the first.
        guard remote?.isConnected != true, status != .connecting else { return }
        Task { await connect() }
    }

    func stop() {
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        queryTask?.cancel()
        queryTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        if remote?.isConnected == true { remote?.disconnect() }
        player?.setRemoteConnected(false)
        status = .off
    }

    /// The setting or the login changed.
    func refresh() {
        guard wanted, let player else { return }
        if !settings.useAppRemote {
            stop()
            self.player = player
            return
        }
        start(player: player)
    }

    /// Opens Spotify so it starts (and resumes playback), then comes back with a token.
    func wakeSpotify() {
        guard let remote = makeRemote() else {
            lastError = String(localized: "Нет Client ID")
            return
        }
        SyncLog.shared.add("remote", "waking Spotify")
        remote.authorizeAndPlayURI("") { [weak self] success in
            Task { @MainActor in
                guard !success else { return }
                self?.status = .unavailable
                self?.lastError = String(localized: "Не удалось открыть Spotify. Он установлен?")
                SyncLog.shared.add("remote", "could not open Spotify")
            }
        }
    }

    /// The `spicylyrics-ios://callback` URL Spotify opens after `wakeSpotify()`.
    func handle(_ url: URL) {
        guard let parameters = remote?.authorizationParameters(from: url) else { return }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            wakeToken = token
            failures = 0
            SyncLog.shared.add("remote", "Spotify handed back a token")
            status = .off
            Task { await connect() }
        } else if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            lastError = message
            status = .unavailable
            SyncLog.shared.add("remote", "Spotify refused: \(message)")
        }
    }

    // MARK: Connection

    private func makeRemote() -> SPTAppRemote? {
        let clientID = settings.effectiveSpotifyClientID
        guard settings.hasValidClientID, let redirect = URL(string: SpotifyAuth.redirectURI) else { return nil }
        if let remote, remoteClientID == clientID { return remote }
        remote?.disconnect()
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirect)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = self
        self.remote = remote
        remoteClientID = clientID
        return remote
    }

    private func connect() async {
        retryTask?.cancel()
        retryTask = nil
        guard wanted, settings.useAppRemote, auth.isLoggedIn else {
            status = .off
            return
        }
        guard auth.hasScope(Self.scope) || wakeToken != nil else {
            if status != .needsLogin { SyncLog.shared.add("remote", "the login lacks \(Self.scope): sign in again") }
            status = .needsLogin
            return
        }
        let token: String
        if let wakeToken {
            token = wakeToken
            self.wakeToken = nil
        } else {
            do {
                token = try await auth.accessToken()
            } catch {
                lastError = error.localizedDescription
                SyncLog.shared.add("remote", "no token: \(error.localizedDescription)")
                scheduleRetry(after: 10)
                return
            }
        }
        guard wanted, let remote = makeRemote() else { return }
        if remote.isConnected { return }
        remote.connectionParameters.accessToken = token
        status = .connecting
        SyncLog.shared.add("remote", "connecting")
        remote.connect()
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.remote?.disconnect()
            self.didDrop(nil, reason: String(localized: "Spotify не ответил за 15 секунд"))
        }
    }

    /// The connection looks alive but Spotify stopped answering truthfully: start over.
    private func reconnect() {
        guard wanted else { return }
        queryTask?.cancel()
        queryTask = nil
        player?.setRemoteConnected(false)
        status = .connecting
        SyncLog.shared.add("remote", "stale, reconnecting")
        remote?.disconnect()
        scheduleRetry(after: 2)
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        guard wanted else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func didConnect() {
        guard let remote, wanted else {
            remote?.disconnect()
            return
        }
        connectTimeout?.cancel()
        connectTimeout = nil
        status = .connected
        failures = 0
        lastError = nil
        // Stayed connected for a while after the last wake: the next refusal starts afresh.
        if Date().timeIntervalSince(lastWake) > 120 { wakes = 0 }
        SyncLog.shared.add("remote", "connected")
        player?.setRemoteConnected(true)
        remote.playerAPI?.delegate = self
        remote.playerAPI?.subscribe(toPlayerState: { _, _ in })
        query()
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.settings.remoteQueryInterval ?? 1.5
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.query()
            }
        }
    }

    private func didDrop(_ error: Error?, reason: String? = nil) {
        queryTask?.cancel()
        queryTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        player?.setRemoteConnected(false)
        let message = reason ?? error.map(Self.describe) ?? "disconnected"
        lastError = message
        SyncLog.shared.add("remote", "no connection: \(message)")
        guard wanted else { return }
        status = .unavailable
        failures += 1
        // Spotify refuses apps it was not woken by (after a restart of this app, an update, or when it was
        // sent to the background): wake it. Only when the song plays on this iPhone: waking Spotify
        // starts playback here, which must never take over a song playing on another device.
        if settings.autoWakeSpotify, player?.isPlayingOnThisPhone == true, wakes < Self.maxWakes,
           Date().timeIntervalSince(lastWake) > Self.wakeCooldown, UIApplication.shared.applicationState == .active {
            wakes += 1
            lastWake = Date()
            SyncLog.shared.add("remote", "refused, waking Spotify (\(wakes)/\(Self.maxWakes))")
            wakeSpotify()
            // If Spotify never hands a token back, try the plain connection again later.
            scheduleRetry(after: 20)
            return
        }
        scheduleRetry(after: min(60, 8 * pow(2, Double(min(failures, 4) - 1))))
    }

    /// The SDK's errors say little on their own; the domain, code and the underlying error tell
    /// "Spotify is not running" from "this app is not allowed".
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    private func query() {
        guard let playerAPI = remote?.playerAPI, remote?.isConnected == true else { return }
        let sentAt = CACurrentMediaTime()
        playerAPI.getPlayerState { [weak self] result, _ in
            let receivedAt = CACurrentMediaTime()
            guard let state = result as? SPTAppRemotePlayerState else { return }
            let sample = Sample(state, at: sentAt + (receivedAt - sentAt) / 2, event: false,
                                roundTrip: receivedAt - sentAt)
            Task { @MainActor in self?.player?.applyRemote(sample) }
        }
    }

    /// The cover straight from the Spotify app (works offline), once per track.
    private func fetchCover(_ track: SPTAppRemoteTrack, uri: String) {
        guard coverURI != uri, let imageAPI = remote?.imageAPI else { return }
        coverURI = uri
        imageAPI.fetchImage(forItem: track, with: CGSize(width: 640, height: 640)) { [weak self] result, _ in
            guard let image = result as? UIImage else { return }
            Task { @MainActor in self?.player?.setRemoteArtwork(image, uri: uri) }
        }
    }

    /// One reading of the Spotify app's player.
    struct Sample: Sendable {
        var uri: String
        var name: String
        var artist: String
        var album: String
        var duration: Double
        /// A song (not a podcast episode or an ad).
        var isTrack: Bool
        /// Seconds, valid at `measuredAt`.
        var position: Double
        var paused: Bool
        var measuredAt: CFTimeInterval
        /// Pushed by Spotify on a change (exact), rather than asked for.
        var event: Bool
        /// Queries: how long the answer took (`measuredAt` is only this exact).
        var roundTrip: Double

        init(_ state: SPTAppRemotePlayerState, at time: CFTimeInterval, event: Bool, roundTrip: Double = 0) {
            uri = state.track.uri
            name = state.track.name
            artist = state.track.artist.name
            album = state.track.album.name
            duration = Double(state.track.duration) / 1000
            isTrack = !state.track.isEpisode && !state.track.isPodcast && !state.track.isAdvertisement
                && uri.hasPrefix("spotify:track:")
            position = Double(state.playbackPosition) / 1000
            paused = state.isPaused
            measuredAt = time
            self.event = event
            self.roundTrip = roundTrip
        }

        /// What App Remote knows of the song, enough for lyrics (the cover comes separately).
        var trackInfo: TrackInfo? {
            guard isTrack, let id = uri.split(separator: ":").last.map(String.init) else { return nil }
            return TrackInfo(id: id, uri: uri, title: name, artists: artist.isEmpty ? [] : [artist], album: album,
                             duration: duration, artworkURL: nil, isLocal: false)
        }
    }
}

extension SpotifyAppRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.didConnect() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let message = error
        Task { @MainActor in self.didDrop(message) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let message = error
        Task { @MainActor in self.didDrop(message) }
    }
}

extension SpotifyAppRemote: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let sample = Sample(playerState, at: CACurrentMediaTime(), event: true)
        nonisolated(unsafe) let track = playerState.track
        Task { @MainActor in
            self.player?.applyRemote(sample)
            self.fetchCover(track, uri: sample.uri)
        }
    }
}

extension SpotifyAppRemote {
    /// The connection state in words, for settings and the sync badge.
    var statusText: String {
        switch status {
        case .off: return String(localized: "Выключено")
        case .needsLogin: return String(localized: "Нужно войти заново")
        case .connecting: return String(localized: "Подключение…")
        case .connected: return String(localized: "Подключено")
        case .unavailable: return String(localized: "Spotify не отвечает")
        }
    }
}
