import AVFoundation
import AVKit
import CoreMedia
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Floating lyrics over other apps: the lyrics are drawn into video frames and shown in the
/// system's Picture in Picture window, which keeps the app running in the background (the
/// Android port's `PictureInPicture.kt` does the same with Android's PiP).
///
/// Not main-actor isolated because AVKit's delegate protocols aren't; every entry point runs on
/// the main thread and reaches the main-actor player through `MainActor.assumeIsolated`.
@Observable
final class LyricsPictureInPicture: NSObject {
    /// Frame size: 2:1 suits one or two lines of lyrics.
    static let frameSize = CGSize(width: 800, height: 400)

    private(set) var isActive = false
    private(set) var isPossible = false
    private(set) var lastError: String?

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private let renderer = PiPFrameRenderer(size: LyricsPictureInPicture.frameSize)
    @ObservationIgnored private var lastPlaying: Bool?
    @ObservationIgnored private var lyricsAnimator: LyricsAnimator?
    /// What the animator was built for: comparing whole lyrics every frame was the costliest
    /// thing PiP did, the player's revision number says the same for free.
    @ObservationIgnored private var animatorKey: (revision: Int, simple: Bool)?
    @ObservationIgnored private weak var performance: PerformanceMonitor?
    @ObservationIgnored private var framesPerSecond: Double = 0

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    /// Connects the player and creates the controller (once the layer is in a window).
    func configure(player: PlayerModel, settings: AppSettings, performance: PerformanceMonitor? = nil) {
        self.player = player
        self.settings = settings
        self.performance = performance
        guard controller == nil, Self.isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = settings.autoPictureInPicture
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            DispatchQueue.main.async { self?.isPossible = controller.isPictureInPicturePossible }
        }
        self.controller = controller
        renderFrame()
        scheduleFrames(fps: idleFramesPerSecond)
    }

    /// While the window is closed: nothing, unless it may open on its own when leaving the app;
    /// then a slow trickle keeps a current frame on the layer (PiP cannot start without one).
    private var idleFramesPerSecond: Double {
        MainActor.assumeIsolated { settings?.autoPictureInPicture ?? false } ? 1 : 0
    }

    func setAutomaticStart(_ enabled: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        if !isActive { scheduleFrames(fps: idleFramesPerSecond) }
    }

    func start() {
        lastError = nil
        guard let controller else {
            lastError = String(localized: "Картинка в картинке не поддерживается на этом устройстве.")
            return
        }
        renderFrame()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // The first frame may still be on its way; try again a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let controller = self.controller else { return }
                if controller.isPictureInPicturePossible {
                    controller.startPictureInPicture()
                } else {
                    SyncLog.log("pip", "not possible right now")
                    self.lastError = String(localized: "Окно «картинка в картинке» сейчас недоступно. Попробуйте ещё раз.")
                }
            }
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: Frames

    private func scheduleFrames(fps: Double) {
        guard fps != framesPerSecond else { return }
        framesPerSecond = fps
        timer?.invalidate()
        timer = nil
        guard fps > 0 else { return }
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.renderFrame() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func renderFrame() {
        guard let player else { return }
        let output = displayLayer.sampleBufferRenderer
        if output.status == .failed { output.flush() }
        guard output.isReadyForMoreMediaData else { return }
        let reduced = MainActor.assumeIsolated { (settings?.powerSaving ?? false) || (performance?.constrained ?? false) }
        let snapshot = MainActor.assumeIsolated {
            if case .loaded(let lyrics) = player.lyricsState {
                let simple = settings?.simpleLyricsMode ?? false
                if animatorKey?.revision != player.lyricsRevision || animatorKey?.simple != simple {
                    lyricsAnimator = LyricsAnimator(lyrics: lyrics, simple: simple)
                    animatorKey = (player.lyricsRevision, simple)
                }
                lyricsAnimator?.step(position: player.position(), now: CACurrentMediaTime(),
                                     blurEnabled: (settings?.blurInactiveLines ?? false) && !reduced)
            } else {
                lyricsAnimator = nil
                animatorKey = nil
            }
            return PiPSnapshot(player: player, settings: settings, animator: lyricsAnimator, reduced: reduced)
        }
        guard let sample = renderer.sampleBuffer(for: snapshot) else { return }
        output.enqueue(sample)

        // Full rate only while something moves: playing, or a line still sliding into place.
        if isActive {
            let moving = snapshot.isPlaying || renderer.isAnimating
            let fps = MainActor.assumeIsolated { settings?.pipFrameRate ?? 30 }
            scheduleFrames(fps: moving ? (reduced ? min(20, fps) : fps) : 5)
        }

        // Keep the PiP play/pause button in step with Spotify.
        if lastPlaying != snapshot.isPlaying {
            lastPlaying = snapshot.isPlaying
            controller?.invalidatePlaybackState()
        }
    }
}

