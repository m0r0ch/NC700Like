import Foundation

/// 接続世代単位の押下時系列レコーダ(純粋・時計は注入可能)。
/// Step A の記録項目:
/// - 接続世代番号、接続・購読開始・初期読み取り結果の時刻
/// - 古い ID かどうか(文字列ラベルで入れる)、押下検出、P1 書込と使用 ID、書込完了、
///   FE03 全通知、再送判定の結果(理由付き)
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
    public func copyText(deviceName: String?, connectionRoute: String?, idEstablishedAtPress: Bool?) -> String {
        guard let pressStart = pressAt else {
            return header(deviceName: deviceName, connectionRoute: connectionRoute, idEstablishedAtPress: idEstablishedAtPress, hasPress: false)
                + "\n(直近の押下なし。押下してから再度コピーしてください)"
        }
        // 直近押より前のイベントは接続世代情報として最新の connect に関連するものだけ残す。
        let pressIndex = events.firstIndex { $0.date >= pressStart } ?? events.count
        var lines = header(deviceName: deviceName, connectionRoute: connectionRoute, idEstablishedAtPress: idEstablishedAtPress, hasPress: true)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for event in events[pressIndex...] {
            let fromPress = relativeMS(event.date, from: pressStart)
            let fromConnect = relativeMS(event.date, from: connectAt)
            lines.append("\(fromConnect)ms(押下\(fromPress)ms) \(event.label)")
        }
        lines.append(contentsOf: summaryLines(pressStart: pressStart, eventsFromPress: Array(events[pressIndex...])))
        return lines.joined(separator: "\n")
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

    private func header(deviceName: String?, connectionRoute: String?, idEstablishedAtPress: Bool?, hasPress: Bool) -> String {
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
        if let established = idEstablishedAtPress {
            lines.append("押下時の{ID}確定: \(established ? "確定済み" : "未確定(古いIDの可能性)")")
        }
        lines.append("形式: 接続+Xms(押下+Yms) ラベル")
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
