import SwiftUI
import UniformTypeIdentifiers

/// Bring-your-own TTML, like the extension's Lyrics Manager: apply a file to the current track
/// just once or save it to the library, and manage what is saved.
struct OwnLyricsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ttmlUploadMode") private var modeRaw = PlayerModel.TTMLMode.library.rawValue

    @State private var importing = false
    @State private var message: (text: String, isError: Bool)?

    private var mode: PlayerModel.TTMLMode { PlayerModel.TTMLMode(rawValue: modeRaw) ?? .library }

    /// `.ttml` files show up with a dynamic type; XML and plain text cover renamed copies.
    private static let types: [UTType] = [UTType(filenameExtension: "ttml"), .xml, .plainText].compactMap { $0 }

    var body: some View {
        NavigationStack {
            List {
                currentTrackSection
                librarySection
            }
            .navigationTitle(String(localized: "Свои тексты (TTML)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Готово")) { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let error): message = (error.localizedDescription, true)
                }
            }
        }
    }

    // MARK: Current track

    private var currentTrackSection: some View {
        Section {
            if let track = player.track {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline)
                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary)
                }

                Picker(String(localized: "Режим"), selection: $modeRaw) {
                    Text(String(localized: "В библиотеку")).tag(PlayerModel.TTMLMode.library.rawValue)
                    Text(String(localized: "Только сейчас")).tag(PlayerModel.TTMLMode.temporary.rawValue)
                }
                .pickerStyle(.segmented)

                Button {
                    importing = true
                } label: {
                    Label(String(localized: "Выбрать файл .ttml"), systemImage: "doc.badge.plus")
                }
                Button {
                    apply(UIPasteboard.general.string)
                } label: {
                    Label(String(localized: "Вставить TTML из буфера"), systemImage: "doc.on.clipboard")
                }

                if player.localLyrics.contains(track.id) || player.hasTemporaryLyrics {
                    Button(role: .destructive) {
                        player.removeOwnLyrics(trackID: track.id)
                        message = (String(localized: "Свой текст убран, вернулся текст из сети."), false)
                    } label: {
                        Label(String(localized: "Убрать свой текст для этого трека"), systemImage: "trash")
                    }
                }

                if let message {
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(message.isError ? .red : .green)
                }
            } else {
                Text(String(localized: "Включите трек в выбранном музыкальном приложении, чтобы привязать к нему свой текст."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Текущий трек"))
        } footer: {
            Text(mode == .library
                 ? String(localized: "Текст сохранится в библиотеке и будет показываться для этого трека вместо текстов из сети.")
                 : String(localized: "Текст покажется только сейчас, до закрытия приложения."))
        }
    }

    // MARK: Library

    private var librarySection: some View {
        Section {
            if player.localLyrics.entries.isEmpty {
                Text(String(localized: "Пока пусто"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(player.localLyrics.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text("\(entry.artist) · \(entry.savedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { player.localLyrics.entries[$0].trackID }
                    ids.forEach { player.removeOwnLyrics(trackID: $0) }
                }
            }
        } header: {
            Text(String(localized: "Библиотека"))
        } footer: {
            Text(String(localized: "Смахните влево, чтобы удалить."))
        }
    }

    // MARK: Import

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            apply(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        } catch {
            message = (String(localized: "Не удалось прочитать файл: \(error.localizedDescription)"), true)
        }
    }

    private func apply(_ text: String?) {
        guard let text, !text.isEmpty else {
            message = (String(localized: "В буфере обмена нет текста."), true)
            return
        }
        do {
            try player.applyTTML(text, mode: mode)
            message = (mode == .library ? String(localized: "Сохранено в библиотеку и показано.") : String(localized: "Показано до закрытия приложения."), false)
        } catch {
            message = (error.localizedDescription, true)
        }
    }
}
