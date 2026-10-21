import SwiftUI
import UIKit
import CoreBluetooth

/// REQ A-4: スキャン機能だけを独立して確認する最小画面。
/// 既存の BLEService とは別に新しい CBCentralManager を1つだけ作り、
/// serviceUUIDs=nil で scanForPeripherals する。
///
/// 診断強化(REQ A拡張):
/// - central.isScanning / scanForPeripherals 呼出回数と時刻
/// - authorization / state 遷移履歴
/// - 30秒間・5秒毎に stopScan→再スキャンを繰り返す再試行モード
/// - 起動時 Info.plist の BLE 関連キー表示
struct ScanProbeView: View {
    @StateObject private var probe = ScanProbe()

    var body: some View {
        List {
            Section("Central 状態(診断A-1/A-4)") {
                probeRow("state", value: probe.stateText)
                probeRow("authorization", value: probe.authorizationText)
                probeRow("isScanning(CoreBluetooth)", value: probe.isScanning ? "YES" : "NO")
                probeRow("didDiscover 呼出数", value: "\(probe.discoverCount)")
                probeRow("scanForPeripherals 呼出数", value: "\(probe.scanCallCount)")
                probeRow("最終スキャン開始", value: probe.lastScanStartText ?? "—")
                Button("スキャン開始/スキャン再開") { probe.start() }
                    .buttonStyle(.bordered)
                if probe.retryRemainingCycles > 0 {
                    Text("再試行モード実行中: 残り \(probe.retryRemainingCycles) 巡(5秒毎に stopScan→再スキャン)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("再試行モード(30秒・5秒毎に stopScan→再スキャン)") {
                    probe.startRetryMode()
                }
                .disabled(probe.retryRemainingCycles > 0)
            }

            Section {
                ForEach(Array(probe.history.prefix(30)), id: \.self) { row in
                    Text(row)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("遷移履歴(state/authorization/isScanning・scan開始)")
            }

            Section {
                ForEach(probe.infoPlistRows, id: \.self) { row in
                    Text(row)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Info.plist(BLE 関連キー・起動時の実見)")
            }

            Section {
                ForEach(probe.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text("RSSI \(entry.rssi) ×\(entry.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("id=\(entry.idPrefix) services=\(entry.services)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("発見できた全デバイス(nil指定)")
            } footer: {
                Text("ここにNC700や周囲のBLE機器が1台も出なければ、スキャンの呼び出し方とは無関係な層に問題がある。")
            }
        }
        .navigationTitle("ScanProbe")
        .onAppear { probe.start() }
    }

    private func probeRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

final class ScanProbe: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct ProbeEntry: Identifiable {
        let id: UUID
        var name: String
        var rssi: NSInteger
        var services: String
        var count: Int
        var idPrefix: String
    }

    @Published private(set) var stateText = "—"
    @Published private(set) var authorizationText = "—"
    @Published private(set) var isScanning = false
    @Published private(set) var discoverCount = 0
    @Published private(set) var scanCallCount = 0
    @Published private(set) var lastScanStartText: String?
    @Published private(set) var entries: [ProbeEntry] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var retryRemainingCycles = 0
    @Published private(set) var infoPlistRows: [String] = []

    private var central: CBCentralManager?
    private var registry: [UUID: ProbeEntry] = [:]
    private var lastState: String = "—"
    private var lastAuthorization: String = "—"
    private var lastScanningFlag = false
    private var retryTimer: Timer?
    private var refreshTimer: Timer?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    override init() {
        super.init()
        collectInfoPlist()
    }

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshFlags()
            }
        }
        scanCallCount += 1
        if let central {
            central.scanForPeripherals(withServices: nil, options: nil)
            if central.state == .poweredOn {
                log("スキャン開始 (呼出#\(scanCallCount)) @ scanForPeripherals(nil)")
            }
        }
        refreshFlags()
    }

    /// 再試行モード: 30秒間・5秒毎に stopScan → 再スキャン。
    func startRetryMode() {
        retryTimer?.invalidate()
        stopCurrentScan()
        retryRemainingCycles = 6
        runRetryCycle()
    }

    private func runRetryCycle() {
        guard retryRemainingCycles > 0 else { return }
        scanCallCount += 1
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("再試行#\(7 - retryRemainingCycles): scanForPeripherals 呼出(#\(scanCallCount))・周期5秒")
        refreshFlags()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopCurrentScan()
            self.log("再試行: stopScan 実行(5秒経過)")
            self.refreshFlags()
            self.retryRemainingCycles -= 1
            if self.retryRemainingCycles > 0 {
                self.runRetryCycle()
            } else {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.log("再試行モード終了(30秒)")
            }
        }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak work] _ in
            work?.perform()
        }
    }

    private func stopCurrentScan() {
        if let central, central.state == .poweredOn {
            central.stopScan()
        }
    }

    private func refreshFlags() {
        guard let central else { return }
        updateDiagnostics(historyCheck: true)
    }

    private func collectInfoPlist() {
        let info = Bundle.main.infoDictionary ?? [:]
        let usage = info["NSBluetoothAlwaysUsageDescription"] as? String
        let background = info["UIBackgroundModes"] as? [String]
        var rows: [String] = []
        rows.append("NSBluetoothAlwaysUsageDescription=\(usage ?? "(未設定)")")
        rows.append("UIBackgroundModes=\(background?.isEmpty == false ? background!.joined(separator: ",") : "(なし)")")
        if let legacy = info["NSBluetoothPeripheralUsageDescription"] as? String {
            rows.append("NSBluetoothPeripheralUsageDescription=\(legacy)")
        } else {
            rows.append("NSBluetoothPeripheralUsageDescription=(未設定)")
        }
        rows.append("CFBundleIdentifier=\(info["CFBundleIdentifier"] as? String ?? "—")")
        infoPlistRows = rows
    }

    private func log(_ note: String) {
        let row = "\(Self.timeFormatter.string(from: Date())) \(note)"
        history.insert(row, at: 0)
        if history.count > 200 {
            history.removeLast(50)
        }
    }

    private func updateDiagnostics(historyCheck: Bool) {
        guard let central else {
            stateText = "未初期化"
            return
        }
        let newState: String = {
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
        let newAuthorization: String = {
            switch central.authorization {
            case .allowedAlways: return "allowedAlways"
            case .denied: return "denied"
            case .notDetermined: return "notDetermined"
            case .restricted: return "restricted"
            @unknown default: return "不明"
            }
        }()
        stateText = newState
        authorizationText = newAuthorization
        isScanning = central.isScanning
        if historyCheck {
            if newState != lastState {
                log("state: \(lastState) → \(newState)")
                lastState = newState
            }
            if newAuthorization != lastAuthorization {
                log("authorization: \(lastAuthorization) → \(newAuthorization)")
                lastAuthorization = newAuthorization
            }
            if central.isScanning != lastScanningFlag {
                log("isScanning: \(lastScanningFlag) → \(central.isScanning)")
                lastScanningFlag = central.isScanning
            }
        }
        entries = registry.values.sorted { $0.count > $1.count }.prefix(80).map { $0 }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, central.authorization == .allowedAlways {
            scanCallCount += 1
            central.scanForPeripherals(withServices: nil, options: nil)
            log("state 遷移に伴うスキャン開始 (呼出#\(scanCallCount))")
        }
        updateDiagnostics(historyCheck: true)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSInteger
    ) {
        discoverCount += 1
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "(名前未取得)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }
            .joined(separator: ",")
        var entry = registry[peripheral.identifier] ?? ProbeEntry(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI,
            services: services.isEmpty ? "(なし)" : services,
            count: 0,
            idPrefix: String(peripheral.identifier.uuidString.prefix(8)).uppercased()
        )
        entry.rssi = RSSI
        entry.count += 1
        if !name.contains("(名前未取得)") && entry.name.contains("(名前未取得)") {
            entry.name = name
        }
        registry[peripheral.identifier] = entry
        updateDiagnostics(historyCheck: true)
    }
}
