#if DEBUG
import Foundation

/// For the README's screen recordings (Debug builds only): plays one song's lyrics on a local
/// clock, with no Spotify account, app or sound involved. Launch arguments:
///
///     -demoTrack <Spotify track ID> -demoTitle <title> -demoArtist <artist>
///     -demoArtwork <cover URL> -demoStart <seconds> -demoDuration <seconds>
///
/// `-demoLandscape YES` turns the screen sideways, `-demoSettings YES` opens Settings,
/// `-demoPiP YES` opens the floating window, `-demoQueue YES` opens the queue with sample tracks, `-demoHideChrome YES` starts with only the lyrics. App
/// settings can be set the same way (`-simpleLyricsMode YES`): launch arguments override
/// UserDefaults.
struct DemoTrack {
    let info: TrackInfo
    let start: Double

    static let current: DemoTrack? = {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: "demoTrack"), !id.isEmpty else { return nil }
        let info = TrackInfo(
            id: id,
            uri: "spotify:track:\(id)",
            title: defaults.string(forKey: "demoTitle") ?? "Spicy Lyrics",
            artists: defaults.string(forKey: "demoArtist").map { [$0] } ?? [],
            album: "",
            duration: defaults.object(forKey: "demoDuration") != nil ? defaults.double(forKey: "demoDuration") : 240,
            artworkURL: defaults.string(forKey: "demoArtwork").flatMap(URL.init(string:)),
            isLocal: false
        )
        return DemoTrack(info: info, start: defaults.double(forKey: "demoStart"))
    }()
}

/// Sample "up next" list for the queue screenshot (no Spotify account in the Simulator).
enum DemoQueue {
    private static let cdn = "https://image-cdn-fa.spotifycdn.com/image/ab67616d00004851"
    private static func track(_ index: Int, _ id: String, _ title: String, _ artist: String, _ cover: String, _ seconds: Double) -> TrackSummary {
        TrackSummary(id: "demo\(index)", uri: "spotify:track:\(id)", title: title, artists: [artist], albumURI: nil,
                     duration: seconds, thumbnailURL: URL(string: cdn + cover), contextURI: nil)
    }

    static let tracks: [TrackSummary] = [
        track(0, "2E6DVdvabtPxTZmUljxytZ", "Mesmerizer", "Bao The Whale, Neuro-sama", "7c65e4c82b767a49bef9e27a", 160),
        track(1, "2kPuQ8BYGdJglM9aFX9pA0", "sleep mode", "KIDSCRY2DAY", "83e0e28d498b56018c783178", 160),
        track(2, "5anhQfzFw43g2yHDJ8tk8m", "I Wanna Be Honest", "PureSnow, Beverly", "8f1ba7258f434ce2423c0cfc", 172),
        track(3, "2eKkLkQcKRINUndAxUdGkH", "The Code", "Nemo", "08d1437f035253a0a65c868f", 180),
    ]
}
#endif