// MARK: - AVKit delegates

extension LyricsPictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        SyncLog.log("pip", "started")
        isActive = true
        scheduleFrames(fps: 30)
        renderFrame()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        SyncLog.log("pip", "stopped")
        isActive = false
        scheduleFrames(fps: idleFramesPerSecond)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        SyncLog.log("pip", "failed to start: \(error.localizedDescription)")
        lastError = String(localized: "Не удалось открыть окно: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension LyricsPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard let player else { return }
        MainActor.assumeIsolated {
            if player.isPlaying != playing { player.togglePlay() }
        }
    }

    /// A live stream as far as AVKit is concerned: no scrubber in the window.
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        guard let player else { return true }
        return MainActor.assumeIsolated { !player.isPlaying }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        if let player {
            MainActor.assumeIsolated {
                player.seek(to: max(0, player.playbackPosition() + skipInterval.seconds))
            }
        }
        completionHandler()
    }
}

// MARK: - What a frame shows

/// How the app draws its lyrics, from the settings.
struct PiPStyle: Equatable {
    var design: UIFontDescriptor.SystemDesign = .default
    var simple = false
    var centered = false
    var glow: Double = 1
    var inactiveBrightness: Double = 1
    /// Distance blur multiplier, 0 when line blur is off.
    var blur: Double = 0
    var lineSpacing: CGFloat = 1
    var translationScale: CGFloat = 1
    /// Lyric size multiplier for the window.
    var textScale: CGFloat = 1
    var showCredits = true

    /// Same as the app's `LyricsTypography.opacity`.
    func opacity(_ value: Double) -> CGFloat {
        CGFloat(clamp(1 - (1 - value) * (2 - inactiveBrightness), 0.05, 1))
    }
}

/// Everything a frame needs, read from the player on the main thread.
struct PiPSnapshot: @unchecked Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkID: String
    var artwork: UIImage?
    /// Drifting cover like the app's background, or a still one (setting / battery saver).
    var animatedBackground = true
    /// The track and artist at the bottom of the window.
    var showTitle = true
    var message: String?
    /// The animator's copy of the lyrics, so line indices and visuals always agree.
    var lyrics: PreparedLyrics?
    var revision = 0
    var visuals: [LineVisual] = []
    var focus = 0
    var position: Double = 0
    var duration: Double = 0
    /// Translations shown under the lines ("Под строкой" mode).
    var translations: [String: String] = [:]
    var style = PiPStyle()
    /// How much the cover behind the lyrics is darkened.
    var backgroundDim: CGFloat = 0.42

    @MainActor
    init(player: PlayerModel, settings: AppSettings?, animator: LyricsAnimator?, reduced: Bool = false) {
        animatedBackground = (settings?.pipAnimatedBackground ?? true) && !reduced
        showTitle = settings?.pipShowTitle ?? true
        title = player.track?.title ?? "Spicy Lyrics"
        artist = player.track?.artistLine ?? ""
        isPlaying = player.isPlaying
        artworkID = player.artworkID
        artwork = player.backgroundArtwork
        if let settings {
            switch LyricsFont(rawValue: settings.lyricsFont) ?? .standard {
            case .standard: style.design = .default
            case .rounded: style.design = .rounded
            case .serif: style.design = .serif
            }
            style.simple = settings.simpleLyricsMode
            style.centered = settings.centerLyrics
            style.glow = settings.glowStrength
            style.inactiveBrightness = settings.inactiveBrightness
            style.blur = settings.blurInactiveLines && settings.pipBlurLines && !reduced ? settings.blurStrength : 0
            style.textScale = CGFloat(settings.pipTextScale)
            style.showCredits = settings.pipShowCredits
            backgroundDim = CGFloat(settings.pipBackgroundDim)
            style.lineSpacing = CGFloat(settings.lineSpacingScale)
            style.translationScale = CGFloat(settings.translationScale)
        }

        switch player.lyricsState {
        case .loaded:
            guard let animator, !animator.lyrics.lines.isEmpty else {
                message = String(localized: "Текст не найден")
                return
            }
            lyrics = animator.lyrics
            revision = player.lyricsRevision
            visuals = animator.visuals
            focus = animator.focusIndex
            position = player.position()
            duration = player.track?.duration ?? 0
            if settings?.translateLyrics == true, settings?.translationReplaces != true,
               settings?.pipShowTranslation != false {
                translations = player.translations
            }
        case .loading:
            message = String(localized: "Загрузка текста…")
        case .notFound:
            message = String(localized: "Текст не найден")
        case .failed, .unavailable:
            message = String(localized: "Текст недоступен")
        case .idle:
            message = player.statusMessage ?? String(localized: "Включите музыку в Spotify")
        }
    }
}

