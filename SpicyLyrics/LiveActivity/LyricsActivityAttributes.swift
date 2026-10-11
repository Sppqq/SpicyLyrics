import ActivityKit
import Foundation

/// The lyrics Live Activity (lock screen and Dynamic Island). Shared by the app, which starts and
/// updates it, and the widget extension, which draws it.
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        /// The line being sung (or the one just sung); "♪" between lines and without lyrics.
        var line: String
        var translation: String?
        var next: String?
        var isPlaying: Bool
        /// While playing, the song runs from `songStart` to `songEnd`: the system moves the
        /// progress bar by itself between updates.
        var songStart: Date
        var songEnd: Date
        /// Paused: how far into the song, 0…1.
        var progress: Double
        /// The cover's main colour, red / green / blue in 0…1.
        var tint: [Double]
    }
}
