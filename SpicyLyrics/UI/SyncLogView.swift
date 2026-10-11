import SwiftUI

/// Settings → Log: every poll, App Remote event and clock correction, and every error, to share
/// when something goes wrong.
struct SyncLogView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(SpotifyAppRemote.self) private var appRemote
    @State private var exported: URL?
    @State private var copied = false

    private let log = SyncLog.shared

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle(String(localized: "Вести журнал"), isOn: $settings.syncLogEnabled)
                if let exported {
                    ShareLink(item: exported) {
                        Label(String(localized: "Отправить файл журнала"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    UIPasteboard.general.string = (header() + [""] + lines()).joined(separator: "\n")
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Скопировано") : String(localized: "Скопировать журнал"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button(role: .destructive) {
                    log.clear()
                    refreshFile()
                } label: {
                    Label(String(localized: "Очистить"), systemImage: "trash")
                }
            } footer: {
                Text(String(localized: "Когда что-то пошло не так (текст отстаёт, пауза не совпадает, ошибка): отправьте файл журнала. В нём тайминги, ошибки, названия треков и настройки, без ключей и токенов."))
            }

            Section(String(localized: "Последние записи")) {
                if log.entries.isEmpty {
                    Text(String(localized: "Пока пусто")).foregroundStyle(.secondary)
                }
                ForEach(log.entries.suffix(300).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SyncLog.time(entry.date))  \(entry.source)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear(perform: refreshFile)
        .onChange(of: log.entries.count) { _, _ in copied = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Обновить"), systemImage: "arrow.clockwise", action: refreshFile)
            }
        }
    }

    private func refreshFile() {
        exported = log.export(header: header())
    }

    private func lines() -> [String] {
        log.entries.map { "\(SyncLog.time($0.date)) [\($0.source)] \($0.message)" }
    }

    private func header() -> [String] {
        let device = UIDevice.current
        return [
            "Spicy Lyrics \(AppVersion.display)",
            "\(device.model), \(device.systemName) \(device.systemVersion)",
            "Exported \(SyncLog.time(Date()))",
            "offset \(Int(settings.timingOffsetMs)) ms, headphone latency \(settings.compensateOutputLatency ? "on" : "off") "
                + "(route \(Int(AudioRoute.outputLatency * 1000)) ms)",
            "App Remote \(settings.useAppRemote ? "on" : "off"): \(appRemote.status), keeps clock \(player.remoteConnected)",
            "web poll \(settings.webPollInterval)s, remote query \(settings.remoteQueryInterval)s",
            "now: \(player.isPlaying ? "playing" : "paused") at \(player.playbackPosition().s3)s, "
                + "track \"\(player.track?.title ?? "-")\" \(player.track?.uri ?? "")",
        ]
    }
}

/// A small badge over the lyrics: where the time last came from and how far off the clock was.
struct SyncIndicator: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let sync = SyncLog.shared.lastSync
            HStack(spacing: 6) {
                Circle()
                    .fill(player.remoteConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                if let sync {
                    Text("\(sync.source) \(sync.drift.signedMs) · \(String(format: "%.1f", context.date.timeIntervalSince(sync.at)))s")
                } else {
                    Text(player.remoteConnected ? "App Remote" : "Web API")
                }
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
