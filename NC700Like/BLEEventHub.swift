import Foundation

/// BLEService が発火する BLE 関連イベント。
/// 実験モード(BLEEventHub)から購読する。押下検出ロジック(ButtonEventDetector)は関与しない。
/// 注意: 音声(FE03 >=100B)の中身は保存しない。カウントのみ。
struct BLEEvent {
    let date: Date
    let kind: Kind
    let bytes: Data

    enum Kind {
        /// 7B61 通知(押下判定前の生値・全19バイトを含む)。
        case notification7B61
        /// ButtonEventDetector が押下と判定した瞬間。
        case press
        /// FE03 制御パケット(<64B、全 HEX 記録可)。
        case control
        /// FE03 音声パケット(>=100B、中身は保存しない)。
        case audio
        /// 切断。
        case disconnected
    }

    /// 直近の 7B61 状態2バイト(押下検出に使う末尾2バイトとは別に、
    /// ユーザーが観察している13バイト目等も含めて runner 側で扱えるように全バイトを渡す)。
    var hexText: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// 複数のハンドラに BLE イベントを中継する薄いハブ。
final class BLEEventHub {
    private var handlerIDs = [UUID]()
    private var handlers = [UUID: (BLEEvent) -> Void]()

    /// 戻り値のトークンを remove に渡して購読解除する。
    @discardableResult
    func addHandler(_ handler: @escaping (BLEEvent) -> Void) -> UUID {
        let id = UUID()
        handlerIDs.append(id)
        handlers[id] = handler
        return id
    }

    func removeHandler(_ token: UUID) {
        handlers[token] = nil
        handlerIDs.removeAll { $0 == token }
    }

    func emit(_ event: BLEEvent) {
        for id in handlerIDs {
            handlers[id]?(event)
        }
    }
}
