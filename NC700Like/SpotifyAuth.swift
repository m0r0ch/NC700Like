import Foundation
import AuthenticationServices
import UIKit
import NC700LikeKit

/// Spotify 認可コードフロー+PKCE の認証を担当(F7)。
/// リフレッシュトークンは Keychain に保存(access token も同様)。ログやコミットには出さない。
@MainActor
final class SpotifyAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyAuth()

    static let redirectURI = "nc700like://callback"
    static let scopes = SpotifyPKCE.defaultScopes
    static let clientIDDefaultsKey = "spotify.clientID"
    /// REQ F7: 期限の60秒前に更新。
    static let expiryLead = 60.0

    enum LoginState: Equatable {
        case loggedOut
        case inProgress
        case loggedIn
    }

    @Published private(set) var loginState: LoginState = .loggedOut
    @Published private(set) var accessTokenExpiresAt: Date?
    @Published private(set) var lastMessage: String = ""

    private var pendingVerifier: String?
    private var pendingState: String?
    private var session: ASWebAuthenticationSession?
    private var refreshTask: Task<String, Error>?

    var clientID: String {
        get { UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.clientIDDefaultsKey) }
    }

    var isLoggedIn: Bool {
        loginState == .loggedIn
    }

    override init() {
        super.init()
        loginState = KeychainStore.load(KeychainStore.Account.refreshToken) != nil ? .loggedIn : .loggedOut
        accessTokenExpiresAt = Self.loadExpiry()
    }

    static func loadExpiry() -> Date? {
        guard let text = KeychainStore.load(KeychainStore.Account.expiresAt),
              let interval = TimeInterval(text)
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// メッセージには秘密情報(client ID / トークン)を含めない。
    func startLogin() {
        let clientID = clientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else {
            lastMessage = "Client ID を入力してください。"
            return
        }
        self.clientID = clientID

        let verifier = SpotifyPKCE.generateCodeVerifier()
        let challenge = SpotifyPKCE.codeChallenge(from: verifier)
        let state = SpotifyPKCE.makeState()
        pendingVerifier = verifier
        pendingState = state
        loginState = .inProgress

        guard
            let url = SpotifyPKCE.authorizeURL(
                clientID: clientID,
                redirectURI: Self.redirectURI,
                scopes: Self.scopes,
                state: state,
                codeChallenge: challenge
            )
        else {
            finishLogin(nil)
            return
        }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "nc700like") { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.handleCallbackURL(callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if session.start() == false {
            finishLogin(nil)
        }
    }

    func cancelLogin() {
        session?.cancel()
        finishLogin(nil)
    }

    func handleCallbackURL(_ callbackURL: URL?, error: (any Error)?) {
        guard error == nil, let callbackURL else {
            finishLogin("認可をキャンセルまたは失敗しました。\(error.map { "\(($0 as NSError).code)" } ?? "")")
            return
        }
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            finishLogin("リダイレクトURLの解析に失敗しました。")
            return
        }
        let query = components.queryItems ?? []
        if let errorItem = query.first(where: { $0.name == "error" })?.value {
            finishLogin("認可でエラーが返りました: \(errorItem)")
            return
        }
        guard components.scheme?.lowercased() == "nc700like" else {
            return
        }
        guard let state = query.first(where: { $0.name == "state" })?.value else {
            finishLogin("state がありません。")
            return
        }
        guard state == pendingState else {
            finishLogin("state が一致しません(CSRFの可能性)。やり直してください。")
            return
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            finishLogin("認可コードがありません。")
            return
        }
        pendingState = nil
        let verifier = pendingVerifier ?? ""
        pendingVerifier = nil
        if verifier.isEmpty {
            finishLogin("内部エラー: verifier がありません。やり直してください。")
            return
        }
        Task { [weak self] in
            await self?.exchangeCode(code, verifier: verifier)
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async {
        do {
            let token = try await requestToken(body: SpotifyPKCE.tokenRequestBody(
                code: code,
                redirectURI: Self.redirectURI,
                clientID: clientID,
                codeVerifier: verifier
            ))
            try store(token, keepRefreshTokenIfAbsent: false)
            finishLogin("ログインしました。")
        } catch {
            finishLogin("トークン取得に失敗: \(Self.errorText(error))")
        }
    }

    private func finishLogin(_ message: String?) {
        session = nil
        if loginState == .inProgress && (KeychainStore.load(KeychainStore.Account.refreshToken) == nil) {
            loginState = .loggedOut
        }
        if let message { lastMessage = message }
    }

    private func store(_ token: SpotifyTokenResponse, keepRefreshTokenIfAbsent: Bool) throws {
        try KeychainStore.save(token.accessToken, account: KeychainStore.Account.accessToken)
        if let refresh = token.refreshToken {
            try KeychainStore.save(refresh, account: KeychainStore.Account.refreshToken)
        } else if keepRefreshTokenIfAbsent {
            // 既存のリフレッシュトークンを継続使用(公式ドキュメント準拠)
        } else {
            KeychainStore.delete(KeychainStore.Account.refreshToken)
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        try KeychainStore.save(String(expiresAt.timeIntervalSince1970), account: KeychainStore.Account.expiresAt)
        loginState = KeychainStore.load(KeychainStore.Account.refreshToken) != nil ? .loggedIn : .loggedOut
        accessTokenExpiresAt = expiresAt
    }

    func logout() {
        KeychainStore.deleteAll()
        loginState = .loggedOut
        accessTokenExpiresAt = nil
        lastMessage = "ログアウトしました。"
    }

    private func cachedValidAccessToken() -> String? {
        guard loginState == .loggedIn || KeychainStore.load(KeychainStore.Account.refreshToken) != nil else { return nil }
        guard let expires = accessTokenExpiresAt ?? Self.loadExpiry(),
              expires.timeIntervalSinceNow > Self.expiryLead,
              let token = KeychainStore.load(KeychainStore.Account.accessToken)
        else { return nil }
        accessTokenExpiresAt = expires
        return token
    }

    /// REQ F7: 常に有効なアクセストークンを返す。期限の60秒前なら更新。
    func ensureValidAccessToken() async throws -> String {
        if let token = cachedValidAccessToken() {
            return token
        }
        if let task = refreshTask {
            return try await task.value
        }
        let task = Task<String, Error> {
            try await refreshAccessToken()
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// SpotifyClient(401 再試行)からも使うため internal。
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = KeychainStore.load(KeychainStore.Account.refreshToken) else {
            throw SpotifyAuthError.notLoggedIn
        }
        let token: SpotifyTokenResponse
        do {
            token = try await requestToken(body: SpotifyPKCE.refreshRequestBody(
                refreshToken: refreshToken,
                clientID: clientID
            ))
        } catch {
            if case let SpotifyHTTPError.status(code, body) = error,
               (400..<500).contains(code),
               SpotifyJSON.decodeErrorBody(body)?.contains("invalid_grant") == true {
                KeychainStore.deleteAll()
                loginState = .loggedOut
                throw SpotifyAuthError.sessionExpired
            }
            throw error
        }
        try store(token, keepRefreshTokenIfAbsent: true)
        return token.accessToken
    }

    private func requestToken(body: String) async throws -> SpotifyTokenResponse {
        guard let url = URL(string: SpotifyPKCE.tokenEndpoint) else {
            throw SpotifyAuthError.configuration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAuthError.configuration
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyHTTPError.status(code: http.statusCode, body: data)
        }
        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        guard !decoded.accessToken.isEmpty else {
            throw SpotifyAuthError.configuration
        }
        return decoded
    }

    static func expiredInText() -> String {
        guard let expiry = loadExpiry() else {
            return KeychainStore.load(KeychainStore.Account.refreshToken) != nil ? "トークンなし(要更新)" : "—"
        }
        let remaining = Int(expiry.timeIntervalSinceNow)
        if remaining <= 0 { return "期限切れ(自動更新されます)" }
        return "残り \(remaining) 秒"
    }

    static func errorText(_ error: Error) -> String {
        switch error {
        case let SpotifyRequestFailure.http(method, path, status, body):
            let message = SpotifyJSON.decodeErrorBody(body) ?? "HTTP \(status)"
            var text = "\(method) /\(path) → \(status): \(message)"
            // ボディが JSON として解析できなかった場合だけ断片を出す(HTML/テキスト想定)。
            if SpotifyJSON.decodeErrorBody(body) == nil, !body.isEmpty {
                if let snippet = String(data: body.prefix(160), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces),
                   !snippet.isEmpty,
                   !snippet.lowercased().contains("token") {
                    text += " / body: \(snippet)"
                } else {
                    text += " / body: (\(body.count) バイト)"
                }
            }
            return text
        case let SpotifyHTTPError.status(code, body):
            let message = SpotifyJSON.decodeErrorBody(body) ?? "HTTP \(code)"
            return "\(code): \(message)"
        case SpotifyAuthError.notLoggedIn:
            return "未ログイン"
        case SpotifyAuthError.sessionExpired:
            return "セッション失効(再ログインが必要)"
        case SpotifyAuthError.configuration:
            return "設定エラー"
        default:
            return String(describing: error)
        }
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

enum SpotifyHTTPError: Error {
    case status(code: Int, body: Data)
}

enum SpotifyAuthError: Error {
    case notLoggedIn
    case sessionExpired
    case configuration
}
