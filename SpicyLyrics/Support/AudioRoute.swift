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

/// Keeps the app running behind the floating lyrics window. iOS lets an app with a PiP window
/// run only while the window "plays"; when Spotify paused for a moment between songs the window
/// showed a pause, iOS suspended the app, and the lyrics stood still until it was opened again.
/// Silence on the shared (mixable) playback session keeps it awake without touching Spotify.
@MainActor
final class SilentAudio {
    static let shared = SilentAudio()

    private let engine = AVAudioEngine()
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let source = AVAudioSourceNode(format: format, renderBlock: Self.renderSilence)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        // A call or another app's audio stops the engine: start it again once that is over.
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume("audio route changed") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            MainActor.assumeIsolated { self?.resume("interruption ended") }
        })
    }

    /// Runs on the audio thread: nothing but zeros.
    private nonisolated static let renderSilence: AVAudioSourceNodeRenderBlock = { _, _, _, buffers in
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return noErr
    }

    func start() {
        wanted = true
        resume("pip")
    }

    func stop() {
        wanted = false
        guard engine.isRunning else { return }
        engine.stop()
        SyncLog.log("audio", "keep-alive off")
    }

    private func resume(_ reason: String) {
        guard wanted, !engine.isRunning else { return }
        AudioRoute.prepare()
        do {
            try engine.start()
            SyncLog.log("audio", "keep-alive on (\(reason))")
        } catch {
            SyncLog.log("audio", "keep-alive failed: \(error.localizedDescription)")
        }
    }
}
