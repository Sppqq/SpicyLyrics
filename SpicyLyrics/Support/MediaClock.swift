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
    #else
    @inline(__always)
    static func now() -> CFTimeInterval { CACurrentMediaTime() }
    #endif
}
