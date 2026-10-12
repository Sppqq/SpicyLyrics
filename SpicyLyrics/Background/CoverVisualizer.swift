import MetalKit
import SwiftUI
import UIKit

/// The nebula full screen: behind the big cover, or alone where lyrics were hidden.
struct CoverVisualizerView: View {
    let player: PlayerModel
    var reduced = false
    /// The background's darkening, so white lines stay readable on bright covers.
    var dim: Double = 0
    /// Random colours (a new set for every song) instead of the cover's.
    var randomColors = false
    /// Counts the frames drawn, for the FPS badge.
    var frameCounter: FrameRateCounter?

    var body: some View {
        CoverVisualizer(image: player.backgroundArtwork, imageID: player.artworkID, player: player, reduced: reduced,
                        randomColors: randomColors, frameCounter: frameCounter)
            .overlay(Color.black.opacity(dim))
            .ignoresSafeArea()
    }
}

/// Experimental: a visualizer in the colours of the cover, for songs without lyrics. iOS lets no
/// app hear what Spotify plays, so it can't follow the sound itself; it follows the playback
/// instead: it runs while the song plays and settles almost to a stop on pause.
struct CoverVisualizer: UIViewRepresentable {
    let image: UIImage?
    let imageID: String
    let player: PlayerModel
    var reduced = false
    var randomColors = false
    var frameCounter: FrameRateCounter?

    static var isSupported: Bool { VisualizerSurface.isSupported }

    func makeUIView(context: Context) -> VisualizerSurface {
        let view = VisualizerSurface()
        let player = player
        view.progress = {
            MainActor.assumeIsolated {
                guard let duration = player.track?.duration, duration > 0 else { return 0 }
                return min(1, max(0, player.playbackPosition() / duration))
            }
        }
        return view
    }

    func updateUIView(_ view: VisualizerSurface, context: Context) {
        view.playing = player.isPlaying
        view.reduced = reduced
        view.frameCounter = frameCounter
        view.setImage(image, id: imageID, random: randomColors)
    }
}

final class VisualizerSurface: ShaderSurface {
    static let isSupported: Bool = {
        guard let library = sharedDevice?.makeDefaultLibrary() else { return false }
        return library.makeFunction(name: "visualizerFragment") != nil
    }()

    private struct Uniforms {
        var deep: SIMD3<Float>
        var vivid: SIMD3<Float>
        var accent: SIMD3<Float>
        var resolution: SIMD2<Float>
        var time: Float
        var progress: Float
        var energy: Float
    }

    var playing = false { didSet { updateRate() } }
    var reduced = false { didSet { updateRate() } }
    var progress: () -> Double = { 0 }
    var frameCounter: FrameRateCounter?

    /// The frame rate it runs at.
    static func framesPerSecond(playing: Bool, reduced: Bool) -> Int {
        reduced ? 20 : (playing ? 30 : 20)
    }

    private var palette = CoverPalette.fallback
    private var target = CoverPalette.fallback
    private var paletteKey: String?
    private var processing: Task<Void, Never>?
    /// Runs with the music; starts somewhere random so two songs never look the same.
    private var time = Double.random(in: 0...500)
    private var energy: Double = 0

    init() {
        super.init(fragment: "visualizerFragment")
        updateRate()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { processing?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // About 1.5 pixels per point on a phone, capped on iPad: soft glow needs no more.
        let scale = min(1.5, 760 / max(bounds.width, 1))
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size { drawableSize = size }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isPaused = window == nil
        resetClock()
    }

    func setImage(_ image: UIImage?, id: String, random: Bool = false) {
        let key = (image == nil ? "" : id) + (random ? "|random" : "")
        guard key != paletteKey else { return }
        paletteKey = key
        processing?.cancel()
        if random {
            // Its own colours for every song, the same ones each time it comes back.
            target = CoverPalette.random(seed: id)
            return
        }
        guard let image else {
            target = .fallback
            return
        }
        processing = Task.detached(priority: .utility) { [weak self] in
            let palette = CoverPalette.of(image)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.paletteKey == key else { return }
                self.target = palette
            }
        }
    }

