#if DEBUG
import Foundation

/// For the README's screen recordings (Debug builds only): plays one song's lyrics on a local
/// clock, with no Spotify account, app or sound involved. Launch arguments:
///
///     -demoTrack <Spotify track ID> -demoTitle <title> -demoArtist <artist>
///     -demoArtwork <cover URL> -demoStart <seconds> -demoDuration <seconds>
///
/// `-demoLandscape YES` turns the screen sideways, `-demoSettings YES` opens Settings,
/// `-demoPiP YES` opens the floating window, `-demoHideChrome YES` starts with only the lyrics. App
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
#endif
