import SwiftUI
import UIKit
import CoreBluetooth

/// REQ A-4: スキャン機能だけを独立して確認する最小画面。
/// 既存の BLEService とは別に新しい CBCentralManager を1つだけ作り、
/// serviceUUIDs=nil・オプションなしで scanForPeripherals する。
struct ScanProbeView: View {
    @StateObject private var probe = ScanProbe()

    var body: some View {
        List {
            Section("Central 状態(診断A-1/A-4)") {
                probeRow("state", value: probe.stateText)
                probeRow("authorization", value: probe.authorizationText)
                probeRow("isScanning(CoreBluetooth)", value: probe.isScanning ? "YES" : "NO")
                probeRow("didDiscover 呼出数", value: "\(probe.discoverCount)")
                Button("スキャン再開") { probe.start() }
                    .buttonStyle(.bordered)
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
                Text("発見できた全デバイス(オプションなし・nil指定)")
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
    @Published private(set) var entries: [ProbeEntry] = []

    private var central: CBCentralManager?
    private var registry: [UUID: ProbeEntry] = [:]

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        guard let central else {
            stateText = "未初期化"
            return
        }
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
        authorizationText = {
            switch central.authorization {
            case .allowedAlways: return "allowedAlways"
            case .denied: return "denied"
            case .notDetermined: return "notDetermined"
            case .restricted: return "restricted"
            @unknown default: return "不明"
            }
        }()
        isScanning = central.isScanning
        entries = registry.values.sorted { $0.count > $1.count }.prefix(80).map { $0 }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, central.authorization == .allowedAlways {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
        updateDiagnostics()
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
        updateDiagnostics()
    }
}