    private func updateRate() {
        preferredFramesPerSecond = Self.framesPerSecond(playing: playing, reduced: reduced)
    }

    override func didDraw(now: CFTimeInterval) {
        frameCounter?.tick(now)
    }

    override func encode(_ encoder: MTLRenderCommandEncoder, dt: Double, now: CFTimeInterval) {
        // A new cover's colours flow in over a couple of seconds.
        palette = palette.mixed(toward: target, amount: Float(1 - exp(-dt * 1.4)))
        energy += ((playing ? 1 : 0) - energy) * (1 - exp(-dt * 2.5))
        time += dt * (0.05 + 0.95 * energy)
        var uniforms = Uniforms(deep: palette.deep, vivid: palette.vivid, accent: palette.accent,
                                resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                                time: Float(time.truncatingRemainder(dividingBy: 10_000)),
                                progress: Float(progress()), energy: Float(energy))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    }
}

/// Three colours picked from a cover: its darkest tone, its most vivid colour and a second vivid
/// colour of another hue, brightened enough to glow.
struct CoverPalette {
    var deep: SIMD3<Float>
    var vivid: SIMD3<Float>
    var accent: SIMD3<Float>

    static let fallback = CoverPalette(deep: SIMD3(0.05, 0.04, 0.12), vivid: SIMD3(0.55, 0.25, 0.95),
                                       accent: SIMD3(1.0, 0.35, 0.55))

    /// A random but harmonious set, picked by `seed` (the same seed, the same colours).
    static func random(seed: String) -> CoverPalette {
        var state: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 { state = (state ^ UInt64(byte)) &* 1_099_511_628_211 }
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let hue: Float = next()
        let spread: Float = 0.18 + next() * 0.3
        let deep = rgb(h: fract(hue + 0.55), s: 0.6, v: 0.16)
        let vivid = rgb(h: hue, s: 0.75, v: 0.95)
        let accent = rgb(h: fract(hue + spread), s: 0.65, v: 1)
        return CoverPalette(deep: deep, vivid: vivid, accent: accent)
    }

    func mixed(toward other: CoverPalette, amount: Float) -> CoverPalette {
        CoverPalette(deep: deep + (other.deep - deep) * amount,
                     vivid: vivid + (other.vivid - vivid) * amount,
                     accent: accent + (other.accent - accent) * amount)
    }

