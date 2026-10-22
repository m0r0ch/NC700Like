# Phase 2 実機検証報告(Spotify ログインとテスト用いいね)

作成日: 2026年10月22日。対象コミット: `205abcb`〜`d6679e4`(CI 成功)。経緯は `HANDOFF.md`・`REPORT-PHASE1-VERIFICATION.md` 参照。

## 検証環境

- iPhone(iOS 26 系)+ Spotify Premium + Spotify デベロッパーダッシュボード(Dev Mode、新規アプリ → 2026年2月移行後の制約適用)。
- NC700Like は署名なし IPA を Sideloadly でインストール。無料 Apple ID。
- 本版の主機能: Spotify 認可コードフロー+PKCE(SpotifyAuth)、Keychain 保管(KeychainStore)、Web API クライアント(SpotifyClient)、UI の「Spotify」セクション(Client ID 入力/ログイン/ログアウト/トークン残時間/テスト用いいね)。

## 仕様確定(移行ガイド・リファレンス確認後)

- 保存は新エンドポイント `PUT /v1/me/library?uris=spotify:track:{id}`(旧 `/v1/me/tracks` 系は不使用)。`uris` はクエリパラメータ(ボディは受理されない)。
- 認可: Authorization Code + PKCE。Client Secret 不要。
- スコープ: `user-read-currently-playing` `user-library-modify` の 2 つで実用上足りることを実機で確認。
- Client ID はアプリ内の TextField に入力して UserDefaults に保存(端末内のみ・コミットなし)。
- リフレッシュトークン・アクセストークン・期限は Keychain(`AfterFirstUnlock`)。
- 期限の 60 秒前までに自動更新。401 は更新→1回だけ再試行。429 は Retry-After 待機(≤60 秒)。

## 実測結果

| # | 項目 | 結果 |
|---|---|---|
| (1) | Spotify ログイン(ASWebAuthenticationSession) | **成功**。認可画面 → コールバック → トークン取得まで到達 |
| (2) | テスト用いいね(再生中の曲を Liked Songs に追加) | **成功**(Spotify アプリの Liked Songs で追加を確認)。ただし下記 405 対応IPA 以降 |
| (3) | 初版 IPA でのテスト用いいね | **失敗: HTTP 405**。空ボディ/Content-Type なしの `PUT /me/library` だった |

## (3) → (2) の対処(405 の解消)

- 症状: テスト用いいねで「エラー: 405: HTTP 405」。
- 切り分け: エンドポイント・メソッド(`PUT`)・スコープは正しいことを再確認。初版は `httpBody` 未設定・Content-Type 未指定の PUT で、エッジ側で method エラーにされた疑い。デバイス側でどの呼び出しが・どんな本文で失敗したかが見えない構造も問題。
- 対応(コミット `5f5ae31`):
  1. `PUT /me/library` 送信時に **`httpBody=Data()`(空ボディ)+ `Content-Type: application/json` を明示**して送る。
  2. エラー表示を「`メソッド /パス → HTTPステータス: 内容 / body断片`」形式に詳細化(トークンは含まない。解析不能な本文だけ断片表示)。
  3. README のトラブルシュートに読み方を追記。
- 結果: 上記 IPA でテスト用いいねが成功(ユーザー報告)。

## 押下検出への含意(確定)

- 押下検出(Detector)と Spotify 保存(F4)は独立して動く。Phase 3 で両者を接続するだけで本命機能が成立する。
- 初回ログイン後のテスト用いいねは再ログイン不要(トークン自動更新)。保存一連の所要は未計測(Phase 3〜5 で計測)。

## 実装構成(Phase 2 新規)

- `NC700LikeKit/SpotifyPKCE.swift`: verifier 生成(バイアス除去)/SHA256→base64url/authorize URL・token ボディ構築(純粋)。RFC 7636 付録 B ベクタの単体テストあり。
- `NC700LikeKit/SpotifyModels.swift`: token レスポンス・currently-playing の最小デコード(2026年2月以降の削除フィールドに依存しない)。
- `KeychainStore.swift`: 汎用 Keychain ラッパ(GenericPassword)。
- `SpotifyAuth.swift`: ASWebAuthenticationSession によるログイン、state 検証、コード交換、更新、ログアウト。
- `SpotifyClient.swift`: currently-playing 取得(204=再生なし)と `PUT /me/library` 保存。401/429 再試行は共通ヘルパ。
- UI/設定: `project.yml` に URL スキーム `nc700like` 登録。ContentView に「Spotify」セクション。

## 残った観測課題(Phase 3 以降)

1. **保存完了までの所要時間**(押下起点で計測。自動送信(P1)は送信後約50msで完了、いいね API は数百ms と予想。Phase 5 で目標 2 秒内)
2. Spotify を別デバイス(スピーカー等)で再生中のときの currently-playing 取得可否(未確認)
3. 429(Dev Mode のクォータ、developer アカウント単位)は運用上出る可能性がある。Retry-After 待機の上限値は要観察
4. ボタン押下で追加した曲の表示(Spotify iアプリ UI)には community 報告(`PUT /me/library` が 200 を返しても UI に反映されない報告)があるが、実機の Liked Songs で追加が見えているため本件該当なしと思われる。押下経由でも再度確認する
5. 通知(UIBackgroundTask 含む)は Phase 4 の範囲

## 変更点(本版まとめ)

- `205abcb`: Phase 2 本体(上記の新規 5 ファイル+UI+URL スキーム)
- `981488a`: Package.swift に platforms 宣言(CryptoKit=macOS 10.15+ の可用性解決)
- `f53edd0`: authorize URL テストの期待値修正
- `5f5ae31`: PUT 空ボディ/Content-Type 明示 + エラー詳細化
- `d6679e4`: README 進捗チェック

単体テスト 21 件(Spotify 関連 11 件を含む)全パス。CI(IPA 生成を含む)成功。
