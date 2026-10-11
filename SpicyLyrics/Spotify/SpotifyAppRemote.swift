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

    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private var remote: SPTAppRemote?
    @ObservationIgnored private var remoteClientID: String?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    /// Token handed back by Spotify after "wake Spotify", used for the next connection.
    @ObservationIgnored private var wakeToken: String?
    @ObservationIgnored private var coverURI: String?

    static let scope = "app-remote-control"

    init(auth: SpotifyAuth, settings: AppSettings) {
        self.auth = auth
        self.settings = settings
    }

    /// Starts following the Spotify app (while the app follows Spotify at all).
    func start(player: PlayerModel) {
        self.player = player
        wanted = true
        if remote?.isConnected != true { Task { await connect() } }
    }

    func stop() {
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        queryTask?.cancel()
        queryTask = nil
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
        guard let remote = makeRemote() else { return }
        remote.authorizeAndPlayURI("") { [weak self] success in
            Task { @MainActor in
                if !success { self?.status = .unavailable }
            }
        }
    }

    /// The `spicylyrics-ios://callback` URL Spotify opens after `wakeSpotify()`.
    func handle(_ url: URL) {
        guard let parameters = remote?.authorizationParameters(from: url) else { return }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            wakeToken = token
            Task { await connect() }
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
            status = .needsLogin
            return
        }
        let token: String
        if let wakeToken {
            token = wakeToken
            self.wakeToken = nil
        } else {
            guard let fresh = try? await auth.accessToken() else {
                scheduleRetry(after: 10)
                return
            }
            token = fresh
        }
        guard wanted, let remote = makeRemote() else { return }
        if remote.isConnected { return }
        remote.connectionParameters.accessToken = token
        status = .connecting
        SyncLog.shared.add("remote", "connecting")
        remote.connect()
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
        status = .connected
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

    private func didDrop(_ error: Error?) {
        queryTask?.cancel()
        queryTask = nil
        player?.setRemoteConnected(false)
        SyncLog.shared.add("remote", "no connection: \(error?.localizedDescription ?? "disconnected")")
        guard wanted else { return }
        status = .unavailable
        scheduleRetry(after: 8)
    }

    private func query() {
        guard let playerAPI = remote?.playerAPI, remote?.isConnected == true else { return }
        let sentAt = CACurrentMediaTime()
        playerAPI.getPlayerState { [weak self] result, _ in
            let receivedAt = CACurrentMediaTime()
            guard let state = result as? SPTAppRemotePlayerState else { return }
            let sample = Sample(state, at: sentAt + (receivedAt - sentAt) / 2, event: false)
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

        init(_ state: SPTAppRemotePlayerState, at time: CFTimeInterval, event: Bool) {
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
