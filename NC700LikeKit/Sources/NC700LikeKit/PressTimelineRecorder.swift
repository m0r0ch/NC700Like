import Foundation

/// 押下時系列レコーダ(純粋・時計は注入可能)。
/// - 接続世代番号、接続時刻、押下起点、書込(連番)と応答(完了/応答候補)、FE03 制御/音声の観測
/// - 時刻は「接続からの経過 ms」と「押下からの経過 ms」の両方
/// 「時系列をコピー」は直近の押下起点からの区切り+ヘッダ(接続情報)を出力する。
public final class PressTimelineRecorder {
    public struct Event: Equatable {
        let date: Date
        let label: String
    }

    /// 送信した書込の記録(連番付き)。
    public struct WriteRecord: Equatable {
        public let seq: Int
        public let date: Date
        public let label: String
    }

    /// 書込に対する応答の記録(書込完了/エコー候補)。
    public struct ResponseRecord: Equatable {
        public let writeSeq: Int
        public let date: Date
        public let label: String
    }

    private var events: [Event] = []
    private var writes: [WriteRecord] = []
    private var responses: [ResponseRecord] = []
    private let now: () -> Date

    public private(set) var generation = 0
    /// この世代の接続時刻(nil = 未接続)。
    public private(set) var connectAt: Date?
    /// 直近押下の時刻(nil = 直近押下なし)。
    public private(set) var pressAt: Date?
    /// 記録済みイベント数(表示用)。
    public var eventCount: Int { events.count }

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 新しい接続世代の開始。時系列・書込・応答は空に戻す。
    public func beginGeneration(connectAt: Date?) {
        generation += 1
        self.connectAt = connectAt
        pressAt = nil
        events = []
        writes = []
        responses = []
    }

    public func add(_ label: String) {
        events.append(Event(date: now(), label: label))
        if events.count > 600 {
            events.removeFirst(events.count - 600)
        }
    }

    /// 書込(連番付き)を記録。イベントにも「書込#N ...」行を出す。
    public func addWrite(_ label: String, seq: Int, date: Date? = nil) {
        let date = date ?? now()
        writes.append(WriteRecord(seq: seq, date: date, label: label))
        events.append(Event(date: date, label: "書込#\(seq) \(label)"))
        trim()
    }

    /// 書込への応答を記録。イベントにも「書込#Nへの応答(+lagMs) ...」行を出す。
    public func addResponse(toWriteSeq writeSeq: Int, label: String, date: Date? = nil) {
        let date = date ?? now()
        responses.append(ResponseRecord(writeSeq: writeSeq, date: date, label: label))
        let lagText: String
        if let write = writes.first(where: { $0.seq == writeSeq && $0.date <= date }) {
            let lag = Int((date.timeIntervalSince(write.date) * 1000).rounded())
            lagText = "+\(lag)ms"
        } else {
            lagText = "+?(書込不明)"
        }
        events.append(Event(date: date, label: "書込#\(writeSeq)への応答(\(lagText)) \(label)"))
        trim()
    }

    private func trim() {
        if events.count > 600 {
            events.removeFirst(events.count - 600)
        }
        if writes.count > 200 {
            writes.removeFirst(writes.count - 200)
        }
        if responses.count > 200 {
            responses.removeFirst(responses.count - 200)
        }
    }

    /// 書込記録一覧(表示用)。
    public var writeRecords: [WriteRecord] { writes }

    /// 応答記録一覧(表示用)。
    public var responseRecords: [ResponseRecord] { responses }

