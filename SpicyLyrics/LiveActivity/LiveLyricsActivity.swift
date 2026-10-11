import ActivityKit
import AVFoundation
import Foundation
import Observation
import UIKit

/// The current lyric line on the lock screen and in the Dynamic Island (a Live Activity).
///
/// The activity only changes when the app updates it, and iOS suspends apps in the background,
/// so while it is on the app keeps itself running with a silent sound mixed with others (it never
/// interrupts Spotify) and keeps following Spotify, as it does for the PiP window. The song's
/// progress bar moves by itself; the line is updated when it changes.
@MainActor
@Observable
final class LiveLyricsActivity {
    private(set) var isRunning = false
    /// Why the activity could not start (shown in settings).
    private(set) var lastError: String?

    /// The app keeps following Spotify in the background while this is true.
    var keepsAppRunning: Bool { isRunning }

    @ObservationIgnored private var activity: Activity<LyricsActivityAttributes>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private let keepAlive = SilentAudio()
    /// What the activity shows right now, to update only on a change.
    @ObservationIgnored private var shownKey: String?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// Lines that can be "the current line" (no interludes or backing vocals), per lyrics revision.
    @ObservationIgnored private var lines: (revision: Int, lines: [PreparedLine])?
    @ObservationIgnored private var tint: (id: String, rgb: [Double])?

    static var areEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func configure(player: PlayerModel, settings: AppSettings) {
        self.player = player
        self.settings = settings
        refresh()
    }

    /// Starts or ends the activity to match the setting. Starting one needs the app on screen;
    /// called again whenever the app becomes active.
    func refresh() {
        guard let settings, let player else { return }
        if settings.liveActivity, player.track != nil || activity != nil {
            start()
        } else if !settings.liveActivity {
            stop()
        }
    }