// MARK: - Drawing frames

/// Draws snapshots into pixel buffers and wraps them as sample buffers for the PiP layer.
///
/// The window shows the app's own lyrics column: same rows, wrapping, fill, glow, line opacity,
/// distance blur and spring scroll, with the credits after the last line. Every row is laid
/// out and rasterized once, so a frame is a copy of the cached background plus a few mask fills.
final class PiPFrameRenderer {
    private let size: CGSize
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private var fonts: [String: UIFont] = [:]
    private var gradients: [String: CGGradient] = [:]

    // Layout of the 800×400 frame.
    private static let inset: CGFloat = 36
    /// Lyric size in frame pixels (the app's 32 pt on a phone, scaled to the window), times the
    /// window's text size setting.
    private static let baseLeadSize: CGFloat = 56
    private var leadSize: CGFloat = 56
    /// Where the line in focus sits, from the top.
    private static let anchor: CGFloat = 28
    private static let clipTop: CGFloat = 12
    /// Radius the soft masks are blurred with (frame pixels).
    private static let softRadius: CGFloat = 6

    private enum RunRef {
        case space
        case syllable(Int, Int)
        case letter(Int, Int, Int)
        case line
    }
    private struct Row {
        var layout: PiPTextLayout
        /// Offset of the text box in the column (duet and centred insets).
        var x: CGFloat
        var runs: [RunRef]
        var fontSize: CGFloat
        /// Where a growing line-synced line is anchored, 0 leading … 1 trailing.
        var anchor: CGFloat
        var isBackground: Bool
    }
    private struct LayoutKey: Equatable {
        var revision: Int
        var style: PiPStyle
        var translations: Int
    }
    /// One entry per lyric line; nil for interludes (drawn as dots).
    private var rows: [Row?] = []
    private var credits: PiPTextLayout?
    private var layoutKey: LayoutKey?
    private var lastLyricEnd: Double = 0
    private var footer: (text: String, layout: PiPTextLayout)?
    private var messageLayout: (text: String, layout: PiPTextLayout)?

    // The column's scroll: the app's critically damped 1 Hz spring.
    private var scroll: CGFloat = 0
    private var velocity: CGFloat = 0
    private var scrollTarget: CGFloat = 0
    private var lastStep: CFTimeInterval?
    private var scrollRevision = -1
    private var purgeCountdown = 0

    /// The column is still gliding to its line.
    private(set) var isAnimating = false

    // The animated background is drawn small (200×100, ten times a second), stretched into a
    // cached full-size backdrop, and that backdrop is copied into every frame.
    private static let backgroundSize = CGSize(width: 200, height: 100)
    private static let backgroundInterval: CFTimeInterval = 0.1
    /// Same layers as the app's `CoverBlobsView`: size × diagonal, centre, rotation period (s),
    /// drift radii and period (s), whether the layer is a soft blob.
    private static let backgroundLayers: [(size: CGFloat, center: CGPoint, rotation: Double,
                                           drift: CGSize, driftPeriod: Double, blob: Bool)] = [
        (1.35, CGPoint(x: 0.5, y: 0.5), 60, .zero, 0, false),
        (0.95, CGPoint(x: 0.22, y: 0.24), -40, CGSize(width: 0.16, height: 0.12), 19, true),
        (0.85, CGPoint(x: 0.82, y: 0.68), 32, CGSize(width: 0.14, height: 0.15), 23, true),
        (0.75, CGPoint(x: 0.3, y: 0.86), -50, CGSize(width: 0.15, height: 0.1), 27, true),
    ]
    private var coverImages: (id: String, base: CGImage, blob: CGImage)?
    private var backdrop: CGContext?
    private var backdropKey: (artworkID: String, animated: Bool, hasArtwork: Bool, dim: CGFloat)?
    private var backdropRenderedAt: CFTimeInterval = 0

