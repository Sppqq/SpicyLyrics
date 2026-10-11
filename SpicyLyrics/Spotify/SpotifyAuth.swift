import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?
    /// The Client ID these tokens belong to; they stop working once the app uses another one.
    var clientID: String?

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
}

enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case cancelled
    case badCallback(String)
    case tokenEndpoint(Int, String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .missingClientID: return String(localized: "Укажите Client ID приложения Spotify в настройках.")
        case .cancelled: return String(localized: "Вход отменён.")
        case .badCallback(let reason): return String(localized: "Spotify вернул ошибку: \(reason)")
        case .tokenEndpoint(let code, let body): return String(localized: "Не удалось получить токен (HTTP \(code)): \(body)")
        case .notLoggedIn: return String(localized: "Нужно войти в Spotify.")
        }
    }
}

/// Authorization Code flow with PKCE against accounts.spotify.com. No client secret is involved,
/// so every user can plug in the Client ID of their own Spotify developer app.
@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    static let redirectURI = "spicylyrics-ios://callback"
    static let callbackScheme = "spicylyrics-ios"
    static let scopes = [
        "user-read-currently-playing",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-recently-played",
        // Lets App Remote read the exact position from the Spotify app on this phone.
        "app-remote-control",
    ]

    @Published private(set) var isLoggedIn = false

    private let settings: AppSettings
    private var tokens: SpotifyTokens?
    private var refreshTask: Task<SpotifyTokens, Error>?
    private var session: ASWebAuthenticationSession?
    private var anchorProvider: PresentationAnchorProvider?
    private static let keychainKey = "spotify.tokens"

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        if let data = Keychain.read(Self.keychainKey),
           let stored = try? JSONDecoder().decode(SpotifyTokens.self, from: data) {
            tokens = stored
            isLoggedIn = stored.refreshToken != nil || stored.isFresh
        }
        // Sessions from the former built-in Client ID (or with none set) are dropped: the app
        // only works through the user's own Spotify app now.
        if tokens != nil, !settings.hasValidClientID || tokens?.clientID != settings.effectiveSpotifyClientID {
            logOut()
        }
    }

    // MARK: Login

    func logIn() async throws {
        let clientID = settings.effectiveSpotifyClientID
        guard !clientID.isEmpty else { throw SpotifyAuthError.missingClientID }

        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]

        let callback = try await authenticate(url: components.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyAuthError.badCallback(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw SpotifyAuthError.badCallback(String(localized: "неверный ответ авторизации")) }

        let newTokens = try await requestToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ], previousRefresh: nil)
        store(newTokens)
    }

    func logOut() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        Keychain.delete(Self.keychainKey)
        isLoggedIn = false
    }

    /// Whether the current login granted `scope`. Logins made before a scope was added lack it
    /// until the user signs in again. Unknown (no scope string stored) counts as granted.
    func hasScope(_ scope: String) -> Bool {
        guard let granted = tokens?.scope else { return true }
        return granted.split(separator: " ").contains { $0 == scope }
    }

    // MARK: Tokens

    /// A usable access token, refreshing it first when it is about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if tokens != nil, tokens?.clientID != settings.effectiveSpotifyClientID || !settings.hasValidClientID {
            // The Client ID changed in settings: this session belongs to the old one.
            logOut()
            throw SpotifyAuthError.notLoggedIn
        }
        if !forceRefresh, let tokens, tokens.isFresh { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }

        guard let refresh = tokens?.refreshToken else {
            logOut()
            throw SpotifyAuthError.notLoggedIn
        }
        let clientID = settings.effectiveSpotifyClientID
        let task = Task { [weak self] () async throws -> SpotifyTokens in
            guard let self else { throw CancellationError() }
            return try await self.requestToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": clientID,
            ], previousRefresh: refresh)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh.accessToken
        } catch SpotifyAuthError.tokenEndpoint(let status, let body) where status == 400 || status == 401 {
            SyncLog.shared.add("auth", "token refresh rejected (\(status)), signing out")
            // The refresh token was revoked (or the Client ID changed): start over.
            logOut()
            throw SpotifyAuthError.tokenEndpoint(status, body)
        }
    }

    private func store(_ newTokens: SpotifyTokens) {
        tokens = newTokens
        if let data = try? JSONEncoder().encode(newTokens) {
            Keychain.write(Self.keychainKey, data: data)
        }
        isLoggedIn = true
    }

    private func requestToken(form: [String: String], previousRefresh: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SpotifyAuthError.tokenEndpoint(status, String(data: data, encoding: .utf8) ?? "")
        }
        struct Payload: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
            let scope: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return SpotifyTokens(
            accessToken: payload.access_token,
            // Spotify may omit a new refresh token on refresh; keep the old one then.
            refreshToken: payload.refresh_token ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(payload.expires_in),
            scope: payload.scope,
            clientID: form["client_id"]
        )
    }

    private func authenticate(url: URL) async throws -> URL {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        let provider = PresentationAnchorProvider(anchor: window ?? ASPresentationAnchor())
        anchorProvider = provider

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: SpotifyAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SpotifyAuthError.badCallback(String(localized: "не удалось открыть окно входа")))
            }
        }
    }

    // MARK: PKCE

    private static func randomVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<96).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Hands ASWebAuthenticationSession the window to present from (it holds this weakly).
private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

extension CharacterSet {
    static let formValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
