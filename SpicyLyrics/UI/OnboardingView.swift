import SwiftUI

/// First run: set up one's own Spotify Client ID (step-by-step guide), then sign in with it.
struct OnboardingView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings
    @State private var error: String?
    @State private var busy = false

    private var canLogIn: Bool { settings.hasValidClientID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sweet Lyrics")
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .foregroundStyle(Sweet.gradient)
                        Text(String(localized: "Синхронные по словам тексты для того, что играет у вас в Spotify."))
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    if canLogIn {
                        loginButton
                    }

                    accessExplanation

                    NavigationLink {
                        SpotifySetupGuideView()
                    } label: {
                        Label(canLogIn ? String(localized: "Сменить Client ID") : String(localized: "Настроить доступ к Spotify (5 минут)"),
                              systemImage: "key.horizontal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background {
                                if canLogIn { Capsule().fill(.white.opacity(0.12)) } else { Capsule().fill(Sweet.gradient) }
                            }
                            .foregroundStyle(.white)
                    }

                    Text(String(localized: "Приложение не связано со Spotify AB и с авторами Spicy Lyrics. Это неофициальный порт расширения Spicy Lyrics под AGPL-3.0."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(
                ZStack {
                    Sweet.night
                    RadialGradient(colors: [Sweet.pink.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                    RadialGradient(colors: [Sweet.lilac.opacity(0.3), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 380)
                }
                .ignoresSafeArea()
            )
        }
    }

    private var loginButton: some View {
        Button {
            Task { await logIn() }
        } label: {
            HStack {
                if busy { ProgressView().tint(.white) }
                Text(String(localized: "Войти через Spotify"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Sweet.gradient, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(SquishButtonStyle())
        .disabled(busy)
    }

    @ViewBuilder
    private var accessExplanation: some View {
        if canLogIn {
            Text(String(localized: "Используется ваш Client ID …\(String(settings.spotifyClientID.suffix(4)))."))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            Text(String(localized: "Чтобы приложение видело, что играет в Spotify, нужно своё приложение в бесплатном кабинете разработчика Spotify и его Client ID. Это обязательно и занимает около 5 минут (нужен Spotify Premium). Пошаговая инструкция — по кнопке ниже."))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func logIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await auth.logIn()
        } catch SpotifyAuthError.cancelled {
            // Nothing to report.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
