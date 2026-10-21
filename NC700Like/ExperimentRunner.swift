import Foundation
import CoreBluetooth
import NC700LikeKit

/// 実験モードの試行フロー(手順0〜質問C・保存)。
/// ButtonEventDetector / DeviceConfiguration には触らない。
final class ExperimentRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preCheck           // 手順0: 送信前チェック
        case waitingForPress    // 手順1: 「ボタンを押してください」
        case choiceA            // 質問A(押下直後の音)
        case sending            // 手順2: 送信(E0 はもう一度押してから確認ボタン)
        case observing          // 手順3: 3秒観察(カウントダウン)
        case choiceB            // 質問B(3秒後の音)
        case choiceC            // 質問C(受付の終わり)
        case memo               // メモ入力 → 保存して次
    }

    struct AudioCounters: Equatable {
        var before = 0
        var bucket0_500 = 0
        var bucket500_1500 = 0
        var bucket1500_3000 = 0
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String = ""
    /// 手順2でまだ送っていないステップ(画面のボタン文言に使う)。自動送信分は START 時点で消える。
    @Published private(set) var pendingSteps: [SequenceStep] = []
    @Published private(set) var observeCountdownRemaining: Int = 3
    @Published private(set) var audio = AudioCounters()
    /// 現在試行の表示用イベント行("+123ms 制御 ..." 形式)。
    @Published private(set) var eventsText: [String] = []
    /// START 検出済み(手順1 の進行表示用)。
    @Published private(set) var startDetected = false

    /// 保存済みセッション(試行履歴。アプリ再起動後も残す)。
    @Published private(set) var session: ExperimentSession = TrialStorage.load()

    // 試行中の回答・メモ(この試行の TrialRecord 保存時に使う)。
    @Published var answerA = ""
    @Published var answerB = ""
    @Published var answerC = ""
    @Published var memoText = ""

    private let ble: BLEService
    private var hubToken: UUID?
    private var scenario: ExperimentScenario = .e0
    private var currentTrial: TrialRecord?
    private var startAt: Date?
    private var sendAnchor: Date?
    private var sentHexes: [String] = []
    private var observeTimer: Timer?
    private var scheduledWorks: [DispatchWorkItem] = []

    init(ble: BLEService) {
        self.ble = ble
        hubToken = ble.eventHub.addHandler { [weak self] event in
            self?.handle(event)
        }
        ble.suppressAutoSend = true
    }

    deinit {
        scheduledWorks.forEach { $0.cancel() }
        observeTimer?.invalidate()
        hubToken.map { ble.eventHub.removeHandler($0) }
    }

    // MARK: - 試行の開始/終了

    /// 手順0 から開始(既に進行中の試行があれば破棄して新規)。
    func begin(scenario: ExperimentScenario) {
        if currentTrial != nil { abort() }
        self.scenario = scenario

        var trial = TrialRecord(
            id: UUID(),
            index: session.trials.count + 1,
            scenario: scenario,
            initial7B61Hex: ble.last7B61Hex,
            sentHex: nil,
            presetNames: [],
            idByteHex: ble.lastControlTerminalHex,
            delayMeasuredMs: nil,
            writeResults: [],
            writeCompletedMs: nil,
            events: [],
            audioBefore: 0,
            audio0_500: 0,
            audio500_1500: 0,
            audio1500_3000: 0,
            final7B61Hex: nil,
            final7B61IsIdle: nil,
            answerA: "",
            answerB: "",
            answerC: "",
            memo: ""
        )
        trial.events.append(TrialEvent(
            relMs: 0,
            text: "試行開始(手順0) 開始時7B61=\(ble.last7B61Hex ?? "-") / {ID}=\(ble.lastControlTerminalHex ?? "-") / 接続=\(ble.connectionRoute)"
        ))
        currentTrial = trial

        answerA = ""
        answerB = ""
        answerC = ""
        memoText = ""
        startAt = nil
        sendAnchor = nil
        sentHexes = []
        startDetected = false
        pendingSteps = scenario.steps
        audio = AudioCounters()
        eventsText = []
        ble.suppressAutoSend = true

        // セッション共通情報(初回のみ記録)。
        if session.deviceName == nil { session.deviceName = ble.connectedDeviceName }
        if session.connectionRouteAtStart == nil { session.connectionRouteAtStart = ble.connectionRoute }
        if session.start7B61Hex == nil { session.start7B61Hex = ble.last7B61Hex }

        phase = .preCheck
        recheck()
    }

    /// 手順0 の再評価: 7B61 の状態で分岐し、必要なら警告を表示する。
    func recheck() {
        guard phase == .preCheck, currentTrial != nil else { return }
        if ble.last7B61Hex == nil {
            notice = "7B61 通知がまだ1回も無いので、手順1に進む前にヘッドホンのボタンを1回押して状態を取得してください。"
            return
        }
        if ble.isIdleState7B61 {
            notice = ""
            enterWaitingForPress()
        } else {
            notice = "受付が続いています(7B61≠00 06)。リセット送信(P1)で一度受付を止めてから手順1に進みます。"
        }
    }

    /// 手順0 の警告後: リセット送信(P1)→2秒待つ→手順1 へ。
    func resetAndContinue() {
        guard phase == .preCheck, currentTrial != nil else { return }
        let data = ControlTemplate.data(.p1, idByte: ble.controlTerminalByte())
        appendEventNow("リセット送信 P1: \(HexTool.hex(data ?? Data()))")
        ble.writeControl(data: data, label: "実験リセット") { [weak self] success in
            guard let self, self.phase == .preCheck else { return }
            if success {
                self.notice = "リセット送信完了(P1)。2秒後に手順1へ進みます。"
                self.appendEventNow("リセット書込完了")
                self.schedule(seconds: 2.0) { self.enterWaitingForPress() }
            } else {
                self.notice = "リセット送信に失敗(未接続/書込特性なし)。「リセットせず進む」を使ってください。"
                self.appendEventNow("リセット書込失敗")
            }
        }
    }

    /// 警告を無視してそのまま手順1へ。
    func skipReset() {
        guard phase == .preCheck, currentTrial != nil else { return }
        appendEventNow("リセットをスキップ")
        enterWaitingForPress()
    }

    private func enterWaitingForPress() {
        notice = ""
        startDetected = false
        phase = .waitingForPress
        appendEventNow("手順1: ヘッドホンのボタンを押してください")
    }

    /// 現在の試行を破棄して idle へ(保存しない)。
    func abort() {
        cancelScheduled()
        observeTimer?.invalidate()
        currentTrial = nil
        pendingSteps = []
        startAt = nil
        sendAnchor = nil
        phase = .idle
        notice = ""
        eventsText = []
    }

    /// メモ確定・保存・idle へ。
    func saveAndNext() {
        guard var trial = currentTrial else { return }
        trial.answerA = answerA
        trial.answerB = answerB
        trial.answerC = answerC
        trial.memo = memoText
        trial.audioBefore = audio.before
        trial.audio0_500 = audio.bucket0_500
        trial.audio500_1500 = audio.bucket500_1500
        trial.audio1500_3000 = audio.bucket1500_3000
        currentTrial = trial
        session.trials.append(trial)
        TrialStorage.save(session)
        abort()
    }

    /// 保存データ全消去。
    func clearAll() {
        session = ExperimentSession()
        TrialStorage.clear()
    }

    // MARK: - 画面操作

    /// 質問A(押下直後の音)。→ 手順2 へ(自動送信シナリオは送信済みなので観察へ)。
    func answerA(_ label: String) {
        guard phase == .choiceA, currentTrial != nil else { return }
        answerA = label
        appendEventNow("音A=\(label)")
        if scenario == .e0 || !pendingSteps.isEmpty {
            phase = .sending
            if pendingSteps.isEmpty {
                appendEventNow("手順2: もう一度ボタンを押して「押しました」を押す")
            }
        } else {
            beginObserve()
        }
    }

    /// 手動送信ボタン(E1〜E4 の1本目等)。残りに手動ステップが無い場合は無視。
    func userTapSend() {
        guard phase == .sending, currentTrial != nil,
              let index = pendingSteps.firstIndex(where: { $0.delayFromStartMs == nil && $0.delayFromPreviousMs == nil })
        else { return }
        let step = pendingSteps.remove(at: index)
        sendStep(step, trigger: "手動送信")
    }

    /// E0: 「もう一度押しました」の確認 → 観察開始。
    func userConfirmManualPress() {
        guard phase == .sending, scenario == .e0, currentTrial != nil else { return }
        appendEventNow("再押下を確認(手動)")
        beginObserve()
    }

    /// E0 用に送信画面を飛ばす押下確認が済んだ場合の再キャンセル(未使用だが公開)。
    func cancelObservation() {
        guard phase == .observing else { return }
        observeTimer?.invalidate()
        phase = .sending
    }

    /// 質問B(3秒後の音)。
    func answerB(_ label: String) {
        guard phase == .choiceB, currentTrial != nil else { return }
        answerB = label
        appendEventNow("音B=\(label)")
        phase = .choiceC
    }

    /// 質問C(受付の終わり)。
    func answerC(_ label: String) {
        guard phase == .choiceC, currentTrial != nil else { return }
        answerC = label
        appendEventNow("受付=\(label)")
        phase = .memo
    }

    // MARK: - 送信実行(+スケジュール)

    private func sendStep(_ step: SequenceStep, trigger: String) {
        guard currentTrial != nil else { return }
        let nowMs = relFromStart()
        if currentTrial?.delayMeasuredMs == nil {
            currentTrial?.delayMeasuredMs = nowMs
        }
        currentTrial?.presetNames.append(step.template.name)
        let data = ControlTemplate.data(step.template, idByte: ble.controlTerminalByte())
        let hex = HexTool.hex(data ?? Data())
        sentHexes.append("\(step.template.name): \(hex)")
        currentTrial?.sentHex = sentHexes.joined(separator: " + ")
        if sendAnchor == nil { sendAnchor = Date() }
        appendEvent(nowMs, "送信(\(trigger)) \(step.template.name): \(hex)")
        ble.writeControl(data: data, label: "実験(\(step.template.name))") { [weak self] success in
            guard let self, let trial = self.currentTrial else { return }
            let doneMs = self.relFromStart()
            if trial.writeCompletedMs == nil {
                self.currentTrial?.writeCompletedMs = doneMs
                self.currentTrial?.writeResults.append(
                    success ? "OK(\(doneMs)ms)" : "ERROR"
                )
            } else {
                self.currentTrial?.writeResults.append(success ? "OK2" : "ERROR2")
            }
            self.appendEvent(doneMs, "書込\(success ? "完了" : "失敗") \(step.template.name)")
            self.scheduleNextFromPreviousStep(after: step)
            self.maybeAutoBeginObserve()
        }
    }

    /// 前ステップ完了に続いて自動送信すべきステップ(delayFromPreviousMs)をスケジュールする。
    private func scheduleNextFromPreviousStep(after step: SequenceStep) {
        guard let next = pendingSteps.first, let delayMs = next.delayFromPreviousMs else { return }
        schedule(seconds: Double(delayMs) / 1000.0) { [weak self] in
            guard let self, let index = self.pendingSteps.firstIndex(where: { $0 == next }) else { return }
            let step = self.pendingSteps.remove(at: index)
            self.sendStep(step, trigger: "自動送信(前書込から\(delayMs)ms)")
        }
    }

    /// START に連動する自動送信(delayFromStartMs)をスケジュールする。
    private func scheduleAutoSendsFromStart() {
        for step in scenario.steps where step.delayFromStartMs != nil {
            let delayMs = step.delayFromStartMs!
            schedule(seconds: Double(delayMs) / 1000.0) { [weak self] in
                guard let self,
                      let index = self.pendingSteps.firstIndex(where: { $0 == step }),
                      self.phase != .idle
                else { return }
                self.pendingSteps.remove(at: index)
                self.sendStep(step, trigger: "自動送信(STARTから\(delayMs)ms)")
            }
        }
    }

    /// 送信が全て済み(=手動ステップ無し)で未観察なら観察を開始する。
    private func maybeAutoBeginObserve() {
        guard phase == .sending, currentTrial != nil, pendingSteps.isEmpty, scenario != .e0 else { return }
        beginObserve()
    }

    // MARK: - 手順3: 3秒観察

    private func beginObserve() {
        guard currentTrial != nil, phase != .observing else { return }
        sendAnchor = sendAnchor ?? Date()
        let anchor = sendAnchor!
        appendEventNow("手順3: 3秒観察 開始")
        observeCountdownRemaining = 3
        phase = .observing
        observeTimer?.invalidate()
        observeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self, let anchor = self.sendAnchor, self.phase == .observing else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(anchor)
            let remaining = max(0, Int(ceil(3.0 - elapsed)))
            self.observeCountdownRemaining = remaining
            if elapsed >= 3.0 {
                timer.invalidate()
                self.finishObservation()
            }
        }
    }

    private func finishObservation() {
        guard currentTrial != nil else { return }
        ble.read7B61Once { [weak self] hex in
            guard let self, self.phase == .observing else { return }
            self.currentTrial?.final7B61Hex = hex
            self.currentTrial?.final7B61IsIdle = self.ble.isIdleState7B61
            self.appendEvent(self.relFromStart(), "3秒後 7B61=\(hex ?? "-") 受付待ち=\(self.ble.isIdleState7B61 ? "YES" : "NO")")
            self.phase = .choiceB
        }
    }

    // MARK: - BLE イベント

    private func handle(_ event: BLEEvent) {
        switch event.kind {
        case .press:
            if phase == .waitingForPress, startAt == nil {
                handleStart(event.date, reason: "押下検出(7B61)")
            }
            appendEvent(relFromStart(), "押下検出 7B61=\(event.hexText)")
        case .control:
            if phase == .waitingForPress, startAt == nil, event.hasControlStart() {
                handleStart(event.date, reason: "FE03 制御パケット(08 0B)")
            }
            appendEvent(relFromStart(), "制御 \(event.bytes.count)B: \(event.hexText)")
        case .notification7B61:
            appendEvent(relFromStart(), "7B61 \(event.hexText)")
        case .audio:
            countAudio(at: Date())
        case .disconnected:
            guard currentTrial != nil else { return }
            notice = "接続が切れました(BLEService が自動復旧します)。保存せず試行中止。"
            abort()
        }
    }

    /// 手順1 START の検出(rel=0 基準点)。7B61 変化 or 制御パケット(08 0B)。
    private func handleStart(_ date: Date, reason: String) {
        guard phase == .waitingForPress, startAt == nil else { return }
        startAt = date
        startDetected = true
        currentTrial?.events = []
        appendEvent(0, "START 検出: \(reason)")
        appendEvent(0, "START時 7B61=\(ble.last7B61Hex ?? "-") / {ID}=\(ble.lastControlTerminalHex ?? "-")")
        phase = .choiceA
        scheduleAutoSendsFromStart()
    }

    // MARK: - helpers

    private func relFromStart() -> Int {
        guard let startAt else { return 0 }
        return Int(Date().timeIntervalSince(startAt) * 1000)
    }

    private func appendEventNow(_ text: String) {
        appendEvent(relFromStart(), text)
    }

    private func appendEvent(_ relMs: Int, _ text: String) {
        guard currentTrial != nil else { return }
        let rel = relMs < 0 ? 0 : relMs
        currentTrial?.events.append(TrialEvent(relMs: rel, text: text))
        if (currentTrial?.events.count ?? 0) > 200 {
            currentTrial?.events.removeFirst(50)
        }
        let row = "\(rel >= 0 ? "+" : "")\(rel)ms \(text)"
        eventsText.append(row)
        if eventsText.count > 200 {
            eventsText.removeFirst(eventsText.count - 200)
        }
    }

    private func countAudio(at now: Date) {
        guard currentTrial != nil else { return }
        guard let anchor = sendAnchor else {
            audio.before += 1
            return
        }
        let rel = Int(now.timeIntervalSince(anchor) * 1000)
        if rel < 0 {
            audio.before += 1
        } else if rel < 500 {
            audio.bucket0_500 += 1
        } else if rel < 1500 {
            audio.bucket500_1500 += 1
        } else if rel < 3000 {
            audio.bucket1500_3000 += 1
        }
    }

    private func schedule(seconds: TimeInterval, work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        scheduledWorks.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelScheduled() {
        scheduledWorks.forEach { $0.cancel() }
        scheduledWorks.removeAll()
    }

    // MARK: - 画面からの参照用

    /// 実行中のシナリオ(idle 界隈では最後に begin されたもの/idle 前の初期値は E0)。
    var currentScenario: ExperimentScenario { scenario }

    /// 画面に表示する現在シナリオ(E1 など)。
    var currentScenarioLabel: String { scenario.label }

    /// 手動送信がまだ残っているステップ一覧(画面の送信ボタン文言用)。
    var pendingManualSteps: [SequenceStep] {
        pendingSteps.filter { $0.delayFromStartMs == nil && $0.delayFromPreviousMs == nil }
    }
}

// MARK: - helpers

extension BLEEvent {
    /// 制御パケットに protobuf「08 0B」(受付開始と推測)のバイト対が含まれるか。
    func hasControlStart() -> Bool {
        let bytes = [UInt8](self.bytes)
        guard bytes.count >= 2 else { return false }
        return (0..<bytes.count - 1).contains { bytes[$0] == 0x08 && bytes[$0 + 1] == 0x0B }
    }
}
