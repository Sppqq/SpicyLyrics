import Foundation
import Observation
import QuartzCore
import UIKit

/// A rolling log of everything that moves the lyrics clock (Web API polls, App Remote events and
/// queries, every correction and why) and of every error: requests, lyrics, translation, Picture
/// in Picture, sign-in. Settings → Log shows it and shares it as a file.
@MainActor
@Observable
final class SyncLog {
    static let shared = SyncLog()

    struct Entry: Identifiable {
        let id: Int
        let date: Date
        /// Media time, for exact spacing between entries.
        let media: CFTimeInterval
        let source: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    /// Latest correction, for the sync indicator.
    private(set) var lastSync: (source: String, drift: Double, at: Date)?
    @ObservationIgnored var enabled = true
    @ObservationIgnored private var nextID = 0
    private static let limit = 4000

    func add(_ source: String, _ message: String, at date: Date = Date()) {
        // Errors go to the reports even with the log off (the user agreed to those separately).
        ReportService.shared.noteError(source: source, message: message)
        guard enabled else { return }
        entries.append(Entry(id: nextID, date: date, media: CACurrentMediaTime(), source: source, message: message))
        nextID += 1
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// From any thread.
    nonisolated static func log(_ source: String, _ message: String) {
        let date = Date()
        Task { @MainActor in shared.add(source, message, at: date) }
    }

    /// A clock reading that was compared with (and maybe applied to) the lyrics clock.
    func synced(_ source: String, drift: Double) {
        lastSync = (source, drift, Date())
    }

    func clear() {
        entries.removeAll()
        lastSync = nil
    }

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormat.string(from: date) }

    /// The whole log as text, with a header describing the device and the sync settings.
    func text(header: [String]) -> String {
        var lines = header
        lines.append("")
        for entry in entries {
            lines.append("\(Self.time(entry.date)) [\(entry.source)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }

    func export(header: [String]) -> URL? {
        // One file, rewritten: the log screen refreshes it as entries come in.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SweetLyrics-log.txt")
        do {
            try ReportService.sanitize(text(header: header)).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Short, log-friendly numbers.
extension Double {
    var s3: String { String(format: "%.3f", self) }
    var signedMs: String { String(format: "%+.0fms", self * 1000) }
}
