import Foundation
import NC700LikeKit

/// 押下からいいね処理までを担う(LikeCoordinator)。
/// - 押下イベントは BLEService.eventHub(.press) から受け取る。
/// - 処理は直列化。処理中の押下は1件だけキューに入れて集約する。
/// - P1(受付キャンセル)送信はいいねの HTTP と並行で即座に発火する(E5 実測: 送信後約0.3秒でマイク終了)。
/// - バックグラウンド実行時間の確保(UIBackgroundTask)は Phase 4。
@MainActor
final class LikeCoordinator: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case like = "いいねする"
        case detectionOnly = "検出のみ(いいねしない)"

        var id: String { rawValue }
    }

    /// 押下ごとの結果(直近10件・F8)。
    struct PressReport: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let elapsedText: String
        let message: String

        /// 押下から完了までのミリ秒を粗く出す(Phase 5 の本計測の前段)。
        static func elapsedText(of interval: TimeInterval) -> String {
            interval <= 0 ? "—" : String(format: "%.0f ms", interval * 1000)
        }
    }

    static let modeKey = "like.mode"
    static let cancelSendKey = "like.cancelReception"

    let ble: BLEService
    let spotifyClient: SpotifyClient

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var cancelReceptionOnPress: Bool {
        didSet { UserDefaults.standard.set(cancelReceptionOnPress, forKey: Self.cancelSendKey) }
    }
    @Published private(set) var reports: [PressReport] = []
    @Published private(set) var likeCount = 0
    @Published private(set) var isProcessing = false

    private var handlerToken: UUID?
    /// 1回のいいね処理の間に検出された押下の数(集約して後続処理する)。
    private var hasPendingPress = false

    init(ble: BLEService, spotifyClient: SpotifyClient = .shared) {
        self.ble = ble
        self.spotifyClient = spotifyClient
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey)
        mode = savedMode.flatMap(Mode.init(rawValue:)) ?? .like
        if UserDefaults.standard.object(forKey: Self.cancelSendKey) == nil {
            cancelReceptionOnPress = true
        } else {
            cancelReceptionOnPress = UserDefaults.standard.bool(forKey: Self.cancelSendKey)
        }
    }

    /// 押下イベントの購読開始(重複登録しない)。
    func attach() {
        guard handlerToken == nil else { return }
        handlerToken = ble.eventHub.addHandler { [weak self] event in
            guard event.kind == .press else { return }
            Task { @MainActor in
                self?.handlePress()
            }
        }
    }

    func detach() {
        if let token = handlerToken {
            ble.eventHub.removeHandler(token)
            handlerToken = nil
        }
    }

    func handlePress() {
        // 実験モード中は通常のいいね処理を抑制(E実験の計測を汚さない)。
        guard !ble.suppressAutoSend else { return }
        guard mode == .like else {
            appendReport(interval: 0, message: "検出のみモード(いいねせず)")
            return
        }
        guard spotifyClient.auth.isLoggedIn else {
            appendReport(interval: 0, message: "Spotify 未ログイン(いいねせず)")
            return
        }
        if cancelReceptionOnPress {
            guard ble.controlTerminalByte() != nil else {
                appendReport(interval: 0, message: "P1 未送信: 制御パケット未受信({ID} 未確定)")
                return
            }
            // 受付キャンセルは即送信(.withResponse の完了は待たない)。
            ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
        }
        if isProcessing {
            hasPendingPress = true
            appendReport(interval: 0, message: "いいね処理中に押下を検出。処理完了後に続行します")
            return
        }
        isProcessing = true
        let started = Date()
        Task { await runProcessing(startedAt: started) }
    }

    private func runProcessing(startedAt: Date) async {
        var started = startedAt
        defer { isProcessing = false }
        while true {
            hasPendingPress = false
            let result = await spotifyClient.likeCurrentTrack()
            let interval = Date().timeIntervalSince(started)
            if case .saved = result {
                likeCount += 1
            }
            appendReport(interval: interval, message: result.message)
            if !hasPendingPress {
                return
            }
            started = Date()
        }
    }

    private func appendReport(interval: TimeInterval, message: String) {
        reports.insert(
            PressReport(date: Date(), elapsedText: PressReport.elapsedText(of: interval), message: message),
            at: 0
        )
        if reports.count > 10 {
            reports.removeLast(reports.count - 10)
        }
    }
}
