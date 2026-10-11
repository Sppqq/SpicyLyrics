import QuartzCore
import SwiftUI

/// One line of lyrics under the big cover, like Spotify's: the line being sung with its backing
/// vocals, word by word with the same fill, lift and glow as the full lyrics. The sung line
/// leaves upwards as the next one rises in; after the last line it fades away.
///
/// The swap is drawn frame by frame from the clock, not with a SwiftUI animation: an animated
/// transaction also animated the words' own lift and scale, so a word jumped as lines changed.
struct ArtworkLyricLine: View {
    let player: PlayerModel
    let settings: AppSettings
    var fontSize: CGFloat = 24

    @State private var animator: LyricsAnimator
    @State private var switcher = LineSwitcher()

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
                let position = player.position(at: now)
                let _ = animator.step(position: position, now: now, blurEnabled: false)
                let _ = switcher.show(Self.shownLine(animator.lyrics.lines, focus: animator.focusIndex, at: position),
                                      now: now, instantly: animator.snapped)
                let progress = switcher.progress(at: now)
                let rise = geometry.size.height * 0.35
                let typography = typography(width: geometry.size.width)
                ZStack(alignment: .topLeading) {
                    if let previous = switcher.previous, progress < 1 {
                        block(previous, typography)
                            .offset(y: -rise * progress)
                            .opacity(1 - progress)
                    }
                    if let current = switcher.current {
                        block(current, typography)
                            .offset(y: rise * (1 - progress))
                            .opacity(progress)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                // Lines leaving upwards must not run over the cover, but the words' glow and the
                // interlude dots' pulse spill past the edges a little: room around them.
                .mask {
                    Rectangle()
                        .padding(.horizontal, -32)
                        .padding(.top, -12)
                        .padding(.bottom, -32)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A lead line with its backing vocals under it.
    private func block(_ index: Int, _ typography: LyricsTypography) -> some View {
        let lines = animator.lyrics.lines
        let visuals = animator.visuals
        return VStack(alignment: .leading, spacing: 0) {
            if lines.indices.contains(index) {
                LyricLineView(line: Self.leftAligned(lines[index]), visual: visuals[index], typography: typography,
                              translation: translation(lines[index]))
                ForEach(Self.backing(of: index, in: lines), id: \.self) { row in
                    LyricLineView(line: Self.leftAligned(lines[row]), visual: visuals[row], typography: typography)
                }
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    /// The line to show: the one in focus, or nothing once the last line (and its backing
    /// vocals) has been sung.
    private static func shownLine(_ lines: [PreparedLine], focus: Int, at position: Double) -> Int? {
        guard lines.indices.contains(focus) else { return nil }
        let isLast = !lines[(focus + 1)...].contains { !$0.isBackground }
        guard isLast else { return focus }
        let end = backing(of: focus, in: lines).map { lines[$0].end }.reduce(lines[focus].end, max)
        return position > end + 1 ? nil : focus
    }

    /// Backing-vocal rows that belong to a lead line.
    private static func backing(of lead: Int, in lines: [PreparedLine]) -> [Int] {
        var rows: [Int] = []
        var index = lead + 1
        while index < lines.count, lines[index].isBackground {
            if lines[index].leadID == lead { rows.append(index) }
            index += 1
        }
        return rows
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

/// Which line is on screen and which one is leaving, and how far the swap has got.
private final class LineSwitcher {
    private(set) var current: Int?
    private(set) var previous: Int?
    private var changedAt: CFTimeInterval = -.infinity
    private static let duration: Double = 0.4

    func show(_ index: Int?, now: CFTimeInterval, instantly: Bool) {
        guard index != current else { return }
        previous = current
        current = index
        // After a seek or a gap the new line just appears.
        changedAt = instantly ? -.infinity : now
    }

    /// 0 when the swap begins … 1 when it is done (eased).
    func progress(at now: CFTimeInterval) -> Double {
        let t = min(1, max(0, (now - changedAt) / Self.duration))
        return t * t * (3 - 2 * t)
    }
}
