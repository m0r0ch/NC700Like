import XCTest
@testable import NC700LikeKit

final class SpotifyPKCETests: XCTestCase {
    func testRFC7636TestVector() {
        // RFC 7636 Appendix B の既知ベクタ。
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(SpotifyPKCE.codeChallenge(from: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierConstraints() {
        let verifier = SpotifyPKCE.generateCodeVerifier()
        XCTAssertEqual(verifier.count, 64)
        for c in verifier {
            XCTAssertTrue(SpotifyPKCE.verifierCharacters.contains(c), "不正文字: \(c)")
        }
        // 2回生成して同一にならないこと
        XCTAssertNotEqual(verifier, SpotifyPKCE.generateCodeVerifier())
    }

    func testPercentEncode() {
        XCTAssertEqual(SpotifyPKCE.percentEncode("nc700like://callback"), "nc700like%3A%2F%2Fcallback")
        XCTAssertEqual(SpotifyPKCE.percentEncode("abc-._~123"), "abc-._~123")
        XCTAssertEqual(SpotifyPKCE.percentEncode("user-library-modify"), "user-library-modify")
    }

    func testTokenRequestBody() {
        let body = SpotifyPKCE.tokenRequestBody(
            code: "a b/c",
            redirectURI: "nc700like://callback",
            clientID: "cid",
            codeVerifier: "verifier"
        )
        // キーはソート順に並ぶ
        let expected = "client_id=cid&code=a%20b%2Fc&code_verifier=verifier&grant_type=authorization_code&redirect_uri=nc700like%3A%2F%2Fcallback"
        XCTAssertEqual(body, expected)
    }

    func testRefreshRequestBody() {
        let body = SpotifyPKCE.refreshRequestBody(refreshToken: "r/t", clientID: "cid")
        XCTAssertEqual(body, "client_id=cid&grant_type=refresh_token&refresh_token=r%2Ft")
    }

    func testAuthorizeURLContainsRequiredParams() throws {
        let url = try XCTUnwrap(SpotifyPKCE.authorizeURL(
            clientID: "cid",
            redirectURI: "nc700like://callback",
            state: "st-1",
            codeChallenge: "challenge123"
        ))
        XCTAssertEqual(url.absoluteString, SpotifyPKCE.authorizeEndpoint)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "cid")
        XCTAssertEqual(value("redirect_uri"), "nc700like://callback")
        XCTAssertEqual(value("state"), "st-1")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), "challenge123")
        XCTAssertEqual(value("scope"), "user-read-currently-playing user-library-modify")
    }

    func testMakeStateIsURLSafeAndUnique() {
        let state = SpotifyPKCE.makeState()
        XCTAssertFalse(state.contains("+"))
        XCTAssertFalse(state.contains("/"))
        XCTAssertFalse(state.contains("="))
        XCTAssertNotEqual(state, SpotifyPKCE.makeState())
    }
}

final class SpotifyModelsTests: XCTestCase {
    func testDecodeCurrentlyPlayingTrack() throws {
        let json = """
        {"is_playing": true, "item": {"type": "track", "id": "abc", "uri": "spotify:track:abc", "name": "Song", "artists": [{"name": "A1"}, {"name": "A2"}]}}
        """
        let decoded = try SpotifyJSON.decodeCurrentlyPlaying(Data(json.utf8))
        XCTAssertEqual(decoded?.isPlaying, true)
        XCTAssertEqual(decoded?.itemKind, .track(id: "abc", uri: "spotify:track:abc", name: "Song", artists: ["A1", "A2"]))
        XCTAssertEqual(decoded?.trackDisplayName, "Song - A1, A2")
    }

    func testDecodeCurrentlyPlayingEpisode() throws {
        let json = """
        {"is_playing": true, "item": {"type": "episode", "id": "e1"}}
        """
        let decoded = try SpotifyJSON.decodeCurrentlyPlaying(Data(json.utf8))
        XCTAssertEqual(decoded?.itemKind, .other(kind: "episode"))
        XCTAssertNil(decoded?.trackDisplayName)
    }

    func testDecodeCurrentlyPlayingWithoutItem() throws {
        let json = """
        {"is_playing": false}
        """
        let decoded = try SpotifyJSON.decodeCurrentlyPlaying(Data(json.utf8))
        XCTAssertEqual(decoded?.isPlaying, false)
    }

    func testDecodeTokenResponse() throws {
        let json = """
        {"access_token":"t","token_type":"Bearer","scope":"user-library-modify","expires_in":3600,"refresh_token":"r"}
        """
        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, SpotifyTokenResponse(accessToken: "t", tokenType: "Bearer", scope: "user-library-modify", expiresIn: 3600, refreshToken: "r"))
    }

    func testDecodeTokenResponseWithoutRefreshToken() throws {
        let json = """
        {"access_token":"t","expires_in":3600}
        """
        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.refreshToken, nil)
    }

    func testDecodeErrorBodyMessages() {
        XCTAssertEqual(SpotifyJSON.decodeErrorBody(Data(#"{"error":{"status":403,"message":"no auth"}}"#.utf8)), "no auth")
        XCTAssertEqual(SpotifyJSON.decodeErrorBody(Data(#"{"error":"invalid_grant"}"#.utf8)), "invalid_grant")
        XCTAssertEqual(SpotifyJSON.decodeErrorBody(Data(#"{"error":{"status":400,"message":"msg","reason":"r1"}}"#.utf8)), "msg (r1)")
        XCTAssertNil(SpotifyJSON.decodeErrorBody(Data("{}".utf8)))
    }
}
