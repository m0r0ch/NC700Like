import Foundation

/// 押下 1 回に紐づく P1 再送ウィンドウの状態と判定(純粋)。
/// 設計要件(Step B):
/// - 再送は押下にトークン的に紐づく(固定の 2.0 秒期限をやめる)。
/// - ウィンドウ既定値は 8.0 秒。
/// - 押下からウィンドウ内に届いた制御パケットの {ID} が、押下時に送った ID と違う場合だけ
///   P1 を 1 回だけ再送する。
/// - 次の押下で前の押下のウィンドウは破棄される(coord の側で新しいウィンドウに入れ替え、
///   `P1ResendWindow.decide(window:)` の window==nil で「破棄済み」を表す)。
public enum CancelRetryConstants {
    /// 再送ウィンドウの既定値(秒)。押下後の制御パケット到着が監視時点で約 2.4〜3.8 秒と
    /// 報告されているため、旧実装の 2.0 秒を拡張した値。
    public static let resendWindowSeconds: TimeInterval = 8.0
    /// 旧実装(方式「現行」)の期限(秒)。
    public static let legacyWindowSeconds: TimeInterval = 2.0
    /// 1 押下あたりの再送上限。
    public static let maxResends: Int = 1
}

public enum P1ResendDecision: Equatable {
    /// P1(または指定テンプレート)を再送する。
    case send(id: UInt8, label: String)
    /// 再送しない。reason は結果欄や時系列に出せる文言。
    case skip(reason: String)
}

public struct P1ResendWindow: Equatable {
    /// 再送ウィンドウの長さ(秒)。
    public let windowSeconds: TimeInterval
    /// 押下を検出した時刻(epoch 秒)。
    public let pressAt: TimeInterval
    /// 押下時に即送した P1 の {ID}(P3 など ID 非依存テンプレや、未送信なら nil)。
    public let immediateID: UInt8?
    /// 押下時に P1 を送ったか(false = 古 ID 未確定のとき送らなかった方式)。
    public let sentImmediate: Bool
    /// 送信済み再送回数(coord 側で成功送信後に increment して戻す)。
    public var resendCount: Int

    public init(
        windowSeconds: TimeInterval,
        pressAt: TimeInterval,
        immediateID: UInt8?,
        sentImmediate: Bool,
        resendCount: Int = 0
    ) {
        self.windowSeconds = windowSeconds
        self.pressAt = pressAt
        self.immediateID = immediateID
        self.sentImmediate = sentImmediate
        self.resendCount = resendCount
    }

    /// 制御パケットの到着に対する再送判定。
    /// - Parameters:
    ///   - window: nil は「次の押下で前の押下のウィンドウを破棄済み」を表す。
    ///   - controlTerminal: 到着した制御パケットの末尾 1 バイト。
    ///   - controlAt: 制御パケットの受信時刻(epoch 秒)。
    ///   - now: 判定時刻(epoch 秒)。
    public static func decide(
        window: P1ResendWindow?,
        controlTerminal: UInt8,
        controlAt: TimeInterval,
        now: TimeInterval
    ) -> P1ResendDecision {
        guard let window else {
            return .skip(reason: "ウィンドウなし(次の押下で破棄済み)")
        }
        guard window.resendCount < CancelRetryConstants.maxResends else {
            return .skip(reason: "再送は \(CancelRetryConstants.maxResends) 回まで")
        }
        let windowElapsed = now - window.pressAt
        guard windowElapsed >= 0, windowElapsed <= window.windowSeconds else {
            return .skip(reason: String(format: "ウィンドウ超過(押下から %.0f 秒)", windowElapsed))
        }
        let latency = controlAt - window.pressAt
        guard latency >= 0, latency <= window.windowSeconds else {
            return .skip(reason: String(format: "制御パケットが押下から %.1f 秒で範囲外", latency))
        }
        if window.sentImmediate, let sentID = window.immediateID, sentID == controlTerminal {
            return .skip(reason: "ID 同一(\(String(format: "%02X", controlTerminal)))のため再送不要")
        }
        let label = window.sentImmediate
            ? String(format: "P1 再送({ID}=%02X)", controlTerminal)
            : String(format: "P1 送信(ウィンドウ待ち / {ID}=%02X)", controlTerminal)
        return .send(id: controlTerminal, label: label)
    }
}
