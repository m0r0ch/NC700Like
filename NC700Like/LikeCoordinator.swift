import Foundation
import UIKit
import NC700LikeKit

/// 押下からいいね処理までを担う(LikeCoordinator)。
/// - 押下イベントは BLEService.eventHub(.press) から受け取る。
/// - 処理は直列化。処理中の押下は1件だけキューに入れて集約する。
/// - 受付キャンセルは方式(P1ResendStrategy)で切り替えられる。
///   現行: 押下時に即 P1(直近 {ID})+ 押下後 2.0 秒の再送ウィンドウ(Phase 4 までの動作)。
///   拡張: 即 P1 + 押下トークンに紐づく 8.0 秒ウィンドウで、違う {ID} の制御パケット到着時に
///         P1 を 1 回だけ再送(電源入れ直し後の古い {ID} が無効になっている問題の対策)。
///   古ID待ち: 古い ID の間(この接続世代で制御パケット未受信)は押下時の P1 を省き、
///         制御パケット到着で 8.0 秒ウィンドウ内に 1 回だけ送る。
///   P3 先行: 古い ID の間は ID 非依存で実機確認済みのキャンセルプリセット P3
///         (`10 00 04 08 0B 4A 00`: Phase 1 実測で P1 と同等に受付をキャンセル)を押下時に送る。
/// - Phase 4: いいね処理中は UIBackgroundTask で実行時間を確保し、完了時に解放する。
///   コーディネータは NC700LikeApp.init() で接続するため、バックグラウンド起動(Cold Start)でも押下を拾う。
@MainActor
final class LikeCoordinator: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case like = "いいねする"
        case detectionOnly = "検出のみ(いいねしない)"

        var id: String { rawValue }
    }

    /// 受付キャンセル方式(実験スイッチ)。
    enum CancelStrategy: String, CaseIterable, Identifiable {
        case current = "現行(即 P1+2秒再送)"
        case extended = "拡張(即 P1+8秒再送)"
        case deferOnStale = "拡張:古ID時は制御パケット待ち"
        case p3OnStale = "拡張:古ID時は P3"
        case p3Only = "P3のみ(ID未確定時・再送なし)"
        case afterSession = "セッション確立後P1(0.5秒×最大3)"

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
    static let strategyKey = "like.cancelStrategy"

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
    @Published var strategy: CancelStrategy {
        didSet { UserDefaults.standard.set(strategy.rawValue, forKey: Self.strategyKey) }
    }
    @Published private(set) var reports: [PressReport] = []
    @Published private(set) var likeCount = 0
    @Published private(set) var isProcessing = false

    private var handlerToken: UUID?
    /// 1回のいいね処理の間に検出された押下の数(集約して後続処理する)。
    private var hasPendingPress = false

    /// 押下単位の再送ウィンドウ(Step B: トークンに紐づける。次の押下で破棄・入れ替え)。
    private var resendWindow: P1ResendWindow?

    /// 方式6(セッション確立後P1)の実行状態。押下ごとに作り替える(token で判別)。
    private struct SessionP1Plan: Equatable {
        let token: UUID
        let pressAt: TimeInterval
        var sentCount: Int
    }
    private var sessionP1Plan: SessionP1Plan?
    /// 方式6: 直近で P1 を送った時刻(エコー検出の基準)。
    private var lastSessionP1SendAt: TimeInterval?
    /// 方式6: 直近の P1 送信後に応答候補の制御パケットが届いたか。
    private var sessionP1EchoReceived = false
    /// 方式6: 音声の最終受信時刻(音声停止検出用)。
    private var lastAudioPacketAt: Date?

    init(ble: BLEService, spotifyClient: SpotifyClient = .shared) {
        self.ble = ble
        self.spotifyClient = spotifyClient
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey)
        mode = savedMode.flatMap(Mode.init(rawValue:)) ?? .like
        let savedStrategy = UserDefaults.standard.string(forKey: Self.strategyKey)
        strategy = savedStrategy.flatMap(CancelStrategy.init(rawValue:)) ?? .p3Only
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
                Task { @MainActor in self?.handleControlEvent(event) }
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

        let pressedAt = ble.lastPressAt ?? Date()
        let idEstablished = ble.isControlIDEstablished
        let terminal = ble.controlTerminalByte()
        ble.timeline.add("押下処理開始 方式=\(strategy.rawValue) gen内{ID}確定=\(idEstablished ? "済" : "未") 直近{ID}=\(terminal.map { String(format: "%02X", $0) } ?? "なし")")

        // 次の押下で前の押下の状態(再送ウィンドウ・方式6の実行状態)は破棄される(入れ替え)。
        resendWindow = nil
        sessionP1Plan = nil
        lastSessionP1SendAt = nil
        sessionP1EchoReceived = false
        switch strategy {
        case .current:
            guard terminal != nil else {
                ble.timeline.add("P1 未送信(直近 {ID} なし)")
                appendReport(interval: 0, message: "P1 未送信: 制御パケット未受信({ID} 未確定)")
                BackgroundTaskManager.shared.endTask(backgroundTaskID)
                return
            }
            ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
            resendWindow = P1ResendWindow(
                windowSeconds: CancelRetryConstants.legacyWindowSeconds,
                pressAt: pressedAt.timeIntervalSince1970,
                immediateID: terminal,
                sentImmediate: true
            )
        case .extended:
            guard terminal != nil else {
                ble.timeline.add("P1 未送信(直近 {ID} なし)")
                appendReport(interval: 0, message: "P1 未送信: 制御パケット未受信({ID} 未確定)")
                BackgroundTaskManager.shared.endTask(backgroundTaskID)
                return
            }
            ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
            resendWindow = P1ResendWindow(
                windowSeconds: CancelRetryConstants.resendWindowSeconds,
                pressAt: pressedAt.timeIntervalSince1970,
                immediateID: terminal,
                sentImmediate: true
            )
        case .deferOnStale:
            if idEstablished, terminal != nil {
                ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
                resendWindow = P1ResendWindow(
                    windowSeconds: CancelRetryConstants.resendWindowSeconds,
                    pressAt: pressedAt.timeIntervalSince1970,
                    immediateID: terminal,
                    sentImmediate: true
                )
            } else {
                // 古い ID の可能性が高いので押下時の送信を省き、制御パケット到着(8秒ウィンドウ内)で送る。
                ble.timeline.add("古い {ID} のため押下時の P1 を省略(ウィンドウ待ち)")
                resendWindow = P1ResendWindow(
                    windowSeconds: CancelRetryConstants.resendWindowSeconds,
                    pressAt: pressedAt.timeIntervalSince1970,
                    immediateID: nil,
                    sentImmediate: false
                )
            }
        case .p3OnStale:
            if idEstablished, terminal != nil {
                ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
                resendWindow = P1ResendWindow(
                    windowSeconds: CancelRetryConstants.resendWindowSeconds,
                    pressAt: pressedAt.timeIntervalSince1970,
                    immediateID: terminal,
                    sentImmediate: true
                )
            } else {
                // Phase 1 実測: P3 は {ID} なしで P1 と同等に受付をキャンセルできる。
                ble.sendDebug(preset: .p3, trigger: "押下直後の受付キャンセル(P3・ID非依存)")
                resendWindow = P1ResendWindow(
                    windowSeconds: CancelRetryConstants.resendWindowSeconds,
                    pressAt: pressedAt.timeIntervalSince1970,
                    immediateID: nil,
                    sentImmediate: true
                )
            }
        case .p3Only:
            if idEstablished, terminal != nil {
                ble.sendDebug(preset: .p1, trigger: "押下直後の受付キャンセル")
                resendWindow = P1ResendWindow(
                    windowSeconds: CancelRetryConstants.resendWindowSeconds,
                    pressAt: pressedAt.timeIntervalSince1970,
                    immediateID: terminal,
                    sentImmediate: true
                )
            } else {
                // 方式5: 未確定なら P3 の単発だけ。再送ウィンドウは作らない。
                ble.sendDebug(preset: .p3, trigger: "押下直後の受付キャンセル(P3のみ・再送なし)")
                resendWindow = nil
                ble.timeline.add("P3 送信済み(再送ウィンドウは作らない)")
            }
        case .afterSession:
            // 方式6: 押下時は送らない。押下後最初の FE03 音声/制御パケットで P1 を送り、
            // 0.5 秒間隔・最大3回の再送(応答候補の制御パケット or 音声停止で打ち止め)。
            let plan = SessionP1Plan(
                token: UUID(),
                pressAt: pressedAt.timeIntervalSince1970,
                sentCount: 0
            )
            sessionP1Plan = plan
            ble.timeline.add("押下時は送信せず(セッション確立待ち)")
            // 順序の揺れ対策: 押下前に届いてキューに残った制御パケットがあれば即送る。
            if let recent = ble.freshControlNearPress(pressAt: pressedAt, lookbackSeconds: 1.0) {
                triggerSessionP1IfWaiting(at: recent.date)
            }
        }

        // 順序の揺れ対策: 押下と同時に届いたセッション開始の制御パケット(08 0B 等)が
        // .press のハンドラより先に処理済みだった場合、ここで直近キューを確認して再送判定に回す。
        if let window = resendWindow,
           let recent = ble.freshControlNearPress(
               pressAt: pressedAt,
               lookbackSeconds: 1.0
           ) {
            evaluate(window: window, terminal: recent.terminal, at: recent.date.timeIntervalSince1970)
        }

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

    /// 制御パケット到着時の再送判定(ウィンドウは押下単位で管理)。
    private func handleControlEvent(_ event: BLEEvent) {
        guard !ble.suppressAutoSend else { return }
        guard mode == .like, cancelReceptionOnPress else { return }
        guard let terminal = event.bytes.last else { return }
        // 方式6: P1 送信直後(0.7秒以内)の制御パケットは応答候補とみなす。
        if let sentAt = lastSessionP1SendAt,
           event.date.timeIntervalSince1970 - sentAt <= 0.7 {
            sessionP1EchoReceived = true
        }
        // 方式6: 押下後最初の制御パケットでセッション確立後の P1 を送る。
        triggerSessionP1IfWaiting(at: event.date)
        evaluate(
            window: resendWindow,
            terminal: terminal,
            at: event.date.timeIntervalSince1970
        )
    }

    /// 方式6 や音声停止の検出のため、音声パケットも記録する。
    private func handleAudioEvent(_ event: BLEEvent) {
        guard !ble.suppressAutoSend else { return }
        lastAudioPacketAt = event.date
        guard mode == .like, cancelReceptionOnPress else { return }
        triggerSessionP1IfWaiting(at: event.date)
    }

    /// 方式6: 押下後最初の音声/制御パケットをトリガにして P1 を送る(以降は 0.5 秒間隔で再送)。
    private func triggerSessionP1IfWaiting(at date: Date) {
        guard var plan = sessionP1Plan, plan.sentCount == 0 else { return }
        guard date.timeIntervalSince1970 > plan.pressAt else { return }
        plan.sentCount = 1
        sessionP1Plan = plan
        sessionP1EchoReceived = false
        ble.timeline.add("セッション確立後の P1 送信(方式6・初回)")
        ble.sendDebug(preset: .p1, trigger: "セッション確立後の受付キャンセル(P1)")
        lastSessionP1SendAt = Date().timeIntervalSince1970
        scheduleSessionP1Resends(token: plan.token)
    }

    /// 方式6: 初回送信から 0.5 秒間隔・最大3回の再送。
    /// 停止条件: 応答候補(制御パケット)が届く/音声が止まる/次の押下で計画が破棄される。
    private func scheduleSessionP1Resends(token: UUID) {
        Task { @MainActor in
            for index in 1...CancelRetryConstants.sessionP1MaxResends {
                try? await Task.sleep(nanoseconds: UInt64(CancelRetryConstants.sessionP1ResendInterval * 1_000_000_000))
                guard let plan = sessionP1Plan, plan.token == token, plan.sentCount >= 1 else { return }
                if sessionP1EchoReceived {
                    ble.timeline.add("セッションP1: 応答候補を検出したため再送を停止")
                    return
                }
                if let audio = lastAudioPacketAt, Date().timeIntervalSince(audio) > 0.4 {
                    ble.timeline.add("セッションP1: 音声が停止したため再送を停止")
                    return
                }
                var updated = plan
                updated.sentCount += 1
                sessionP1Plan = updated
                ble.sendDebug(preset: .p1, trigger: "セッション確立後P1 再送#\(index)")
                lastSessionP1SendAt = Date().timeIntervalSince1970
                sessionP1EchoReceived = false
            }
            ble.timeline.add("セッションP1: 再送上限に到達")
        }
    }

    private func evaluate(window: P1ResendWindow?, terminal: UInt8, at: TimeInterval) {
        let now = Date().timeIntervalSince1970
        let decision = P1ResendWindow.decide(
            window: window,
            controlTerminal: terminal,
            controlAt: at,
            now: now
        )
        switch decision {
        case .send(let id, let label):
            var updated = window
            updated?.resendCount += 1
            resendWindow = updated
            ble.timeline.add("再送判定: \(label)")
            let elapsed = window.map { max(0, now - $0.pressAt) }
            appendReport(
                interval: elapsed ?? 0,
                message: window?.sentImmediate == true ? label : "制御パケット到着で P1 送信({ID}=\(String(format: "%02X", id)))"
            )
            ble.sendDebug(preset: .p1, hexString: nil, trigger: label)
        case .skip(let reason):
            ble.timeline.add("再送判定: 送らない(\(reason))")
        }
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
