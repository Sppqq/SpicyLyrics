import Foundation
import Observation
import UIKit

/// Looks for a newer stable release on GitHub (Settings → About → "Новые версии"), at most every
/// few hours, and offers it once per version. Alpha builds already run ahead of the last stable
/// release, so they only hear about a stable one that overtook them; local builds never ask.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let url: URL
    }

    /// A newer stable release than this build, once found.
    private(set) var latest: Release?
    private(set) var checking = false
    /// When the last check finished (shown in settings), nil before the first one.
    private(set) var lastChecked: Date?
    private(set) var failed = false

    @ObservationIgnored private let settings: AppSettings
    private static let endpoint = URL(string: "https://api.github.com/repos/Sppqq/sweet-lyrics-ios/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/Sppqq/sweet-lyrics-ios/releases/latest")!
    private static let interval: TimeInterval = 6 * 3600
    private static let lastCheckKey = "updateLastCheck"

    init(settings: AppSettings) {
        self.settings = settings
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Local Xcode builds have no real version to compare (`-demoUpdates YES` tries it anyway).
    static var isSupported: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demoUpdates") { return true }
        #endif
        return AppVersion.channel != "dev"
    }

    /// The release to tell the user about now: newer, notices on, not skipped.
    var pendingNotice: Release? {
        guard settings.notifyUpdates, let latest, latest.version != settings.skippedUpdateVersion else { return nil }
        return latest
    }

    /// Checks unless one ran recently (`force` from the settings button).
    func check(force: Bool = false) async {
        guard Self.isSupported, !checking else { return }
        if !force {
            guard settings.notifyUpdates else { return }
            if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        }
        checking = true
        failed = false
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("SweetLyrics-iOS/\(AppVersion.marketing)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            struct Payload: Decodable { let tag_name: String; let html_url: String? }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
            let now = Date()
            lastChecked = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
            if Self.isNewer(version, than: AppVersion.marketing) {
                latest = Release(version: version, url: payload.html_url.flatMap(URL.init(string:)) ?? Self.releasesPage)
                SyncLog.shared.add("update", "\(version) is out (this is \(AppVersion.display))")
            } else {
                latest = nil
            }
        } catch {
            failed = true
        }
    }

    /// "Пропустить эту версию": no more notices until a newer one.
    func skip(_ release: Release) {
        settings.skippedUpdateVersion = release.version
    }

    /// Updates come through AltStore or SideStore (My Apps); without either, the release page.
    func openUpdate(_ release: Release) {
        let stores = ["altstore://", "sidestore://"].compactMap(URL.init(string:))
        func open(_ index: Int) {
            guard index < stores.count else {
                UIApplication.shared.open(release.url)
                return
            }
            UIApplication.shared.open(stores[index]) { opened in
                if !opened { open(index + 1) }
            }
        }
        open(0)
    }

    /// Plain `X.Y.Z` comparison; anything after a "-" is ignored.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