    static func of(_ image: UIImage) -> CoverPalette {
        guard let cgImage = image.cgImage else { return fallback }
        let n = 24
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                          bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return fallback }
        // Spelled out step by step: older compilers time out type-checking the compact forms.
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            let r = Float(bytes[i * 4]) / 255
            let g = Float(bytes[i * 4 + 1]) / 255
            let b = Float(bytes[i * 4 + 2]) / 255
            pixels.append(SIMD3<Float>(r, g, b))
        }

        // Colours come from the most colourful pixels only (the top sixth by chroma), so a few
        // bright flowers count for more than a large beige wall: averaging everything gave mud.
        func chroma(_ color: SIMD3<Float>) -> Float {
            let (_, s, v) = hsv(color)
            return s * v
        }
        let byChroma = pixels.sorted { chroma($0) > chroma($1) }
        let colourful = Array(byChroma.prefix(max(24, pixels.count / 6)))

        // A grey or black-and-white cover: moonlight, a cool silver blue with a violet edge.
        guard let best = colourful.first, chroma(best) >= 0.15 else {
            return CoverPalette(deep: rgb(h: 0.64, s: 0.55, v: 0.1), vivid: rgb(h: 0.6, s: 0.32, v: 0.95),
                                accent: rgb(h: 0.72, s: 0.38, v: 1))
        }

        // k-means (k = 4) over those, seeded around the colour wheel.
        let byHue = colourful.sorted { hsv($0).h < hsv($1).h }
        var centers: [SIMD3<Float>] = []
        for k in 0..<4 {
            let index: Int = min(byHue.count - 1, (k * 2 + 1) * byHue.count / 8)
            centers.append(byHue[index])
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for _ in 0..<10 {
            var sums = [SIMD3<Float>](repeating: .zero, count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for pixel in colourful {
                var nearest = 0
                var nearestDistance = Float.infinity
                for (index, center) in centers.enumerated() {
                    let d: SIMD3<Float> = pixel - center
                    let distance: Float = d.x * d.x + d.y * d.y + d.z * d.z
                    if distance < nearestDistance { nearestDistance = distance; nearest = index }
                }
                sums[nearest] += pixel
                counts[nearest] += 1
            }
            for index in centers.indices where counts[index] > 0 {
                centers[index] = sums[index] / Float(counts[index])
            }
        }
        var clusters: [(color: SIMD3<Float>, share: Float)] = []
        for index in centers.indices where counts[index] > 0 {
            let share = Float(counts[index]) / Float(colourful.count)
            clusters.append((color: centers[index], share: share))
        }
        func score(_ cluster: (color: SIMD3<Float>, share: Float)) -> Float {
            chroma(cluster.color) * (0.3 + sqrt(cluster.share))
        }
        let ranked = clusters.sorted { score($0) > score($1) }
        let lead = ranked.first?.color ?? best
        let leadHue = hsv(lead).h
        let second = ranked.dropFirst().first { cluster in
            let difference = abs(hsv(cluster.color).h - leadHue)
            return min(difference, 1 - difference) > 0.07 && chroma(cluster.color) > 0.15
        }
        // One colour only: its neighbour on the wheel, so the nebula still shimmers.
        let accent = second?.color ?? rgb(h: fract(leadHue + 0.09), s: hsv(lead).s, v: 1)

        // Dark orange and dark yellow read as brown: their shadows lean towards crimson instead.
        let warm = leadHue > 0.02 && leadHue < 0.17
        let deepHue = warm ? fract(leadHue - 0.07) : leadHue
        return CoverPalette(deep: rgb(h: deepHue, s: 0.9, v: 0.22),
                            vivid: lift(lead, saturation: 0.72, value: 0.95, maxValue: 1),
                            accent: lift(accent, saturation: 0.62, value: 1, maxValue: 1))
    }

    private static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    private static func fract(_ x: Float) -> Float { x - x.rounded(.down) }

    /// At least this saturated and bright (grey covers still get some colour), at most `maxValue`.
    private static func lift(_ c: SIMD3<Float>, saturation: Float, value: Float, maxValue: Float) -> SIMD3<Float> {
        let (h, s, v) = hsv(c)
        return rgb(h: h, s: max(s, saturation), v: min(max(v, value), maxValue))
    }

    private static func hsv(_ c: SIMD3<Float>) -> (h: Float, s: Float, v: Float) {
        let maxC = max(c.x, c.y, c.z), minC = min(c.x, c.y, c.z)
        let delta = maxC - minC
        var h: Float = 0
        if delta > 1e-5 {
            if maxC == c.x { h = (c.y - c.z) / delta } else if maxC == c.y { h = 2 + (c.z - c.x) / delta } else { h = 4 + (c.x - c.y) / delta }
            h = fract(h / 6)
        }
        return (h, maxC > 0 ? delta / maxC : 0, maxC)
    }

    private static func rgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let k = SIMD3<Float>(5, 3, 1)
        var result = SIMD3<Float>(repeating: 0)
        for i in 0..<3 {
            let n = (k[i] + h * 6).truncatingRemainder(dividingBy: 6)
            result[i] = v - v * s * max(0, min(n, 4 - n, 1))
        }
        return result
    }
}
