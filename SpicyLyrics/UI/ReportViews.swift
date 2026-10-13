import PhotosUI
import SwiftUI

/// Settings → Reports: whether errors may be sent by themselves, and a form to report a problem.
struct ReportSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Отправлять отчёты об ошибках"), isOn: $settings.sendsReports)
            } footer: {
                Text(String(localized: "Когда что-то ломается, приложение анонимно отправит разработчику журнал: версия приложения, модель телефона и iOS, названия треков, тайминги и настройки. Без аккаунта Spotify, ключей, токенов и имён ваших устройств. Не чаще пяти раз в день, хранится 90 дней."))
            }

            Section {
                NavigationLink {
                    ReportComposeView()
                        .settingsPage()
                        .navigationTitle(String(localized: "Сообщить о проблеме"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(String(localized: "Сообщить о проблеме"), systemImage: "exclamationmark.bubble")
                }
            } footer: {
                Text(String(localized: "Опишите, что не так, приложите фото и журнал. Это увидит только разработчик."))
            }
        }
    }
}

/// Describe a problem, attach up to three photos and the log, and send it.
struct ReportComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeLog = true
    @State private var picked: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var canSend: Bool {
        !sending && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty || includeLog)
    }

    var body: some View {
        Form {
            Section(String(localized: "Что случилось")) {
                TextEditor(text: $message)
                    .frame(minHeight: 120)
            }

            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: 3, matching: .images) {
                    Label(String(localized: "Добавить фото"), systemImage: "photo.on.rectangle")
                }
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(photos.indices, id: \.self) { index in
                                thumbnail(index)
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "Фото"))
            } footer: {
                Text(String(localized: "До трёх фото, например скриншот. Их увидит только разработчик."))
            }

            Section {
                Toggle(String(localized: "Приложить журнал"), isOn: $includeLog)
            } footer: {
                Text(String(localized: "В журнале тайминги, ошибки, названия треков и настройки, без ключей, токенов и имён ваших устройств."))
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        Text(String(localized: "Отправить"))
                        Spacer()
                        if sending { ProgressView() }
                    }
                }
                .disabled(!canSend)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .onChange(of: picked) { _, items in
            Task { await load(items) }
        }
        .alert(String(localized: "Отправлено"), isPresented: $sent) {
            Button("OK") { dismiss() }
        } message: {
            Text(String(localized: "Спасибо! Отчёт ушёл разработчику."))
        }
    }

    @ViewBuilder
    private func thumbnail(_ index: Int) -> some View {
        if let image = UIImage(data: photos[index]) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        guard picked.indices.contains(index) else { return }
                        picked.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var loaded: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = Self.compress(data) else { continue }
            loaded.append(jpeg)
        }
        photos = loaded
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await ReportService.shared.send(
                kind: "manual", message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                photos: photos, includeLog: includeLog)
            sent = true
        } catch {
            failure = error.localizedDescription
        }
    }

    /// A JPEG of at most ~1600 px and under 1.8 MB (the server takes 2 MB).
    private static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        var longestSide: CGFloat = 1600
        for quality in [0.7, 0.5, 0.35] {
            let scale = min(1, longestSide / max(image.size.width, image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let jpeg = scaled.jpegData(compressionQuality: quality), jpeg.count < 1_800_000 { return jpeg }
            longestSide *= 0.7
        }
        return nil
    }
}