    init(size: CGSize) {
        self.size = size
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func sampleBuffer(for snapshot: PiPSnapshot) -> CMSampleBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        let now = CACurrentMediaTime()

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: Self.sRGB,
                                   bitmapInfo: Self.bitmapInfo) {
            copyBackdrop(snapshot, now: now, into: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
            // Top-left origin from here on.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(snapshot, in: CGRect(origin: .zero, size: size), now: now, context: context)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private var clipBottom: CGFloat = 0

    private func draw(_ snapshot: PiPSnapshot, in rect: CGRect, now: CFTimeInterval, context: CGContext) {
        let inset = Self.inset
        clipBottom = rect.height - (snapshot.showTitle ? 62 : 10)

        // Footer: track and artist (can be switched off).
        if snapshot.showTitle {
            let text = snapshot.artist.isEmpty ? snapshot.title : "\(snapshot.title) — \(snapshot.artist)"
            if footer?.text != text {
                footer = (text, PiPTextLayout(blocks: [PiPTextBlock(runs: [text], font: ctFont(24, .semibold, .default),
                                                                    gray: 0.55, singleLine: true)],
                                              width: rect.width - inset * 2))
            }
            if let layout = footer?.layout, let mask = layout.sharp.first {
                context.fill(mask: mask, in: layout.firstRect.offsetBy(dx: inset, dy: rect.height - 50), white: 1)
            }
        }

        guard let lyrics = snapshot.lyrics else {
            isAnimating = false
            let text = snapshot.message ?? ""
            if messageLayout?.text != text {
                messageLayout = (text, PiPTextLayout(blocks: [PiPTextBlock(runs: [text],
                                                                           font: ctFont(46, .bold, snapshot.style.design))],
                                                     width: rect.width - inset * 2))
            }
            if let layout = messageLayout?.layout, let mask = layout.sharp.first {
                let top = ((Self.clipTop + clipBottom) / 2 - layout.size.height / 2).rounded()
                context.fill(mask: mask, in: layout.firstRect.offsetBy(dx: inset, dy: top), white: 0.85)
            }
            return
        }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: Self.clipTop, width: rect.width, height: clipBottom - Self.clipTop))
        drawLyrics(lyrics, snapshot, width: rect.width - inset * 2, now: now, context: context)
        context.restoreGState()
    }

    // MARK: Lyrics column

    private func buildRows(_ lyrics: PreparedLyrics, _ snapshot: PiPSnapshot, width column: CGFloat) {
        let style = snapshot.style
        let cqw = column / 100
        let hasDuets = lyrics.lines.contains(where: \.oppositeAligned)
        let size = leadSize
        let lead = ctFont(size, .bold, style.design)
        let background = ctFont(size * 0.75, .bold, style.design)
        let still = ctFont(size * 5 / 7, .medium, style.design)

        rows = lyrics.lines.map { line -> Row? in
            // `.line { padding-right: 5cqw }`, or 15cqw on the side a duet line leans away from.
            var left: CGFloat = 0, right = cqw * 5
            if style.centered {
                left = cqw * 5
            } else if hasDuets {
                if line.oppositeAligned { left = cqw * 15; right = 0 } else { right = cqw * 15 }
            }
            let alignment: CGFloat = style.centered ? 0.5 : (line.oppositeAligned ? 1 : 0)
            var texts: [String] = []
            var runs: [RunRef] = []
            var font = lead
            var extra: [PreparedWord] = []
            switch line.kind {
            case .interlude:
                return nil
            case .syllable(let words, let backing):
                for (w, word) in words.enumerated() {
                    if w > 0 { texts.append(" "); runs.append(.space) }
                    for (s, syllable) in word.syllables.enumerated() {
                        if let letters = syllable.letters, !letters.isEmpty {
                            for (l, letter) in letters.enumerated() {
                                texts.append(letter.text)
                                runs.append(.letter(w, s, l))
                            }
                        } else {
                            texts.append(syllable.text)
                            runs.append(.syllable(w, s))
                        }
                    }
                }
                font = line.isBackground ? background : lead
                extra = backing
            case .line(let text):
                texts = [text]
                runs = [.line]
            case .static(let text):
                texts = [text]
                runs = [.line]
                font = still
            }
            var blocks = [PiPTextBlock(runs: texts, font: font, alignment: alignment)]
            if !extra.isEmpty {
                let text = extra.map { $0.syllables.map(\.text).joined() }.joined(separator: " ")
                blocks.append(PiPTextBlock(runs: [text], font: background, gray: 0.5, alignment: alignment))
            }
            if let translation = snapshot.translations[line.sourceText], !translation.isEmpty {
                // A backing vocal's translation is as much smaller as the vocal itself.
                let translationSize = (line.isBackground ? size * 0.75 : size) * 0.55 * style.translationScale
                blocks.append(PiPTextBlock(runs: [translation], font: ctFont(translationSize, .semibold, style.design),
                                           gray: line.isBackground ? 0.45 : 0.6, alignment: alignment,
                                           spacing: size * 0.1))
            }
            return Row(layout: PiPTextLayout(blocks: blocks, width: max(1, column - left - right)), x: left,
                       runs: runs, fontSize: CTFontGetSize(font), anchor: alignment, isBackground: line.isBackground)
        }
        lastLyricEnd = lyrics.kind == .static ? 0 : lyrics.lines.map(\.end).max() ?? 0
        credits = style.showCredits ? creditsLayout(lyrics, width: column - cqw * 5, design: style.design) : nil
    }

