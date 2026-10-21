# NC700Like

Bose NC 700 の音声アシスタントボタンを押すと、Spotify で再生中の曲を Liked Songs に追加する iPhone アプリです。
Mac なし(Windows + Sideloadly + GitHub Actions)でビルド・インストールできます。

## 進捗

- [x] Phase 0: 空のアプリ・CI・IPA 生成
- [x] Phase 1: BLE 接続と購読(押下検出の実機確認)
- [ ] Phase 2: Spotify ログインとテスト用いいね
- [ ] Phase 3: 押下 → いいねの連携
- [ ] Phase 4: バックグラウンド常駐・自動再接続・通知
- [ ] Phase 5: 応答時間の計測と短縮・ログ整備

## リポジトリ構成

```
NC700Like/
├─ NC700LikeKit/                  純粋ロジックの Swift Package(単体テストあり)
├─ NC700Like/                     アプリ本体(SwiftUI)
├─ project.yml                    XcodeGen 定義(.xcodeproj は生成物のためコミットしない)
└─ .github/workflows/build-ipa.yml  CI(swift test → xcodegen → xcodebuild → IPA)
```

## IPA の取得(GitHub Actions)

GitHub Actions が main ブランチへの push で自動実行します。
手動実行は「Actions」タブ → 「build-ipa」→「Run workflow」。
完了したら、実行ページの「Artifacts」から `NC700Like-ipa` をダウンロードして展開すると `NC700Like.ipa` が入っています。

## Windows へのインストール(Sideloadly)

1. iPhone を USB ケーブルで PC に接続し、iPhone 上で「このコンピュータを信頼」を選ぶ(初回のみ)。
2. iTunes を Apple 公式サイトからインストール(重要: Microsoft Store 版ではなく Apple 公式版。Sideloadly が Apple ドライバを使います)。
3. Sideloadly を https://sideloadly.io からインストールして起動。
4. Sideloadly に `NC700Like.ipa` をドラッグ。
5. 「Apple account」に無料の Apple ID(iCloud メールAddress)、パスワードを入力。
6. 「Advanced options」で「Remove app extension」以外はデフォルトのままで OK。
7. 「Start」を押す。Apple ID の二段階認証を求められたら iPhone の画面で「パスワードとセキュリティ」→ 確認コードを入力、
   さらにキーチェーンのパスワード(Windows ログイン時の PC パスワードのことも多い)を聞かれたら入力。
8. 完了したら iPhone にアイコンが表示されます。

### iPhone 側の設定(初回のみ)

1. iPhone を PC に接続したまま、設定 → プライバシーとセキュリティ → 開発者モード → オン(要再起動)。
2. 設定 → 一般 → VPN とデバイス管理 → Apple ID の「〜〜〜」を選び「信頼」。
3. Wi-Fi やモバイル通信をオンにして普通に起動します。

## 7 日ごとの再署名

無料の Apple ID で署名したアプリは 7 日で期限が切れます。期限が切れると起動できません。

- 期限が近づいたら/切れたら、iPhone のアプリを一度削除(または Sideloadly で上書き)し、上の手順で再度署名してインストールします。
- 無料 Apple ID で同時に署名できるアプリは 3 つまでです。
- 毎回同じ Apple ID を使ってください。

## 使い方(Phase 1 時点)

Spotify 連携はまだありません。BLE 接続と押下検出を確認する段階です。

1. アプリを起動し、Bluetooth の利用許可を求められたら「許可」。
2. **Alexa アプリを完全に終了する**(アプリスイッチャーから上にスワイプ)。Alexa アプリが BLE 接続を専有するとヘッドホンが広告を止め、NC700Like から見つからないことがある。Spotify は再生してよい。
3. Bose NC 700 の電源を入れ、設定は Alexa のまま。
4. 「接続状態」が次のように変われば成功: スキャン中… → 接続中… → 接続 → 購読中。
   - 10 秒間 FDD2 絞りで見つからない場合、自動で広域スキャンに切り替わり、見つけた周辺機器をログに出す(診断用)。
4. ヘッドホンの音声アシスタントボタンを押す。
   - 「押下検出」の検出回数が増え、「最終検出」時刻が更新されれば Phase 1 は成功。
   - ログの「押下」行に受信した生の HEX が出る。次のような値があるはず:
     - 待機時: `02 06 40 24 02 00 00 00 0F 00 07 00 1C 0F 00 F4 04 00 06`
     - 押下後: `02 06 40 24 02 00 00 00 0F 00 07 00 1C 0F 00 F4 04 10 0E`
5. ボタンを押すたびに検出回数が +1 され、連打(300 ミリ秒以内)では 1 回だけになる。
6. ヘッドホンの電源をオフ → オンすると、数秒内に自動で再接続し購読に戻る。
7. ログの各行は長押し(コンテキストメニュー)で HEX をコピーできる。Alexa アプリを起動中/終了中の両方で試し、購読の競合を確認する。

実機の HEX が設計書の観測と違う場合は、注意: 推測で決めない。ログをコピーして保存しておく(Phase 2 以降や、ズレている場合のオフセット見直しに使う)。

設定変更(応急): `NC700LikeKit` の `DeviceConfiguration.default` が UUID・オフセット・状態値・スキャン名の既定値。JSON で上書きができる(json は `NC700LikeConfiguration.json` をアプリバンドルに置く設計、Phase 1 では既定値のまま)。

## 注意: 強制終了しないこと

- アプリスイッチャー(ホーム画面から上スライドで一時停止して出る画面)からアプリを上にフリックして強制終了すると、iOS の仕様上 BLE の常駐も止まり、再起動するまで押下を拾えません。
- Phase 4 以降はアプリをバックグラウンドに置くだけで動き続けます。**強制終了はしないでください。**
- OS が停めそうになったらまた起動して戻るだけで動作を再開します。

## トラブルシュート

- **起動した瞬間に落ちる/「信頼されていない開発元」**: 設定 → 一般 → VPN とデバイス管理 → Apple ID を「信頼」する。署名の期限切れ(7 日)の可能性もあるので、再署名する。
- **「開発者モードが必要」**: 設定 → プライバシーとセキュリティ → 開発者モードをオン(再起動が必要)。
- **Sideloadly が iPhone を認識しない**: Microsoft Store 版 iTunes が入っているとドライバが足りないことがある。Apple 公式版 iTunes を入れる。ケーブル・ポートを変える。iPhone の「このコンピュータを信頼」をやり直す。
- **Sideloadly で認証エラー(Apple ID)**: Apple ID のアプリ用パスワードを設定して、それを入力する(https://appleid.apple.com → サインイン → アプリ用パスワード)。
- **Apps の上限(3 つ)を超えた**: 既に入れてある他の無料署名アプリを削除してからやり直す。
- **Apple ID がロックされた気がする**: 短時間に何度もサイドロードすると Apple 側で一時的にブロックされることがある。数時間待つ。
- **IPA がビルドされていない**: Actions の「build-ipa」のちに失敗していないか確認。失敗時は xcodebuild-log アーティファクトを確認。

## 開発メモ

- ビルドは GitHub Actions(macOS ランナー)で行う。ローカル(Windows)ではビルドできない。
- Spotify Web API のライブラリ系エンドポイントは 2026 年 2 月の移行ガイドに従う
  (https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide )。
- 秘密情報(Apple ID パスワード、Spotify のトークンなど)はコミットもログ出力もしない。
