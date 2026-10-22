import Foundation

/// /api/token のレスポンス。
public struct SpotifyTokenResponse: Codable, Equatable {
    public let accessToken: String
    public let tokenType: String?
    public let scope: String?
    public let expiresIn: Int
    public let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

/// GET /me/player/currently-playing の最小限デコード(2026年2月以降の削除フィールドに依存しない)。
public struct SpotifyCurrentlyPlaying: Equatable {
    public enum ItemKind: Equatable {
        case track(id: String, uri: String, name: String, artists: [String])
        case other(kind: String)
    }

    public let itemKind: ItemKind
    public let isPlaying: Bool

    public var trackDisplayName: String? {
        if case .track(_, _, let name, let artists) = itemKind {
            return artists.isEmpty ? name : "\(name) - \(artists.joined(separator: ", "))"
        }
        return nil
    }
}

public enum SpotifyJSON {
    public static func decodeCurrentlyPlaying(_ data: Data) throws -> SpotifyCurrentlyPlaying? {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any] else { return nil }
        let isPlaying = dict["is_playing"] as? Bool ?? false
        guard let item = dict["item"] as? [String: Any] else {
            return SpotifyCurrentlyPlaying(itemKind: .other(kind: "unknown"), isPlaying: isPlaying)
        }
        let type = item["type"] as? String ?? ""
        guard type == "track" else {
            return SpotifyCurrentlyPlaying(itemKind: .other(kind: type), isPlaying: isPlaying)
        }
        let id = item["id"] as? String ?? ""
        let uri = item["uri"] as? String ?? "spotify:track:\(id)"
        let name = item["name"] as? String ?? ""
        let artists = ((item["artists"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
        guard !id.isEmpty else {
            return SpotifyCurrentlyPlaying(itemKind: .other(kind: "track(no id)"), isPlaying: isPlaying)
        }
        return SpotifyCurrentlyPlaying(itemKind: .track(id: id, uri: uri, name: name, artists: artists), isPlaying: isPlaying)
    }

    public static func decodeErrorBody(_ data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let dict = root as? [String: Any]
        else { return nil }
        if let message = dict["error"] as? String {
            return message
        }
        if let error = dict["error"] as? [String: Any] {
            let message = error["message"] as? String
            let reason = error["reason"] as? String
            if let m = message { return reason.map { "\(m) (\($0))" } ?? m }
        }
        return nil
    }
}
