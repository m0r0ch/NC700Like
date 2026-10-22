import Foundation
import UIKit

/// 押下からいいね処理までを担う(LikeCoordinator)。
/// - 押下イベントは BLEService.eventHub(.press) から受け取る。
/// - 受付キャンセルは P3(`10 00 04 08 0B 4A 00`)の単発({ID} 不要・再送なし)。
///   実験ラウンド1〜3の結論: P3 は全成功(6/6)、P1 は「その押下で開かれたセッションの
///   {ID}」でのみ有効で、押下前に届いた制御パケット由来の ID では失敗するため P3 に統一。
///   方式1〜6(P1 送信/再送の各実験スイッチ)は削除済み(tag: pre-cleanup-p3)。
/// - 押下→音声停止の実験ログ(1行)を報告欄と時系列に出す(コピーして報告に貼れる形)。
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

    /// 音声の最終受信時刻(押下→音声停止の実験ログ用)。
    private var lastAudioPacketAt: Date?
    /// 押下→音声停止の確認用タスク(新しい音声パケットごとに作り替える)。
    private var audioStopCheckTask: Task<Void, Never>?

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
            case .audio:
                Task { @MainActor in self?.handleAudioEvent(event) }
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
        if !cancelReceptionOnPress {
            ble.timeline.add("受付キャンセルはオフ(トグル)")
            proceed(with: backgroundTaskID)
            return
        }

        ble.timeline.add("押下処理開始(P3 の単発。直近制御terminal=\(ble.lastControlTerminalHex ?? "なし"))")
        ble.sendDebug(preset: .p3, trigger: "押下直後の受付キャンセル(P3のみ・再送なし)")
        ble.timeline.add("P3 送信済み(再送なし)")

        proceed(with: backgroundTaskID)
    }

    private func proceed(with backgroundTaskID: UIBackgroundTaskIdentifier) {
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

    /// 音声パケットも記録する(押下→音声停止の実験ログ用)。
    private func handleAudioEvent(_ event: BLEEvent) {
        guard !ble.suppressAutoSend else { return }
        lastAudioPacketAt = event.date
        scheduleAudioStopCheck()
    }

    /// 押下→音声停止の実験ログ: 音声が止まってから確認し、1 行だけ報告欄に出す。
    /// 「停止」= 最終音声パケットから 0.4 秒以上無音(実測基準)。
    private func scheduleAudioStopCheck() {
        audioStopCheckTask?.cancel()
        guard mode == .like, cancelReceptionOnPress, !ble.suppressAutoSend else { return }
        guard let pressDate = ble.lastPressAt, pressDate <= lastAudioPacketAt ?? .distantPast else { return }
        audioStopCheckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            guard let stoppedAt = self.lastAudioPacketAt else { return }
            guard pressDate <= stoppedAt else { return }
            guard Date().timeIntervalSince(stoppedAt) >= 0.4 else { return }
            self.logExperimentLine(pressDate: pressDate, audioStoppedAt: stoppedAt)
        }
    }

    /// 実験ログ 1 行: 「押下→音声停止 X.XX 秒 成功/失敗」。失敗時は押下後の生の制御パケットを添える。
    /// 成功判定: 押下から約 2 秒以内に音声が止まる(実機ラウンド1で確認した通常のキャンセル所要)。
    private func logExperimentLine(pressDate: Date, audioStoppedAt: Date) {
        let elapsed = audioStoppedAt.timeIntervalSince(pressDate)
        let elapsedText = String(format: "%.2f 秒", max(0, elapsed))
        let controls = ble.recentControls.filter { $0.date >= pressDate.addingTimeInterval(-0.05) }
        let text: String
        if elapsed <= 2.0 {
            text = "実験ログ: 押下→音声停止 \(elapsedText) 成功"
        } else {
            let controlText = controls.isEmpty
                ? "(押下後の制御パケットなし)"
                : controls.map { "[\(Self.controlDateText($0.date, pressDate))] \($0.hex)" }.joined(separator: " / ")
            text = "実験ログ: 押下→音声停止 \(elapsedText) 失敗 制御=\(controlText)"
        }
        ble.timeline.add(text)
        appendReport(interval: elapsed, message: text)
    }

    private static func controlDateText(_ date: Date, _ pressDate: Date) -> String {
        String(format: "押下+%.0fms", max(0, date.timeIntervalSince(pressDate)) * 1000)
    }

    private func runProcessing(startedAt: Date, backgroundTaskID: UIBackgroundTaskIdentifier) async {
        var started = startedAt
        defer {
            isProcessing = false
            BackgroundTaskManager.shared.endTask(backgroundTaskID)
        }
        while true {
            hasPendingPress = false
            ble.timeline.add("Spotify 呼出開始")
            let result = await spotifyClient.likeCurrentTrack()
            let interval = Date().timeIntervalSince(started)
            ble.timeline.add("Spotify 結果: \(result.message)")
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
