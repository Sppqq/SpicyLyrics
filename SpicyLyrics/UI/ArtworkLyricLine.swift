import SwiftUI

/// One line of lyrics under the big cover, like Spotify's: the line being sung, word by word with
/// the same fill, lift and glow as the full lyrics; the next line rises in as it starts.
struct ArtworkLyricLine: View {
    let player: PlayerModel
    let settings: AppSettings
    var fontSize: CGFloat = 24

    @State private var animator: LyricsAnimator

    init(lyrics: PreparedLyrics, player: PlayerModel, settings: AppSettings, fontSize: CGFloat = 24) {
        self.player = player
        self.settings = settings
        self.fontSize = fontSize
        _animator = State(initialValue: LyricsAnimator(lyrics: lyrics, simple: settings.simpleLyricsMode))
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: player.isPlaying ? 1.0 / 30 : 1.0 / 10)) { _ in
                let now = MediaClock.now()
                let _ = animator.step(position: player.position(at: now), now: now, blurEnabled: false)
                let index = animator.focusIndex
                let lines = animator.lyrics.lines
                ZStack(alignment: .topLeading) {
                    if lines.indices.contains(index) {
                        LyricLineView(line: Self.leftAligned(lines[index]), visual: animator.visuals[index],
                                      typography: typography(width: geometry.size.width),
                                      translation: translation(lines[index]))
                            .id(index)
                            // The sung line leaves upwards as the next one rises in, never on top of it.
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .animation(.easeInOut(duration: 0.4), value: index)
            }
        }
        .allowsHitTesting(false)
    }

    private func typography(width: CGFloat) -> LyricsTypography {
        LyricsTypography(
            fontSize: fontSize,
            cqw: max(width, 1) / 100,
            hasDuets: false,
            simple: settings.simpleLyricsMode,
            centered: false,
            font: LyricsFont(rawValue: settings.lyricsFont) ?? .standard,
            blurScale: 0,
            glowScale: settings.glowStrength,
            inactiveBrightness: settings.inactiveBrightness,
            lineSpacingScale: 1,
            translationScale: CGFloat(settings.translationScale),
            translationBrightness: settings.translationBrightness,
            weight: (LyricsWeight(rawValue: settings.lyricsWeight) ?? .bold).fontWeight
        )
    }

    private func translation(_ line: PreparedLine) -> String? {
        guard settings.translateLyrics, !settings.translationReplaces else { return nil }
        return player.translations[line.sourceText]
    }

    /// Duet lines lean right in the full lyrics; under the cover every line starts on the left.
    private static func leftAligned(_ line: PreparedLine) -> PreparedLine {
        var line = line
        line.oppositeAligned = false
        return line
    }
}