    /// 押下を起点として記録(以降の相対 ms はこの時刻基準)。
    /// at を指定すると event と pressAt を同一時刻に揃える。
    public func markPress(_ label: String, at: Date? = nil) {
        let date = at ?? now()
        pressAt = date
        events.append(Event(date: date, label: label))
        if events.count > 600 {
            events.removeFirst(events.count - 600)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func relativeMS(_ date: Date, from base: Date?) -> String {
        guard let base else { return "—" }
        let ms = Int((date.timeIntervalSince(base) * 1000).rounded())
        return String(format: "%+d", ms)
    }

    /// 1 回分(直近の押下起点以降+以前の接続情報)の時系列をコピー用テキストにする。
    public func copyText(deviceName: String?, connectionRoute: String?, terminalAtPress: String?) -> String {
        guard let pressStart = pressAt else {
            return header(deviceName: deviceName, connectionRoute: connectionRoute, terminalAtPress: terminalAtPress, hasPress: false)
                + "\n(直近の押下なし。押下してから再度コピーしてください)"
        }
        // 直近押より前のイベントは接続世代情報として最新の connect に関連するものだけ残す。
        let pressIndex = events.firstIndex { $0.date >= pressStart } ?? events.count
        var lines = header(deviceName: deviceName, connectionRoute: connectionRoute, terminalAtPress: terminalAtPress, hasPress: true)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // 同一ラベルの連続行(FE03 音声パケットの連続通知など)は1行に畳む(音声が169行になり
        // 重要な行を押し出すことがあったため)。末尾に「×N」を付けて重複件数を明示する。
        for run in collapseRuns(Array(events[pressIndex...])) {
            let fromPress = relativeMS(run.representative.date, from: pressStart)
            let fromConnect = relativeMS(run.representative.date, from: connectAt)
            let repeatText = run.count > 1 ? " ×\(run.count)" : ""
            lines.append("\(fromConnect)ms(押下\(fromPress)ms) \(run.representative.label)\(repeatText)")
        }
        lines.append(contentsOf: summaryLines(pressStart: pressStart, eventsFromPress: Array(events[pressIndex...])))
        return lines.joined(separator: "\n")
    }

    /// 連続する同一ラベルをまとめる(時刻は最初の1件を使う)。
    private func collapseRuns(_ source: [Event]) -> [(representative: Event, count: Int)] {
        var result: [(representative: Event, count: Int)] = []
        for event in source {
            if let last = result.last, last.representative.label == event.label {
                result[result.count - 1].count += 1
            } else {
                result.append((event, 1))
            }
        }
        return result
    }

    /// 集計ブロック: セッション指標(音声の開始/終了/継続)と書込→応答の pair。
    private func summaryLines(pressStart: Date, eventsFromPress: [Event]) -> [String] {
        var result: [String] = []
        result.append("--- 集計 ---")

        let audioEvents = eventsFromPress.filter { $0.label.hasPrefix("FE03音声") }
        if audioEvents.isEmpty {
            result.append("音声: なし")
        } else {
            let first = relativeMS(audioEvents.first!.date, from: pressStart)
            let last = relativeMS(audioEvents.last!.date, from: pressStart)
            let span = Int(audioEvents.last!.date.timeIntervalSince(audioEvents.first!.date))
            // 直近の音声が計測時点近くまで続いていれば「継続中」を注記
            let ongoing = (now().timeIntervalSince(audioEvents.last!.date)) < 0.3
                ? "(コピー時点で継続中の可能性)"
                : ""
            result.append("音声: 押下\(first)ms〜押下\(last)ms(継続 \(span)s, \(audioEvents.count)件)\(ongoing)")
        }

        let pressWrites = writes.filter { $0.date >= pressStart }
        if pressWrites.isEmpty {
            result.append("書込: なし")
        } else {
            for write in pressWrites {
                let at = relativeMS(write.date, from: pressStart)
                let resp = responses
                    .filter { $0.writeSeq == write.seq && $0.date >= write.date }
                    .compactMap { record -> String? in
                        let lag = Int((record.date.timeIntervalSince(write.date) * 1000).rounded())
                        return "\(record.label) +\(lag)ms"
                    }
                let respText = resp.isEmpty ? "応答なし" : "応答: \(resp.joined(separator: " / "))"
                result.append("書込#\(write.seq): \(write.label)(押下\(at)ms) \(respText)")
            }
        }
        return result
    }

    private func header(deviceName: String?, connectionRoute: String?, terminalAtPress: String?, hasPress: Bool) -> String {
        var lines: [String] = []
        lines.append("### 時系列(1 押下分)")
        lines.append("生成日時: \(Self.timestamp(now()))")
        lines.append("接続世代: \(generation)")
        if let connectAt {
            lines.append("接続: \(Self.timestamp(connectAt))(経過 \(relativeMS(now(), from: connectAt))ms)")
        } else {
            lines.append("接続: 未接続")
        }
        if let pressAt {
            lines.append("押下起点: \(Self.timestamp(pressAt))")
        } else {
            lines.append("押下起点: なし")
        }
        if let deviceName { lines.append("デバイス: \(deviceName)") }
        if let route = connectionRoute { lines.append("接続経路: \(route)") }
        if let terminal = terminalAtPress {
            lines.append("押下時の直近制御terminal: \(terminal)(観測。判定には使わない)")
        } else {
            lines.append("押下時の直近制御terminal: なし")
        }
        lines.append("形式: 接続+Xms(押下+Yms) ラベル")
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