    /// The block after the last line, as in the app (`LyricsCreditsView`).
    private func creditsLayout(_ lyrics: PreparedLyrics, width: CGFloat, design: UIFontDescriptor.SystemDesign) -> PiPTextLayout? {
        let size = leadSize
        let gap = size * 0.25
        let small = ctFont(size * 0.41, .semibold, design)
        var blocks: [PiPTextBlock] = []
        func add(_ text: String, _ font: CTFont, _ gray: CGFloat) {
            blocks.append(PiPTextBlock(runs: [text], font: font, gray: gray, spacing: blocks.isEmpty ? 0 : gap))
        }
        if !lyrics.songwriters.isEmpty {
            add("Written by: " + lyrics.songwriters.joined(separator: ", "), ctFont(size * 0.47, .semibold, design), 0.7)
        }
        let credits = lyrics.credits
        if let provider = credits.providedBy { add("Provided by: " + provider, small, 0.55) }
        if credits.isCommunity == true, credits.maker != nil || credits.uploader != nil {
            add("These lyrics have been provided by our community", ctFont(size * 0.41, .bold, design), 0.65)
        }
        if let maker = credits.maker { add("Made by @" + maker.name, small, 0.7) }
        if let uploader = credits.uploader {
            let role = credits.maker != nil ? "Uploaded by" : (credits.isCommunity == true ? "Made by" : "Submitted by")
            add(role + " @" + uploader.name, small, 0.7)
        }
        guard !blocks.isEmpty else { return nil }
        return PiPTextLayout(blocks: blocks, width: max(1, width))
    }

    private func drawLyrics(_ lyrics: PreparedLyrics, _ snapshot: PiPSnapshot, width column: CGFloat,
                            now: CFTimeInterval, context: CGContext) {
        let style = snapshot.style
        let key = LayoutKey(revision: snapshot.revision, style: style, translations: snapshot.translations.count)
        if key != layoutKey || rows.count != lyrics.lines.count {
            leadSize = (Self.baseLeadSize * style.textScale).rounded()
            buildRows(lyrics, snapshot, width: column)
            layoutKey = key
        }
        let size = leadSize
        let cqw = column / 100
        // The app's `1cqw` gap, a little roomier at this size.
        let spacing = (cqw * 1.6 * style.lineSpacing).rounded()
        let dotsHeight = size * 1.18

        // Where every row sits in the column.
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        tops.reserveCapacity(rows.count)
        heights.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let visual = snapshot.visuals.indices.contains(index) ? snapshot.visuals[index] : LineVisual()
            let height: CGFloat
            if let row {
                height = row.layout.size.height
                // `.bg-line { margin: -1cqw 0 1cqw }`: tucked right under the line above.
                if row.isBackground, index > 0 { y -= spacing }
            } else {
                // An interlude only takes up room while it is on (and eases in and out).
                height = (dotsHeight * CGFloat(clamp(visual.opacity, 0, 1))).rounded()
            }
            tops.append(y)
            heights.append(height)
            if height > 0 { y += height + spacing }
        }
        let creditsTop = y + size * 0.45 - spacing

        // Scroll target: the line in focus at the anchor, the credits once the song is sung.
        let viewport = clipBottom - Self.clipTop
        var target: CGFloat
        if lyrics.kind == .static {
            let progress = snapshot.duration > 0 ? CGFloat(clamp(snapshot.position / snapshot.duration, 0, 1)) : 0
            target = max(0, creditsTop - viewport * 0.5) * progress - Self.anchor
        } else if snapshot.position > lastLyricEnd + 0.6, credits != nil {
            target = creditsTop - Self.anchor
        } else {
            target = (tops.indices.contains(snapshot.focus) ? tops[snapshot.focus] : 0) - Self.anchor
        }
        target = target.rounded()
        let dt = min(1.0 / 15, max(0, now - (lastStep ?? now)))
        lastStep = now
        if scrollRevision != snapshot.revision || abs(target - scroll) > viewport * 2.5
            || UIAccessibility.isReduceMotionEnabled {
            scroll = target
            velocity = 0
            scrollRevision = snapshot.revision
        } else if dt > 0 {
            // Critically damped, ω = 2π (the app's `spring(response: 1, dampingFraction: 1)`).
            let omega: CGFloat = 2 * .pi
            let steps = max(1, Int((dt / (1.0 / 120)).rounded(.up)))
            let h = CGFloat(dt) / CGFloat(steps)
            for _ in 0..<steps {
                velocity += (-omega * omega * (scroll - target) - 2 * omega * velocity) * h
                scroll += velocity * h
            }
        }
        scrollTarget = target
        isAnimating = abs(velocity) > 2 || abs(scroll - target) > 0.5

