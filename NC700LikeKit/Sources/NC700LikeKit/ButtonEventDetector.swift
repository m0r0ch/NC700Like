import Foundation

/// FDD2サービスの7B61特性から押下を検出する純粋ロジック。
///
/// 設計書第3章の観測事実:
/// - 値は19バイトで、末尾2バイト(index 17,18)だけが変化する。
/// - 待機時 `00 06`、押下後 `10 0E` で、押すたびに交互に入れ替わる。
public struct ButtonEventDetector: Sendable {
    public enum Output: Equatable, Sendable {
        /// 押下とみなす変化
        case press
        /// 無視(同状態の重複、未知の値、短すぎる値、押下後の抑制中)
        case ignored
    }

    /// 押下発火後この秒数以内の 7B61 状態変化は「離した/再状態化」とみなして押下扱いしない。
    /// 00 06(受付待ち)の意味が確定するまでの暫定抑止(実験A)。
    public static let postPressSuppressInterval: TimeInterval = 1.0

    public let configuration: DeviceConfiguration

    public private(set) var lastKnownState: [UInt8]?
    private var lastPressAt: TimeInterval?

    public init(configuration: DeviceConfiguration = .default) {
        self.configuration = configuration
    }

    public mutating func reset() {
        lastKnownState = nil
        lastPressAt = nil
    }

    /// 通知または読み出し値を処理する。
    ///
    /// - Parameters:
    ///   - value: 受信したバイト列(HEXとして画面に出す値そのもの)
    ///   - timestamp: 単調に増える秒。呼び出し側が Date や DispatchTime から渡す
    ///   - isInitial: 接続直後の初期値取得では true。状態を記録するが発火しない
    /// - Returns: 押下検出なら .press
    @discardableResult
    public mutating func process(value: [UInt8], at timestamp: TimeInterval, isInitial: Bool = false) -> Output {
        guard let state = extractState(from: value) else { return .ignored }
        guard let known = configuration.pressStates.first(where: { $0 == state }) else {
            // 未知の値は状態として扱わない。既知状態に戻ったときに
            // 「同状態の重複」として無視され続けるための挙動。
            return .ignored
        }
        defer { lastKnownState = known }
        if isInitial {
            return .ignored
        }
        guard known != lastKnownState else { return .ignored }
        // ここまで到達 = 既知状態どうしの変化。直近の押下発火から約1秒は、
        // 離し/再状態化の変化(00 06 ↔ 10 0E)を押下として数えない(暫定)。
        let suppressInterval = max(configuration.debounceInterval, Self.postPressSuppressInterval)
        if let last = lastPressAt, timestamp - last < suppressInterval {
            return .ignored
        }
        lastPressAt = timestamp
        return .press
    }

    /// stateOffsetInBytes の位置から stateLengthInBytes バイトを取り出す。
    /// 既定設定では value[17..<19](0始まり。設計書の「17番目と18番目」)。
    public func extractState(from value: [UInt8]) -> [UInt8]? {
        let offset = configuration.stateOffsetInBytes
        let length = configuration.stateLengthInBytes
        guard value.count >= offset + length else { return nil }
        return Array(value[offset..<(offset + length)])
    }
}
