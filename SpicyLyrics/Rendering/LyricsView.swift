import QuartzCore
import SwiftUI

/// The scrolling, animated lyrics. One `TimelineView` drives the animator once per frame.
struct LyricsView: View {
    let lyrics: PreparedLyrics
    let player: PlayerModel
    let settings: AppSettings
    /// Height (points) hidden under the header / controls; lyrics fade out before reaching them.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var horizontalPadding: CGFloat = 24
    /// Go easy on the GPU (Low Power Mode, a hot phone or the user's choice): 30 fps, no line blur.
    var reduced = false
    /// Bigger lyrics on wide screens (iPad), like the extension's `7cqw` font size.
    var fontScale: CGFloat = 1
    /// Any touch or scroll on the lyrics (shows the controls again).
    var onInteraction: () -> Void = {}
    /// A tap on empty space between lines (toggles the controls).
    var onBackgroundTap: () -> Void = {}

    @State private var animator: LyricsAnimator
    @State private var userScrolling = false
    @State private var resumeAutoScrollAt: Date = .distantPast
    /// Live two-finger pinch, applied to the font size until the fingers lift.
    @State private var pinchScale: CGFloat = 1
    /// "Reset size" pill after a pinch; each pinch restarts its countdown.
    @State private var showResetSize = false
    @State private var resetSizeTick = 0

    init(lyrics: PreparedLyrics, player: PlayerModel, settings: AppSettings,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, horizontalPadding: CGFloat = 24,
         reduced: Bool = false, fontScale: CGFloat = 1,
         onInteraction: @escaping () -> Void = {}, onBackgroundTap: @escaping () -> Void = {}) {
        self.lyrics = lyrics
        self.player = player
        self.settings = settings
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.horizontalPadding = horizontalPadding
        self.reduced = reduced
        self.fontScale = fontScale
        self.onInteraction = onInteraction
        self.onBackgroundTap = onBackgroundTap
        _animator = State(initialValue: LyricsAnimator(lyrics: lyrics, simple: settings.simpleLyricsMode))
    }

    /// Always the animator's copy, so line indices and visuals can never disagree.
    private var shown: PreparedLyrics { animator.lyrics }

    private func typography(width: CGFloat) -> LyricsTypography {
        LyricsTypography(
            fontSize: clamp(CGFloat(settings.fontSize) * pinchScale, AppSettings.fontRange.lowerBound,
                            AppSettings.fontRange.upperBound) * fontScale,
            cqw: max(width, 1) / 100,
            hasDuets: shown.lines.contains(where: \.oppositeAligned),
            simple: settings.simpleLyricsMode,
            centered: settings.centerLyrics,
            font: LyricsFont(rawValue: settings.lyricsFont) ?? .standard,
            blurScale: CGFloat(settings.blurStrength),
            glowScale: settings.glowStrength,
            inactiveBrightness: settings.inactiveBrightness,
            lineSpacingScale: CGFloat(settings.lineSpacingScale),
            translationScale: CGFloat(settings.translationScale)
        )
    }

    /// Spicy Lyrics centres the active line in the visible lyrics, 30 px above the middle
    /// (`ScrollTo(..., "Center")` with a 30 px padding).
    private func anchor(height: CGFloat) -> UnitPoint {
        let visibleCentre = (topInset + height - bottomInset) / 2
        return UnitPoint(x: 0.5, y: clamp((visibleCentre - 30) / max(height, 1), 0.1, 0.9))
    }

    /// The virtualizer's glide: a critically damped 1 Hz spring (`SMOOTH_SCROLL_FREQUENCY/DAMPING`).
    private static let scrollAnimation = Animation.spring(response: 1, dampingFraction: 1)
    /// `USER_SCROLL_COOLDOWN` in ScrollToActiveLine.ts.
    private static let userScrollCooldown: TimeInterval = 0.75

    private var frameInterval: Double {
        if !player.isPlaying { return 1.0 / 15 }
        return reduced ? 1.0 / 30 : 1.0 / 60
    }

