import Foundation
import CoreBluetooth
import NC700LikeKit

/// 押下検出と接続イベントを画面に出すためのログ。
struct BLELogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let kind: Kind
    let hex: String?
    let note: String

    enum Kind: Equatable {
        case connection
        case discovery
        case notification
        case press
        case audio
        case control
        case error
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// REQ C-2: ミリ秒まで。
    var timeText: String {
        Self.timeFormatter.string(from: date)
    }

    var kindText: String {
        switch kind {
        case .connection: return "接続"
        case .discovery: return "発見"
        case .notification: return "7B61"
        case .press: return "押下"
        case .audio: return "音声"
        case .control: return "制御"
        case .error: return "ERROR"
        }
    }
}

/// 広域スキャンで見つかった周辺機器の1行分。
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var idPrefix: String
    var servicesText: String
    var rssi: NSInteger
    var matches: Bool
    var seenCount: Int

    var rowText: String {
        "\(name) / id=\(idPrefix) / services=\(servicesText) / RSSI=\(rssi) / 観測\(seenCount)回\(matches ? " / ★一致" : "")"
    }
}

struct BLECatalogCharacteristic: Identifiable, Equatable {
    var id: String { uuid }
    let uuid: String
    let properties: String
}

struct BLECatalogService: Identifiable, Equatable {
    var id: String { uuid }
    let uuid: String
    var characteristics: [BLECatalogCharacteristic]
}

enum BLEConnectionPhase: Equatable {
    case idle(device: String?)          // 再接続待ち/待機
    case scanning                       // 広域スキャン中
    case pending(device: String)        // 保留接続中=ヘッドホン待ち
    case connected(device: String)      // 接続中
    case subscribed(device: String)     // 接続中+両購読済み

    var label: String {
        switch self {
        case .idle(let d):
            return d ?? "待機中(再接続待ち)"
        case .scanning:
            return "スキャン中…(広域・全デバイス照会)"
        case .pending(let d):
            return "\(d) 保留接続中(ヘッドホン待ち)"
        case .connected(let d):
            return "\(d) 接続 ✓(購読準備中)"
        case .subscribed(let d):
            return "\(d) 接続 ✓ 購読中"
        }
    }
}

/// F1/F2/F6 の BLE 層。
/// 実機の確定事実:
/// - スキャン自体は一旦不調 NC700Like ではn dと Discover が呼ばれず、nRF Connect は見える。
///   そのため接続は「保存識別子/システム接続取得/保留接続」を主経路とし、スキャンは補助。
/// - FE03 の 2BEEA05B… を購読しないと押下でエラー音声になり 7B61 も変わらない。
/// - 受付中は FE03 に音声が流れ続ける。制御(<64B)/音声(>=100B)で扱いを分ける。
final class BLEService: NSObject, ObservableObject {
    static let restorationIdentifier = "jp.nc700like.BLEService"

    /// RelayCoordinator から参照する共有インスタンス(App は1つの CBCentralManager のみ)。
    static let shared = BLEService()

    @Published private(set) var phase: BLEConnectionPhase = .idle(device: "Bluetooth 初期化中")
    @Published private(set) var logs: [BLELogEntry] = []
    @Published private(set) var pressCount = 0
    @Published private(set) var lastPressAt: Date?
    @Published private(set) var lastNotificationHex: String?

    @Published private(set) var subscribed7B61 = false
    @Published private(set) var subscribedFE03 = false

    @Published private(set) var audioSessionCount = 0
    @Published private(set) var audioPacketCount = 0

    @Published private(set) var authorizationText = "—"
    @Published private(set) var stateText = "—"
    @Published private(set) var isScanning = false
    /// REQ A-1: CoreBluetooth 自身の isScanning(自前フラグは isScanningLocal 相当)
    @Published private(set) var isScanningCore = false
    @Published private(set) var discoverCallbackCount = 0
    @Published private(set) var lastDiscoveredName: String?

    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var serviceCatalog: [BLECatalogService] = []

    /// REQ B-9: どの経路で接続したか。
    @Published private(set) var connectionRoute = "—"

    /// REQ D-2: 直近の制御パケット末尾1バイト({ID}の置換元)。
    @Published private(set) var lastControlTerminalHex: String?

    /// 電源入れ直し対策(Phase 4): この接続世代で制御パケットを受けて {ID} が確定しているか。
    /// 接続のたびに false に戻し、新しい制御パケットを受信した時点で true になる。
    @Published private(set) var isControlIDEstablished = false