    private func start() {
        if activity == nil, let existing = Activity<LyricsActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            // One left from the last launch: carry on with it.
            activity = existing
            watch(existing)
        }
        if activity == nil {
            guard UIApplication.shared.applicationState == .active, let state = makeState() else { return }
            guard Self.areEnabled else {
                lastError = String(localized: "Live Activities выключены для Spicy Lyrics в настройках iOS.")
                return
            }
            do {
                let started = try Activity.request(attributes: LyricsActivityAttributes(),
                                                   content: ActivityContent(state: state.content, staleDate: nil),
                                                   pushType: nil)
                activity = started
                shownKey = state.key
                watch(started)
                lastError = nil
                SyncLog.shared.add("activity", "started")
            } catch {
                lastError = error.localizedDescription
                SyncLog.shared.add("activity", "could not start: \(error.localizedDescription)")
                return
            }
        }
        guard !isRunning else { return }
        isRunning = true
        keepAlive.start()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        keepAlive.stop()
        stateTask?.cancel()
        stateTask = nil
        isRunning = false
        shownKey = nil
        activity = nil
        let ending = Activity<LyricsActivityAttributes>.activities
        guard !ending.isEmpty else { return }
        SyncLog.shared.add("activity", "ended")
        Task {
            for activity in ending { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Swiped away on the lock screen (or ended by iOS after its 8 hours): let go until the app
    /// is opened again.
    private func watch(_ activity: Activity<LyricsActivityAttributes>) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                guard let self, self.activity?.id == activity.id else { return }
                SyncLog.shared.add("activity", "closed by the system or the user")
                self.timer?.invalidate()
                self.timer = nil
                self.keepAlive.stop()
                self.isRunning = false
                self.activity = nil
                self.shownKey = nil
                return
            }
        }
    }

    private func tick() {
        guard let activity, let state = makeState(), state.key != shownKey else { return }
        shownKey = state.key
        Task { await activity.update(ActivityContent(state: state.content, staleDate: nil)) }
    }

    // MARK: What it shows

    private struct Shown {
        var content: LyricsActivityAttributes.ContentState
        /// Changes only when what is shown should (not with every tick of the clock).
        var key: String
    }

    private func makeState() -> Shown? {
        guard let player, let settings else { return nil }
        let title: String
        let artist: String
        switch player.content {
        case .track(let track): title = track.title; artist = track.artistLine
        case .episode(let name, let show, _): title = name; artist = show
        case .ad: title = String(localized: "Реклама"); artist = ""
        case .unknown, .none: title = "Spicy Lyrics"; artist = ""
        }
        let position = player.position()
        var line = "♪"
        var next: String?
        var translation: String?
        var index = -1
        if case .loaded(let lyrics) = player.lyricsState, lyrics.kind != .static {
            let lines = currentLines(player.lyricsRevision, lyrics)
            index = Self.index(in: lines, at: position)
            if index >= 0 {
                let current = lines[index]
                // Long after a line ended and well before the next one: an instrumental break.
                let nextStart = index + 1 < lines.count ? lines[index + 1].start : .infinity
                if position > current.end + 2, nextStart - position > 2 {
                    index = -2 - index
                } else {
                    line = current.plainText
                    if settings.translateLyrics, !settings.translationReplaces, settings.liveActivityTranslation {
                        translation = player.translations[current.sourceText]
                    }
                }
            }
            let nextIndex = index >= 0 ? index + 1 : (index == -1 ? 0 : -index - 1)
            if settings.liveActivityNextLine, lines.indices.contains(nextIndex) { next = lines[nextIndex].plainText }
        }
        let duration = player.track?.duration ?? 0
        let played = player.playbackPosition()
        let songStart = Date().addingTimeInterval(-played)
        let state = LyricsActivityAttributes.ContentState(
            title: title, artist: artist, line: line, translation: translation, next: next,
            isPlaying: player.isPlaying, songStart: songStart, songEnd: songStart.addingTimeInterval(max(duration, 1)),
            progress: duration > 0 ? played / duration : 0, tint: tintColor(player))
        // A seek or a resync (`snapToken`) moves the progress bar's dates; a new cover, its colour.
        let key = "\(player.track?.uri ?? title)|\(index)|\(player.isPlaying)|\(translation ?? "")|\(next ?? "")|\(player.snapToken)|\(tint?.id ?? "")"
        return Shown(content: state, key: key)
    }

    private func currentLines(_ revision: Int, _ lyrics: PreparedLyrics) -> [PreparedLine] {
        if let lines, lines.revision == revision { return lines.lines }
        let filtered = lyrics.lines.filter { !$0.isInterlude && !$0.isBackground }
        lines = (revision, filtered)
        return filtered
    }

    /// The last line that has started at `time`, or -1.
    private static func index(in lines: [PreparedLine], at time: Double) -> Int {
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// The cover's most vivid colour, worked out once per cover.
    private func tintColor(_ player: PlayerModel) -> [Double] {
        let id = player.artworkID
        if let tint, tint.id == id { return tint.rgb }
        guard let image = player.backgroundArtwork else { return [1, 1, 1] }
        let vivid = CoverPalette.of(image).vivid
        let rgb = [Double(vivid.x), Double(vivid.y), Double(vivid.z)]
        tint = (id, rgb)
        return rgb
    }
}

/// A looping silent sound, mixed with other audio: while it plays, iOS keeps the app running in
/// the background (the app already declares background audio for Picture in Picture).
private final class SilentAudio {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        AudioRoute.prepare()
        guard let player = try? AVAudioPlayer(data: Self.silence) else { return }
        player.numberOfLoops = -1
        player.play()
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// One second of 8 kHz, 8-bit mono silence as a WAV file.
    private static let silence: Data = {
        let samples = 8000
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + samples)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(8000); append32(8000); append16(1); append16(8)
        append("data"); append32(UInt32(samples))
        data.append(contentsOf: [UInt8](repeating: 128, count: samples))
        return data
    }()
}
