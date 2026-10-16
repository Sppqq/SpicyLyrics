import Foundation
import MediaPlayer
import Observation
import UIKit
import CryptoKit

/// The public system player exposes Music only, never another app's Now Playing state.
@MainActor
@Observable
final class AppleMusicPlayer {
    struct Sample {
        let track: TrackInfo?
        let position: Double
        let paused: Bool
        let measuredAt: CFTimeInterval
    }

    private(set) var authorization = MPMediaLibrary.authorizationStatus()
    @ObservationIgnored private let player = MPMusicPlayerController.systemMusicPlayer
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var artworkReady = false
    @ObservationIgnored private var lastArtworkAttemptAt: CFTimeInterval = -.infinity
    @ObservationIgnored var onSample: ((Sample) -> Void)?
    @ObservationIgnored var onArtwork: ((UIImage, String) -> Void)?

    func requestAuthorization() async {
        authorization = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        if pollTask != nil { read() }
    }

    func start() {
        guard pollTask == nil else { read(); return }
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            })
        }
        player.beginGeneratingPlaybackNotifications()
        read()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let milliseconds = self?.player.playbackState == .playing ? 750 : 2000
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard !Task.isCancelled, let self else { return }
                self.read()
            }
        }
    }

    func stop() {
        let wasStarted = pollTask != nil
        pollTask?.cancel()
        pollTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if wasStarted { player.endGeneratingPlaybackNotifications() }
        resetArtwork()
    }

    func read() {
        authorization = MPMediaLibrary.authorizationStatus()
        guard authorization == .authorized else {
            resetArtwork()
            onSample?(Sample(track: nil, position: 0, paused: true, measuredAt: MediaClock.now()))
            return
        }
        let item = player.nowPlayingItem
        let position = player.currentPlaybackTime
        let measuredAt = MediaClock.now()
        let paused = player.playbackState != .playing
        guard let item else {
            resetArtwork()
            onSample?(Sample(track: nil, position: 0, paused: true, measuredAt: measuredAt))
            return
        }
        let storeID = item.playbackStoreID
        let identity: String
        if !storeID.isEmpty, storeID != "0" {
            identity = storeID
        } else if item.persistentID != 0 {
            identity = "local:\(item.persistentID)"
        } else {
            let metadata = "\(item.title ?? "")|\(item.artist ?? "")|\(item.albumTitle ?? "")|\(item.playbackDuration)"
            identity = "metadata:" + SHA256.hash(data: Data(metadata.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let id = "am:" + identity
        let track = TrackInfo(id: id, uri: "music:", title: item.title ?? "", artists: [item.artist ?? ""],
                              album: item.albumTitle ?? "", duration: max(0, item.playbackDuration),
                              artworkURL: nil, isLocal: false)
        onSample?(Sample(track: track, position: position.isFinite ? max(0, position) : 0,
                         paused: paused, measuredAt: measuredAt))
        guard artworkTrackID != id || (!artworkReady && measuredAt - lastArtworkAttemptAt >= 10) else { return }
        artworkTrackID = id
        artworkReady = false
        lastArtworkAttemptAt = measuredAt
        artworkTask?.cancel()
        if let image = item.artwork?.image(at: CGSize(width: 600, height: 600)) {
            artworkReady = true
            onArtwork?(image, id)
        } else if !storeID.isEmpty, storeID != "0", storeID.allSatisfy({ $0.isNumber }) {
            artworkTask = Task { [weak self] in
                guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(storeID)"),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = root["results"] as? [[String: Any]],
                      let cover = results.first?["artworkUrl100"] as? String,
                      let coverURL = URL(string: cover.replacingOccurrences(of: "100x100", with: "600x600")),
                      let imageData = try? await URLSession.shared.data(from: coverURL).0,
                      let image = UIImage(data: imageData), !Task.isCancelled,
                      let self, self.artworkTrackID == id else { return }
                self.artworkReady = true
                self.onArtwork?(image, id)
            }
        }
    }

    func togglePlay() {
        guard authorization == .authorized else { return }
        if player.playbackState == .playing { player.pause() } else { player.play() }
        read()
    }

    private func resetArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkTrackID = nil
        artworkReady = false
        lastArtworkAttemptAt = -.infinity
    }

    func next() {
        guard authorization == .authorized else { return }
        player.skipToNextItem()
        read()
    }

    func previous() {
        guard authorization == .authorized else { return }
        player.skipToPreviousItem()
        read()
    }
    func seek(to seconds: Double) {
        guard authorization == .authorized else { return }
        player.currentPlaybackTime = seconds
        read()
    }
}