    /// 接続世代番号(connect()/復元のたびに+1。時系列のヘッダに出す)。
    private(set) var connectionGeneration = 0

    /// 押下時系列レコーダ(Step A)。全モードで BLE イベント・書込・再送判定を記録する。
    let timeline = PressTimelineRecorder()

    /// 直近の FE03 制御パケット(時刻つき)。押下処理と制御パケット受信の
    /// イベント順序の揺れ(.press の Task が .control より後で処理される等)を
    /// 吸収するため、押下処理時に直前の制御パケットを参照できるようにする。
    struct RecentControl: Equatable {
        let date: Date
        let terminal: UInt8
        let hex: String
    }
    private(set) var recentControls: [RecentControl] = []
    private var awaitingInitialFE03Report = false
    private var initialFE03ReadAt: Date?

    /// REQ D-4: 自動送信のモード(画面のピッカーとバインド)。
    @Published var autoSendMode: AutoSendMode = .off

    // MARK: 実験モード向け(ExperimentRunner/BLEEventHub)

    /// BLE イベント中継ハブ(実験モードが購読する)。
    let eventHub = BLEEventHub()

    /// 実験モード中は通常の自動送信(D-4)を抑制する。
    @Published var suppressAutoSend = false

    /// 直近の 7B61 全値(19バイト HEX)。実験の手順0/手順3 記録に使う。
    @Published private(set) var last7B61Hex: String?

    /// 現在接続中(または直近接続)のデバイス名。実験セッションの記録に使う。
    var connectedDeviceName: String? { peripheral?.name }

    private var notify7B61: CBCharacteristic?
    private var pending7B61ReadCompletion: ((String?) -> Void)?
    private var pendingWriteCompletion: ((Bool) -> Void)?

    let configuration: DeviceConfiguration

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var detector = ButtonEventDetector()
    private var awaitingInitialValue = false
    private var awaitingConnection = false
    private var retryWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?
    private let savedIdentifierKey = "savedPeripheralIdentifier"

    private var scanning = false
    private var discoverCallbacks = 0
    private var lastDiscoveryName: String?
    private var discoveredDict: [UUID: DiscoveredDevice] = [:]
    private var seenIdentifiers = Set<UUID>()
    private var lastCoreScanningLogged: Bool?

    private var audioPacketTotal = 0
    private var audioLoggedInSession = 0
    private var lastAutoSentPreset: DebugPreset?

