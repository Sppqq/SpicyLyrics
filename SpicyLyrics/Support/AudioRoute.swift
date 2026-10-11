import AVFoundation

/// The delay between Spotify's playback position and what reaches the ears on this iPhone's
/// current audio output (AirPods and other Bluetooth headphones add ~150–250 ms).
enum AudioRoute {
    /// A playback session that mixes with others: it never interrupts Spotify, lets iOS report
    /// the latency of the current route, and is what Picture in Picture requires.
    static func prepare() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    /// Output latency of the current route in seconds (clamped to something plausible).
    static var outputLatency: Double {
        min(max(AVAudioSession.sharedInstance().outputLatency, 0), 0.5)
    }

    /// Name of the current output ("iPhone Speaker", "AirPods Pro").
    static var outputName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "?"
    }
}
