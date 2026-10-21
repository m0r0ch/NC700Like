import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var ble = BLEService()

    var body: some View {
        NavigationStack {
            List {
                Section("接続状態") {
                    HStack(spacing: 12) {
                        statusIcon
                        Text(ble.phase.label)
                            .font(.body)
                    }
                    diagnosticRow("認可", value: ble.authorizationText)
                    diagnosticRow("state", value: ble.stateText)
                    diagnosticRow("スキャン中", value: ble.isScanning ? "YES" : "—")
                    diagnosticRow("didDiscover 呼出数", value: "\(ble.discoverCallbackCount)")
                    diagnosticRow("最終発見", value: ble.lastDiscoveredName ?? "—")
                    HStack {
                        Text("7B61 購読")
                        Spacer()
                        Text(ble.subscribed7B61 ? "7B61購読済み ✓" : "—")
                            .foregroundStyle(ble.subscribed7B61 ? .green : .secondary)
                    }
                    HStack {
                        Text("FE03 購読")
                        Spacer()
                        Text(ble.subscribedFE03 ? "FE03購読済み ✓" : "—")
                            .foregroundStyle(ble.subscribedFE03 ? .green : .secondary)
                    }
                    Button("再接続 / スキャン開始") {
                        ble.connectExplicit()
                    }
                }

                Section("押下検出") {
                    HStack {
                        Text("検出回数")
                        Spacer()
                        Text("\(ble.pressCount)")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("最終検出")
                        Spacer()
                        Text(ble.lastPressAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("音声受付セッション")
                        Spacer()
                        Text("\(ble.audioSessionCount)")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("FE03 パケット数")
                        Spacer()
                        Text("\(ble.audioPacketCount)")
                            .monospacedDigit()
                    }
                }

                Section {
                    ForEach(ble.discoveredDevices.prefix(40)) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if device.matches {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                }
                                Text(device.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text("RSSI \(device.rssi)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("id=\(device.idPrefix) services=\(device.servicesText) 観測\(device.seenCount)回")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .contextMenu {
                            Button("この行をコピー") {
                                UIPasteboard.general.string = device.rowText
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("スキャン一覧(発見できた全デバイス)")
                        Spacer()
                        if !ble.discoveredDevices.isEmpty {
                            Button("一覧をコピー") {
                                UIPasteboard.general.string = ble.discoveredAllText
                            }
                            .font(.caption)
                        }
                    }
                } footer: {
                    Text("★=名前またはFDD2が一致した対象。0件ならNC700の広告そのものが飛んでいない状態です。")
                }

                Section {
                    ForEach(ble.serviceCatalog) { service in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("サービス \(service.uuid)")
                                .font(.caption.bold())
                            ForEach(service.characteristics) { char in
                                Text("\(char.uuid) [\(char.properties)]")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("サービス/特性カタログ(接続後の実見)")
                        Spacer()
                        if !ble.serviceCatalog.isEmpty {
                            Button("一覧をコピー") {
                                UIPasteboard.general.string = ble.catalogAllText
                            }
                            .font(.caption)
                        }
                    }
                } footer: {
                    Text("FE03の書き込み用特性(write)の有無を確認するのに使えます。")
                }

                Section {
                    ForEach(ble.logs) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(entry.timeText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(entry.kindText)
                                    .font(.caption2.bold())
                                    .foregroundStyle(kindColor(entry.kind))
                            }
                            if let hex = entry.hex {
                                Text(hex)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            if !entry.note.isEmpty {
                                Text(entry.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .contextMenu {
                            Button("HEX をコピー") {
                                UIPasteboard.general.string = entry.hex ?? ""
                            }
                            Button("行全体をコピー") {
                                UIPasteboard.general.string = ble.copyText(of: entry)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("ログ(新着順、最大100件)")
                        Spacer()
                        if !ble.logs.isEmpty {
                            Button("クリア") {
                                ble.clearLogs()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("NC700Like 診断")
        }
    }

    private func diagnosticRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch ble.phase {
        case .subscribed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .connected, .connecting, .scanning:
            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func kindColor(_ kind: BLELogEntry.Kind) -> Color {
        switch kind {
        case .connection: return .blue
        case .discovery: return .indigo
        case .notification: return .secondary
        case .press: return .green
        case .audio: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    ContentView()
}
