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
                lyricsAnimator?.step(position: player.position(), now: CACurrentMediaTime(), blurEnabled: false)
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
            let moving = snapshot.isPlaying || renderer.isTransitioning
            scheduleFrames(fps: moving ? (reduced ? 20 : 30) : 5)
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
        isActive = true
        scheduleFrames(fps: 30)
        renderFrame()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        scheduleFrames(fps: idleFramesPerSecond)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
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

/// Everything a frame needs, read from the player on the main thread.
struct PiPSnapshot: @unchecked Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkID: String
    var artwork: UIImage?
    /// The current line as (text, brightness 0…1) runs, already timed.
    var current: [(text: String, lit: Double)] = []
    struct AnimatedRun {
        var text: String
        var visual: GlyphVisual
    }
    var animatedRuns: [AnimatedRun] = []
    /// Backing vocals under the current line (one row per group, so two in a row both show).
    var backgrounds: [[(text: String, lit: Double)]] = []
    /// The same rows with the animator's per-syllable / per-letter visuals.
    var backgroundRuns: [[AnimatedRun]] = []
    /// Translation of the current line ("Под строкой" mode), and of each backing vocal row.
    var translation: String?
    var backgroundTranslations: [String?] = []
    var dots: [GlyphVisual] = []
    var dotGroupScale: Double = 0
    var next: String?
    struct Neighbor {
        var id: String
        var text: String
        var offset: Int
    }
    var neighbors: [Neighbor] = []
    var simple = false
    var interlude = false
    var message: String?
    var fontDesign: UIFontDescriptor.SystemDesign = .default
    /// Includes timing so consecutive identical lines still animate independently.
    var lineID = ""
    /// Drifting cover like the app's background, or a still one (setting / battery saver).
    var animatedBackground = true
    /// The track and artist at the bottom of the window.
    var showTitle = true

    @MainActor
    init(player: PlayerModel, settings: AppSettings?, animator: LyricsAnimator?, reduced: Bool = false) {
        animatedBackground = (settings?.pipAnimatedBackground ?? true) && !reduced
        showTitle = settings?.pipShowTitle ?? true
        title = player.track?.title ?? "Spicy Lyrics"
        artist = player.track?.artistLine ?? ""
        isPlaying = player.isPlaying
        artworkID = player.artworkID
        artwork = player.backgroundArtwork
        simple = settings?.simpleLyricsMode ?? false
        switch LyricsFont(rawValue: settings?.lyricsFont ?? "") ?? .standard {
        case .standard: fontDesign = .default
        case .rounded: fontDesign = .rounded
        case .serif: fontDesign = .serif
        }

        switch player.lyricsState {
        case .loaded(let lyrics):
            guard lyrics.kind != .static else {
                current = [(lyrics.lines.first?.plainText ?? "", 1)]
                next = lyrics.lines.dropFirst().first?.plainText
                neighbors = lyrics.lines.dropFirst().prefix(2).enumerated().map {
                    Neighbor(id: "static:\($0.offset + 1)", text: $0.element.plainText, offset: $0.offset + 1)
                }
                lineID = "static:0"
                message = String(localized: "Текст без синхронизации")
                return
            }
            let time = player.position()
            let rows = lyrics.lines.filter { !$0.isBackground }
            guard let index = rows.lastIndex(where: { $0.start <= time }) else {
                interlude = true
                next = rows.first(where: { !$0.isInterlude })?.plainText
                neighbors = rows.enumerated().filter { !$0.element.isInterlude }.prefix(2).enumerated().map {
                    Neighbor(id: "\($0.element.offset):\($0.element.element.start)",
                             text: $0.element.element.plainText, offset: $0.offset + 1)
                }
                return
            }
            let row = rows[index]
            let showsTranslation = (settings?.translateLyrics ?? false) && !(settings?.translationReplaces ?? false)
            if showsTranslation, !row.isInterlude {
                translation = player.translations[row.sourceText]
            }
            let visual = lyrics.lines.firstIndex(where: { $0.id == row.id }).flatMap { animator?.visuals[$0] }
            lineID = "\(index):\(row.start)"
            if let previous = rows[..<index].lastIndex(where: { !$0.isInterlude }) {
                neighbors.append(Neighbor(id: "\(previous):\(rows[previous].start)",
                                          text: rows[previous].plainText, offset: -1))
            }
            for (offset, entry) in rows.enumerated().dropFirst(index + 1)
                .filter({ !$0.element.isInterlude }).prefix(3).enumerated() {
                neighbors.append(Neighbor(id: "\(entry.offset):\(entry.element.start)",
                                          text: entry.element.plainText, offset: offset + 1))
            }
            next = rows[(index + 1)...].first(where: { !$0.isInterlude })?.plainText
            switch row.kind {
            case .interlude:
                interlude = time < row.end
                dots = visual?.dots ?? []
                dotGroupScale = visual?.dotGroupScale ?? 0
                if !interlude { current = [(row.plainText, 1)] }
            case .syllable(let lead, _):
                current = Self.runs(lead, at: time)
                let backingLines = lyrics.lines.filter { $0.isBackground && $0.leadID == row.id }
                for line in backingLines {
                    guard case .syllable(let words, _) = line.kind else { continue }
                    backgrounds.append(Self.runs(words, at: time))
                    let lineVisual = lyrics.lines.firstIndex(where: { $0.id == line.id }).flatMap { animator?.visuals[$0] }
                    backgroundRuns.append(Self.animated(words, lineVisual?.lead))
                }
                if showsTranslation {
                    backgroundTranslations = backingLines.map { player.translations[$0.sourceText] }
                }
                animatedRuns = Self.animated(lead, visual?.lead)
            case .line(let text):
                let lit = time >= row.end ? 1 : min(1, max(0, (time - row.start) / max(row.end - row.start, 0.01)))
                current = [(text, 0.3 + 0.7 * lit)]
                var glyph = visual?.line ?? GlyphVisual(gradient: lit)
                glyph.scale = visual?.scale ?? 1
                animatedRuns = [AnimatedRun(text: text, visual: glyph)]
            case .static(let text):
                current = [(text, 1)]
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

extension PiPSnapshot {
    /// Words as runs carrying the animator's visuals (letters for emphasized syllables).
    static func animated(_ words: [PreparedWord], _ visuals: [[SyllableVisual]]?) -> [AnimatedRun] {
        var runs: [AnimatedRun] = []
        for (w, word) in words.enumerated() {
            if w > 0 { runs.append(AnimatedRun(text: " ", visual: GlyphVisual(gradient: 1))) }
            for (s, syllable) in word.syllables.enumerated() {
                let value = visuals.flatMap { $0.indices.contains(w) && $0[w].indices.contains(s) ? $0[w][s] : nil }
                    ?? SyllableVisual()
                if let letters = syllable.letters, letters.count == value.letters.count {
                    runs += zip(letters, value.letters).map { AnimatedRun(text: $0.0.text, visual: $0.1) }
                } else {
                    runs.append(AnimatedRun(text: syllable.text, visual: value.glyph))
                }
            }
        }
        return runs
    }

    /// Small rows under the active line: its translation, backing vocals and their translations.
    var underRows: Int {
        (translation == nil ? 0 : 1) + backgrounds.count + backgroundTranslations.compactMap { $0 }.count
    }

    /// Syllables as (text, how lit 0…1) runs, with a space run between words.
    static func runs(_ words: [PreparedWord], at time: Double) -> [(text: String, lit: Double)] {
        words.enumerated().flatMap { w, word -> [(text: String, lit: Double)] in
            let syllables = word.syllables.map { syllable -> (text: String, lit: Double) in
                let lit: Double
                if time >= syllable.end { lit = 1 }
                else if time <= syllable.start { lit = 0 }
                else { lit = (time - syllable.start) / max(syllable.end - syllable.start, 0.01) }
                return (syllable.text, lit)
            }
            let gap: [(text: String, lit: Double)] = w == 0 ? [] : [(text: " ", lit: 1)]
            return gap + syllables
        }
    }
}

// MARK: - Drawing frames

/// Draws snapshots into pixel buffers and wraps them as sample buffers for the PiP layer.
final class PiPFrameRenderer {
    private let size: CGSize
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var currentSnapshot: PiPSnapshot?
    private var outgoingSnapshot: PiPSnapshot?
    private var transitionStart: CFTimeInterval = 0

    /// A line is still moving into place.
    var isTransitioning: Bool { outgoingSnapshot != nil }

    // Things that used to be rebuilt on every frame.
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let fillMask = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                             colorComponents: [1, 1, 1, 0], locations: [0, 1], count: 2)!
    private var fonts: [String: UIFont] = [:]
    private struct TextLayout {
        let key: String
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        let ranges: [NSRange]
    }
    /// One cached layout per slot ("lead", "bg0", "bg1"…).
    private var textLayouts: [String: TextLayout] = [:]
    private var measuredHeights: [String: CGFloat] = [:]
    /// Font sizes that make a line fit its box, by text, size and box.
    private var fittedSizes: [String: CGFloat] = [:]

    // The animated background is drawn small (200×100, ten times a second) and stretched: it is
    // a blur, so nobody can tell, and it costs a fraction of drawing it at full size.
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
    private var backgroundFrame: CGImage?
    private var backgroundRenderedAt: CFTimeInterval = 0
    private var backgroundAnimated = true

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

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            // UIKit drawing expects a top-left origin.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            draw(snapshot, in: CGRect(origin: .zero, size: size), context: context)
            UIGraphicsPopContext()
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

    private func draw(_ snapshot: PiPSnapshot, in rect: CGRect, context: CGContext) {
        drawBackground(snapshot, in: rect, context: context)

        let inset = Self.inset
        let textWidth = rect.width - inset * 2

        // Footer: track and artist (can be switched off).
        if snapshot.showTitle {
            let footer = NSAttributedString(
                string: snapshot.artist.isEmpty ? snapshot.title : "\(snapshot.title) — \(snapshot.artist)",
                attributes: [.font: font(24, .semibold, snapshot.fontDesign), .foregroundColor: UIColor.white.withAlphaComponent(0.55)]
            )
            footer.draw(with: CGRect(x: inset, y: rect.height - 50, width: textWidth, height: 32),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }

        let now = CACurrentMediaTime()
        if let previous = currentSnapshot,
           previous.artworkID == snapshot.artworkID,
           (previous.lineID != snapshot.lineID || previous.message != snapshot.message ||
            previous.interlude != snapshot.interlude ||
            previous.current.map(\.text) != snapshot.current.map(\.text)) {
            outgoingSnapshot = previous
            transitionStart = now
        } else if currentSnapshot?.artworkID != snapshot.artworkID {
            outgoingSnapshot = nil
        }
        currentSnapshot = snapshot
        let progress = UIAccessibility.isReduceMotionEnabled ? 1 : min(1, max(0, (now - transitionStart) / 0.42))
        let eased = CGFloat(1 - pow(1 - progress, 3))
        context.saveGState()
        context.clip(to: CGRect(x: inset - 12, y: 14, width: textWidth + 24,
                                height: rect.height - (snapshot.showTitle ? 72 : 28)))
        drawLyrics(snapshot, from: outgoingSnapshot, progress: eased, in: rect, context: context)
        context.restoreGState()
        if progress >= 1 { outgoingSnapshot = nil }
    }

    // A PiP window on a phone is small: the frame shows the current line big, the next ones
    // smaller, and nothing above. Every row is laid out once at the active size and only scaled
    // while it moves, so its words never re-wrap mid-animation.
    private static let inset: CGFloat = 36
    private static let top: CGFloat = 26
    private static let activeSize: CGFloat = 66
    private static let activeMaxHeight: CGFloat = 176
    /// Upcoming lines are the active layout at this scale.
    private static let neighborScale: CGFloat = 0.6

    private func drawLyrics(_ snapshot: PiPSnapshot, from previous: PiPSnapshot?, progress: CGFloat,
                            in rect: CGRect, context: CGContext) {
        let inset = Self.inset
        let width = rect.width - inset * 2
        if let message = snapshot.message, snapshot.current.isEmpty, !snapshot.interlude {
            NSAttributedString(string: message, attributes: [
                .font: font(48, .bold, snapshot.fontDesign),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]).draw(with: CGRect(x: inset, y: 100, width: width, height: 130),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            return
        }

        // Match rows by lyric identity: the upcoming row moves into the active slot and the
        // active one slides up and out.
        struct Row {
            var id: String
            var text: String
            var offset: Int
        }
        func rows(_ value: PiPSnapshot) -> [Row] {
            [Row(id: value.lineID, text: value.interlude ? "•  •  •" : value.current.map(\.text).joined(), offset: 0)] +
                value.neighbors.filter { $0.offset > 0 }.map { Row(id: $0.id, text: $0.text, offset: $0.offset) }
        }
        let design = snapshot.fontDesign
        /// The one size a row is laid out at, whether it is active or not.
        func size(_ text: String) -> CGFloat {
            fittedSize(text, preferred: Self.activeSize, weight: .bold, design: design,
                       box: CGSize(width: width, height: Self.activeMaxHeight))
        }
        func textHeight(_ text: String) -> CGFloat {
            min(Self.activeMaxHeight, measuredHeight(text, size: size(text), design: design, width: width))
        }
        func activeBlock(_ value: PiPSnapshot) -> CGFloat {
            let line = value.current.map(\.text).joined()
            let text = value.interlude || line.isEmpty ? 70 : textHeight(line)
            return text + (value.underRows > 0 ? 6 + CGFloat(value.underRows) * Self.backgroundRowHeight : 0)
        }
        func y(_ offset: Int, _ value: PiPSnapshot) -> CGFloat {
            guard offset > 0 else { return Self.top }
            var y = Self.top + activeBlock(value) + 20
            for row in rows(value) where row.offset > 0 && row.offset < offset {
                y += textHeight(row.text) * Self.neighborScale + 12
            }
            return y
        }
        func emphasis(_ offset: Int) -> CGFloat { offset == 0 ? 1 : 0 }

        let targetRows = rows(snapshot)
        let oldRows = previous.map(rows) ?? targetRows
        let oldByID = Dictionary(oldRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targetIDs = Set(targetRows.map(\.id))
        let allRows = targetRows + oldRows.filter { !targetIDs.contains($0.id) }
        for row in allRows where !row.text.isEmpty {
            let old = oldByID[row.id]
            let exists = targetIDs.contains(row.id)
            let startY = old.map { y($0.offset, previous ?? snapshot) } ?? (y(row.offset, snapshot) + 40)
            let endY = exists ? y(row.offset, snapshot) : Self.top - textHeight(row.text) - 20
            let rowY = startY + (endY - startY) * progress
            let startEmphasis = old.map { emphasis($0.offset) } ?? 0
            let endEmphasis = exists ? emphasis(row.offset) : 0
            let active = startEmphasis + (endEmphasis - startEmphasis) * progress
            let alpha: CGFloat = exists ? (old == nil ? progress : 1) : 1 - progress
            let scale = Self.neighborScale + (1 - Self.neighborScale) * active
            let textFont = font(size(row.text), .bold, design)
            let box = CGRect(x: 0, y: 0, width: width, height: Self.activeMaxHeight)

            context.saveGState()
            context.setAlpha(alpha)
            context.translateBy(x: inset, y: rowY)
            context.scaleBy(x: scale, y: scale)
            if row.offset == 0, exists, snapshot.interlude, !snapshot.dots.isEmpty {
                context.scaleBy(x: 1.6, y: 1.6)
                drawDots(snapshot, in: CGRect(x: 0, y: 0, width: width, height: 60), context: context)
            } else if row.offset == 0, exists, !snapshot.interlude {
                let used = drawSyllables(snapshot, font: textFont, in: box, context: context)
                var top = used + 6
                if let translation = snapshot.translation {
                    drawTranslation(translation, at: top, size: 34, alpha: 0.6, snapshot: snapshot, inset: 0, width: width)
                    top += Self.backgroundRowHeight
                }
                drawBackgroundVocals(snapshot, below: top, inset: 0, width: width, context: context)
            } else {
                NSAttributedString(string: row.text, attributes: [
                    .font: textFont, .foregroundColor: UIColor.white.withAlphaComponent(0.4 + 0.55 * active),
                ]).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
            context.restoreGState()
        }
    }

    /// Draws the active line and returns the height its text takes.
    @discardableResult
    private func drawSyllables(_ snapshot: PiPSnapshot, font textFont: UIFont,
                               in box: CGRect, context: CGContext) -> CGFloat {
        let runs = snapshot.animatedRuns.isEmpty
            ? snapshot.current.map { PiPSnapshot.AnimatedRun(text: $0.text, visual: GlyphVisual(gradient: $0.lit)) }
            : snapshot.animatedRuns
        return drawRuns(runs, slot: "lead", simple: snapshot.simple, font: textFont, in: box,
                        dim: 0.32, lit: 1, glowStrength: 1, context: context)
    }

    /// Lays the runs out once, then applies the main player's spring-driven transforms to each
    /// syllable or emphasized letter without letting animation change wrapping. Returns the
    /// height the text takes.
    @discardableResult
    private func drawRuns(_ runs: [PiPSnapshot.AnimatedRun], slot: String, simple: Bool, font textFont: UIFont,
                          in box: CGRect, dim: CGFloat, lit: CGFloat, glowStrength: CGFloat,
                          context: CGContext) -> CGFloat {
        let dimColor = UIColor.white.withAlphaComponent(dim)
        let litColor = UIColor.white.withAlphaComponent(lit)
        // Text layout is the expensive part: build it once per line (and size), not per frame.
        let key = runs.map(\.text).joined(separator: "\u{1}") + "|\(textFont.fontName)|\(textFont.pointSize)|\(box.size)"
        if textLayouts[slot]?.key != key {
            let text = NSMutableAttributedString()
            var ranges: [NSRange] = []
            for run in runs {
                ranges.append(NSRange(location: text.length, length: (run.text as NSString).length))
                text.append(NSAttributedString(string: run.text, attributes: [
                    .font: textFont, .ligature: 0, .foregroundColor: dimColor,
                ]))
            }
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: box.size)
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            container.lineBreakMode = .byWordWrapping
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            textLayouts[slot] = TextLayout(key: key, storage: storage, layout: layout, container: container, ranges: ranges)
        }
        guard let cached = textLayouts[slot] else { return 0 }
        let storage = cached.storage, layout = cached.layout, container = cached.container, ranges = cached.ranges
        let usedHeight = layout.usedRect(for: container).height
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for (run, characters) in zip(runs, ranges) where characters.length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            var fragments: [CGRect] = []
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                            in: container) { fragment, _ in fragments.append(fragment) }
            let totalWidth = fragments.reduce(CGFloat.zero) { $0 + $1.width }
            guard totalWidth > 0 else { continue }
            let value = run.visual
            let scale = reduceMotion ? CGFloat(1) : CGFloat(value.scale)
            let lift = reduceMotion ? CGFloat.zero : CGFloat(value.yOffset) * textFont.pointSize
            let glow = reduceMotion ? CGFloat.zero : CGFloat(max(0, value.glow)) * glowStrength
            let edge = CGFloat(value.gradient) * totalWidth
            let feather = totalWidth * (simple ? 0.5 : 0.2)
            var advance: CGFloat = 0
            for fragment in fragments {
                let frame = fragment.offsetBy(dx: box.minX, dy: box.minY)
                context.saveGState()
                context.setAlpha(CGFloat(value.opacity))
                context.translateBy(x: frame.midX, y: frame.midY + lift)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -frame.midX, y: -frame.midY)
                context.clip(to: frame.insetBy(dx: -2, dy: -6))
                layout.drawGlyphs(forGlyphRange: glyphs, at: box.origin)
                if edge + feather > advance {
                    storage.addAttribute(.foregroundColor, value: litColor, range: characters)
                    context.saveGState()
                    // Composite the fill mask inside a layer, so the gradient cannot
                    // erase the dim glyph underneath or the lyrics background.
                    context.setShadow(offset: .zero, blur: 8 * glow,
                                      color: UIColor.white.withAlphaComponent(min(1, 0.55 * glow)).cgColor)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    layout.drawGlyphs(forGlyphRange: glyphs, at: box.origin)
                    context.setBlendMode(.destinationIn)
                    let start = frame.minX + edge - advance
                    let end = start + max(1, feather)
                    context.drawLinearGradient(Self.fillMask, start: CGPoint(x: start, y: frame.minY),
                                               end: CGPoint(x: end, y: frame.minY),
                                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    context.endTransparencyLayer()
                    context.restoreGState()
                    storage.addAttribute(.foregroundColor, value: dimColor, range: characters)
                }
                context.restoreGState()
                advance += fragment.width
            }
        }
        return usedHeight
    }

    private static let backgroundRowHeight: CGFloat = 48

    /// Backing vocals under the active line, smaller and dimmer (`.bg-line` is 0.75× the lead
    /// size, `--gradient-alpha` 0.6 / 0.3), animated like the lead: fill, lift, scale and glow.
    private func drawBackgroundVocals(_ snapshot: PiPSnapshot, below top: CGFloat, inset: CGFloat, width: CGFloat,
                                      context: CGContext) {
        var top = top
        for (index, plain) in snapshot.backgrounds.enumerated() {
            let animated = snapshot.backgroundRuns.indices.contains(index) ? snapshot.backgroundRuns[index] : []
            let runs = animated.isEmpty
                ? plain.map { PiPSnapshot.AnimatedRun(text: $0.text, visual: GlyphVisual(gradient: $0.lit)) }
                : animated
            let text = runs.map(\.text).joined()
            let size = fittedSize(text, preferred: 40, weight: .bold, design: snapshot.fontDesign,
                                  box: CGSize(width: width, height: Self.backgroundRowHeight))
            drawRuns(runs, slot: "bg\(index)", simple: snapshot.simple, font: font(size, .bold, snapshot.fontDesign),
                     in: CGRect(x: inset, y: top, width: width, height: Self.backgroundRowHeight),
                     dim: 0.3, lit: 0.75, glowStrength: 0.6, context: context)
            top += Self.backgroundRowHeight
            if snapshot.backgroundTranslations.indices.contains(index),
               let translation = snapshot.backgroundTranslations[index] {
                drawTranslation(translation, at: top, size: 30, alpha: 0.45, snapshot: snapshot, inset: inset, width: width)
                top += Self.backgroundRowHeight
            }
        }
    }

    /// One row of translation text, shrunk to fit its row.
    private func drawTranslation(_ text: String, at top: CGFloat, size preferred: CGFloat, alpha: CGFloat,
                                 snapshot: PiPSnapshot, inset: CGFloat, width: CGFloat) {
        let size = fittedSize(text, preferred: preferred, weight: .semibold, design: snapshot.fontDesign,
                              box: CGSize(width: width, height: Self.backgroundRowHeight))
        NSAttributedString(string: text, attributes: [
            .font: font(size, .semibold, snapshot.fontDesign),
            .foregroundColor: UIColor.white.withAlphaComponent(alpha),
        ]).draw(with: CGRect(x: inset, y: top, width: width, height: Self.backgroundRowHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawDots(_ snapshot: PiPSnapshot, in box: CGRect, context: CGContext) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let groupScale = reduceMotion ? 1 : snapshot.dotGroupScale
        guard groupScale > 0 else { return }
        context.saveGState()
        context.translateBy(x: box.minX + 42, y: box.minY + 30)
        context.scaleBy(x: groupScale, y: groupScale)
        for (index, dot) in snapshot.dots.enumerated() {
            let scale = reduceMotion ? 1 : dot.scale
            let lift = reduceMotion ? 0 : dot.yOffset * 50
            let diameter = 17 * scale
            context.saveGState()
            context.setAlpha(CGFloat(dot.opacity))
            if !reduceMotion {
                context.setShadow(offset: .zero, blur: 8 * dot.glow,
                                  color: UIColor.white.withAlphaComponent(min(1, dot.glow * 0.55)).cgColor)
            }
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: Double(index) * 27 - 27 - diameter / 2,
                                            y: lift - diameter / 2, width: diameter, height: diameter))
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// The largest size (down to 60% of `preferred`) at which `text` fits in `box` without truncation.
    private func fittedSize(_ text: String, preferred: CGFloat, weight: UIFont.Weight,
                            design: UIFontDescriptor.SystemDesign, box: CGSize) -> CGFloat {
        let key = "\(text)|\(preferred)|\(weight.rawValue)|\(design.rawValue)|\(box.width)|\(box.height)"
        if let cached = fittedSizes[key] { return cached }
        if fittedSizes.count > 64 { fittedSizes.removeAll() }
        let minimum = (preferred * 0.6).rounded()
        var size = preferred
        while size > minimum {
            let height = NSAttributedString(string: text, attributes: [.font: font(size, weight, design)])
                .boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin], context: nil).height
            if height <= box.height { break }
            size -= 2
        }
        size = max(size, minimum)
        fittedSizes[key] = size
        return size
    }

    /// Height of `text` in the bold active-line font at `size`, wrapped to `width`.
    private func measuredHeight(_ text: String, size: CGFloat, design: UIFontDescriptor.SystemDesign,
                                width: CGFloat) -> CGFloat {
        let key = "\(text)|\(size)|\(design.rawValue)|\(width)"
        if let cached = measuredHeights[key] { return cached }
        if measuredHeights.count > 64 { measuredHeights.removeAll() }
        let height = ceil(NSAttributedString(string: text, attributes: [.font: font(size, .bold, design)])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin], context: nil).height)
        measuredHeights[key] = height
        return height
    }

    private func font(_ size: CGFloat, _ weight: UIFont.Weight, _ design: UIFontDescriptor.SystemDesign) -> UIFont {
        let key = "\(size)|\(weight.rawValue)|\(design.rawValue)"
        if let cached = fonts[key] { return cached }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
        fonts[key] = font
        return font
    }

    // MARK: Background

    private func drawBackground(_ snapshot: PiPSnapshot, in rect: CGRect, context: CGContext) {
        UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).setFill()
        context.fill(rect)
        if let artwork = snapshot.artwork, coverImages?.id != snapshot.artworkID,
           let rendered = CoverBlobsView.render(artwork) {
            coverImages = (snapshot.artworkID, rendered.base, rendered.blob)
            backgroundFrame = nil
        }
        if snapshot.artwork != nil, let images = coverImages {
            let now = CACurrentMediaTime()
            if backgroundAnimated != snapshot.animatedBackground {
                backgroundAnimated = snapshot.animatedBackground
                backgroundFrame = nil
            }
            if backgroundFrame == nil || (backgroundAnimated && now - backgroundRenderedAt >= Self.backgroundInterval) {
                backgroundFrame = renderBackground(images, time: backgroundAnimated ? now : 0)
                backgroundRenderedAt = now
            }
            if let frame = backgroundFrame {
                context.saveGState()
                context.interpolationQuality = .medium
                UIImage(cgImage: frame).draw(in: rect)
                context.restoreGState()
            }
        }
        // Darker than the app's background: the window is small and has to stay readable.
        UIColor.black.withAlphaComponent(0.42).setFill()
        context.fill(rect)
    }

    /// One frame of the drifting cover, at low resolution.
    private func renderBackground(_ images: (id: String, base: CGImage, blob: CGImage), time t: CFTimeInterval) -> CGImage? {
        let size = Self.backgroundSize
        guard let small = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
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