        // Draw what is on screen.
        var firstVisible = Int.max, lastVisible = -1
        for index in rows.indices {
            let top = tops[index] - scroll + Self.clipTop
            let height = heights[index]
            guard height > 0, top + height > Self.clipTop - 4, top < clipBottom + 4 else { continue }
            firstVisible = min(firstVisible, index)
            lastVisible = max(lastVisible, index)
            let visual = snapshot.visuals.indices.contains(index) ? snapshot.visuals[index] : LineVisual()
            let opacity = style.opacity(visual.opacity) * edgeFade(top: top, height: height)
            guard opacity > 0.01 else { continue }
            if let row = rows[index] {
                drawRow(row, index: index, line: lyrics.lines[index], visual: visual, focus: snapshot.focus,
                        origin: CGPoint(x: Self.inset + row.x, y: top), opacity: opacity, style: style, context: context)
            } else {
                drawDots(visual, top: top, height: height, column: column, centered: style.centered,
                         opacity: CGFloat(visual.opacity) * edgeFade(top: top, height: height), style: style,
                         context: context)
            }
        }
        if let credits {
            let top = creditsTop - scroll + Self.clipTop
            if top < clipBottom, top + credits.size.height > Self.clipTop, let mask = credits.sharp.first {
                context.fill(mask: mask, in: credits.firstRect.offsetBy(dx: Self.inset, dy: top),
                             white: edgeFade(top: top, height: credits.size.height))
                if let restMask = credits.sharp.rest, let rest = credits.restRect {
                    context.fill(mask: restMask, in: rest.offsetBy(dx: Self.inset, dy: top),
                                 white: edgeFade(top: top, height: credits.size.height))
                }
            }
        }

