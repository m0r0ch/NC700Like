# Phase 3 実機検証報告(押下 → いいね連携)

作成日: 2026年10月22日。対象コミット: `3a2b7ed`(Phase 3 本体)〜`0e6f3f9`(CI 修正)。経緯は `HANDOFF.md`・`REPORT-PHASE2-VERIFICATION.md` 参照。

## 検証環境

- iPhone(iOS 26.3.1)+ Spotify Premium。接続経路: 切断後の即時保留接続(B-4)。
- コミット `0e6f3f9` の IPA を Sideloadly でインストール。CI(swift test → xcodebuild → IPA)成功。
- 生成日時 2026-10-22T07:26:15Z の状態で実機確認。

## 本版の主機能

- `LikeCoordinator`: 押下イベント(.press)購読 → 押下直後に P1 送信(Alexa 受付キャンセル)→ Spotify の再生中の曲を `PUT /me/library` で Liked Songs に追加。処理は直列化(処理中の押下は集約)。
- モード「いいねする / 検出のみ」+「押下直後に P1 で受付をキャンセル」トグル(UserDefaults 永続化)。結果ログ直近 10 件(所要 ms 付き)。
- 実験モード中(`ble.suppressAutoSend`)は連携を停止(E実験の計測を汚さない)。

## 実測結果(ユーザー報告)

| # | 項目 | 結果 |
|---|---|---|
| (1) | Spotify で曲を再生中に押下 → 「いいね追加: 曲名」+ Liked Songs 追加 | **成功** |
| (2) | P1 による Alexa 受付キャンセル(送信後約 0.3 秒で終了) | **成功**(Phase 3 手順どおり) |
| (3) | 同一曲を 2 回押す | 2 回目も追加され、**Liked Songs の追加日順が変わる**(要望: 追加済みなら再追加しない → 対処は下記) |
| (4) | Spotify を一時停止中に押す | 「**再生中の曲なし**」表示。落ちない(設計どおり) |
| (5) | 実験モード中の押下 | 連携欄に変化なし・受付キャンセルもなし = 連携自動停止が機能(設計どおり。E0 試行の詳細 60 行ログと併せ確認) |

## (3) の対処(追加済み曲の再追加防止)

- 切り分け: `PUT /me/library` を既に保存済みの URI に送ると追加日が更新され、Liked Songs の先頭に来てしまう(ユーザー観測)。
- 追加保存の前に `GET /v1/me/library/contains?uris=...` で確認し、保存済みなら PUT を送らない。
- このエンドポイントは 2026年2月移行ガイドで「contains は `/me/library/contains` に統合」された新しいもの。スコープ `user-library-read` が新たに必要。
- 対応コミット(本報告同時):
  1. `NC700LikeKit/SpotifyModels.swift` に `SpotifyJSON.decodeLibraryContains`(bool 配列のデコード)+ 単体テスト 2 件。
  2. `SpotifyPKCE.defaultScopes` に `user-library-read` を追加 → **既存ログイン済み端末は「ログアウト → 再ログイン」が必要**(スコープはトークン発行時に確定するため)。
  3. `SpotifyClient` に `isAlreadySaved(uri:)` と結果 `.alreadySaved(title)`(表示: 「既にいいね済みのため追加しません: 曲名」)を追加。押下処理の流れは fetch → contains 確認 → (未保存なら)保存。
  4. README の該当箇所(スコープ・確認手順)追記。
- 実機確認: **未実施**(Phase 4 の確認手順で実施予定)。

## 押下検出と P1 の含意(確定)

- 保存経路と P1 送信経路は直列化されており、連打でも押下単位で処理される(集約あり)。
- P1 の{ID}には FE03 制御パケット末尾バイトが必要。起動直後の最初の押下で FE03 未受信のままのときは「P1 未送信: 制御パケット未受信」になる(防御動作として正しい)。
- 実験モード中は連携停止が両経路に効く(P1 もいいね API も送らない)。

## 残った観測課題(Phase 4 以降)

1. **バックグラウンド常駐**: ホーム画面に戻したまま長時間放置したときの BLE セッション維持 UIBackgroundTask・通知(Phase 4 本体で実装済み。確認手順は README「Phase 4 の確認手順」)。
2. **自動再接続**: ヘッドホン電源入れ直し→自動で`購読中`へ戻ることの観察(Phase 1 時点では確認済みだが、連携込みでの再接続は未確認)。
3. 追加済み曲の再追加防止の実機確認(上記)。
4. 応答時間の本計測・短縮(目標 2 秒内)は Phase 5。

## 変更点(本版まとめ)

- `3a2b7ed`: Phase 3 本体(LikeCoordinator + BLEService.shared + UI セクション + README 手順)。
- `200c1db`: CI 失敗修正(ContentView の body が型検査不能 → Section 9 本を @ViewBuilder 計算プロパティに分割)。
- `0e6f3f9`: CI 失敗修正(PressReport に存在しない `isHighlighted` の参照を削除)。
- 本報告同時コミット: 追加済み曲の再追加防止(decodeLibraryContains + スコープ追加 + isAlreadySaved/alreadySaved + README)。

## Phase 3 の動作確認チェックリスト(README 145〜)

- [x] 押下 → 「いいね追加: 曲名」+ Liked Songs 追加(実機 2026-10-22)
- [x] P1 で受付が約 0.3 秒後にキャンセルされる(音A=ピコン直後に終了)
- [x] Spotify 一時停止中 → 「再生中の曲なし」(追加されない。落ちない)
- [x] 実験モード中 → 連携停止(P1 送信なし・いいねなし)
- [x] 既にいいね済みの曲 → 「既にいいね済みのため追加しません」(実機確認済み 2026-10-22・再ログイン後)