    init(configuration: DeviceConfiguration = .load()) {
        self.configuration = configuration
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
        detector = ButtonEventDetector(configuration: configuration)
        // 診断値・発見一覧は1秒ごとに反映(A-1/A-3もこの間隔で観測)。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDiagnostics()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public

    func connectExplicit() {
        guard central.state == .poweredOn else { return }
        startConnect()
    }

    /// REQ B-7: 識別子を再取得するボタン(nRF Connect で接続してから押す)。
    func reacquireIdentifier() {
        guard central.state == .poweredOn else { return }
        let serviceUUID = CBUUID(string: configuration.serviceUUID)
        let found = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        appendLog(kind: .connection, hex: nil, note: "識別子を再取得: FDD2 で接続中の周辺機器 \(found.count)件")
        if let p = found.first {
            connect(p, route: "識別子を再取得ボタン")
        } else {
            appendLog(kind: .error, hex: nil, note: "FDD2 接続中の周辺機器がありません。nRF Connect を接続してからボタンを押してください")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    /// REQ C-3: 全ログを1タップでコピー。
    var allLogsText: String {
        logs.reversed().map { copyText(of: $0) }.joined(separator: "\n")
    }

    var discoveredAllText: String {
        discoveredDevices.map { $0.rowText }.joined(separator: "\n")
    }

    var catalogAllText: String {
        serviceCatalog.map { service in
            let chars = service.characteristics.isEmpty
                ? "  (特性なし)"
                : service.characteristics.map { "  \($0.uuid) [\($0.properties)]" }.joined(separator: "\n")
            return "サービス \(service.uuid)\n\(chars)"
        }.joined(separator: "\n")
    }

    func copyText(of entry: BLELogEntry) -> String {
        var lines = ["\(entry.timeText) [\(entry.kindText)]"]
        if let hex = entry.hex { lines.append(hex) }
        if !entry.note.isEmpty { lines.append(entry.note) }
        return lines.joined(separator: "\n")
    }

    /// 直近の FE03 制御パケットの 1 件分(押下処理が参照する)。
    var latestControl: RecentControl? { recentControls.last }

    /// 制御パケット受信時の共同記録({ID}・時系列・確定フラグ・直近キュー)。
    private func recordControlPacket(_ bytes: [UInt8], hexAll: String) {
        let date = Date()
        guard let terminal = bytes.last else {
            timeline.add("FE03制御(\(bytes.count)B terminalなし)")
            return
        }
        lastControlTerminalHex = String(format: "%02X", terminal)
        timeline.add("FE03制御(\(bytes.count)B terminal=\(String(format: "%02X", terminal)))")
        recentControls.append(RecentControl(date: date, terminal: terminal, hex: hexAll))
        if recentControls.count > 20 {
            recentControls.removeFirst(recentControls.count - 20)
        }
        if !isControlIDEstablished {
            isControlIDEstablished = true
            timeline.add("制御パケット受信で {ID} 確定(この接続世代で初回)")
        }
    }

    /// 押下処理から参照する、押下直前(指定秒以内)の制御パケットのうち末尾 ID が違う最初の 1 件。
    /// (.press のイベント処理順序の揺れで window 設定前に制御パケットを取り逃すことがあるため。)
    func freshControlNearPress(pressAt: Date, lookbackSeconds: TimeInterval) -> RecentControl? {
        let cutoff = pressAt.addingTimeInterval(-lookbackSeconds)
        let bounds = pressAt.addingTimeInterval(lookbackSeconds)
        return recentControls.first { $0.date >= cutoff && $0.date <= bounds }
    }

    /// REQ D-1: 手動送信(.withResponse)。エラー/成功はログに出す。
    func sendDebug(preset: DebugPreset? = nil, hexString: String? = nil, trigger: String) {
        guard let peripheral, peripheral.state == .connected else {
            appendLog(kind: .error, hex: nil, note: "送信不可(未接続)")
            return
        }
        guard let writeCharacteristic else {
            appendLog(kind: .error, hex: nil, note: "送信不可(書込特性が見つかっていない)")
            return
        }
        let template = preset?.template ?? hexString ?? ""
        guard !template.isEmpty else {
            appendLog(kind: .error, hex: nil, note: "送信不可(HEXが空)")
            return
        }
        let idByte = controlTerminalByte()
        guard let data = HexTool.parse(template, idByte: idByte) else {
            appendLog(kind: .error, hex: nil, note: "送信不可(HEX解析失敗: \(template) / 直近ID=\(lastControlTerminalHex ?? "なし"))")
            return
        }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog(kind: .control, hex: nil, note: "\(trigger) 送信 → \(writeCharacteristic.uuid.uuidString) (\(data.count)B): \(hex)")
        let idText = template.contains("{ID}") ? (idByte.map { String(format: "%02X", $0) } ?? "なし") : "ID不要"
        timeline.add(String(format: "書込(\(data.count)B {ID}=%@): %@", idText, trigger))
        peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
    }

    func sendDebugAuto(trigger: String) {
        guard autoSendMode != .off else { return }
        let preset: DebugPreset
        switch autoSendMode {
        case .off:
            return
        case .p1: preset = .p1
        case .p2: preset = .p2
        case .p3: preset = .p3
        case .p3ThenP1:
            preset = (lastAutoSentPreset == .p3) ? .p1 : .p3
        }
        lastAutoSentPreset = preset
        sendDebug(preset: preset, trigger: "\(trigger) 自動送信(\(preset.rawValue))")
    }

    func controlTerminalByte() -> UInt8? {
        guard let hex = lastControlTerminalHex else { return nil }
        return UInt8(hex, radix: 16)
    }

    /// 直近の 7B61 が受付待ち状態(pressStates の先頭値=00 06)か。
    /// 実験の手順0/手順3 記録に使う。
    var isIdleState7B61: Bool {
        guard let hex = last7B61Hex else { return false }
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard let state = detector.extractState(from: bytes) else { return false }
        guard let idle = configuration.pressStates.first else { return false }
        return state.elementsEqual(idle)
    }

    /// 渡された 7B61 値が「押し込み状態(pressStates[1]=10 0E)」か。
    /// 押下検出は両状態の遷移で発火するため、実験の START 検出では
    /// 押し込み状態側の遷移だけを START として採用する(試行12 の誤検出対策)。
    func isPressedState(_ data: Data) -> Bool {
        guard configuration.pressStates.count >= 2 else { return false }
        let bytes = [UInt8](data)
        guard let state = detector.extractState(from: bytes) else { return false }
        return state.elementsEqual(configuration.pressStates[1])
    }

    /// 実験モード用の書込(.withResponse)。完了/失敗を completion で返す。
    /// data が nil(未接続・HEX解析失敗・書込特性なし)は false で即返す。
    func writeControl(data: Data?, label: String, completion: @escaping (Bool) -> Void) {
        guard let data, !data.isEmpty else {
            appendLog(kind: .error, hex: nil, note: "\(label) 送信不可(HEX解析失敗 / 直近ID=\(lastControlTerminalHex ?? "なし"))")
            completion(false)
            return
        }
        guard let peripheral, peripheral.state == .connected else {
            appendLog(kind: .error, hex: nil, note: "\(label) 送信不可(未接続)")
            completion(false)
            return
        }
        guard let writeCharacteristic else {
            appendLog(kind: .error, hex: nil, note: "\(label) 送信不可(書込特性が見つかっていない)")
            completion(false)
            return
        }
        appendLog(kind: .control, hex: nil, note: "\(label) 送信 → \(writeCharacteristic.uuid.uuidString) (\(data.count)B): \(HexTool.hex(data))")
        pendingWriteCompletion = completion
        peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
    }

    /// 実験用: 7B61 を1回読み直して HEX で返す(read 通知経由)。
    /// 読めない(未接続/特性なし)ときは nil を completion に渡す。
    func read7B61Once(completion: @escaping (String?) -> Void) {
        guard let peripheral, peripheral.state == .connected, let notify7B61 else {
            completion(last7B61Hex)
            return
        }
        pending7B61ReadCompletion = completion
        peripheral.readValue(for: notify7B61)
    }

    // MARK: - Private: connection flow (REQ B)

    private func startConnect() {
        cancelRetry()
        stopScan()
        guard central.state == .poweredOn, central.authorization == .allowedAlways else {
            updateStateDiagnostics()
            return
        }
        let serviceUUID = CBUUID(string: configuration.serviceUUID)

        // 優先順1: 保存識別子での保留接続(スキャン不要・タイムアウトなし)
        if let saved = savedIdentifier {
            let retrieved = central.retrievePeripherals(withIdentifiers: [saved])
            appendLog(kind: .connection, hex: nil, note: "retrievePeripherals(保存識別子) = \(retrieved.count)件")
            if let p = retrieved.first {
                connect(p, route: "保存識別子による保留接続")
                return
            }
        }

        // 優先順2: システムがBLE接続済みの周辺機器を取得して接続
        if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            connect(connected, route: "システム接続からの取得")
            return
        }

        // 優先順3: 広域スキャン(補助)
        startUnfilteredScan()
    }

    /// REQ B-5: 未接続の間は5秒ごとの定期処理。
    private func maintenanceTick() {
        guard central.state == .poweredOn, central.authorization == .allowedAlways else { return }
        if peripheral?.state == .connected { return }
        if peripheral?.state == .connecting { return }
        if awaitingConnection { return }
        startConnect()
    }

    /// REQ A-5: スキャン(補助経路)。サービス指定なし・AllowDuplicates有効。
    private func startUnfilteredScan() {
        guard central.state == .poweredOn, central.authorization == .allowedAlways else { return }
        guard !scanning else { return }
        scanning = true
        phase = .scanning
        appendLog(kind: .connection, hex: nil, note: "広域スキャン開始(重複許可・全デバイス照会)")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func stopScan() {
        if central.state == .poweredOn { central.stopScan() }
        scanning = false
    }

    /// REQ B-1: connect は identifier を必ず保存する。state が connected なら
    /// GATT 探索からやり直し、disconnected なら connect() を呼ぶ(保留接続)。
    private func connect(_ p: CBPeripheral, route: String) {
        cancelRetry()
        stopScan()
        peripheral?.delegate = nil
        peripheral = p
        p.delegate = self
        awaitingInitialValue = false
        awaitingConnection = false
        subscribed7B61 = false
        subscribedFE03 = false
        serviceCatalog = []
        writeCharacteristic = nil
        audioSessionCount = 0
        audioPacketCount = 0
        audioPacketTotal = 0
        audioLoggedInSession = 0
        lastAutoSentPreset = nil
        connectionRoute = route
        // 電源入れ直し対策: 接続のたびに {ID} を未確定に戻し、時系列を新世代で開始する。
        connectionGeneration += 1
        isControlIDEstablished = false
        recentControls.removeAll()
        awaitingInitialFE03Report = false
        timeline.beginGeneration(connectAt: Date())
        timeline.add("接続開始 経路=\(route) id=\(p.identifier.uuidString.prefix(8)) state=\(stateName(p.state))")
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedIdentifierKey)

        if p.state == .connected {
            appendLog(kind: .connection, hex: nil, note: "connect() 呼出 [経路: \(route)] state=connected のため全サービス探索から継続")
            resolveServiceDiscovery(for: p)
            return
        }
        guard p.state == .disconnected else {
            appendLog(kind: .error, hex: nil, note: "connect() 呼出 [経路: \(route)] は実行せず(state=\(stateName(p.state)))、5秒後の定期処理で再試行")
            return
        }
        awaitingConnection = true
        phase = .pending(device: p.name ?? "(名前未取得)")
        appendLog(kind: .connection, hex: nil, note: "connect() 呼出 [経路: \(route)] id=\(p.identifier.uuidString.prefix(8)) state=\(stateName(p.state))")
        central.connect(p)
    }

    private func resolveServiceDiscovery(for p: CBPeripheral) {
        p.delegate = self
        serviceCatalog = []
        notify7B61 = nil
        p.discoverServices(nil)
    }

    private func stateName(_ state: CBPeripheralState) -> String {
        switch state {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "不明"
        }
    }

    private func scheduleRetryConnect(seconds: TimeInterval, reason: String) {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if let self, !self.awaitingConnection {
                self.startConnect()
            }
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    // MARK: - Private: diagnostics

    private func updateStateDiagnostics() {
        authorizationText = {
            switch central.authorization {
            case .allowedAlways: return "許可 ✓"
            case .denied: return "拒否(設定→プライバシーとセキュリティ→Bluetooth)"
            case .notDetermined: return "未確認(許可ダイアログ未応答)"
            case .restricted: return "制限中(画面時間/MDM 等)"
            @unknown default: return "不明"
            }
        }()
        stateText = {
            switch central.state {
            case .poweredOn: return "poweredOn"
            case .poweredOff: return "poweredOff"
            case .unauthorized: return "unauthorized"
            case .unsupported: return "unsupported"
            case .resetting: return "resetting"
            case .unknown: return "unknown"
            @unknown default: return "不明"
            }
        }()
        isScanning = scanning
        isScanningCore = central.isScanning
        discoverCallbackCount = discoverCallbacks
        lastDiscoveredName = lastDiscoveryName
        discoveredDevices = sortedDiscoveredList()
    }

    private func sortedDiscoveredList() -> [DiscoveredDevice] {
        discoveredDict.values.sorted { a, b in
            if a.matches != b.matches { return a.matches }
            if a.seenCount != b.seenCount { return a.seenCount > b.seenCount }
            return a.name < b.name
        }
    }

    private func refreshDiagnostics() {
        updateStateDiagnostics()
        audioPacketCount = audioPacketTotal
        // REQ A-1: CoreBluetooth の isScanning を1秒ごとに観測。変化したときだけログに残す
        // (毎秒残すと100件のログをすぐ溢れさせるため)。
        if lastCoreScanningLogged != isScanningCore {
            lastCoreScanningLogged = isScanningCore
            appendLog(kind: .connection, hex: nil, note: "isScanning(CoreBluetooth) = \(isScanningCore) / 自前フラグ = \(scanning)")
        }
        // REQ B-5: 未接続のときの再取得・保留接続は5秒ごとにまとめて実施する
        maintenanceCounter += 1
        if maintenanceCounter >= 5 {
            maintenanceCounter = 0
            maintenanceTick()
        }
        // FE03 初期読み取りの応答確認(6秒無応答なら観測結果として時系列に記録)
        if awaitingInitialFE03Report, let asked = initialFE03ReadAt,
           Date().timeIntervalSince(asked) > 6 {
            awaitingInitialFE03Report = false
            timeline.add("FE03初期読み取り: 6秒間無応答(read 非対応の可能性。{ID} は次の制御パケットまで未確定)")
        }
    }

    private var maintenanceCounter = 0

    // MARK: - Private: audio/control handling (REQ C/D)

    private func startAudioSession() {
        audioSessionCount += 1
        audioLoggedInSession = 0
        appendLog(kind: .audio, hex: nil, note: "受付セッション#\(audioSessionCount) 開始(FE03 購読中)")
    }

    /// REQ D-4: 制御パケット受信時に自動送信モードに従って送る。
    /// 実験モード(suppressAutoSend)中は抑制する。
    private func maybeAutoSendOnControl() {
        guard autoSendMode != .off else { return }
        guard !suppressAutoSend else { return }
        sendDebugAuto(trigger: "制御パケット受信につき")
    }

    // MARK: - Logging

    private func appendLog(kind: BLELogEntry.Kind, hex: String?, note: String) {
        logs.insert(BLELogEntry(date: Date(), kind: kind, hex: hex, note: note), at: 0)
        if logs.count > 100 {
            logs.removeLast(logs.count - 100)
        }
    }

    private var savedIdentifier: UUID? {
        UserDefaults.standard.string(forKey: savedIdentifierKey).flatMap(UUID.init(uuidString:))
    }

    private func propertiesText(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeWithoutResponse") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        if p.contains(.broadcast) { parts.append("broadcast") }
        if p.contains(.authenticatedSignedWrites) { parts.append("signedWrite") }
        if p.contains(.extendedProperties) { parts.append("extended") }
        if p.contains(.notifyEncryptionRequired) { parts.append("notifyEnc") }
        if p.contains(.indicateEncryptionRequired) { parts.append("indicateEnc") }
        return parts.isEmpty ? "(なし)" : parts.joined(separator: ",")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard central.authorization == .allowedAlways else {
                phase = .idle(device: "Bluetooth の利用が許可されていません(設定→NC700Like→Bluetooth)")
                appendLog(kind: .error, hex: nil, note: "state=poweredOn だが authorization=拒否(スキャンしない)")
                updateStateDiagnostics()
                return
            }
            startConnect()
        case .poweredOff:
            phase = .idle(device: "Bluetooth オフ!コントロールセンターでオンにしてください(スキャンは行いません)")
        case .unauthorized:
            phase = .idle(device: "Bluetooth の利用が許可されていません(設定→NC700Like→Bluetooth)")
        case .unsupported:
            phase = .idle(device: "この端末では Bluetooth LE を利用できません")
        case .resetting, .unknown:
            phase = .idle(device: "Bluetooth 初期化中")
        @unknown default:
            phase = .idle(device: "Bluetooth 状態不明")
        }
        updateStateDiagnostics()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSInteger
    ) {
        discoverCallbacks += 1
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }
        let nameMatches = name?.range(of: configuration.scanNameFragment, options: .caseInsensitive) != nil
        let serviceMatches = advServices.contains {
            $0.caseInsensitiveCompare(configuration.serviceUUID) == .orderedSame
        }
        let matches = nameMatches || serviceMatches

        let entry = DiscoveredDevice(
            id: peripheral.identifier,
            name: name ?? "(名前未取得)",
            idPrefix: String(peripheral.identifier.uuidString.prefix(8)).uppercased(),
            servicesText: advServices.isEmpty ? "(なし)" : advServices.joined(separator: ","),
            rssi: RSSI,
            matches: matches,
            seenCount: (discoveredDict[peripheral.identifier]?.seenCount ?? 0) + 1
        )
        discoveredDict[peripheral.identifier] = entry
        lastDiscoveryName = name

        if seenIdentifiers.insert(peripheral.identifier).inserted {
            appendLog(
                kind: .discovery, hex: nil,
                note: "\(matches ? "★" : "")発見: \(entry.name) id=\(entry.idPrefix) services=\(entry.servicesText) RSSI=\(RSSI)"
            )
        }

        if matches {
            stopScan()
            connect(peripheral, route: "スキャン発見")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        awaitingConnection = false
        appendLog(kind: .connection, hex: nil, note: "didConnect 受信 [経路: \(connectionRoute)]")
        timeline.add("didConnect 受信")
        peripheral.delegate = self
        serviceCatalog = []
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        awaitingConnection = false
        let nsError = error as NSError?
        appendLog(kind: .error, hex: nil, note: "didFailToConnect domain=\(nsError?.domain ?? "-") code=\(nsError?.code ?? -1) \(error?.localizedDescription ?? "不明")")
        phase = .idle(device: "接続失敗 — 2秒後に再試行します")
        scheduleRetryConnect(seconds: 2.0, reason: "didFailToConnect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        awaitingConnection = false
        subscribed7B61 = false
        subscribedFE03 = false
        pendingWriteCompletion = nil
        pending7B61ReadCompletion = nil
        eventHub.emit(BLEEvent(date: Date(), kind: .disconnected, bytes: Data()))
        let nsError = error as NSError?
        appendLog(kind: .connection, hex: nil, note: "切断 domain=\(nsError?.domain ?? "-") code=\(nsError?.code ?? -1) state=\(stateName(peripheral.state))")
        timeline.add("切断 domain=\(nsError?.domain ?? "-") code=\(nsError?.code ?? -1)")
        phase = .idle(device: "接続が切れました — 即座に保留接続を再設定します")
        cancelRetry()
        if peripheral.state == .disconnected {
            connect(peripheral, route: "切断後の即時保留接続(B-4)")
        } else {
            scheduleRetryConnect(seconds: 2.0, reason: "切断後フォールバック")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        if let p = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let first = p.first {
            peripheral = first
            first.delegate = self
            awaitingConnection = false
            connectionGeneration += 1
            isControlIDEstablished = false
            recentControls.removeAll()
            awaitingInitialFE03Report = false
            timeline.beginGeneration(connectAt: Date())
            timeline.add("状態復元(バックグラウンド再起動) id=\(first.identifier.uuidString.prefix(8))")
            UserDefaults.standard.set(first.identifier.uuidString, forKey: savedIdentifierKey)
            appendLog(kind: .connection, hex: nil, note: "状態復元: 周辺機器 \(first.identifier.uuidString.prefix(8)) を取得。GATT探索をやり直します(REQ B-8)")
            resolveServiceDiscovery(for: first)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "サービス探索エラー: \(error.localizedDescription)")
            return
        }
        let uuids = peripheral.services?.map { $0.uuid.uuidString } ?? []
        appendLog(kind: .connection, hex: nil, note: "発見サービス \(uuids.count)件: \(uuids.joined(separator: ", "))")
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "特性探索エラー(\(service.uuid.uuidString)): \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        let entry = BLECatalogService(
            uuid: service.uuid.uuidString,
            characteristics: chars.map {
                BLECatalogCharacteristic(uuid: $0.uuid.uuidString, properties: propertiesText($0.properties))
            }
        )
        if let index = serviceCatalog.firstIndex(where: { $0.uuid == entry.uuid }) {
            serviceCatalog[index] = entry
        } else {
            serviceCatalog.append(entry)
        }

        for characteristic in chars {
            appendLog(
                kind: .discovery, hex: nil,
                note: "特性 \(characteristic.uuid.uuidString)(\(service.uuid.uuidString)) [\(propertiesText(characteristic.properties))]"
            )
            let uuid = characteristic.uuid.uuidString.uppercased()
            if uuid.caseInsensitiveCompare(configuration.characteristicUUID) == .orderedSame {
                if !characteristic.isNotifying {
                    awaitingInitialValue = true
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                }
            } else if uuid.caseInsensitiveCompare(configuration.audioCharacteristicUUID) == .orderedSame {
                if !characteristic.isNotifying {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if uuid.caseInsensitiveCompare(configuration.writeCharacteristicUUID) == .orderedSame {
                writeCharacteristic = characteristic
                appendLog(kind: .connection, hex: nil, note: "書込特性を見つけました(FE03 手動送信ツールが使用可能)")
            }

            // 実験用: 7B61 特性を保持(read7B61Once で使う)。
            if uuid.caseInsensitiveCompare(configuration.characteristicUUID) == .orderedSame {
                notify7B61 = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "購読失敗(\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
            return
        }
        let uuid = characteristic.uuid.uuidString.uppercased()
        if uuid.caseInsensitiveCompare(configuration.characteristicUUID) == .orderedSame {
            subscribed7B61 = characteristic.isNotifying
            appendLog(kind: .connection, hex: nil, note: "7B61購読: \(characteristic.isNotifying ? "開始" : "停止")")
            timeline.add("7B61購読\(characteristic.isNotifying ? "開始" : "停止")")
        } else if uuid.caseInsensitiveCompare(configuration.audioCharacteristicUUID) == .orderedSame {
            subscribedFE03 = characteristic.isNotifying
            appendLog(kind: .connection, hex: nil, note: "FE03購読: \(characteristic.isNotifying ? "開始" : "停止")")
            timeline.add("FE03購読\(characteristic.isNotifying ? "開始" : "停止")(直後に初期読み取り)")
            if characteristic.isNotifying {
                awaitingInitialFE03Report = true
                initialFE03ReadAt = Date()
                // 電源入れ直し後の再接続では制御パケット({ID} の置換元)が来るまで待つ必要がある。
                // 購読開始直後に1回読み、直近値が読めれば {ID} を早期に確定させる(Phase 4: 再接続後の即時キャンセル用)。
                peripheral.readValue(for: characteristic)
            }
        }
        phase = .subscribed(device: peripheral.name ?? "Bose NC 700")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let completion = pendingWriteCompletion
        pendingWriteCompletion = nil
        if let error = error {
            let nsError = error as NSError
            appendLog(kind: .error, hex: nil, note: "書込失敗 domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            timeline.add("書込完了: 失敗 domain=\(nsError.domain) code=\(nsError.code)")
            completion?(false)
        } else {
            appendLog(kind: .control, hex: nil, note: "書込完了(withResponse)")
            timeline.add("書込完了: 成功")
            completion?(true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "値取得エラー(\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
            timeline.add("\(characteristic.uuid.uuidString) 値取得エラー: \(error.localizedDescription)")
            if uuid.caseInsensitiveCompare(configuration.audioCharacteristicUUID) == .orderedSame, awaitingInitialFE03Report {
                awaitingInitialFE03Report = false
                timeline.add("FE03初期読み取り: エラー(FE03 が read 非対応の可能性。{ID} は次の制御パケットまで未確定)")
            }
            return
        }
        guard let data = characteristic.value else { return }

        // REQ C-1: <64B は制御で毎回全バイト。>=100B は音声でセッション頭5個だけ。
        if uuid.caseInsensitiveCompare(configuration.audioCharacteristicUUID) == .orderedSame {
            let bytes = [UInt8](data)
            if bytes.count < 64 {
                if awaitingInitialFE03Report {
                    awaitingInitialFE03Report = false
                    timeline.add("FE03初期読み取り: 値あり(\([UInt8](data).count)B)")
                }
                let hexAll = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                recordControlPacket(bytes, hexAll: hexAll)
                appendLog(kind: .control, hex: hexAll, note: "FE03制御 \(bytes.count)B (末尾=\(lastControlTerminalHex ?? "-"))")
                eventHub.emit(BLEEvent(date: Date(), kind: .control, bytes: data))
                maybeAutoSendOnControl()
                return
            }
            audioPacketTotal += 1
            timeline.add("FE03音声(\(bytes.count)B)")
            eventHub.emit(BLEEvent(date: Date(), kind: .audio, bytes: data))
            if bytes.count >= 100 && audioLoggedInSession < 5 {
                let head = bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                appendLog(kind: .audio, hex: head, note: "FE03音声 #\(audioLoggedInSession + 1) 長さ=\(bytes.count)")
                audioLoggedInSession += 1
            }
            return
        }

        guard uuid.caseInsensitiveCompare(configuration.characteristicUUID) == .orderedSame else { return }
        let bytes = [UInt8](data)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let timestamp = Date().timeIntervalSince1970
        let wasInitial = awaitingInitialValue
        awaitingInitialValue = false

        last7B61Hex = hex
        eventHub.emit(BLEEvent(date: Date(), kind: .notification7B61, bytes: data))

        let readCompletion = pending7B61ReadCompletion
        pending7B61ReadCompletion = nil
        readCompletion?(hex)

        var output: ButtonEventDetector.Output
        if wasInitial {
            detector.reset()
            output = detector.process(value: bytes, at: timestamp, isInitial: true)
        } else {
            output = detector.process(value: bytes, at: timestamp)
        }
        lastNotificationHex = hex

        switch output {
        case .press:
            pressCount += 1
            lastPressAt = Date()
            startAudioSession()
            eventHub.emit(BLEEvent(date: lastPressAt!, kind: .press, bytes: data))
            timeline.markPress("押下検出 state=\(stateHex(of: bytes))", at: lastPressAt)
            appendLog(kind: .press, hex: hex, note: "押下を検出 (state=\(stateHex(of: bytes)))")
        case .ignored:
            if wasInitial {
                appendLog(kind: .notification, hex: hex, note: "初期値として記録 (state=\(stateHex(of: bytes)))")
            } else {
                appendLog(kind: .notification, hex: hex, note: "変化なし/無視 (state=\(stateHex(of: bytes)))")
            }
        }
    }

    private func stateHex(of bytes: [UInt8]) -> String {
        guard let state = detector.extractState(from: bytes) else { return "-(短い値)" }
        return state.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
