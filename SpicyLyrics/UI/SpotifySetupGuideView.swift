import SwiftUI

/// Step-by-step guide to creating one's own Spotify developer app and signing in with its
/// Client ID. Required for everyone: the app has no Client ID of its own.
struct SpotifySetupGuideView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    private static let dashboard = URL(string: "https://developer.spotify.com/dashboard")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Свой доступ к Spotify")
                        .font(.largeTitle.bold())
                    Text("Приложению нужен ваш собственный Client ID: так Spotify разрешает ему видеть, что у вас играет. Это бесплатно и занимает около 5 минут.")
                        .foregroundStyle(.white.opacity(0.75))
                }

                requirementCard

                step(1, "Откройте Spotify for Developers") {
                    Text("Войдите тем же аккаунтом, что и в приложении Spotify. При первом входе примите условия (Accept the terms) и подтвердите e-mail, если попросят.")
                    actionButton("Открыть developer.spotify.com", systemImage: "safari") {
                        openURL(Self.dashboard)
                    }
                    Text("Удобнее делать с компьютера, но и с телефона получится.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }

                step(2, "Создайте приложение") {
                    Text("Нажмите **Create app** и заполните форму:")
                    bullet("**App name** — любое, например «Spicy Lyrics».")
                    bullet("**App description** — любое, например «Тексты песен».")
                    bullet("**Website** — можно оставить пустым.")
                    bullet("**Redirect URIs** — вставьте адрес ниже и нажмите **Add**:")
                    redirectURIBox
                    bullet("В **Which API/SDKs are you planning to use?** отметьте **Web API**.")
                    bullet("Поставьте галочку согласия с условиями и нажмите **Save**.")
                }

                step(3, "Добавьте себя в пользователи") {
                    Text("В приложении откройте **Settings** → вкладка **User Management** → **Add new user**. Имя любое, e-mail — тот, к которому привязан ваш аккаунт Spotify, затем **Add user**.")
                    Text("Так же можно добавить ещё до четырёх друзей, и они войдут с вашим Client ID.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }

                step(4, "Скопируйте Client ID") {
                    Text("Вкладка **Basic Information** → поле **Client ID** (32 символа, буквы и цифры) → скопируйте.")
                    Label("Client secret не нужен. Никому его не отправляйте.", systemImage: "exclamationmark.shield")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                step(5, "Вставьте Client ID и войдите") {
                    clientIDField
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Button {
                        Task { await saveAndLogIn() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.black) }
                            Text("Сохранить и войти")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.12, green: 0.84, blue: 0.38), in: Capsule())
                        .foregroundStyle(.black)
                    }
                    .disabled(busy || !AppSettings.isValidClientID(draft))
                }

                troubleshooting
            }
            .padding(22)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.14), .black],
                           startPoint: .topLeading, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .foregroundStyle(.white)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if draft.isEmpty { draft = settings.spotifyClientID }
        }
    }

    // MARK: Pieces

    private var requirementCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Что понадобится", systemImage: "checklist")
                .font(.headline)
            Text("• Аккаунт **Spotify Premium**: с 2026 года Spotify запускает приложения разработчиков только у владельцев с Premium.")
            Text("• 5 минут и браузер.")
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var redirectURIBox: some View {
        HStack {
            Text(SpotifyAuth.redirectURI)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = SpotifyAuth.redirectURI
                copied = true
            } label: {
                Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var clientIDField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Client ID", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button {
                    if let text = UIPasteboard.general.string {
                        draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Label("Вставить", systemImage: "doc.on.clipboard")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(12)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !draft.isEmpty && !AppSettings.isValidClientID(draft) {
                Text("Client ID — это 32 символа из цифр и букв a–f. Проверьте, что скопирован именно Client ID, а не Client secret.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Если не получается")
                .font(.headline)
            problem("«INVALID_CLIENT: Invalid redirect URI»",
                    "Redirect URI в приложении Spotify должен быть ровно spicylyrics-ios://callback — без пробелов и без слэша в конце. После правки нажмите Save.")
            problem("«INVALID_CLIENT: Invalid client»",
                    "Client ID скопирован не полностью или с ошибкой. Скопируйте его ещё раз со вкладки Basic Information.")
            problem("Вход прошёл, но Spotify отвечает ошибкой 403",
                    "Добавьте свой e-mail в User Management (шаг 3) и проверьте, что у владельца приложения есть Premium.")
            problem("«Закончился лимит запросов»",
                    "Spotify ограничивает число запросов на аккаунт разработчика. Подождите несколько минут.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func problem(_ title: String, _ fix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(fix).font(.callout).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Color(red: 0.12, green: 0.84, blue: 0.38).opacity(0.85), in: Circle())
                .foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.weight(.semibold))
                content()
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.14), in: Capsule())
        }
    }

    // MARK: Sign in

    private func saveAndLogIn() async {
        let clientID = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppSettings.isValidClientID(clientID) else { return }
        busy = true
        error = nil
        defer { busy = false }
        // Switch over only if sign-in works: a cancelled attempt keeps the current session.
        let previous = settings.spotifyClientID
        settings.spotifyClientID = clientID
        do {
            try await auth.logIn()
            dismiss()
        } catch {
            settings.spotifyClientID = previous
            if case SpotifyAuthError.cancelled = error { return }
            self.error = error.localizedDescription
        }
    }
}
