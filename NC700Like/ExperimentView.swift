import SwiftUI
import UIKit

/// 実験モード(E0〜E10)。1 試行 = 押下→送信→3秒観察→3質問→保存。
/// BLE 側は BLEService(通常の接続/購読を共用)、フローは ExperimentRunner。
struct ExperimentView: View {
    @ObservedObject var ble: BLEService
    @StateObject private var runner: ExperimentRunner

    init(ble: BLEService) {
        self.ble = ble
        _runner = StateObject(wrappedValue: ExperimentRunner(ble: ble))
    }

    // おすすめセットの自動進行用。
    @State private var autoQueue: [ExperimentScenario] = []
    @State private var selectedScenario: ExperimentScenario = .e0
    @State private var repeatPerScenario = 2

    var body: some View {
        List {
            statusSection
            switch runner.phase {
            case .idle:
                idleSection
                historySection
            case .preCheck:
                preCheckSection
            case .waitingForPress:
                waitingSection
            case .choiceA:
                choiceASection
            case .sending:
                sendingSection
            case .observing:
                observingSection
            case .choiceB:
                choiceBSection
            case .choiceC:
                choiceCSection
            case .memo:
                memoSection
            }
            liveSection
        }
        .navigationTitle("実験モード(E0〜E10)")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 共通

    private var statusSection: some View {
        Section("接続") {
            HStack(spacing: 12) {
                switch ble.phase {
                case .subscribed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .connected, .pending, .scanning:
                    Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
                case .idle:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
                Text(ble.phase.label).font(.caption)
            }
            HStack {
                Text("7B61(受付待ち=00 06)")
                Spacer()
                Text(ble.last7B61Hex ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ble.isIdleState7B61 ? .green : .orange)
                    .textSelection(.enabled)
            }
            HStack {
                Text("直近{ID}")
                Spacer()
                Text(ble.lastControlTerminalHex ?? "—")
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("音声パケット合計")
                Spacer()
                Text("\(ble.audioPacketCount)").monospacedDigit()
            }
        }
    }

    private var liveSection: some View {
        Section {
            ForEach(Array(runner.eventsText.suffix(20).enumerated()), id: \.offset) { _, row in
                Text(row)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            if runner.phase != .idle {
                HStack {
                    Text("音声カウント")
                    Spacer()
                    Text("前=\(runner.audio.before) 0-500=\(runner.audio.bucket0_500) 500-1500=\(runner.audio.bucket500_1500) 1500-3000=\(runner.audio.bucket1500_3000)")
                        .font(.caption2)
                        .monospacedDigit()
                }
                Button("中止(保存しない)", role: .destructive) {
                    runner.abort()
                }
            }
        } header: {
            Text("時系列(START基準)")
        }
    }

    // MARK: - Phase: idle(セット開始と履歴)

    private var idleSection: some View {
        Section("実験の開始") {
            HStack {
                Text("開始時 7B61")
                Spacer()
                Text(ble.isIdleState7B61 ? "受付待ち(00 06) ✓" : "受付中(リセット推奨)")
                    .foregroundStyle(ble.isIdleState7B61 ? .green : .orange)
            }
            Picker("シナリオ(単発)", selection: $selectedScenario) {
                ForEach(ExperimentScenario.allCases) { scenario in
                    Text("\(scenario.label) — \(scenario.name)").tag(scenario)
                }
            }
            .pickerStyle(.menu)
            Stepper("各シナリオの繰り返し: \(repeatPerScenario)回", value: $repeatPerScenario, in: 1...5)
            Button("このシナリオを開始") {
                autoQueue = []
                runner.begin(scenario: selectedScenario)
            }
            Button("おすすめセット(E0,E1,E3,E5,E8 ×\(repeatPerScenario))を開始") {
                autoQueue = Self.buildQueue(ExperimentScenario.recommendedSet, repeatPerScenario)
                if let first = autoQueue.first {
                    autoQueue.removeFirst()
                    runner.begin(scenario: first)
                }
            }
            Text("手順: 手順0(7B61確認) → 手順1(ボタン押下待ち) → 質問A → 手順2(送信) → 手順3(3秒観察) → 質問B/C → メモ → 保存。実験中は通常の自動送信を停止します。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static func buildQueue(_ scenarios: [ExperimentScenario], _ repeatPerScenario: Int) -> [ExperimentScenario] {
        scenarios.flatMap { scenario in
            (0..<repeatPerScenario).map { _ in scenario }
        }
    }

    private var historySection: some View {
        Section {
            if runner.session.trials.isEmpty {
                Text("まだ試行の記録がありません。").foregroundStyle(.secondary)
            }
            ForEach(runner.session.trials) { trial in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(trial.index) \(trial.scenario.label) 送信=\(trial.sentHex ?? "(押すだけ)") 書込=\(trial.writeResults.joined(separator: "/"))")
                        .font(.caption)
                    Text("音A=\(trial.answerA) 音B=\(trial.answerB) 受付=\(trial.answerC) 終了7B61=\((trial.final7B61Hex?.prefix(23) ?? "-"))…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("要約をコピー") {
                    UIPasteboard.general.string = ExperimentReport.summary(runner.session)
                }
                Button("詳細をコピー") {
                    UIPasteboard.general.string = ExperimentReport.detail(runner.session)
                }
                Button("全消去", role: .destructive) {
                    runner.clearAll()
                }
            }
            .font(.caption)
            Text("設定 > NC700Like > ファイルを開けば nc700like_experiments.json も保存済み。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("試行履歴(\(runner.session.trials.count)件)")
        }
    }

    // MARK: - Phase: preCheck(手順0)

    private var preCheckSection: some View {
        Section("手順0: 送信前チェック") {
            Text(runner.notice.isEmpty ? "7B61 を確認しています…" : runner.notice)
                .font(.callout)
            Button("もう一度チェック(recheck)") {
                runner.recheck()
            }
            if !ble.isIdleState7B61 {
                Button("リセット送信(P1)をして手順1へ") {
                    runner.resetAndContinue()
                }
                Button("リセットせず進む") {
                    runner.skipReset()
                }
            }
        }
    }

    // MARK: - Phase: waitingForPress(手順1)

    private var waitingSection: some View {
        Section("手順1: ボタンを押してください") {
            Text("\(runner.currentScenarioLabel) を実行します。ヘッドホンのボタンを押すと自動で次に進みます(7B61 変化 or 制御パケット検出)。")
            Text("START 待ち…")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(runner.notice.isEmpty ? "" : runner.notice)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Phase: choiceA(質問A)

    private var choiceASection: some View {
        Section("質問A: 押した直後の音") {
            Text("出席した音はどれですか?").font(.callout)
            choiceButtons(["ピコン", "エラー音声", "無音"]) { runner.answerA($0) }
        }
    }

    // MARK: - Phase: sending(手順2)

    private var sendingSection: some View {
        Section("手順2: 送信") {
            if runner.currentScenario == .e0 {
                Text("ヘッドホンのボタンをもう一度押してください(押し終わったら下の確認を押す)。")
                    .font(.callout)
                Button("「もう一度押しました」") {
                    runner.userConfirmManualPress()
                }
            } else if let next = runner.pendingManualSteps.first {
                Text("START からの遅延実測値は記録されます。以下の送信を行ってください。")
                    .font(.callout)
                Button(next.label) {
                    runner.userTapSend()
                }
                .buttonStyle(.borderedProminent)
                Text("残り \(runner.pendingManualSteps.count) 送信")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("(送信は自動実行されました)")
            }
        }
    }

    // MARK: - Phase: observing(手順3)

    private var observingSection: some View {
        Section("手順3: 3秒観察中") {
            Text("残り \(runner.observeCountdownRemaining)秒…")
                .font(.headline)
                .foregroundStyle(.blue)
            Text("音声パケット数を区間カウントしています。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Phase: choiceB/c/memo

    private var choiceBSection: some View {
        Section("質問B: 送信後3秒間の音") {
            Text("聞こえた音はどれですか?").font(.callout)
            choiceButtons(["なし", "終了音", "エラー音声", "音声が流れた"]) { runner.answerB($0) }
        }
    }

    private var choiceCSection: some View {
        Section("質問C: 受付の終わり") {
            Text("音声受付(受付指示)はどうなりましたか?").font(.callout)
            choiceButtons(["終わった", "続いている", "不明"]) { runner.answerC($0) }
        }
    }

    private var memoSection: some View {
        Section("メモと保存") {
            TextField("メモ(任意・テンプレ差分や特異点)", text: $runner.memoText)
            Button("保存して次へ") {
                runner.saveAndNext()
                if let next = autoQueue.first {
                    autoQueue.removeFirst()
                    runner.begin(scenario: next)
                }
            }
            .buttonStyle(.borderedProminent)
            Text("試行#\(runner.session.trials.count + 1) を保存します。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func choiceButtons(_ labels: [String], _ action: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(labels, id: \.self) { labelText in
                Button(labelText) { action(labelText) }
                    .buttonStyle(.bordered)
            }
        }
    }
}
