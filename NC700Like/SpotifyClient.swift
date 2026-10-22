import Foundation
import NC700LikeKit

/// Spotify Web API クライアント(F4)。
/// 2026年2月移行ガイド準拠: 保存は PUT /me/library(Spotify URI 指定)。
@MainActor
final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()

    static let apiBase = "https://api.spotify.com/v1"

    let auth: SpotifyAuth

    enum LikeResult: Equatable {
        case saved(String)
        case alreadySaved(String)
        case nothingPlaying
        case notTrack(kind: String)
        case notLoggedIn
        case error(String)

        var message: String {
            switch self {
            case .saved(let title): "いいね追加: \(title)"
            case .alreadySaved(let title): "既にいいね済みのため追加しません: \(title)"
            case .nothingPlaying: "再生中の曲なし"
            case .notTrack(let kind): "曲以外のため保存しません(kind=\(kind))"
            case .notLoggedIn: "Spotify に未ログインです。上のボタンでログインしてください。"
            case .error(let text): "エラー: \(text)"
            }
        }
    }

    @Published private(set) var lastResult: LikeResult?
    @Published private(set) var isBusy = false

    private let session: URLSession

    init(auth: SpotifyAuth = .shared, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func performTestLike() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastResult = await likeCurrentTrack()
    }

    /// 押下処理(Phase 3 で LikeCoordinator から利用予定)。
    func likeCurrentTrack() async -> LikeResult {
        do {
            guard auth.isLoggedIn else { return .notLoggedIn }
            guard let item = try await fetchCurrentlyPlaying() else {
                return .nothingPlaying
            }
            switch item.itemKind {
            case .other(let kind):
                return .notTrack(kind: kind)
            case .track(_, let uri, let name, let artists):
                if try await isAlreadySaved(uri: uri) {
                    let display = artists.isEmpty ? name : "\(name) - \(artists.joined(separator: ", "))"
                    return .alreadySaved(display)
                }
                try await saveToLibrary(uri: uri)
                let display = artists.isEmpty ? name : "\(name) - \(artists.joined(separator: ", "))"
                return .saved(display)
            }
        } catch {
            return .error(SpotifyAuth.errorText(error))
        }
    }

    /// GET /me/player/currently-playing。204 は再生なし(nil)。
    private func fetchCurrentlyPlaying() async throws -> SpotifyCurrentlyPlaying? {
        guard let components = URLComponents(string: "\(Self.apiBase)/me/player/currently-playing") else {
            throw SpotifyAuthError.configuration
        }
        let (status, _, data) = try await spotifyRequest(urlRequest: components)
        if status == 204 || data.isEmpty {
            return nil
        }
        return try SpotifyJSON.decodeCurrentlyPlaying(data)
    }

    /// GET /me/library/contains?uris=... で既に保存済みか確認(ライブラリの追加順を壊さないため)。
    private func isAlreadySaved(uri: String) async throws -> Bool {
        guard var components = URLComponents(string: "\(Self.apiBase)/me/library/contains") else {
            throw SpotifyAuthError.configuration
        }
        components.queryItems = [URLQueryItem(name: "uris", value: uri)]
        let (_, _, data) = try await spotifyRequest(urlRequest: components)
        let flags = try SpotifyJSON.decodeLibraryContains(data)
        return flags.first ?? false
    }

    /// PUT /me/library?uris=spotify:track:{id}(移行ガイド後の新しいエンドポイント)。
    /// 空ボディでも Content-Type と Content-Length: 0 を明示して送る(一部のエッジが
    /// ボディ/ヘッダ無しの PUT を method エラー扱いにした報告があるため)。
    private func saveToLibrary(uri: String) async throws {
        guard var components = URLComponents(string: "\(Self.apiBase)/me/library") else {
            throw SpotifyAuthError.configuration
        }
        components.queryItems = [URLQueryItem(name: "uris", value: uri)]
        let (status, _, _) = try await spotifyRequest(
            urlRequest: components,
            method: "PUT",
            body: Data(),
            contentType: "application/json"
        )
        guard (200..<300).contains(status) else {
            throw SpotifyAuthError.configuration
        }
    }

    /// リトライ方針(設計書5章): 401 はトークン更新して1回だけ再試行。429 は Retry-After に従う(1回待機して再試行)。
    /// 失敗時はメソッド/パス/本文を含む診断エラーを投げる(トークンは含まない)。
    private func spotifyRequest(
        urlRequest components: URLComponents,
        method: String? = nil,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Int, URLResponse, Data) {
        guard let url = components.url else {
            throw SpotifyAuthError.configuration
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let method { request.httpMethod = method }
        if let body { request.httpBody = body }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let path = url.path.replacingOccurrences(of: "/v1", with: "")
        var token = try await auth.ensureValidAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await session.data(for: request)
        var http = response as? HTTPURLResponse
        var status = http?.statusCode ?? 0

        if status == 401 {
            token = try await auth.refreshAccessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
            http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
        }

        if status == 429,
           let retryAfter = http?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter), seconds <= 60 {
            try? await Task.sleep(nanoseconds: UInt64((seconds + 1) * 1_000_000_000))
            (data, response) = try await session.data(for: request)
            http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
        }

        guard (200..<300).contains(status) else {
            throw SpotifyRequestFailure.http(
                method: method ?? "GET",
                path: path,
                status: status,
                body: data
            )
        }
        return (status, response, data)
    }
}

enum SpotifyRequestFailure: Error {
    case http(method: String, path: String, status: Int, body: Data)
}
