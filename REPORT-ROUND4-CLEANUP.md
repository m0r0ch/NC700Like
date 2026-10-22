# 第4弾報告: 整理ラウンド(方式スイッチの完全撤去)とログ整備

対象ビルド:
- 削除のみコミット: `87d8d46`(tag `pre-cleanup-p3` の次) — CI 緑・Kitテスト緑
- ログ整備コミット: `5f45a9a` — CI 緑
- tag: `pre-cleanup-p3` = `82b2dde`(整理前の最後のコミット。GitHub origin に push 済み)

## 1. 方式6 の削除状況(第2弾で指示分)

- **62d009c(第2弾指示への対応コミット)で削除済み**。Picker/コード(CancelStrategy.afterSession、
  SessionP1Plan、0.5秒×3 再送)/Kit 定数(sessionP1ResendInterval・sessionP1MaxResends)すべて。
- 本ラウンドの削除コミット(87d8d46)で方式1〜4とPickerも含めて完全に消えたため、
  現在「方式」に関係するコードは存在しない。

## 2. 整理ラウンドの削除範囲(ファイルと規模)

コミット `87d8d46`: 7 ファイル、**+128 行 / -580 行(純減 452 行)**。

| ファイル | 変更 | 内容 |
|---|---|---|
| `NC700LikeKit/Sources/NC700LikeKit/P1ResendWindow.swift` | **削除(-88行)** | CancelRetryConstants(再送ウィンドウ)/P1ResendWindow/P1ResendDecision |
| `NC700LikeKit/Tests/.../CancellationResendTests.swift` | **削除(-225行)** | P1ResendWindowTests(9件) |
| `NC700LikeKit/Tests/.../PressTimelineRecorderTests.swift` | 新規(+88行) | 旧 CancellationResendTests から時系列テスト(5件)を残し、×N 圧縮の新規テスト追加 |
| `NC700Like/LikeCoordinator.swift` | 約-160行 | CancelStrategy(5方式)/strategy 保持/switch 4経路/evaluate()/handleControlEvent/resendWindow を全部削除 → P3 単発に一本化 |
| `NC700Like/BLEService.swift` | 約-80行 | isControlIDEstablished(確定フラグ)/echoSameAsWriteID(エコー判定)/awaitingInitialFE03Report+initialFE03ReadAt(初期読み取り待ち)/freshControlNearPress を削除 |
| `NC700Like/ContentView.swift` | -13行 | 「再送方式」Picker 削除。Toggle 表記を「P3 で受付をキャンセル」に更新 |
| `NC700LikeKit/.../PressTimelineRecorder.swift` | 整理 | copyText の引数を `idEstablishedAtPress: Bool` → `terminalAtPress: String`(ヘッダ行「押下時の直近制御terminal: …(観測。判定には使わない)」) |

**残したもの(上位側の指示どおり)**: P3単発送信、押下検出(トグル+1秒抑止、`postPressSuppressInterval` 定数1か所)、実験ログ(押下→音声停止1行)、Spotify診断、制御パケット(23B/12B)末尾の観測(lastControlTerminalHex/recentControls、時系列の「FE03制御(N)B terminal=..」行)。判定ロジックは一切なく観測のみ。
**残す実験系**: E実験(ExperimentRunner/ExperimentView、P1系プリセットの {ID} 置換や AutoSendMode は実験用に残置)。「押下直後にP3で受付をキャンセル」の on/off トグルと「連携(いいね/検出のみ)」Picker も残置(実験比較用。Phase 5 の UI 整備で見直す)。

## 3. ログ上限の件の対応

| 問題 | 対応 |
|---|---|
| [ログ] が直近 100 件で押し出される | 保存上限を **100 → 300 件** に拡大(1件あたり1行なので軽微) |
| 特性列挙が 1 接続で約 35 行消費 | **1 接続 = 1 行**の要約に圧縮(「特性一覧 FDD2: <uuid> [props; ...]」) |
| FE03 音声パケット行が 1 セッションで 169 行消費(21:46 の実例) | 時系列コピーで**連続同一ラベル行を ×N に畳む**(「FE03音声(232B) ×169」)。内容は維持、集計ブロックは従来どおり全件で計算 |
| 押下の話が1つのログで追えない | 時系列に **「Spotify 呼出開始」「Spotify 結果: …」** の2行を追加。押下→P3送信→書込完了→音声→(Spotify)→いいね結果が 1 コピーで通る |

※時系列レコーダ自体の上限は 600 イベント(1接続世代)。圧縮されたコピーでは 1 押下あたり約 10〜20 行に収まる見込み。押下ごとの時系列は次の押下で置き換わる(1 押下分が基本設計)。電源入れ直し直後の複数押下を残したい場合は押すたびにコピーするか、失った場合は報告欄の実験ログ行(直近10件)で補う。

## 4. 12B/23B の末尾の照合結果(第3弾報告の訂正を含む)

**結論: 第3弾報告の「P3 応答の 12B の末尾=現在のセッション ID」は訂正。12B の末尾は常に 01(観測 9/9)で固定値に見える。押下で開くセッションの番号は 23B の「セッション開始制御パケット」の末尾と考えるのが整合する。**

| パケット | 観測 | 解釈(仮説) |
|---|---|---|
| P3 応答の 12B | P3 送信後に到着。全 9 件(round1 1件/round2 3件/round3 5件)とも **terminal=01 固定** | セッション番号とは別の固定項目(「通知タイプ/自側=01」など)の可能性 |
| 23B(セッション開始制御パケット `10 00 14 08 0B 5A … 1A 02 08 N`)の末尾 N | round2: 01→02→03(電源入れ直し後の押下順)、round3: **04→05→06→07→08** と 1 ずつ増加。**BLE 再接続(22:26:56)をまたいで続いた** | **受付セッションの通し番号(デバイス内カウンタ)**。電源入れ直しで初期化(round2 の最初=01)、BLE 再接続では保持 |
| P1 成功例(round3 21:50 の {ID}=02) | 02 はこの接続世代内で取得したセッション番号 | P1(と再送の {ID})が効くのは「今開いているセッションの番号(=23B の N)」と一致した場合(H7 を補強) |

参考: 21:46 失敗時は P1(5E: 押下前に届いた制御パケット由来)で、このセッションの番号(01)とは別物だった。
※ このラウンドの貼付ログに 23B の生バイト列は含まれていないため、末尾位置(`1A 02 08 N` の N)は過去の表記からの推定を含む。判定には使っていないため動作には影響しない。

## 5. Phase 4 の状態

- 実機 9/9 成功(電源入れ直し直後 3 回を含む。ただし #1〜#4 の時系列コピーはなし=[発見]上限の影響、実験者への聞き取りと画面上の成功演出のみ) — **Phase 4(受付キャンセル)はひとまず完了**という上位側の判断で進行。
- 整理後の実機確認 1 回(削除済みビルドで電源入れ直し直後の1〜2押下、ログ付き)で Phase 4 を正式完了とする。その後 Phase 5(本計測・長期安定性・UI微調整)へ。

## 6. 次の実験(上位側の判断待ち)

- 整理後ビルド(`5f45a9a`)で: 電源入れ直し → 最初の押下 1〜2 回 → 「時系列をコピー」+報告欄の実験ログ行を送る(#1〜#4 欠落分の穴埋め)。
- (任意・優先度低) 23B が複数回観測される場合の末尾 N と 12B=01 の関係を、未判定のまま継続観測。判定には使わない。
