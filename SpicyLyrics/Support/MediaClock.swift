import QuartzCore

/// The lyrics' sense of "now". Always `CACurrentMediaTime()`, except in Debug builds launched
/// with `-demoTimeScale <s>`: then time runs `s` times as fast, so a slow Simulator recording
/// can be sped back up into a smooth clip (the README's recordings).
enum MediaClock {
    #if DEBUG
    static let scale: Double = {
        let value = UserDefaults.standard.double(forKey: "demoTimeScale")
        return value > 0 ? value : 1
    }()
    private static let origin = CACurrentMediaTime()

    static func now() -> CFTimeInterval {
        guard scale != 1 else { return CACurrentMediaTime() }
        return origin + (CACurrentMediaTime() - origin) * scale
    }

    /// SwiftUI animations run on the real clock: stretch their durations by this so they keep
    /// pace with a slowed demo clock (else the recording, sped back up, shows them too fast).
    static var durationScale: Double { 1 / scale }
    #else
    @inline(__always)
    static func now() -> CFTimeInterval { CACurrentMediaTime() }

    static let durationScale: Double = 1
    #endif
}
