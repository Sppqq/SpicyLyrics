import QuartzCore
import SwiftUI

/// Counts the frames actually drawn, for the FPS badge (main thread only). Deliberately not
/// observable: ticking it every frame must not make SwiftUI redraw anything.
final class FrameRateCounter {
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var measured: Double = 0

    func tick(_ now: CFTimeInterval = CACurrentMediaTime()) {
        if windowStart == 0 { windowStart = now }
        frames += 1
        lastTick = now
        let elapsed = now - windowStart
        if elapsed >= 0.5 {
            measured = Double(frames) / elapsed
            frames = 0
            windowStart = now
        }
    }

    /// Frames per second over the last half second; 0 once frames stop coming.
    func fps(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        now - lastTick > 1 ? 0 : measured
    }
}

/// "58 / 60 fps" over the lyrics.
struct FPSBadge: View {
    let counter: FrameRateCounter
    let target: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let fps = counter.fps()
            HStack(spacing: 5) {
                Circle()
                    .fill(fps >= target * 0.9 ? Color.green : (fps >= target * 0.6 ? Color.yellow : Color.red))
                    .frame(width: 7, height: 7)
                Text("\(Int(fps.rounded())) / \(Int(target.rounded())) fps")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35), in: Capsule())
        }
        .allowsHitTesting(false)
    }
}
