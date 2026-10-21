import Foundation
import CoreBluetooth
import NC700LikeKit

/// 押下検出と接続イベントを画面に出すためのログ。
struct BLELogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let kind: Kind
    /// 受信した生のHEX(通知値のみ)
    let hex: String?
    /// 補足情報(接続状態の変化、押下検出など)
    let note: String

    enum Kind: Equatable {
        case connection
        case notification
        case press
        case error
    }

    var timeText: String {
        date.formatted(date: .omitted, time: .standard)
    }
}

enum BLEConnectionPhase: Equatable {
    case idle(device: String?)
    case scanning
    case connecting(device: String)
    case connected(device: String)
    case subscribed(device: String)
    case failed(device: String)

    var label: String {
        switch self {
        case .idle(let d):
            return d ?? "Bluetooth 初期化中"
        case .scanning:
            return "スキャン中… Bose NC 700 を探しています"
        case .connecting(let d):
            return "\(d) 接続中…"
        case .connected(let d):
            return "\(d) 接続 ✓(購読準備中)"
        case .subscribed(let d):
            return "\(d) 接続 ✓ 購読中"
        case .failed(let d):
            return "\(d) 接続失敗"
        }
    }
}

/// F1/F2/(F3 の検出を除くレイヤ)。
/// 通知値を ButtonEventDetector に流し、結果をログに出す。
final class BLEService: NSObject, ObservableObject {
    static let restorationIdentifier = "jp.nc700like.BLEService"

    @Published private(set) var phase: BLEConnectionPhase = .idle(device: nil)
    @Published private(set) var logs: [BLELogEntry] = []
    @Published private(set) var pressCount = 0
    @Published private(set) var lastPressAt: Date?
    @Published private(set) var lastNotificationHex: String?

    let configuration: DeviceConfiguration

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var detector = ButtonEventDetector()
    private var awaitingInitialValue = false
    private var reconnectWorkItem: DispatchWorkItem?
    private let savedIdentifierKey = "savedPeripheralIdentifier"

    init(configuration: DeviceConfiguration = .load()) {
        self.configuration = configuration
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier
            ]
        )
        detector = ButtonEventDetector(configuration: configuration)
    }

    // MARK: - Public

    func connectExplicit() {
        cancelReconnect()
        guard central.state == .poweredOn else { return }
        startConnect()
    }

    func copyText(of entry: BLELogEntry) -> String {
        var lines: [String] = [
            "\(entry.timeText) [\(entry.kindText)]"
        ]
        if let hex = entry.hex {
            lines.append(hex)
        }
        if !entry.note.isEmpty {
            lines.append(entry.note)
        }
        return lines.joined(separator: "\n")
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Private: connection flow

    private func startConnect() {
        let serviceUUID = CBUUID(string: configuration.serviceUUID)

        // 保存済み識別子があれば即接続
        if let saved = savedIdentifier,
           let p = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(p)
            return
        }

        // 接続済み(Bose側が保持している)周辺機器を再取得
        if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            connect(connected)
            return
        }

        // 見つからなければスキャン
        setPhase(.scanning)
        appendLog(kind: .connection, hex: nil, note: "スキャン開始")
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func connect(_ p: CBPeripheral) {
        cancelReconnect()
        peripheral?.delegate = nil
        peripheral = p
        p.delegate = self
        awaitingInitialValue = false
        characteristic = nil
        setPhase(.connecting(device: displayName(of: p)))
        appendLog(kind: .connection, hex: nil, note: "接続中: \(displayName(of: p)) \(p.identifier.uuidString.prefix(8))")
        central.connect(p)
    }

    private func displayName(of p: CBPeripheral) -> String {
        p.name ?? "(名前未取得)"
    }

    private func scheduleReconnect(reason: String) {
        appendLog(kind: .connection, hex: nil, note: "3秒後に再接続 (\(reason))")
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

    // MARK: - Logging

    private func appendLog(kind: BLELogEntry.Kind, hex: String?, note: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let entry = BLELogEntry(date: Date(), kind: kind, hex: hex, note: note)
            self.logs.insert(entry, at: 0)
            if self.logs.count > 100 {
                self.logs.removeLast(self.logs.count - 100)
            }
        }
    }

    private func setPhase(_ newPhase: BLEConnectionPhase) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = newPhase
        }
    }

    private var savedIdentifier: UUID? {
        UserDefaults.standard.string(forKey: savedIdentifierKey).flatMap(UUID.init(uuidString:))
    }
}

