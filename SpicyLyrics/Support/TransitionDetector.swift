import Foundation

enum TransitionMode: String, CaseIterable, Identifiable, Hashable {
    case automatic, manual
    var id: String { rawValue }
}

/// Estimates describe observed player behavior, never a setting read from the music app.
struct TransitionDetector: Codable {
    struct Sample: Codable {
        var remaining: Double
        var startOffset: Double
    }

    struct Estimate: Codable {
        var crossfadeSeconds: Double? = nil
        var autoMix = false
        var isKnown: Bool { crossfadeSeconds != nil || autoMix }
    }

    private struct History: Codable {
        var samples: [Sample] = []
        var estimate = Estimate()
    }

    private var histories: [String: History] = [:]

    init() {}

    func estimate(for source: PlaybackSource) -> Estimate {
        histories[source.rawValue]?.estimate ?? Estimate()
    }

    mutating func reset(for source: PlaybackSource) {
        histories[source.rawValue] = nil
    }

    mutating func record(remaining: Double, startOffset: Double, source: PlaybackSource) {
        guard remaining.isFinite, startOffset.isFinite, startOffset >= 0 else { return }
        var history = histories[source.rawValue] ?? History()
        history.samples.append(Sample(remaining: remaining, startOffset: startOffset))
        history.samples = Array(history.samples.suffix(6))

        // A recent agreeing run adapts without mixing an old setting into the new one.
        let values = history.samples.map { $0.remaining < 0.7 ? 0 : $0.remaining }
        var agreeing: [Double] = []
        for value in values.reversed() {
            let candidate = agreeing + [value]
            guard (value == 0) == (values.last == 0),
                  (candidate.max() ?? 0) - (candidate.min() ?? 0) <= 1.5 else { break }
            agreeing = candidate
        }
        if agreeing.count >= 2 {
            let sorted = agreeing.sorted()
            let middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            history.estimate.crossfadeSeconds = median == 0 ? 0 : min(12, max(1, median.rounded()))
        }

        if source == .appleMusic {
            let recent = Array(history.samples.suffix(4))
            let clean = history.samples.suffix(3)
            let longTransitions = recent.filter { $0.remaining > 2 }.map(\.remaining)
            let variable = longTransitions.count >= 2
                && (longTransitions.max() ?? 0) - (longTransitions.min() ?? 0) > 3
            if clean.count == 3, clean.allSatisfy({ $0.remaining < 0.7 && $0.startOffset < 1 }) {
                history.estimate.autoMix = false
            } else if recent.filter({ $0.startOffset > 1.5 }).count >= 2 || variable {
                history.estimate.autoMix = true
            }
        }
        histories[source.rawValue] = history
    }

    /// Session-only eligibility: gaps, pauses and seeks must not train persisted estimates.
    struct PlaybackRun {
        private var trackID: String?
        private var startedAt: TimeInterval = 0
        private var interrupted = true

        init() {}

        mutating func begin(trackID: String?, playing: Bool, at now: TimeInterval) {
            self.trackID = trackID
            startedAt = now
            interrupted = trackID == nil || !playing
        }

        mutating func interrupt() { interrupted = true }

        func allowsMeasurement(trackID: String, at now: TimeInterval) -> Bool {
            self.trackID == trackID && !interrupted && now - startedAt >= 20
        }
    }
}
