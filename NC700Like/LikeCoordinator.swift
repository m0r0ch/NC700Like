import Foundation
import UIKit
import NC700LikeKit

/// 押下からいいね処理までを担う(LikeCoordinator)。
/// - 押下イベントは BLEService.eventHub(.press) から受け取る。
/// - 処理は直列化。処理中の押下は1件だけキューに入れて集約する。
/// - P1(受付キャンセル)送信はいいねの HTTP と並行で即座に発火する(E5 実測: 送信後約0.3秒でマイク終了)。
/// - Phase 4: いいね処理中は UIBackgroundTask で実行時間を確保し、完了時に解放する。
///   コーディネータは NC700LikeApp.init() で接続するため、バックグラウンド起動(Cold Start)でも押下を拾う。
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

    /// App・画面のどちらからも同じインスタンスを使う(Cold Start でのバックグラウンド購読のため)。
    static let shared = LikeCoordinator(ble: .shared)

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

    /// 押下後の P1 再送(電源入れ直し後の最初の押下で古い {ID} が無効な対策)。
    /// 押下後まもなく流れるセッション開始の制御パケットを取って、違う {ID} で P1 を1回だけ再送する。
    /// 期限は押下後 2.0 秒。E10(連続 P1×2)相当の運用。
    private var cancelSessionUntil: Date?
    private var p1SentCount = 0
    private var lastP1Terminal: UInt8?

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
            switch event.kind {
            case .press:
                Task { @MainActor in self?.handlePress() }
            case .control:
                Task { @MainActor in self?.handleControl(bytes: event.bytes) }
            default:
                break
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
            NotificationManager.shared.postLikeResult("Spotify 未ログインのためいいねしませんでした")
            return
        }
        let backgroundTaskID = BackgroundTaskManager.shared.beginTask(reason: "押下 → いいね処理")
        p1SentCount = 0
        lastP1Terminal = nil
        cancelSessionUntil = nil
        if cancelReceptionOnPress {
            guard ble.controlTerminalByte() != nil else {
                appendReport(interval: 0, message: "P1 未送信: 制御パケット未受信({ID} 未確定)")
                BackgroundTaskManager.shared.endTask(backgroundTaskID)
                return
            }
            cancelSessionUntil = Date().addingTimeInterval(2.0)
            // 受付キャンセルは即送信(.withResponse の完了は待たない)。古い {ID} の可能性もあるため、
            // 押下後の制御パケットで handleControl が新 {ID} 再送を判定する。
            ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
            p1SentCount = 1
            lastP1Terminal = ble.controlTerminalByte()
        }
        if isProcessing {
            hasPendingPress = true
            appendReport(interval: 0, message: "いいね処理中に押下を検出。処理完了後に続行します")
            BackgroundTaskManager.shared.endTask(backgroundTaskID)
            return
        }
        isProcessing = true
        let started = Date()
        Task { await runProcessing(startedAt: started, backgroundTaskID: backgroundTaskID) }
    }

    /// 押下後に流れる FE03 制御パケット。押下後 2.0 秒以内で、押下時に送った P1 の {ID} と
    /// 異なる末尾バイトのパケットが来たら、新 {ID} で P1 を 1 回だけ再送する。
    /// (電源入れ直し後の最初の押下に効く。以降は即送信の P1 が効くため再送は動かない。)
    private func handleControl(bytes: Data) {
        guard !ble.suppressAutoSend else { return }
        guard mode == .like, cancelReceptionOnPress else { return }
        guard let deadline = cancelSessionUntil, Date() < deadline else { return }
        guard p1SentCount >= 1, p1SentCount < 2 else { return }
        guard let terminal = bytes.last else { return }
        guard terminal != lastP1Terminal else { return }
        cancelSessionUntil = nil
        p1SentCount += 1
        lastP1Terminal = terminal
        ble.sendDebug(preset: .p1, trigger: "押下後の制御パケットで新 {ID} 再送(2回目)")
    }

    private func runProcessing(startedAt: Date, backgroundTaskID: UIBackgroundTaskIdentifier) async {
        var started = startedAt
        defer {
            isProcessing = false
            BackgroundTaskManager.shared.endTask(backgroundTaskID)
        }
        while true {
            hasPendingPress = false
            let result = await spotifyClient.likeCurrentTrack()
            let interval = Date().timeIntervalSince(started)
            if case .saved = result {
                likeCount += 1
            }
            appendReport(interval: interval, message: result.message)
            NotificationManager.shared.postLikeResult(result.message)
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
