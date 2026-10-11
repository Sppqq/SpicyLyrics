import Foundation
import Observation
import SwiftUI

/// User preferences, persisted in UserDefaults. The Spicy Lyrics key lives here too: it is a
/// public client key (`sl_pk_…`), not a secret.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// The user's own Client ID (from their own Spotify developer app). Required: none is built in.
    var spotifyClientID: String { didSet { defaults.set(spotifyClientID, forKey: Keys.clientID) } }
    var spicyLyricsKey: String { didSet { defaults.set(spicyLyricsKey, forKey: Keys.spicyKey) } }
    /// Shifts lyrics against the playback clock, in milliseconds. Positive = lyrics earlier.
    var timingOffsetMs: Double { didSet { defaults.set(timingOffsetMs, forKey: Keys.offset) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    var blurInactiveLines: Bool { didSet { defaults.set(blurInactiveLines, forKey: Keys.blur) } }
    var dynamicBackground: Bool { didSet { defaults.set(dynamicBackground, forKey: Keys.background) } }
    var showRomanization: Bool { didSet { defaults.set(showRomanization, forKey: Keys.romanization) } }
    var useLRCLibFallback: Bool { didSet { defaults.set(useLRCLibFallback, forKey: Keys.lrclib) } }
    var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: Keys.keepScreenOn) } }
    /// Fade the header and controls out while lyrics play, like Apple Music.
    var autoHideControls: Bool { didSet { defaults.set(autoHideControls, forKey: Keys.autoHide) } }
    /// Subtract the audio output delay (Bluetooth) when Spotify plays on this iPhone.
    var compensateOutputLatency: Bool { didSet { defaults.set(compensateOutputLatency, forKey: Keys.outputLatency) } }
    /// Read the position from the Spotify app on this phone (App Remote) when it is reachable.
    var useAppRemote: Bool { didSet { defaults.set(useAppRemote, forKey: Keys.appRemote) } }
    /// Seconds between Web API polls while playing (when App Remote is not keeping time).
    var webPollInterval: Double { didSet { defaults.set(webPollInterval, forKey: Keys.webPollInterval) } }
    /// Seconds between App Remote position queries.
    var remoteQueryInterval: Double { didSet { defaults.set(remoteQueryInterval, forKey: Keys.remoteQueryInterval) } }
    /// Keep the sync log (Settings → Sync log).
    var syncLogEnabled: Bool { didSet { defaults.set(syncLogEnabled, forKey: Keys.syncLog) } }
    /// Small badge over the lyrics: where the time came from and how far off it was.
    var showSyncIndicator: Bool { didSet { defaults.set(showSyncIndicator, forKey: Keys.syncIndicator) } }
    // Picture in Picture look.
    var pipTextScale: Double { didSet { defaults.set(pipTextScale, forKey: Keys.pipTextScale) } }
    var pipBackgroundDim: Double { didSet { defaults.set(pipBackgroundDim, forKey: Keys.pipBackgroundDim) } }
    var pipFrameRate: Double { didSet { defaults.set(pipFrameRate, forKey: Keys.pipFrameRate) } }
    var pipShowTranslation: Bool { didSet { defaults.set(pipShowTranslation, forKey: Keys.pipShowTranslation) } }
    var pipBlurLines: Bool { didSet { defaults.set(pipBlurLines, forKey: Keys.pipBlurLines) } }
    /// Translate the lyrics on the device and show the translation under each line.
    var translateLyrics: Bool { didSet { defaults.set(translateLyrics, forKey: Keys.translate) } }
    var translationLanguage: String { didSet { defaults.set(translationLanguage, forKey: Keys.translationLanguage) } }
    /// `TranslationProvider.rawValue`: where translations come from.
    var translationProvider: String { didSet { defaults.set(translationProvider, forKey: Keys.translationProvider) } }
    /// The user's own DeepL API key (kept in the Keychain).
    var deeplKey: String {
        didSet {
            let key = deeplKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { Keychain.delete(Self.deeplKeychainKey) } else { Keychain.write(Self.deeplKeychainKey, data: Data(key.utf8)) }
        }
    }
    /// Interface language: "system", "en" or "ru". Applied through `AppleLanguages` on the next launch.
    var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Keys.appLanguage)
            Self.applyLanguage(appLanguage)
        }
    }
    /// Show the translation instead of the original line (re-timed), not under it.
    var translationReplaces: Bool { didSet { defaults.set(translationReplaces, forKey: Keys.translationReplaces) } }
    /// Open the floating lyrics window when leaving the app.
    var autoPictureInPicture: Bool { didSet { defaults.set(autoPictureInPicture, forKey: Keys.autoPiP) } }
    /// PiP: drifting cover background like the app (off = still cover, for weaker phones).
    var pipAnimatedBackground: Bool { didSet { defaults.set(pipAnimatedBackground, forKey: Keys.pipAnimatedBackground) } }
    /// PiP: track and artist under the lyrics.
    var pipShowTitle: Bool { didSet { defaults.set(pipShowTitle, forKey: Keys.pipShowTitle) } }
    /// `PiPFormat.rawValue`: the window's shape.
    var pipFormat: String { didSet { defaults.set(pipFormat, forKey: Keys.pipFormat) } }
    /// Spicy Lyrics' Simple Lyrics Mode: calmer word animation, softer fill.
    var simpleLyricsMode: Bool { didSet { defaults.set(simpleLyricsMode, forKey: Keys.simpleMode) } }
    /// Centre the lyrics instead of aligning them left (duets then stay centred too).
    var centerLyrics: Bool { didSet { defaults.set(centerLyrics, forKey: Keys.centerLyrics) } }
    /// `LyricsFont.rawValue`.
    var lyricsFont: String { didSet { defaults.set(lyricsFont, forKey: Keys.lyricsFont) } }
    /// Swipes to change tracks and pinch to resize the lyrics.
    var gesturesEnabled: Bool { didSet { defaults.set(gesturesEnabled, forKey: Keys.gestures) } }
    /// The system volume slider under the playback buttons.
    var showVolumeSlider: Bool { didSet { defaults.set(showVolumeSlider, forKey: Keys.volumeSlider) } }
    /// Battery saver: 30 fps lyrics, no line blur, still background.
    var powerSaving: Bool { didSet { defaults.set(powerSaving, forKey: Keys.powerSaving) } }
    /// Landscape: show the big artwork / the title and artist next to the lyrics.
    var landscapeArtwork: Bool { didSet { defaults.set(landscapeArtwork, forKey: Keys.landscapeArtwork) } }
    var landscapeTitle: Bool { didSet { defaults.set(landscapeTitle, forKey: Keys.landscapeTitle) } }
    /// Landscape: nothing but the lyrics; a tap brings the controls back for a few seconds.
    var landscapeLyricsOnly: Bool { didSet { defaults.set(landscapeLyricsOnly, forKey: Keys.landscapeLyricsOnly) } }
    /// Show just the background instead of the "lyrics not found" notice.
    var hideNotFoundNotice: Bool { didSet { defaults.set(hideNotFoundNotice, forKey: Keys.hideNotFound) } }
    /// Show just the background instead of unsynced (static) lyrics.
    var hideStaticLyrics: Bool { didSet { defaults.set(hideStaticLyrics, forKey: Keys.hideStatic) } }

    // Look & feel (multipliers are 1 at the original's values).
    /// Strength of the blur on lines away from the active one.
    var blurStrength: Double { didSet { defaults.set(blurStrength, forKey: Keys.blurStrength) } }
    /// Strength of the glow around sung words.
    var glowStrength: Double { didSet { defaults.set(glowStrength, forKey: Keys.glowStrength) } }
    /// Brightness of lines that are not being sung.
    var inactiveBrightness: Double { didSet { defaults.set(inactiveBrightness, forKey: Keys.inactiveBrightness) } }
    /// Gap between lines.
    var lineSpacingScale: Double { didSet { defaults.set(lineSpacingScale, forKey: Keys.lineSpacingScale) } }
    /// Size of the translation under a line, × its default.
    var translationScale: Double { didSet { defaults.set(translationScale, forKey: Keys.translationScale) } }
    /// Black layer over the background, 0…0.7.
    var backgroundDim: Double { didSet { defaults.set(backgroundDim, forKey: Keys.backgroundDim) } }
    /// Speed of the background drift.
    var backgroundSpeed: Double { didSet { defaults.set(backgroundSpeed, forKey: Keys.backgroundSpeed) } }
    /// Blur of the background cover.
    var backgroundBlur: Double { didSet { defaults.set(backgroundBlur, forKey: Keys.backgroundBlur) } }
    /// Seconds before the controls hide while a song plays.
    var autoHideDelay: Double { didSet { defaults.set(autoHideDelay, forKey: Keys.autoHideDelay) } }
    /// `LyricsWeight.rawValue`.
    var lyricsWeight: String { didSet { defaults.set(lyricsWeight, forKey: Keys.lyricsWeight) } }
    /// Where the line being sung sits in the visible lyrics: 0.5 is the middle (the original).
    var activeLinePosition: Double { didSet { defaults.set(activeLinePosition, forKey: Keys.activeLinePosition) } }
    /// × the speed of the glide to the next line.
    var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: Keys.scrollSpeed) } }
    /// × the brightness of the translation under a line.
    var translationBrightness: Double { didSet { defaults.set(translationBrightness, forKey: Keys.translationBrightness) } }
    /// × the saturation of the cover behind the lyrics (app and PiP).
    var backgroundSaturation: Double { didSet { defaults.set(backgroundSaturation, forKey: Keys.backgroundSaturation) } }
    /// Lyrics frame rate while a song plays (battery saver caps it at 30).
    var lyricsFrameRate: Double { didSet { defaults.set(lyricsFrameRate, forKey: Keys.lyricsFrameRate) } }
    /// Frame counter over the lyrics / in the PiP window.
    var showLyricsFPS: Bool { didSet { defaults.set(showLyricsFPS, forKey: Keys.showLyricsFPS) } }
    var pipShowFPS: Bool { didSet { defaults.set(pipShowFPS, forKey: Keys.pipShowFPS) } }
    /// Open Spotify once by itself when it keeps refusing the SDK connection.
    var autoWakeSpotify: Bool { didSet { defaults.set(autoWakeSpotify, forKey: Keys.autoWakeSpotify) } }

    /// Keys baked in at build time from `Config/Secrets.xcconfig` or CI secrets (may be empty).
    /// When present they are fixed: the app ignores anything typed in settings.
    let bundledSpicyLyricsKey = BundledKeys.spicyLyricsKey.flatMap(AppSettings.clientKey)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.pipAnimatedBackground: true,
            Keys.pipShowTitle: true,
            Keys.offset: 0.0,
            Keys.fontSize: Self.defaultFontSize,
            Keys.blur: true,
            Keys.background: true,
            Keys.romanization: false,
            Keys.lrclib: true,
            Keys.keepScreenOn: true,
            Keys.autoHide: true,
            Keys.landscapeArtwork: true,
            Keys.powerSaving: false,
            Keys.volumeSlider: true,
            Keys.gestures: true,
            Keys.outputLatency: true,
            Keys.simpleMode: false,
            Keys.autoPiP: false,
            Keys.translate: false,
            Keys.appLanguage: "system",
            Keys.translationReplaces: false,
            Keys.translationLanguage: Locale.current.language.languageCode?.identifier ?? "en",
            Keys.translationProvider: TranslationProvider.defaultProvider.rawValue,
            Keys.pipFormat: PiPFormat.wide.rawValue,
            Keys.centerLyrics: false,
            Keys.lyricsFont: LyricsFont.standard.rawValue,
            Keys.landscapeTitle: true,
            Keys.landscapeLyricsOnly: false,
            Keys.hideNotFound: false,
            Keys.hideStatic: false,
            Keys.blurStrength: 1.0,
            Keys.glowStrength: 1.0,
            Keys.inactiveBrightness: 1.0,
            Keys.lineSpacingScale: 1.0,
            Keys.translationScale: 1.0,
            Keys.backgroundDim: Self.defaultBackgroundDim,
            Keys.backgroundSpeed: 1.0,
            Keys.backgroundBlur: 1.0,
            Keys.autoHideDelay: 4.0,
            Keys.lyricsWeight: LyricsWeight.bold.rawValue,
            Keys.activeLinePosition: 0.5,
            Keys.scrollSpeed: 1.0,
            Keys.translationBrightness: 1.0,
            Keys.backgroundSaturation: 1.0,
            Keys.lyricsFrameRate: 60.0,
            Keys.showLyricsFPS: false,
            Keys.pipShowFPS: false,
            Keys.autoWakeSpotify: false,
        ])
        spotifyClientID = defaults.string(forKey: Keys.clientID) ?? ""
        spicyLyricsKey = defaults.string(forKey: Keys.spicyKey) ?? ""
        timingOffsetMs = defaults.double(forKey: Keys.offset)
        fontSize = defaults.double(forKey: Keys.fontSize)
        blurInactiveLines = defaults.bool(forKey: Keys.blur)
        dynamicBackground = defaults.bool(forKey: Keys.background)
        showRomanization = defaults.bool(forKey: Keys.romanization)
        useLRCLibFallback = defaults.bool(forKey: Keys.lrclib)
        keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        autoHideControls = defaults.bool(forKey: Keys.autoHide)
        powerSaving = defaults.bool(forKey: Keys.powerSaving)
        showVolumeSlider = defaults.bool(forKey: Keys.volumeSlider)
        gesturesEnabled = defaults.bool(forKey: Keys.gestures)
        compensateOutputLatency = defaults.bool(forKey: Keys.outputLatency)
        useAppRemote = defaults.object(forKey: Keys.appRemote) as? Bool ?? true
        webPollInterval = defaults.object(forKey: Keys.webPollInterval) as? Double ?? 2
        remoteQueryInterval = defaults.object(forKey: Keys.remoteQueryInterval) as? Double ?? 1.5
        syncLogEnabled = defaults.object(forKey: Keys.syncLog) as? Bool ?? true
        showSyncIndicator = defaults.object(forKey: Keys.syncIndicator) as? Bool ?? false
        pipTextScale = defaults.object(forKey: Keys.pipTextScale) as? Double ?? 1
        pipBackgroundDim = defaults.object(forKey: Keys.pipBackgroundDim) as? Double ?? 0.42
        pipFrameRate = defaults.object(forKey: Keys.pipFrameRate) as? Double ?? 30
        pipShowTranslation = defaults.object(forKey: Keys.pipShowTranslation) as? Bool ?? true
        pipBlurLines = defaults.object(forKey: Keys.pipBlurLines) as? Bool ?? true
        simpleLyricsMode = defaults.bool(forKey: Keys.simpleMode)
        autoPictureInPicture = defaults.bool(forKey: Keys.autoPiP)
        pipAnimatedBackground = defaults.bool(forKey: Keys.pipAnimatedBackground)
        pipShowTitle = defaults.bool(forKey: Keys.pipShowTitle)
        translateLyrics = defaults.bool(forKey: Keys.translate)
        translationLanguage = defaults.string(forKey: Keys.translationLanguage) ?? "en"
        translationReplaces = defaults.bool(forKey: Keys.translationReplaces)
        translationProvider = defaults.string(forKey: Keys.translationProvider) ?? TranslationProvider.defaultProvider.rawValue
        deeplKey = Keychain.read(Self.deeplKeychainKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        pipFormat = defaults.string(forKey: Keys.pipFormat) ?? PiPFormat.wide.rawValue
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        centerLyrics = defaults.bool(forKey: Keys.centerLyrics)
        lyricsFont = defaults.string(forKey: Keys.lyricsFont) ?? LyricsFont.standard.rawValue
        landscapeArtwork = defaults.bool(forKey: Keys.landscapeArtwork)
        landscapeTitle = defaults.bool(forKey: Keys.landscapeTitle)
        landscapeLyricsOnly = defaults.bool(forKey: Keys.landscapeLyricsOnly)
        hideNotFoundNotice = defaults.bool(forKey: Keys.hideNotFound)
        hideStaticLyrics = defaults.bool(forKey: Keys.hideStatic)
        blurStrength = defaults.double(forKey: Keys.blurStrength)
        glowStrength = defaults.double(forKey: Keys.glowStrength)
        inactiveBrightness = defaults.double(forKey: Keys.inactiveBrightness)
        lineSpacingScale = defaults.double(forKey: Keys.lineSpacingScale)
        translationScale = defaults.double(forKey: Keys.translationScale)
        backgroundDim = defaults.double(forKey: Keys.backgroundDim)
        backgroundSpeed = defaults.double(forKey: Keys.backgroundSpeed)
        backgroundBlur = defaults.double(forKey: Keys.backgroundBlur)
        autoHideDelay = defaults.double(forKey: Keys.autoHideDelay)
        lyricsWeight = defaults.string(forKey: Keys.lyricsWeight) ?? LyricsWeight.bold.rawValue
        activeLinePosition = defaults.double(forKey: Keys.activeLinePosition)
        scrollSpeed = defaults.double(forKey: Keys.scrollSpeed)
        translationBrightness = defaults.double(forKey: Keys.translationBrightness)
        backgroundSaturation = defaults.double(forKey: Keys.backgroundSaturation)
        lyricsFrameRate = defaults.double(forKey: Keys.lyricsFrameRate)
        showLyricsFPS = defaults.bool(forKey: Keys.showLyricsFPS)
        pipShowFPS = defaults.bool(forKey: Keys.pipShowFPS)
        autoWakeSpotify = defaults.bool(forKey: Keys.autoWakeSpotify)
    }

    /// The Client ID to sign in with: always the user's own.
    var effectiveSpotifyClientID: String {
        spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidClientID: Bool { Self.isValidClientID(spotifyClientID) }

    /// A Spotify Client ID is 32 hex characters.
    static func isValidClientID(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 32 && value.allSatisfy(\.isHexDigit)
    }

    /// The Spicy Lyrics client key built into the app, else the one typed in settings.
    var validSpicyKey: String? {
        bundledSpicyLyricsKey ?? Self.clientKey(spicyLyricsKey)
    }

    var hasBundledSpicyKey: Bool { bundledSpicyLyricsKey != nil }

    private static func clientKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sl_pk_"), key.count >= 14 else { return nil }
        return key
    }

    /// The app follows the phone's language (English unless it is Russian) or a fixed choice.
    /// iOS reads `AppleLanguages` at launch, so a change shows after the app restarts.
    static func applyLanguage(_ language: String) {
        if language == "en" || language == "ru" {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Lyric font size limits (settings slider and pinch).
    static let fontRange: ClosedRange<CGFloat> = 22...56
    static let defaultFontSize = 32.0
    static let defaultBackgroundDim = 0.28
    private static let deeplKeychainKey = "deeplKey"

    var provider: TranslationProvider {
        let chosen = TranslationProvider(rawValue: translationProvider) ?? .defaultProvider
        // Apple's on-device translation needs iOS 18: fall back to Google before that.
        return chosen.isAvailable ? chosen : .google
    }

    var format: PiPFormat { PiPFormat(rawValue: pipFormat) ?? .wide }

    /// Back to the original look: text size, alignment, font and every effect slider.
    func resetLyricsLook() {
        fontSize = Self.defaultFontSize
        lyricsFont = LyricsFont.standard.rawValue
        centerLyrics = false
        lineSpacingScale = 1
        translationScale = 1
        lyricsWeight = LyricsWeight.bold.rawValue
        activeLinePosition = 0.5
        scrollSpeed = 1
        translationBrightness = 1
    }

    func resetEffects() {
        simpleLyricsMode = false
        blurInactiveLines = true
        blurStrength = 1
        glowStrength = 1
        inactiveBrightness = 1
    }

    func resetBackground() {
        dynamicBackground = true
        backgroundDim = Self.defaultBackgroundDim
        backgroundSpeed = 1
        backgroundBlur = 1
        backgroundSaturation = 1
    }

    private enum Keys {
        static let clientID = "spotifyClientID"
        static let spicyKey = "spicyLyricsKey"
        static let offset = "timingOffsetMs"
        static let fontSize = "fontSize"
        static let blur = "blurInactiveLines"
        static let background = "dynamicBackground"
        static let romanization = "showRomanization"
        static let lrclib = "useLRCLibFallback"
        static let keepScreenOn = "keepScreenOn"
        static let autoHide = "autoHideControls"
        static let powerSaving = "powerSaving"
        static let volumeSlider = "showVolumeSlider"
        static let gestures = "gesturesEnabled"
        static let outputLatency = "compensateOutputLatency"
        static let appRemote = "useAppRemote"
        static let webPollInterval = "webPollInterval"
        static let remoteQueryInterval = "remoteQueryInterval"
        static let syncLog = "syncLogEnabled"
        static let syncIndicator = "showSyncIndicator"
        static let pipTextScale = "pipTextScale"
        static let pipBackgroundDim = "pipBackgroundDim"
        static let pipFrameRate = "pipFrameRate"
        static let pipShowTranslation = "pipShowTranslation"
        static let pipBlurLines = "pipBlurLines"
        static let simpleMode = "simpleLyricsMode"
        static let autoPiP = "autoPictureInPicture"
        static let pipAnimatedBackground = "pipAnimatedBackground"
        static let pipShowTitle = "pipShowTitle"
        static let translate = "translateLyrics"
        static let translationLanguage = "translationLanguage"
        static let translationReplaces = "translationReplaces"
        static let appLanguage = "appLanguage"
        static let centerLyrics = "centerLyrics"
        static let lyricsFont = "lyricsFont"
        static let landscapeArtwork = "landscapeArtwork"
        static let landscapeTitle = "landscapeTitle"
        static let landscapeLyricsOnly = "landscapeLyricsOnly"
        static let hideNotFound = "hideNotFoundNotice"
        static let hideStatic = "hideStaticLyrics"
        static let blurStrength = "blurStrength"
        static let glowStrength = "glowStrength"
        static let inactiveBrightness = "inactiveBrightness"
        static let lineSpacingScale = "lineSpacingScale"
        static let translationScale = "translationScale"
        static let backgroundDim = "backgroundDim"
        static let backgroundSpeed = "backgroundSpeed"
        static let backgroundBlur = "backgroundBlur"
        static let autoHideDelay = "autoHideDelay"
        static let lyricsWeight = "lyricsWeight"
        static let translationProvider = "translationProvider"
        static let pipFormat = "pipFormat"
        static let activeLinePosition = "activeLinePosition"
        static let scrollSpeed = "scrollSpeed"
        static let translationBrightness = "translationBrightness"
        static let backgroundSaturation = "backgroundSaturation"
        static let lyricsFrameRate = "lyricsFrameRate"
        static let showLyricsFPS = "showLyricsFPS"
        static let pipShowFPS = "pipShowFPS"
        static let autoWakeSpotify = "autoWakeSpotify"
    }
}

/// Typeface for the lyrics.
enum LyricsFont: String, CaseIterable, Identifiable {
    case standard, rounded, serif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "SF Pro"
        case .rounded: return "SF Pro Rounded"
        case .serif: return "New York"
        }
    }
}

/// Thickness of the lyrics (the original is bold).
enum LyricsWeight: String, CaseIterable, Identifiable {
    case semibold, bold, heavy, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .semibold: return String(localized: "Полужирный")
        case .bold: return String(localized: "Жирный")
        case .heavy: return String(localized: "Плотный")
        case .black: return String(localized: "Сверхжирный")
        }
    }

    var uiWeight: UIFont.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}
