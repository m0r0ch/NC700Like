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
        case error
    }

    var timeText: String {
        date.formatted(date: .omitted, time: .standard)
    }

    var kindText: String {
        switch kind {
        case .connection: return "接続"
        case .discovery: return "発見"
        case .notification: return "受信"
        case .press: return "押下"
        case .audio: return "音声"
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
    case idle(device: String?)
    case scanning
    case connecting(device: String)
    case connected(device: String)
    case subscribed(device: String)

    var label: String {
        switch self {
        case .idle(let d):
            return d ?? "待機中"
        case .scanning:
            return "スキャン中…(広域・全デバイス照会)"
        case .connecting(let d):
            return "\(d) 接続中…"
        case .connected(let d):
            return "\(d) 接続 ✓(購読準備中)"
        case .subscribed(let d):
            return "\(d) 接続 ✓ 購読中"
        }
    }
}

/// F1/F2 の BLE 層。実機調査の確定事実:
/// - 広告は FDD2/FE26/FE03。名前 LE-Bose NC 700 Headphones。
/// - FE03 の 2BEEA05B… を購読しないと押下でエラー音声になり 7B61 も変わらない。
/// - 受付中は FE03 に音声が流れ続ける(保存/全表示はしない)。
final class BLEService: NSObject, ObservableObject {
    static let restorationIdentifier = "jp.nc700like.BLEService"

    @Published private(set) var phase: BLEConnectionPhase = .idle(device: "Bluetooth 初期化中")
    @Published private(set) var logs: [BLELogEntry] = []
    @Published private(set) var pressCount = 0
    @Published private(set) var lastPressAt: Date?
    @Published private(set) var lastNotificationHex: String?

    @Published private(set) var subscribed7B61 = false
    @Published private(set) var subscribedFE03 = false

    @Published private(set) var audioSessionCount = 0
    @Published private(set) var audioPacketCount = 0

    /// 診断表示(REQ A-3)
    @Published private(set) var authorizationText = "—"
    @Published private(set) var stateText = "—"
    @Published private(set) var isScanning = false
    @Published private(set) var discoverCallbackCount = 0
    @Published private(set) var lastDiscoveredName: String?

    /// 広域スキャンの一覧(REQ A-5)
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []

    /// 見つかった全サービスと全特性(REQ D)
    @Published private(set) var serviceCatalog: [BLECatalogService] = []

    let configuration: DeviceConfiguration

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var detector = ButtonEventDetector()
    private var awaitingInitialValue = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?
    private let savedIdentifierKey = "savedPeripheralIdentifier"

    private var scanning = false
    private var discoverCallbacks = 0
    private var lastDiscoveryName: String?
    private var discoveredDict: [UUID: DiscoveredDevice] = [:]
    private var seenIdentifiers = Set<UUID>()

    private var audioPacketTotal = 0
    private var audioLoggedInSession = 0

    init(configuration: DeviceConfiguration = .load()) {
        self.configuration = configuration
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
        detector = ButtonEventDetector(configuration: configuration)
        // 診断値や発見一覧は1秒ごとに画面へ反映する。CoreBluetoothのdelegateは
        // queue: nil でメインキューに届くため、内部集計はここでまとめて公開する。
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

    func clearLogs() {
        logs.removeAll()
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

    // MARK: - Private: connection flow

    private func startConnect() {
        cancelReconnect()
        stopScan()
        guard central.state == .poweredOn, central.authorization == .allowedAlways else {
            updateStateDiagnostics()
            return
        }
        let serviceUUID = CBUUID(string: configuration.serviceUUID)

        if let saved = savedIdentifier,
           let p = central.retrievePeripherals(withIdentifiers: [saved]).first {
            appendLog(kind: .connection, hex: nil, note: "保存済み識別子で直接接続を試みます")
            connect(p)
            return
        }
        if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            appendLog(kind: .connection, hex: nil, note: "システム接続済みのFDD2周辺機器を検出。直接接続します")
            connect(connected)
            return
        }
        startUnfilteredScan()
    }

    /// REQ A-5: 最初からサービス指定なし・AllowDuplicates有効の広域スキャン。
    private func startUnfilteredScan() {
        guard central.state == .poweredOn, central.authorization == .allowedAlways else { return }
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

    private func connect(_ p: CBPeripheral) {
        cancelReconnect()
        stopScan()
        peripheral?.delegate = nil
        peripheral = p
        p.delegate = self
        awaitingInitialValue = false
        subscribed7B61 = false
        subscribedFE03 = false
        serviceCatalog = []
        audioSessionCount = 0
        audioPacketCount = 0
        audioPacketTotal = 0
        audioLoggedInSession = 0
        phase = .connecting(device: p.name ?? "(名前未取得)")
        appendLog(kind: .connection, hex: nil, note: "接続中: \(p.name ?? "(名前未取得)") id=\(p.identifier.uuidString.prefix(8))")
        central.connect(p)
    }

    private func scheduleReconnect(reason: String) {
        appendLog(kind: .connection, hex: nil, note: "3秒後に再接続 (\(reason))")
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startConnect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
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

    /// 1秒おきに画面向けの published 値を更新する。
    private func refreshDiagnostics() {
        updateStateDiagnostics()
        audioPacketCount = audioPacketTotal
    }

    // MARK: - Private: audio session (REQ C)

    private func startAudioSession() {
        audioSessionCount += 1
        audioLoggedInSession = 0
        appendLog(kind: .audio, hex: nil, note: "受付セッション#\(audioSessionCount) 開始(FE03 購読中)")
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

    /// REQ D: 特性プロパティの文字列表現。
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
            phase = .idle(device: nil)
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
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedIdentifierKey)
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog(kind: .connection, hex: nil, note: "接続しました。全サービスを探索します")
        peripheral.delegate = self
        serviceCatalog = []
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appendLog(kind: .error, hex: nil, note: "接続失敗: \(error?.localizedDescription ?? "不明")")
        phase = .idle(device: "接続失敗 — 再試行します")
        scheduleReconnect(reason: "didFailToConnect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        subscribed7B61 = false
        subscribedFE03 = false
        appendLog(kind: .connection, hex: nil, note: "切断: \(error?.localizedDescription ?? "正常")")
        phase = .idle(device: "切断 — 再接続します")
        scheduleReconnect(reason: "didDisconnect")
    }

    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        if let p = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let first = p.first {
            peripheral = first
            first.delegate = self
            UserDefaults.standard.set(first.identifier.uuidString, forKey: savedIdentifierKey)
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
        } else if uuid.caseInsensitiveCompare(configuration.audioCharacteristicUUID) == .orderedSame {
            subscribedFE03 = characteristic.isNotifying
            appendLog(kind: .connection, hex: nil, note: "FE03購読: \(characteristic.isNotifying ? "開始" : "停止")")
        }
        phase = .subscribed(device: peripheral.name ?? "Bose NC 700")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "値取得エラー(\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()

        // REQ C: FE03 は音声。保存/全表示はしない。受付セッションごとに最初の
        // 5 パケットだけ長さと先頭16バイトをログに出し、以降は件数のみ。
        if uuid.caseInsensitiveCompare(configuration.audioCharacteristicUUID) == .orderedSame {
            audioPacketTotal += 1
            if audioLoggedInSession < 5 {
                let head = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                appendLog(kind: .audio, hex: head, note: "FE03 #\(audioLoggedInSession + 1) Length=\(data.count)")
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
