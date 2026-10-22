import Foundation
import CryptoKit

/// Spotify 認可コードフロー+PKCE のうち、ネットワークとUIを含まない純粋部分。
public enum SpotifyPKCE {
    public static let authorizeEndpoint = "https://accounts.spotify.com/authorize"
    public static let tokenEndpoint = "https://accounts.spotify.com/api/token"

    /// RFC 7636 §4.1: 43〜128 文字。アルファベット/数字/._~- を使用。
    public static let verifierCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    public static let defaultScopes = "user-read-currently-playing user-library-modify user-library-read"

    /// code verifier を生成する(SystemRandomNumberGenerator は暗号論的に安全)。
    public static func generateCodeVerifier(length: Int = 64) -> String {
        precondition(length >= 43 && length <= 128)
        let chars = Array(verifierCharacters)
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        var index = 0
        while index < length {
            // バイアス除去(65文字×3=195 で割り切れる範囲のみ採用)
            var byte = UInt8.random(in: 0...255, using: &rng)
            while byte >= 195 {
                byte = UInt8.random(in: 0...255, using: &rng)
            }
            bytes.append(chars[Int(byte) % chars.count].asciiValue!)
            index += 1
        }
        return String(bytes: bytes, encoding: .ascii)!
    }

    /// SHA256 → base64url(paddingなし)。
    public static func codeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    public static func makeState() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// /authorize へのリダイレクト用URL。
    public static func authorizeURL(
        clientID: String,
        redirectURI: String,
        scopes: String = SpotifyPKCE.defaultScopes,
        state: String,
        codeChallenge: String
    ) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "scope", value: scopes),
        ]
        return components?.url
    }

    /// 認可コード交換のPOSTボディ(application/x-www-form-urlencoded)。
    public static func tokenRequestBody(
        code: String,
        redirectURI: String,
        clientID: String,
        codeVerifier: String
    ) -> String {
        let params: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ]
        return formEncode(params)
    }

    /// リフレッシュ用のPOSTボディ。
    public static func refreshRequestBody(refreshToken: String, clientID: String) -> String {
        formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    public static func formEncode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0))=\(percentEncode($1))" }
            .joined(separator: "&")
    }

    /// フォームURLエンコード(RFC 3986: アルファベット・数字・-._~ 以外はすべてpercentエンコード)。
    public static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
