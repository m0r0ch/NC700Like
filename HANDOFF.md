# 引き継ぎメモ(Phase 1 実機検証の中断時点)

作成日: 2026年10月22日。Phase 1 の実装と CI は完了したが、実機での動作確認が未達のため中断。

## これまでに完了したこと

**リポジトリ**: 本リポジトリ(main ブランチ)。CI 成功の版まで push 済み。

**Phase 0(完了、実機インストール確認済み)**
- XcodeGen の `project.yml`、GitHub Actions のワークフロー( macOS で `swift test` → xcodegen → 署名なし IPA 生成 → アーティファクト)、README(Sideloadly 手順)、空の SwiftUI アプリ + Swift Package `NC700LikeKit`。

**Phase 1(実装・CI は完了。実機検証が未完了)**
- `NC700LikeKit/Sources/NC700LikeKit/DeviceConfiguration.swift`
  - FDD2・特性 7B61AD83-041C-4333-A0AB-EFB2AB7BDD43・状態値 `00 06` / `10 0E`(0 始まり index 17,18 = 末尾 2 バイト)・デバウンス 300ms・スキャン名 `Bose NC 700` を集約。
  - `NC700LikeConfiguration.json` をアプリバンドルに置けば上書きできる設計(Phase 1 では既定値のまま)。
- `NC700LikeKit/Sources/NC700LikeKit/ButtonEventDetector.swift`
  - 純粋ロジック。初期値では発火しない / 同状態の重複を無視 / 既知状態どうしの変化を押下とみなす / 300ms デバウンス / 未知の値は状態を汚染しない。
- 単体テスト 10 件(`ButtonEventDetectorTests`)パス。
- `NC700Like/BLEService.swift`
  - CBCentralManager(状態復元識別子つき)→ FDD2 でスキャン → 発見したら識別子を UserDefaults に保存 → 保存済み識別子 / `retrieveConnectedPeripherals(withServices:)` での直接接続 → サービス/特性探索 → `setNotifyValue` + `readValue` → HEX ログ(最大 100 件、各行コピー可)→ 切断後 3 秒で自動再接続。
- 画面(`ContentView.swift`): 接続状態アイコン+ラベル、押下回数/最終検出時刻、生 HEX ログ、手動再接続ボタン。
- Info.plist: `NSBluetoothAlwaysUsageDescription`、`UIBackgroundModes=[bluetooth-central]`。

## できないところ: Phase 1 の受け入れ未達(スキャンで NC700 が見つからない)

**症状**
- 設計書第 8 章 Phase 1 の確認手順 3 で失敗。
- ヘッドホンの電源はオン、iPhone 側の接続(Alexa に反応し音声が流れる)は成立している。
- しかしアプリは「スキャン中…」のまま変化なし。接続/購読に進まない。

**実施した対処と結果**
- 初版: FDD2 絞りスキャン → 発見 0。
- 改良版(コミット `761ce8b`):
  - 10 秒見つからなければ FDD2 絞りをやめて全デバイスをログに出す広域スキャンへ自動切替。
  - 名前または広告サービス一致で発見ログ・識別子保存・接続。
  - `retrieveConnectedPeripherals(withServices:[FDD2])` による「他アプリが BLE 接続済みなら取得して直接接続」の経路を強化。
- 結果: ユーザー報告では変化なし。

**残された疑問・次に確認すべきこと**
1. **広域スキャンのログ内容が未取得(最優先)**。広域で NC700 の名前/ID が 1 件もログに出ていないのか、出たのに一致判定が合わなかったのかで対処が変わる。ログは画面の各行長押しでコピーできる。
2. **nRF Connect(iOS)による並行観測**。同じ状態(Spotify 再生中、Alexa アプリ完全終了)で FDD2 の広告が実際に飛んでいるか、ローカル名が adv に乗っているか。nRF に見えてアプリに見えないならコード側、nRF にも見えないならデバイス側の広告停止が確定的。
3. **仮説(未検証)**
   - (a) NC700 は BLE 接続されると広告を止める(Alexa アプリが接続した場合など)。
   - (b) 広告はするがサービス UUID が adv の service-UUIDs フィールドに乗らない(nRF Connect の表示形式との混同の可能性)。
   - (c) CBUUID 照合の形式問題(短縮形/大文字小文字)。
   - (d) Bluetooth パーミッション拒否(表示上は現れていないが要確認)。
   - どれも確定していない。
4. **API 最終手段**。スキャンに頼らず接続する方法: iOS がかつて NC700 に BLE 接続したことがあれば identifier を記憶している。`retrievePeripherals(withIdentifiers:)` だけで接続できる可能性。identifier の入手方法(nRF Connect での確認など)の検討。

**引き継ぎ時の制約(設計書の再掲)**
- Windows 環境で Mac/Xcode なし。ビルド検証は GitHub Actions、実機は Sideloadly による署名 IPA。
- コードの構成・設定・観測事実は、リポジトリの README と `NC700 いいねボタン 実装設計書とエージェント向けプロンプト.md` 参照。
