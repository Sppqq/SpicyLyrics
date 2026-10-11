import Foundation
import Observation
import QuartzCore
import UIKit

/// Follows what Spotify is playing and keeps a smooth local clock between polls.
@MainActor
@Observable
final class PlayerModel {
    enum LyricsState: Equatable {
        case idle
        case loading
        case loaded(PreparedLyrics)
        case notFound
        case unavailable(String)
        case failed(String)
    }

    private(set) var content: PlaybackSnapshot.Content?
    private(set) var isPlaying = false
    private(set) var artwork: UIImage?
    /// Small copy of the artwork for the animated background.
    private(set) var backgroundArtwork: UIImage?
    private(set) var artworkID = ""
    /// Bumped whenever new lyrics are shown, so the lyrics view starts fresh.
    private(set) var lyricsRevision = 0
    private(set) var lyricsState: LyricsState = .idle
    private(set) var statusMessage: String?

    enum AccessProblem: Equatable {
        /// The account isn't on the Client ID's allowlist.
        case notRegistered
        case quotaExceeded
    }
    /// Why Spotify refuses this account, when the fix is the user's own Client ID.
    private(set) var accessProblem: AccessProblem?
    /// Album / playlist Spotify is playing from, used to keep context when picking a track.
    private(set) var contextURI: String?
    private(set) var deviceName: String?
    var transientError: String?

    var track: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    @ObservationIgnored private let api: SpotifyAPI
    @ObservationIgnored private let lyrics: LyricsService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var rawLyrics: LyricsDocument?
    @ObservationIgnored private var preparedRomanized = false
    @ObservationIgnored private var preparedSimple = false
    /// Translations the shown lyrics were built with (replace mode), to rebuild only on change.
    @ObservationIgnored private var preparedReplacements: [String: String] = [:]
    /// Changes only when different lyrics arrive; translations belong to one revision of these.
    private(set) var documentRevision = 0
    @ObservationIgnored private var lastArtworkURL: URL?

    // Clock anchor: position `anchorPosition` was correct at `anchorTime`. `slew` is a small
    // correction blended in over `slewDuration`, so the clock never visibly jumps or runs backwards.
    @ObservationIgnored private var anchorPosition: Double = 0
    @ObservationIgnored private var anchorTime: CFTimeInterval = CACurrentMediaTime()
    @ObservationIgnored private var slew: Double = 0
    @ObservationIgnored private var slewSpan: Double = 0.8
    /// The previous report, to tell a live position from a frozen one.
    @ObservationIgnored private var lastSample: (progress: Double, measuredAt: CFTimeInterval, stamp: Double?)?
    /// Spotify only updates this device's position on play / pause / seek (its phone app does
    /// this): between those, `progress_ms` stays put and must not be read as a pause.
    @ObservationIgnored private var frozenReports = false
    /// Consecutive live reports far behind our clock (a seek back on another device).
    @ObservationIgnored private var behindStreak = 0
    @ObservationIgnored private var holdUntil: CFTimeInterval = 0
    @ObservationIgnored private var backoffUntil: CFTimeInterval = 0

    private static let slewDuration: Double = 0.8
    /// Being behind Spotify by more than this jumps instead of catching up smoothly.
    private static let resyncThreshold: Double = 1.0
    /// Being behind by less than this is noise.
    private static let catchUpThreshold: Double = 0.12
    /// A live report this far behind us, twice in a row, is a seek back elsewhere.
    private static let seekBackThreshold: Double = 2.5

    /// The user's saved TTML files.
    @ObservationIgnored let localLyrics: LocalLyricsStore
    /// TTML applied "just once": kept for its track until the app quits.
    @ObservationIgnored private var temporaryLyrics: [String: LyricsDocument] = [:]

    init(api: SpotifyAPI, lyrics: LyricsService, settings: AppSettings, localLyrics: LocalLyricsStore) {
        self.api = api
        self.lyrics = lyrics
        self.settings = settings
        self.localLyrics = localLyrics
    }

    // MARK: Clock

    /// Lyrics clock in seconds at media time `now`: playback position plus the user's offset,
    /// minus the audio output's delay when Spotify plays on this phone (Bluetooth headphones).
    func position(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        let latency = settings.compensateOutputLatency && playingOnThisPhone ? outputLatency : 0
        return playbackPosition(at: now) + settings.timingOffsetMs / 1000 - latency
    }

    /// True from (re)starting the poll until Spotify has answered: what is on screen may be an
    /// old track (the app was in the background while the song changed).
    private(set) var isResyncing = false
    /// On-device translations of the current lyrics, keyed by the original line text.
    private(set) var translations: [String: String] = [:]
    @ObservationIgnored private var outputLatency: Double = 0
    @ObservationIgnored private var playingOnThisPhone = false