    var body: some View {
        GeometryReader { geometry in
            let typography = typography(width: geometry.size.width - horizontalPadding * 2)
            let anchor = anchor(height: geometry.size.height)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    TimelineView(.animation(minimumInterval: frameInterval)) { _ in
                        let now = CACurrentMediaTime()
                        let _ = animator.step(position: player.position(at: now), now: now,
                                              blurEnabled: settings.blurInactiveLines && !userScrolling && !reduced)
                        let focus = animator.focusIndex
                        let visuals = animator.visuals

                        LazyVStack(alignment: .leading, spacing: typography.lineSpacing) {
                            ForEach(shown.lines) { line in
                                LyricLineView(line: line, visual: visuals[line.id], typography: typography,
                                              translation: settings.translateLyrics && !settings.translationReplaces
                                                  ? player.translations[line.sourceText] : nil)
                                    .equatable()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onInteraction()
                                        guard shown.kind != .static else { return }
                                        resumeAutoScrollAt = .distantPast
                                        player.seek(to: max(0, line.start - settings.timingOffsetMs / 1000))
                                    }
                                    .contextMenu { lineMenu(line) }
                                    .id(line.id)
                            }
                            LyricsCreditsView(lyrics: shown, lyricSize: typography.fontSize)
                                .padding(.top, typography.fontSize * 0.45)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, geometry.size.height * 0.6)
                        .contentShape(Rectangle())
                        .onTapGesture { onBackgroundTap() }
                        .onChange(of: focus) { _, newFocus in
                            guard shown.kind != .static, !userScrolling, Date() >= resumeAutoScrollAt else { return }
                            withAnimation(Self.scrollAnimation) {
                                proxy.scrollTo(newFocus, anchor: anchor)
                            }
                        }
                        // The visible area changes when the controls show or hide: re-centre.
                        .onChange(of: anchor.y) { _, _ in
                            guard shown.kind != .static, !userScrolling else { return }
                            withAnimation(Self.scrollAnimation) {
                                proxy.scrollTo(animator.focusIndex, anchor: anchor)
                            }
                        }
                        .task {
                            guard shown.kind != .static else { return }
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(animator.focusIndex, anchor: anchor)
                        }
                    }
                }
                .modifier(ScrollInteractionObserver { interacting in
                    userScrolling = interacting
                    if interacting {
                        onInteraction()
                    } else {
                        resumeAutoScrollAt = Date().addingTimeInterval(Self.userScrollCooldown)
                    }
                })
                .mask(EdgeFade(top: topInset, bottom: bottomInset))
                // Pinch to resize the lyrics; saved when the fingers lift.
                .pinch(enabled: settings.gesturesEnabled) { scale in
                    pinchScale = scale
                } onEnd: { scale in
                    let size = clamp(settings.fontSize * Double(scale), Double(AppSettings.fontRange.lowerBound),
                                     Double(AppSettings.fontRange.upperBound))
                    settings.fontSize = size.rounded()
                    pinchScale = 1
                    if settings.fontSize != AppSettings.defaultFontSize {
                        resetSizeTick += 1
                        withAnimation(.easeOut(duration: 0.2)) { showResetSize = true }
                    }
                }
                .overlay(alignment: .bottom) {
                    if showResetSize {
                        resetSizeButton
                            .padding(.bottom, bottomInset + 16)
                            .transition(.opacity)
                    }
                }
                .task(id: resetSizeTick) {
                    guard showResetSize else { return }
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    // Fades away slowly, so there is time to notice and tap it.
                    withAnimation(.easeIn(duration: 1.5)) { showResetSize = false }
                }
            }
        }
    }

    /// Undo an accidental pinch.
    private var resetSizeButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                settings.fontSize = AppSettings.defaultFontSize
            }
            withAnimation(.easeOut(duration: 0.25)) { showResetSize = false }
        } label: {
            Label(String(localized: "Сбросить размер"), systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }
}