        // Keep bitmaps only for rows near the window.
        purgeCountdown -= 1
        if purgeCountdown <= 0, lastVisible >= 0 {
            purgeCountdown = 30
            for index in rows.indices where index < firstVisible - 3 || index > lastVisible + 6 {
                if let row = rows[index], row.layout.isRasterized { row.layout.purge() }
            }
        }
    }

    /// Rows leaving the top or entering at the bottom fade with how much of them is inside.
    private func edgeFade(top: CGFloat, height: CGFloat) -> CGFloat {
        let h = max(height, 1)
        let inside = min((top + h - Self.clipTop) / h, (clipBottom - top) / h)
        let value = clamp(inside, 0, 1)
        return value * value * (3 - 2 * value)
    }

    private func drawRow(_ row: Row, index: Int, line: PreparedLine, visual: LineVisual, focus: Int,
                         origin: CGPoint, opacity: CGFloat, style: PiPStyle, context: CGContext) {
        let layout = row.layout
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // The app's distance blur (`blur(radius: blur × strength / 2)` at 32 pt), at this size.
        let radius = CGFloat(visual.blur * style.blur / 2) * leadSize / 32
        let soft = style.blur > 0 ? min(1, radius / Self.softRadius) : 0
        let alpha: GradientAlpha = row.isBackground ? .background
            : (style.simple ? GradientAlpha(lit: 1, unlit: 0.3) : .lead)

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if case .line = line.kind, visual.scale != 1, !reduceMotion {
            // Active line-synced lines grow to 1.05 from their aligned edge.
            let anchor = CGPoint(x: layout.size.width * row.anchor, y: layout.size.height / 2)
            context.translateBy(x: anchor.x, y: anchor.y)
            context.scaleBy(x: CGFloat(visual.scale), y: CGFloat(visual.scale))
            context.translateBy(x: -anchor.x, y: -anchor.y)
        }

        let animated: Bool
        switch line.kind {
        case .syllable, .line: animated = visual.state == .active || abs(index - focus) <= 2
        default: animated = false
        }
        if animated, soft < 0.05 {
            drawPieces(row, visual: visual, alpha: alpha, opacity: opacity, style: style, context: context)
        } else {
            let lit: Bool
            switch line.kind {
            case .static: lit = true
            case .line: lit = visual.line.gradient >= 1
            default: lit = visual.state == .sung
            }
            let value: CGFloat = isStatic(line) ? 1 : CGFloat(lit ? alpha.lit : alpha.unlit)
            fillMixed(layout.sharp.first, layout.soft.first, soft: soft, rect: layout.firstRect,
                      alpha: value * opacity, context: context)
        }
        if let rest = layout.restRect {
            fillMixed(layout.sharp.rest, soft > 0.02 ? layout.soft.rest : nil, soft: soft, rect: rest,
                      alpha: opacity, context: context)
        }
        context.restoreGState()
    }

    private func isStatic(_ line: PreparedLine) -> Bool {
        if case .static = line.kind { return true }
        return false
    }

    /// A sharp mask, cross-faded into its soft copy as the distance blur grows.
    private func fillMixed(_ sharp: CGImage?, _ soft: CGImage?, soft amount: CGFloat, rect: CGRect,
                           alpha: CGFloat, context: CGContext) {
        if amount < 0.98, let sharp { context.fill(mask: sharp, in: rect, white: alpha * (1 - amount)) }
        if amount > 0.02, let soft { context.fill(mask: soft, in: rect, white: alpha * amount * 1.15) }
    }

    /// The line being sung: each syllable / letter with the animator's fill, lift, scale and glow.
    private func drawPieces(_ row: Row, visual: LineVisual, alpha: GradientAlpha, opacity: CGFloat,
                            style: PiPStyle, context: CGContext) {
        let layout = row.layout
        let masks = layout.sharp
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let fade = CGFloat(style.simple ? 0.5 : 0.2)
        let gradient = fillGradient(alpha)
        var glows: [CGImage?]?
        for (p, piece) in layout.pieces.enumerated() {
            guard masks.pieces.indices.contains(p), let mask = masks.pieces[p] else { continue }
            let glyph: GlyphVisual
            let kind: GlowKind
            switch row.runs[piece.run] {
            case .space:
                continue
            case .syllable(let w, let s):
                glyph = Self.syllable(visual.lead, w, s)?.glyph ?? GlyphVisual()
                kind = .syllable
            case .letter(let w, let s, let l):
                let syllable = Self.syllable(visual.lead, w, s)
                if let syllable, syllable.letters.indices.contains(l) {
                    // The letter rides its word's own scale and lift.
                    var letter = syllable.letters[l]
                    letter.scale *= syllable.glyph.scale
                    letter.yOffset += syllable.glyph.yOffset
                    glyph = letter
                    kind = .letter
                } else {
                    glyph = syllable?.glyph ?? GlyphVisual()
                    kind = .syllable
                }
            case .line:
                glyph = visual.line
                kind = .line
            }
            let runWidth = layout.runWidths[piece.run]
            let scale = reduceMotion ? 1 : CGFloat(glyph.scale)
            let lift = reduceMotion ? 0 : CGFloat(glyph.yOffset) * row.fontSize
            let glyphRect = piece.glyphRect

            context.saveGState()
            context.setAlpha(opacity * CGFloat(glyph.opacity))
            context.translateBy(x: glyphRect.midX, y: glyphRect.midY + lift)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -glyphRect.midX, y: -glyphRect.midY)

            // Glow first, so it sits behind the letters like a shadow.
            let glow = reduceMotion ? 0 : kind.opacity(glyph.glow * style.glow)
            if glow > 0.004 {
                if glows == nil { glows = layout.soft.pieces }
                if let glows, glows.indices.contains(p), let soft = glows[p] {
                    context.fill(mask: soft, in: piece.rect, white: CGFloat(glow) * 1.6)
                }
            }
            let edge = glyphRect.minX + CGFloat(glyph.gradient) * runWidth - piece.advance - piece.rect.minX
            let feather = max(1, runWidth * fade)
            context.fill(mask: mask, in: piece.rect) { context, _ in
                context.drawLinearGradient(gradient, start: CGPoint(x: edge, y: 0), end: CGPoint(x: edge + feather, y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }
    }

    private static func syllable(_ visuals: [[SyllableVisual]], _ w: Int, _ s: Int) -> SyllableVisual? {
        visuals.indices.contains(w) && visuals[w].indices.contains(s) ? visuals[w][s] : nil
    }

    private func fillGradient(_ alpha: GradientAlpha) -> CGGradient {
        let key = "\(alpha.lit)|\(alpha.unlit)"
        if let cached = gradients[key] { return cached }
        let gradient = CGGradient(colorSpace: Self.sRGB,
                                  colorComponents: [1, 1, 1, CGFloat(alpha.lit), 1, 1, 1, CGFloat(alpha.unlit)],
                                  locations: [0, 1], count: 2)!
        gradients[key] = gradient
        return gradient
    }

    /// Interlude dots, as the app's `InterludeDotsView`.
    private func drawDots(_ visual: LineVisual, top: CGFloat, height: CGFloat, column: CGFloat, centered: Bool,
                          opacity: CGFloat, style: PiPStyle, context: CGContext) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let groupScale = reduceMotion ? 1 : CGFloat(visual.dotGroupScale)
        guard groupScale > 0.001, !visual.dots.isEmpty, opacity > 0.01 else { return }
        let size = leadSize
        let dotFont = size * 1.3
        let diameter = dotFont * 0.348
        let advance = dotFont * 0.485 + 2.88
        let groupWidth = advance * CGFloat(visual.dots.count)
        let left = Self.inset + (centered ? (column - groupWidth) / 2 : 0)
        context.saveGState()
        context.translateBy(x: left + groupWidth / 2, y: top + height / 2)
        context.scaleBy(x: groupScale, y: groupScale)
        for (index, dot) in visual.dots.enumerated() {
            let scale = reduceMotion ? 1 : CGFloat(dot.scale)
            let lift = reduceMotion ? 0 : CGFloat(dot.yOffset) * size
            let d = diameter * scale
            let x = -groupWidth / 2 + advance * (CGFloat(index) + 0.5)
            context.saveGState()
            context.setAlpha(opacity * CGFloat(dot.opacity))
            let glow = reduceMotion ? 0 : GlowKind.dot.opacity(dot.glow * style.glow)
            if glow > 0.004 {
                context.setShadow(offset: .zero, blur: GlowKind.dot.radius(dot.glow) * 2 * size / 32,
                                  color: UIColor.white.withAlphaComponent(CGFloat(glow)).cgColor)
            }
            context.setFillColor(UIColor.white.withAlphaComponent(CGFloat(GradientAlpha.lead.lit)).cgColor)
            context.fillEllipse(in: CGRect(x: x - d / 2, y: lift - d / 2, width: d, height: d))
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func ctFont(_ size: CGFloat, _ weight: UIFont.Weight, _ design: UIFontDescriptor.SystemDesign) -> CTFont {
        let key = "\(size)|\(weight.rawValue)|\(design.rawValue)"
        if let cached = fonts[key] { return cached as CTFont }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
        fonts[key] = font
        return font as CTFont
    }

    // MARK: Background

    /// Copies the cached backdrop (cover, drifting, darkened) into the frame, redrawing it at
    /// most ten times a second.
    private func copyBackdrop(_ snapshot: PiPSnapshot, now: CFTimeInterval, into base: UnsafeMutableRawPointer,
                              bytesPerRow: Int) {
        let width = Int(size.width), height = Int(size.height)
        if backdrop == nil {
            backdrop = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: Self.sRGB, bitmapInfo: Self.bitmapInfo)
        }
        guard let backdrop, let source = backdrop.data else { return }
        if let artwork = snapshot.artwork, coverImages?.id != snapshot.artworkID,
           let rendered = CoverBlobsView.render(artwork) {
            coverImages = (snapshot.artworkID, rendered.base, rendered.blob)
            backdropKey = nil
        }
        let hasArtwork = snapshot.artwork != nil && coverImages != nil
        let stale = backdropKey?.artworkID != snapshot.artworkID || backdropKey?.animated != snapshot.animatedBackground
            || backdropKey?.hasArtwork != hasArtwork || backdropKey?.dim != snapshot.backgroundDim
        if stale || (snapshot.animatedBackground && hasArtwork && now - backdropRenderedAt >= Self.backgroundInterval) {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            backdrop.setFillColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
            backdrop.fill(rect)
            if hasArtwork, let images = coverImages,
               let frame = renderBackground(images, time: snapshot.animatedBackground ? now : 0) {
                backdrop.interpolationQuality = .medium
                backdrop.draw(frame, in: rect)
            }
            // Darker than the app's background: the window is small and has to stay readable.
            backdrop.setFillColor(red: 0, green: 0, blue: 0, alpha: snapshot.backgroundDim)
            backdrop.fill(rect)
            backdropKey = (snapshot.artworkID, snapshot.animatedBackground, hasArtwork, snapshot.backgroundDim)
            backdropRenderedAt = now
        }
        let rowBytes = width * 4
        for row in 0..<height {
            memcpy(base + row * bytesPerRow, source + row * backdrop.bytesPerRow, rowBytes)
        }
    }

    /// One frame of the drifting cover, at low resolution.
    private func renderBackground(_ images: (id: String, base: CGImage, blob: CGImage), time t: CFTimeInterval) -> CGImage? {
        let size = Self.backgroundSize
        guard let small = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: Self.sRGB, bitmapInfo: Self.bitmapInfo
        ) else { return nil }
        small.interpolationQuality = .low
        let diagonal = hypot(size.width, size.height)
        for layer in Self.backgroundLayers {
            let side = diagonal * layer.size
            let angle = 2 * Double.pi * t / layer.rotation
            let drift = layer.driftPeriod > 0 ? 2 * Double.pi * t / layer.driftPeriod : 0
            let center = CGPoint(
                x: size.width * layer.center.x + CGFloat(cos(drift)) * size.width * layer.drift.width,
                y: size.height * layer.center.y + CGFloat(sin(drift)) * size.height * layer.drift.height
            )
            small.saveGState()
            small.translateBy(x: center.x, y: center.y)
            small.rotate(by: CGFloat(angle))
            small.draw(layer.blob ? images.blob : images.base, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            small.restoreGState()
        }
        return small.makeImage()
    }
}

// MARK: - Hosting the layer

/// Puts the PiP layer into the window (AVKit needs it there); tucked behind the background.
struct PictureInPictureHost: UIViewRepresentable {
    let pip: LyricsPictureInPicture

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(pip.displayLayer)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {}

    final class HostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}
