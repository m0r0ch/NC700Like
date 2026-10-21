import SwiftUI
import CoreBluetooth

/// NC700Like 本体とは無関係に、CBCentralManager の広告受信だけを観測する名簿。
final class ScanMinService: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct Device: Identifiable {
        let id: UUID
        var name: String
        var services: String
        var rssi: NSInteger
        var count: Int
        var idPrefix: String
    }

    @Published private(set) var stateText = "初期化中"
    @Published private(set) var authorizationText = "—"
    @Published private(set) var discoverCount = 0
    @Published private(set) var devices: [Device] = []
    @Published private(set) var lastDiscoveryText: String?

    private var central: CBCentralManager!
    private var registry: [UUID: Device] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateText = "poweredOn"
        default:
            break
        }
        stateText = stateName(central.state)
        authorizationText = "\(central.authorization)"
        if central.state == .poweredOn { scan() }
    }

    private func stateName(_ state: CBCentralManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "不明"
        }
    }

    private func scan() {
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
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
        var device = registry[peripheral.identifier] ?? Device(
            id: peripheral.identifier,
            name: name,
            services: services.isEmpty ? "(なし)" : services,
            rssi: RSSI,
            count: 0,
            idPrefix: String(peripheral.identifier.uuidString.prefix(8)).uppercased()
        )
        device.rssi = RSSI
        device.count += 1
        if !name.contains("(名前未取得)") && device.name.contains("(名前未取得)") {
            device.name = name
        }
        registry[peripheral.identifier] = device
        lastDiscoveryText = "\(name) / services=\(device.services) / RSSI=\(RSSI)"
        devices = registry.values
            .sorted { $0.count > $1.count }
            .prefix(80)
            .map { $0 }
    }
}

struct ScanMinListView: View {
    @StateObject private var service = ScanMinService()

    var body: some View {
        List {
            Section("状態") {
                HStack {
                    Text("state / auth")
                    Spacer()
                    Text("\(service.stateText) / \(service.authorizationText)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("didDiscover 呼出数")
                    Spacer()
                    Text("\(service.discoverCount)").monospacedDigit()
                }
                if let last = service.lastDiscoveryText {
                    Text("最終発見: \(last)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Section {
                ForEach(service.devices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(device.name) / RSSI \(device.rssi) ×\(device.count)")
                            .lineLimit(1)
                        Text("id=\(device.idPrefix) services=\(device.services)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("発見デバイス(nil・他アプリ無し)")
            } footer: {
                Text("本アプリ単独でも NC700 系の広告が1台も出ない場合、デバイス側ではなく iOS/認可側の静的な問題と結論付けられます。")
            }
        }
        .navigationTitle("BLEScanMin")
        .navigationBarTitleDisplayMode(.inline)
    }
}