extension LyricsView {
    /// Long press on a line.
    @ViewBuilder
    func lineMenu(_ line: PreparedLine) -> some View {
        if !line.isInterlude {
            if shown.kind != .static {
                Button {
                    player.seek(to: max(0, line.start - settings.timingOffsetMs / 1000))
                } label: {
                    Label(String(localized: "Перемотать сюда"), systemImage: "play.circle")
                }
            }
            Button {
                UIPasteboard.general.string = line.plainText
            } label: {
                Label(String(localized: "Скопировать строку"), systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = shown.lines.filter { !$0.isInterlude }.map(\.plainText).joined(separator: "\n")
            } label: {
                Label(String(localized: "Скопировать весь текст"), systemImage: "doc.on.doc.fill")
            }
            ShareLink(item: line.plainText) {
                Label(String(localized: "Поделиться строкой"), systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Pauses auto-scroll while the user drags the lyrics (iOS 18+; on iOS 17 it simply keeps following).
private struct ScrollInteractionObserver: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { oldPhase, newPhase in
                switch newPhase {
                case .interacting, .tracking:
                    onChange(true)
                case .idle:
                    // Only a user scroll coming to rest counts, not our own scrollTo animation.
                    switch oldPhase {
                    case .interacting, .tracking, .decelerating:
                        onChange(false)
                    default:
                        break
                    }
                default:
                    break
                }
            }
        } else {
            content
        }
    }
}

/// Soft fade at the top and bottom like the extension's `--ImageMask`. The clear bands follow the
/// header and controls, so lyrics never run underneath them (and animate with them).
private struct EdgeFade: View {
    var top: CGFloat
    var bottom: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, top))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
            Color.clear.frame(height: max(0, bottom))
        }
    }
}

/// The block after the last line, in Spicy Lyrics' order and wording (`ApplyLyricsCredits.ts`,
/// `ApplyProvider.ts`, `ApplyIsByCommunity.tsx`): writers, provider, then the community sync's
/// maker and uploader. Sizes follow Mixed.css relative to the lyric size.
private struct LyricsCreditsView: View {
    let lyrics: PreparedLyrics
    let lyricSize: CGFloat

    private var credits: LyricsCredits { lyrics.credits }
    /// A little larger than on desktop, for a phone screen (as the Android port does).
    private var small: CGFloat { max(12, lyricSize * 0.34 * 1.2) }

    var body: some View {
        VStack(alignment: .leading, spacing: lyricSize * 0.25) {
            if !lyrics.songwriters.isEmpty {
                Text("Written by: " + lyrics.songwriters.joined(separator: ", "))
                    .font(.system(size: max(14, lyricSize * 0.47), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let provider = credits.providedBy {
                Text("Provided by: " + provider)
                    .font(.system(size: small, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if credits.isCommunity == true, credits.maker != nil || credits.uploader != nil {
                Text("These lyrics have been provided by our community")
                    .font(.system(size: small, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            if let maker = credits.maker {
                ContributorRow(role: "Made by", contributor: maker, size: small)
            }
            if let uploader = credits.uploader {
                ContributorRow(
                    role: credits.maker != nil ? "Uploaded by" : (credits.isCommunity == true ? "Made by" : "Submitted by"),
                    contributor: uploader,
                    size: small
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Made by @name" with the avatar after it; tapping opens the Spicy Lyrics profile.
private struct ContributorRow: View {
    let role: String
    let contributor: LyricsContributor
    let size: CGFloat
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 4) {
            (Text(role + " ").foregroundStyle(.white.opacity(0.6))
                + Text("@" + contributor.name).bold().underline().foregroundStyle(.white.opacity(0.75)))
                .font(.system(size: size, weight: .semibold))
            if let avatar = contributor.avatarURL {
                AsyncImage(url: avatar) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: size * 1.4, height: size * 1.4)
                .clipShape(Circle())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = contributor.profileURL { openURL(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(contributor.profileURL != nil ? .isLink : [])
    }
}
