import Foundation

// MARK: - シナリオ定義(E0〜E10)

/// 1回の送信手順。START(7B61 変化+FE03 開始)を基準にした手動/自動を表す。
struct SequenceStep: Codable, Equatable {
    /// どのテンプレートを送るか(E0 の送信なし手順は isManual で表現)。
    var template: ControlTemplate
    /// START からの遅延 ms。nil は「ユーザー操作で送る(手動)」。
    var delayFromStartMs: Int?
    /// 前の送信完了からの遅延 ms(E4 の P1=200、E10 の2本目=500)。
    var delayFromPreviousMs: Int?
    /// 送信ボタンのラベル用。
    var label: String

    init(template: ControlTemplate, delayFromStartMs: Int? = nil, delayFromPreviousMs: Int? = nil, label: String) {
        self.template = template
        self.delayFromStartMs = delayFromStartMs
        self.delayFromPreviousMs = delayFromPreviousMs
        self.label = label
    }
}

/// 実験シナリオ E0〜E10。
enum ExperimentScenario: String, CaseIterable, Codable, Identifiable {
    case e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10

    var id: String { rawValue }

    var label: String { rawValue.uppercased() }

    var name: String {
        switch self {
        case .e0: return "対照: 送信なし(もう一度ボタンを押す)"
        case .e1: return "P1 手動送信"
        case .e2: return "P2 手動送信"
        case .e3: return "P3 手動送信"
        case .e4: return "P3 送信 → 200ms 後に P1"
        case .e5: return "P1 自動送信(START直後)"
        case .e6: return "P2 自動送信(START直後)"
        case .e7: return "P3 自動送信(START直後)"
        case .e8: return "対照: C0 自動送信(START+1000ms)"
        case .e9: return "対照: C1({ID+1})自動送信(START+1000ms)"
        case .e10: return "連続 P1×2(500ms間隔)"
        }
    }

    /// 対照シナリオ(送信で受付を消すことを期待しない系)。
    var isContrast: Bool {
        switch self {
        case .e0, .e8, .e9: return true
        default: return false
        }
    }

    /// 送信なし(E0)。既存手順(観察と回答)は送信シナリオと共通。
    var sendsNothing: Bool { self == .e0 }

    /// 送手順の定義。
    var steps: [SequenceStep] {
        switch self {
        case .e0:
            return []
        case .e1:
            return [SequenceStep(template: .p1, label: "P1 を送信")]
        case .e2:
            return [SequenceStep(template: .p2, label: "P2 を送信")]
        case .e3:
            return [SequenceStep(template: .p3, label: "P3 を送信")]
        case .e4:
            return [
                SequenceStep(template: .p3, label: "P3 を送信"),
                SequenceStep(template: .p1, delayFromPreviousMs: 200, label: "P1(P3から200ms後・自動)"),
            ]
        case .e5:
            return [SequenceStep(template: .p1, delayFromStartMs: 0, label: "P1(START直後・自動)")]
        case .e6:
            return [SequenceStep(template: .p2, delayFromStartMs: 0, label: "P2(START直後・自動)")]
        case .e7:
            return [SequenceStep(template: .p3, delayFromStartMs: 0, label: "P3(START直後・自動)")]
        case .e8:
            return [SequenceStep(template: .c0, delayFromStartMs: 1000, label: "C0(START+1000ms・自動)")]
        case .e9:
            return [SequenceStep(template: .c1, delayFromStartMs: 1000, label: "C1(START+1000ms・自動)")]
        case .e10:
            return [
                SequenceStep(template: .p1, delayFromStartMs: 0, label: "P1 連続1本目(START直後・自動)"),
                SequenceStep(template: .p1, delayFromPreviousMs: 500, label: "P1 連続2本目(+500ms・自動)"),
            ]
        }
    }

    /// おすすめセット(2周する想定)。
    static let recommendedSet: [ExperimentScenario] = [.e0, .e1, .e3, .e5, .e8]
}

// MARK: - 試行の記録模型(Codable・ファイル永続化)

struct TrialEvent: Codable, Equatable {
    /// START(手順1 検出)を 0 とする相対ミリ秒。START 前は負。
    var relMs: Int
    var text: String
}

struct TrialRecord: Codable, Identifiable, Equatable {
    let id: UUID
    /// 説明用の順番(1始まり)。
    var index: Int
    var scenario: ExperimentScenario
    /// 手順1 開始時の 7B61 全 HEX。
    var initial7B61Hex: String?
    /// 手順2 で送ったデータ(置換後)。E0 は nil。
    var sentHex: String?
    /// 送ったテンプレート名(P1 など)。
    var presetNames: [String]
    /// 置換に使った直近制御パケット末尾1バイト。
    var idByteHex: String?
    /// START からの送信開始までの実測 ms(自動送信のみ/E0・手動は記録する)。
    var delayMeasuredMs: Int?
    /// 書込結果("OK" または "ERROR: ...")。連送は順番に並ぶ。
    var writeResults: [String]
    /// 書込完了までの実測 ms(1本目)。失敗時 nil。
    var writeCompletedMs: Int?
    /// 時系列イベント(START 基準相対 ms)。
    var events: [TrialEvent]
    /// 音声パケット数の区間カウント(中身は保存しない)。
    var audioBefore: Int
    var audio0_500: Int
    var audio500_1500: Int
    var audio1500_3000: Int
    /// 手順3 終了時(送信後3秒)の 7B61 全 HEX。
    var final7B61Hex: String?
    /// 7B61 が受付待ち状態(00 06 相当)か。
    var final7B61IsIdle: Bool?
    /// 質問A(送信直後の音): ピコン/エラー音声/無音/その他。
    var answerA: String
    /// 質問B(3秒後の音): なし/終了音/エラー音声/音声が流れた/その他。
    var answerB: String
    /// 質問C(受付の終わり): 終わった/続いている/不明。
    var answerC: String
    /// 補足メモ。
    var memo: String
    var createdAt: Date
}