extension BLELogEntry {
    var kindText: String {
        switch kind {
        case .connection: return "接続"
        case .notification: return "受信"
        case .press: return "押下"
        case .error: return "ERROR"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            setPhase(.idle(device: nil))
            startConnect()
        case .poweredOff:
            setPhase(.idle(device: "Bluetooth オフ — 設定でオンにしてください"))
        case .unauthorized:
            setPhase(.idle(device: "Bluetooth 利用が許可されていません"))
        case .unsupported:
            setPhase(.idle(device: "この端末ではBluetooth LEを利用できません"))
        case .resetting, .unknown:
            setPhase(.idle(device: "Bluetooth 初期化中"))
        @unknown default:
            setPhase(.idle(device: "Bluetooth 状態不明"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSInteger
    ) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
              name.range(of: configuration.scanNameFragment, options: .caseInsensitive) != nil
        else {
            appendLog(kind: .connection, hex: nil, note: "別の周辺機器を無視: \(peripheral.identifier.uuidString.prefix(8))")
            return
        }
        central.stopScan()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedIdentifierKey)
        appendLog(kind: .connection, hex: nil, note: "発見: \(name) RSSI=\(RSSI)")
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog(kind: .connection, hex: nil, note: "接続しました")
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: configuration.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appendLog(kind: .error, hex: nil, note: "接続失敗: \(error?.localizedDescription ?? "不明")")
        scheduleReconnect(reason: "didFailToConnect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristic = nil
        appendLog(kind: .connection, hex: nil, note: "切断: \(error?.localizedDescription ?? "正常")")
        setPhase(.idle(device: "切断 — 再接続します"))
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
        guard let service = peripheral.services?.first(
            where: { $0.uuid.uuidString.caseInsensitiveCompare(configuration.serviceUUID) == .orderedSame }
        ) else {
            appendLog(
                kind: .error, hex: nil,
                note: "サービス見つかりません。実見: " +
                    (peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "なし")
            )
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: configuration.characteristicUUID)], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "特性探索エラー: \(error.localizedDescription)")
            return
        }
        guard let characteristic = service.characteristics?.first(
            where: { $0.uuid.uuidString.caseInsensitiveCompare(configuration.characteristicUUID) == .orderedSame }
        ) else {
            appendLog(kind: .error, hex: nil, note: "特性が見つかりません: \(configuration.characteristicUUID)")
            return
        }
        self.characteristic = characteristic
        awaitingInitialValue = true
        peripheral.setNotifyValue(true, for: characteristic)
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "購読失敗: \(error.localizedDescription)")
            return
        }
        setPhase(.subscribed(device: peripheral.name ?? "Bose NC 700"))
        appendLog(kind: .connection, hex: nil, note: "購読開始: \(characteristic.uuid.uuidString)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString.caseInsensitiveCompare(configuration.characteristicUUID) == .orderedSame else {
            return
        }
        if let error = error {
            appendLog(kind: .error, hex: nil, note: "値取得エラー: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastNotificationHex = hex
        }

        switch output {
        case .press:
            let now = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pressCount += 1
                self.lastPressAt = now
            }
            appendLog(kind: .press, hex: hex, note: "押下を検出 (state=\(stateText(of: bytes)))")
        case .ignored:
            if wasInitial {
                appendLog(kind: .notification, hex: hex, note: "初期値として記録 (state=\(stateText(of: bytes)))")
            } else {
                appendLog(kind: .notification, hex: hex, note: "変化なし/無視 (state=\(stateText(of: bytes)))")
            }
        }
    }

    private func stateText(of bytes: [UInt8]) -> String {
        guard let state = detector.extractState(from: bytes) else { return "-(短い値)" }
        return state.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