    /// Spotify's playback position in seconds at media time `now`.
    func playbackPosition(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        let duration = track?.duration ?? .infinity
        return min(max(0, rawPosition(at: now)), duration)
    }

    private func rawPosition(at now: CFTimeInterval) -> Double {
        guard isPlaying else { return anchorPosition }
        let elapsed = max(0, now - anchorTime)
        return anchorPosition + elapsed + slew * min(1, elapsed / slewSpan)
    }

    /// Re-anchors the clock at `position` right now, dropping any pending correction.
    private func setClock(_ position: Double, at now: CFTimeInterval = CACurrentMediaTime()) {
        anchorPosition = position
        anchorTime = now
        slew = 0
        behindStreak = 0
    }

    /// Blends the clock toward `target` over a short span instead of jumping (a jump back would
    /// re-light sung words, a jump forward skips them).
    private func blend(to target: Double, predicted: Double, now: CFTimeInterval) {
        anchorPosition = predicted
        anchorTime = now
        slew = target - predicted
        // At most ±50 % speed while correcting, so the clock never stalls or runs backwards.
        slewSpan = max(Self.slewDuration, abs(slew) * 2)
    }

    private func apply(_ snapshot: PlaybackSnapshot?) {
        guard let snapshot else {
            // No active device. Keep the last track on screen, just stop the clock.
            if isPlaying {
                setClock(rawPosition(at: CACurrentMediaTime()))
                isPlaying = false
            }
            lastSample = nil
            statusMessage = String(localized: "Сейчас ничего не играет в Spotify")
            return
        }
        statusMessage = nil
        contextURI = snapshot.contextURI
        deviceName = snapshot.deviceName
        // A "Smartphone" device is (almost always) this iPhone: its audio route delay applies.
        playingOnThisPhone = snapshot.deviceType?.lowercased() == "smartphone"
        outputLatency = AudioRoute.outputLatency

        let now = CACurrentMediaTime()
        let trackChanged = content != snapshot.content
        // Right after a control action, polls may still describe the old state.
        if now < holdUntil && !trackChanged { return }

        // Live or frozen? A playing position that did not move between two reports is frozen:
        // Spotify only refreshes it on play / pause / seek for some devices (its phone app).
        var stampChanged = false
        if let last = lastSample, !trackChanged, snapshot.isPlaying, isPlaying {
            if snapshot.measuredAt - last.measuredAt > 0.8 {
                frozenReports = abs(snapshot.progress - last.progress) < 0.15
            }
            stampChanged = snapshot.stateChangedAt != nil && snapshot.stateChangedAt != last.stamp
        } else if trackChanged {
            frozenReports = false
        }
        lastSample = (snapshot.progress, snapshot.measuredAt, snapshot.stateChangedAt)

        let measured = snapshot.progress + (snapshot.isPlaying ? now - snapshot.measuredAt : 0)
        // On a frozen device `progress_ms` is the position at `timestamp` (the last state change).
        var stampEstimate: Double?
        if frozenReports, snapshot.isPlaying, let stamp = snapshot.stateChangedAt {
            let estimate = snapshot.progress + (Date().timeIntervalSince1970 - stamp)
            if estimate >= snapshot.progress, estimate <= (track?.duration ?? .infinity) + 1 {
                stampEstimate = estimate
            }
        }

        let stateChanged = isPlaying != snapshot.isPlaying
        let predicted = rawPosition(at: now)
        // Part of the previous correction not blended in yet: the clock is already heading there.
        let unapplied = isPlaying ? slew * (1 - min(1, max(0, now - anchorTime) / slewSpan)) : 0
        let target = predicted + unapplied

        if trackChanged || stateChanged || !snapshot.isPlaying || isResyncing {
            // Play, pause, a new song or the first report after the background: Spotify's
            // position is exact at these moments.
            setClock(measured, at: now)
        } else if frozenReports {
            // Keep our own clock; the frozen value only says where the last change happened.
            if stampChanged, let stampEstimate {
                setClock(stampEstimate, at: now) // a seek elsewhere
            } else if let stampEstimate, stampEstimate - target > Self.catchUpThreshold {
                // Opened mid-song, the first report was the stale frozen value: catch up.
                if stampEstimate - target > Self.resyncThreshold {
                    setClock(stampEstimate, at: now)
                } else {
                    blend(to: stampEstimate, predicted: predicted, now: now)
                }
            }
        } else {
            // Spotify's position can only be late (a stale or cached answer), never early. So a
            // report ahead of us means we are behind; one behind us is old news, unless it is far
            // behind twice in a row (a seek back on another device).
            let drift = measured - target
            if drift > Self.resyncThreshold {
                setClock(measured, at: now)
            } else if drift > Self.catchUpThreshold {
                blend(to: measured, predicted: predicted, now: now)
                behindStreak = 0
            } else if drift < -Self.seekBackThreshold {
                behindStreak += 1
                if behindStreak >= 2 { setClock(measured, at: now) }
            } else {
                behindStreak = 0
            }
        }

        if stateChanged { isPlaying = snapshot.isPlaying }
        if trackChanged {
            content = snapshot.content
            onContentChanged()
        }
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        // Coming back from the background: the song may have changed meanwhile.
        if content != nil { isResyncing = true }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Returns how long to wait before the next poll.
    private func pollOnce() async -> Double {
        let now = CACurrentMediaTime()
        if now < backoffUntil { return backoffUntil - now }
        do {
            apply(try await api.playbackState())
            accessProblem = nil
            isResyncing = false
            return nextPollInterval()
        } catch SpotifyAPIError.rateLimited(let retryAfter) {
            backoffUntil = now + retryAfter
            return retryAfter
        } catch SpotifyAPIError.quotaExceeded(let retryAfter) {
            accessProblem = .quotaExceeded
            statusMessage = SpotifyAPIError.quotaExceeded(retryAfter: retryAfter).errorDescription
            backoffUntil = now + retryAfter
            return retryAfter
        } catch SpotifyAPIError.userNotRegistered {
            accessProblem = .notRegistered
            statusMessage = SpotifyAPIError.userNotRegistered.errorDescription
            return 15
        } catch SpotifyAuthError.notLoggedIn {
            statusMessage = SpotifyAuthError.notLoggedIn.errorDescription
            return 5
        } catch is CancellationError {
            return 1
        } catch {
            statusMessage = error.localizedDescription
            // Right after returning to the app the first request often hits a stale connection:
            // retry quickly instead of showing the old track for seconds.
            return isResyncing ? 0.6 : 4
        }
    }

    /// The local clock carries the position between polls, so Spotify is asked every 2 s while
    /// playing (the quota is shared by everyone on a Client ID) and sooner near the end of a track,
    /// so the next song is picked up promptly.
    private func nextPollInterval() -> Double {
        guard isPlaying else { return 3 }
        if let duration = track?.duration, duration > 0 {
            let remaining = duration - playbackPosition()
            if remaining > 0, remaining < 2 { return max(0.5, remaining + 0.3) }
        }
        return 2
    }

    func refreshNow() {
        Task { _ = await pollOnce() }
    }

    // MARK: Controls

    func togglePlay() {
        let wasPlaying = isPlaying
        control({ [api] in
            if wasPlaying { try await api.pause() } else { try await api.play() }
        }, optimistic: { [weak self] in
            guard let self else { return }
            self.setClock(self.rawPosition(at: CACurrentMediaTime()))
            self.isPlaying = !wasPlaying
        })
    }

    func next() { control({ [api] in try await api.next() }) }
    func previous() { control({ [api] in try await api.previous() }) }

    func seek(to seconds: Double) {
        control({ [api] in try await api.seek(to: seconds) }, optimistic: { [weak self] in
            self?.setClock(seconds)
        })
    }

    /// Jumps to an upcoming track by skipping everything queued before it.
    func skipAhead(_ count: Int) {
        guard count > 0 else { return }
        control({ [api] in
            for index in 0..<count {
                if index > 0 { try await Task.sleep(for: .milliseconds(150)) }
                try await api.next()
            }
        })
    }

    /// Plays `track`, continuing with the album or playlist it came from when there is one.
    func play(_ track: TrackSummary, context: String?) {
        let contexts = [context, track.albumURI].compactMap { $0 }.filter(Self.supportsOffset)
        control({ [api] in
            for contextURI in contexts {
                do {
                    try await api.play(trackURI: track.uri, inContext: contextURI)
                    return
                } catch SpotifyAPIError.http(let status, _) where status == 400 || status == 404 {
                    continue // The track isn't part of that context (or it is gone); try the next.
                }
            }
            try await api.play(uris: [track.uri])
        })
    }

    func addToQueue(_ track: TrackSummary) {
        Task {
            do {
                try await api.addToQueue(track.uri)
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    func upcomingTracks() async throws -> [TrackSummary] { try await api.queue() }
    func recentTracks() async throws -> [TrackSummary] { try await api.recentlyPlayed() }
    func searchTracks(_ query: String, offset: Int) async throws -> [TrackSummary] {
        try await api.search(query, offset: offset)
    }

    /// Only albums and playlists accept a starting track (`offset`).
    private static func supportsOffset(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:album:") || uri.hasPrefix("spotify:playlist:")
    }

    private func control(_ action: @escaping () async throws -> Void, optimistic: (() -> Void)? = nil) {
        optimistic?()
        // Ignore stale polls for a moment so the optimistic state isn't undone.
        holdUntil = CACurrentMediaTime() + 1.5
        Task {
            do {
                try await action()
                try? await Task.sleep(for: .milliseconds(400))
            } catch {
                transientError = error.localizedDescription
            }
            holdUntil = 0
            _ = await pollOnce()
        }
    }

    // MARK: Lyrics & artwork

    private func onContentChanged() {
        translations = [:]
        lyricsTask?.cancel()
        lyricsTask = nil
        rawLyrics = nil
        switch content {
        case .track:
            loadLyrics(force: false)
        case .episode:
            lyricsState = .unavailable(String(localized: "Для подкастов тексты недоступны"))
        case .ad:
            lyricsState = .unavailable(String(localized: "Реклама"))
        case .unknown:
            lyricsState = .unavailable(String(localized: "Не удалось распознать трек"))
        case .none:
            lyricsState = .idle
        }
        loadArtwork()
    }

    func loadLyrics(force: Bool) {
        guard let track else { return }
        if let temporary = temporaryLyrics[track.id] {
            show(temporary)
            return
        }
        lyricsTask?.cancel()
        lyricsState = .loading
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyrics.lyrics(for: track, ignoreCache: force)
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            self.lyricsTask = nil
            switch result {
            case .found(let document):
                self.show(document)
            case .notFound:
                self.lyricsState = .notFound
            case .failed(let reason):
                if reason != "cancelled" { self.lyricsState = .failed(reason) }
            }
        }
    }

    func setTranslations(_ result: [String: String], revision: Int) {
        guard revision == documentRevision, result != translations else { return }
        translations = result
        settingsChanged()
    }

    /// What replaces the original lines right now (translation in replace mode).
    private var replacements: [String: String] {
        settings.translateLyrics && settings.translationReplaces ? translations : [:]
    }

    func clearLyricsCache() {
        lyrics.clearCache()
    }

    // MARK: Own TTML

    enum TTMLMode: String, CaseIterable {
        /// Saved in the library: used for this track from now on.
        case library
        /// Only until the app quits (the extension's "Just once").
        case temporary
    }

    enum TTMLError: LocalizedError {
        case noTrack
        var errorDescription: String? { String(localized: "Сейчас не играет трек Spotify, к которому можно привязать текст.") }
    }

    var hasTemporaryLyrics: Bool { track.map { temporaryLyrics[$0.id] != nil } ?? false }

    /// Parses a TTML and shows it for the current track, saving it to the library if asked.
    func applyTTML(_ text: String, mode: TTMLMode) throws {
        guard let track else { throw TTMLError.noTrack }
        let document: LyricsDocument
        switch mode {
        case .library:
            document = try localLyrics.save(text, for: track)
            temporaryLyrics[track.id] = nil
        case .temporary:
            document = try TTMLParser.parse(text, sourceName: "Local TTML (temporary)")
            temporaryLyrics[track.id] = document
        }
        show(document)
    }

    /// Removes a track's own lyrics (saved and temporary) and reloads if it is playing.
    func removeOwnLyrics(trackID: String) {
        localLyrics.remove(trackID)
        temporaryLyrics[trackID] = nil
        if track?.id == trackID { loadLyrics(force: false) }
    }

    private func show(_ document: LyricsDocument) {
        lyricsTask?.cancel()
        lyricsTask = nil
        rawLyrics = document
        translations = [:]
        documentRevision += 1
        prepare(document)
    }

    private func prepare(_ document: LyricsDocument) {
        preparedRomanized = settings.showRomanization
        preparedSimple = settings.simpleLyricsMode
        preparedReplacements = replacements
        lyricsRevision += 1
        lyricsState = .loaded(PreparedLyrics(document: document, romanized: preparedRomanized,
                                             simple: preparedSimple, replacements: preparedReplacements))
    }

    /// Re-prepares the current lyrics after a display setting (or a replacing translation) changed.
    func settingsChanged() {
        guard let rawLyrics,
              preparedRomanized != settings.showRomanization || preparedSimple != settings.simpleLyricsMode
                || preparedReplacements != replacements
        else { return }
        prepare(rawLyrics)
    }

    private func loadArtwork() {
        let url: URL?
        switch content {
        case .track(let track): url = track.artworkURL
        case .episode(_, _, let artworkURL): url = artworkURL
        default: url = nil
        }
        guard url != lastArtworkURL else { return }
        lastArtworkURL = url
        artworkTask?.cancel()
        guard let url else {
            artwork = nil
            backgroundArtwork = nil
            artworkID = ""
            return
        }
        artworkTask = Task { [weak self] in
            guard let response = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: response.0),
                  !Task.isCancelled,
                  let self
            else { return }
            self.artwork = image
            self.backgroundArtwork = image.downscaled(to: 160)
            self.artworkID = url.absoluteString
        }
    }
}