/// 1回の実験(セッション全体にまたがる試行の集まり)。TrialStorage で永続化。
struct ExperimentSession: Codable {
    var deviceName: String?
    var connectionRouteAtStart: String?
    /// セッション開始時の 7B61 全 HEX。
    var start7B61Hex: String?
    var trials: [TrialRecord] = []
    var createdAt: Date = Date()
}

// MARK: - 永続化

/// 試行記録を Documents に JSON で保存(アプリ再起動後も残す)。
enum TrialStorage {
    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("nc700like_experiments.json")
    }

    static func load() -> ExperimentSession {
        guard let url = fileURL else { return ExperimentSession() }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ExperimentSession.self, from: data)
        } catch {
            return ExperimentSession()
        }
    }

    static func save(_ session: ExperimentSession) {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("TrialStorage.save failed: \(error.localizedDescription)")
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - レポート生成(要約=1行1試行テーブル、詳細=### 試行N・60行まで)

enum ExperimentReport {
    /// 「要約をコピー」の内容。
    static func summary(_ session: ExperimentSession) -> String {
        var lines: [String] = []
        lines.append("## 要約")
        lines.append("生成日時: \( ExperimentReport.isoNow())")
        lines.append("commit: \(BuildCommit.sha)")
        lines.append("接続経路: \(session.connectionRouteAtStart ?? "-") / 実験開始時 7B61: \(session.start7B61Hex ?? "-")")
        lines.append("")
        lines.append("No | シナリオ | 送信 | 遅延ms | 書込 | 送信後7B61 | 音A | 音B | 受付")
        for trial in session.trials {
            let send = trial.sentHex ?? "(押すだけ)"
            let delay = trial.delayMeasuredMs.map { String($0) } ?? "-"
            let write = trial.writeResults.isEmpty ? "-" : trial.writeResults.joined(separator: "/")
            let post = trial.final7B61Hex ?? "-"
            lines.append("\(trial.index) | \(trial.scenario.label) | \(send) | \(delay) | \(write) | \(post) | \(trial.answerA) | \(trial.answerB) | \(trial.answerC)")
        }
        return lines.joined(separator: "\n")
    }

    /// 「詳細をコピー」の内容。1 試行 60 行まで。
    static func detail(_ session: ExperimentSession) -> String {
        var lines: [String] = []
        lines.append("## 詳細")
        lines.append("生成日時: \(isoNow())")
        lines.append("commit: \(BuildCommit.sha)")
        lines.append("接続経路: \(session.connectionRouteAtStart ?? "-")")
        lines.append("デバイス: \(session.deviceName ?? "-")")
        lines.append("実験開始時 7B61: \(session.start7B61Hex ?? "-")")
        lines.append("iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for trial in session.trials {
            lines.append("")
            lines.append("### 試行 \(trial.index): \(trial.scenario.label) / \(trial.scenario.name)")
            lines.append(contentsOf: trialDetailBody(trial))
        }
        return lines.joined(separator: "\n")
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    private static func trialDetailBody(_ trial: TrialRecord) -> [String] {
        var lines: [String] = []
        lines.append("- 開始時 7B61: \(trial.initial7B61Hex ?? "-")")
        lines.append("- 送信: \(trial.sentHex ?? "(なし/E0)")")
        lines.append("- テンプレート: \(trial.presetNames.isEmpty ? "(なし)" : trial.presetNames.joined(separator: "+"))")
        lines.append("- {ID}: \(trial.idByteHex ?? "-")")
        if let delay = trial.delayMeasuredMs { lines.append("- 遅延(START→送信): \(delay)ms") }
        if let done = trial.writeCompletedMs { lines.append("- 書込完了: \(done)ms") }
        lines.append("- 書込結果: \(trial.writeResults.isEmpty ? "-" : trial.writeResults.joined(separator: " / "))")
        lines.append("- 音声: 送信前=\(trial.audioBefore) 0-500=\(trial.audio0_500) 500-1500=\(trial.audio500_1500) 1500-3000=\(trial.audio1500_3000)")
        let idle = trial.final7B61IsIdle.map { $0 ? "YES" : "NO" } ?? "-"
        lines.append("- 終了時 7B61: \(trial.final7B61Hex ?? "-") (受付待ち状態: \(idle))")
        lines.append("- 音A(送信直後): \(trial.answerA)")
        lines.append("- 音B(3秒後): \(trial.answerB)")
        lines.append("- 受付(音C): \(trial.answerC)")
        if !trial.memo.isEmpty { lines.append("- メモ: \(trial.memo)") }
        if !trial.events.isEmpty {
            lines.append("- 時系列:")
            for event in trial.events.prefix(40) {
                lines.append("  - \(event.relMs)ms \(event.text)")
            }
        }
        return lines
    }
}
