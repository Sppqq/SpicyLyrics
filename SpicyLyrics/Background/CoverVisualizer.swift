import MetalKit
import SwiftUI
import UIKit

/// The nebula full screen: behind the big cover, or alone where lyrics were hidden.
struct CoverVisualizerView: View {
    let player: PlayerModel
    var reduced = false
    /// The background's darkening, so white lines stay readable on bright covers.
    var dim: Double = 0

    var body: some View {
        CoverVisualizer(image: player.backgroundArtwork, imageID: player.artworkID, player: player, reduced: reduced)
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
        view.setImage(image, id: imageID)
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

    func setImage(_ image: UIImage?, id: String) {
        let key = image == nil ? "" : id
        guard key != paletteKey else { return }
        paletteKey = key
        processing?.cancel()
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
        preferredFramesPerSecond = reduced ? 20 : (playing ? 30 : 20)
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

        // k-means with k = 5, seeded along brightness.
        let sorted = pixels.sorted { luma($0) < luma($1) }
        var centers: [SIMD3<Float>] = []
        for k in 0..<5 {
            let index: Int = min(sorted.count - 1, (k * 2 + 1) * sorted.count / 10)
            centers.append(sorted[index])
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for _ in 0..<8 {
            var sums = [SIMD3<Float>](repeating: .zero, count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for pixel in pixels {
                var best = 0
                var bestDistance = Float.infinity
                for (index, center) in centers.enumerated() {
                    let d: SIMD3<Float> = pixel - center
                    let distance: Float = d.x * d.x + d.y * d.y + d.z * d.z
                    if distance < bestDistance { bestDistance = distance; best = index }
                }
                sums[best] += pixel
                counts[best] += 1
            }
            for index in centers.indices where counts[index] > 0 {
                centers[index] = sums[index] / Float(counts[index])
            }
        }
        var clusters: [(color: SIMD3<Float>, share: Float)] = []
        for index in centers.indices where counts[index] > 0 {
            let share = Float(counts[index]) / Float(pixels.count)
            clusters.append((color: centers[index], share: share))
        }
        guard !clusters.isEmpty else { return fallback }

        func vividness(_ cluster: (color: SIMD3<Float>, share: Float)) -> Float {
            let (_, s, v) = hsv(cluster.color)
            return sqrt(cluster.share) * (0.25 + s) * (0.3 + v)
        }
        let byVividness = clusters.sorted { vividness($0) > vividness($1) }
        let vivid = byVividness[0].color
        let vividHue = hsv(vivid).h
        let accentCluster = byVividness.dropFirst().first { cluster in
            let difference = abs(hsv(cluster.color).h - vividHue)
            return min(difference, 1 - difference) > 0.08 && hsv(cluster.color).s > 0.15
        }
        // A cover of one colour: the accent is that colour turned a little around the wheel.
        let accent = accentCluster?.color ?? rgb(h: fract(vividHue + 0.12), s: hsv(vivid).s, v: hsv(vivid).v)
        let deep = clusters.min { luma($0.color) < luma($1.color) }!.color

        return CoverPalette(deep: lift(deep, saturation: 0.35, value: 0.08, maxValue: 0.35),
                            vivid: lift(vivid, saturation: 0.55, value: 0.8, maxValue: 1),
                            accent: lift(accent, saturation: 0.5, value: 0.9, maxValue: 1))
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
