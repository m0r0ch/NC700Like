import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var ble = BLEService()
    @State private var debugHex = DebugPreset.p1.template

    var body: some View {
        NavigationStack {
            List {
                Section("接続状態") {
                    HStack(spacing: 12) {
                        statusIcon
                        Text(ble.phase.label)
                            .font(.body)
                    }
                    diagnosticRow("接続経路", value: ble.connectionRoute)
                    diagnosticRow("認可", value: ble.authorizationText)
                    diagnosticRow("state", value: ble.stateText)
                    diagnosticRow("isScanning(自前フラグ)", value: ble.isScanning ? "YES" : "NO")
                    diagnosticRow("isScanning(CoreBluetooth)", value: ble.isScanningCore ? "YES" : "NO")
                    diagnosticRow("didDiscover 呼出数", value: "\(ble.discoverCallbackCount)")
                    diagnosticRow("最終発見", value: ble.lastDiscoveredName ?? "—")
                    diagnosticRow("7B61 購読", value: ble.subscribed7B61 ? "7B61購読済み ✓" : "—")
                    diagnosticRow("FE03 購読", value: ble.subscribedFE03 ? "FE03購読済み ✓" : "—")
                    Button("手動で再接続 / スキャン") {
                        ble.connectExplicit()
                    }
                }

                Section {
                    Text("接続できないとき: nRF Connect で NC700 に接続してから、下のボタンを押してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("識別子を再取得(システム接続を探す)") {
                        ble.reacquireIdentifier()
                    }
                } header: {
                    Text("デバイス再取得(B-7)")
                } footer: {
                    Text("電源入れ直しで識別子が変わった疑いがある場合に使います。")
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

                Section("FE03 手動送信(デバッグ用・未検証)") {
                    HStack {
                        Text("直近制御パケット末尾({ID})")
                        Spacer()
                        Text(ble.lastControlTerminalHex ?? "—")
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "HEX(スペース区切り可、{ID}は末尾バイトに置換)",
                        text: $debugHex
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    HStack {
                        ForEach(DebugPreset.allCases) { preset in
                            Button(preset.rawValue) {
                                debugHex = preset.template
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Picker("制御パケット受信時の自動送信", selection: $ble.autoSendMode) {
                        ForEach(AutoSendMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("このHEXを書き込む(.withResponse)") {
                        ble.sendDebug(hexString: debugHex, trigger: "手動")
                    }
                    Text("P1/P2/P3 は仮説の未検証データです。書込結果と送信後の 7B61・FE03 の受信はログに出ます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                        Text("ログ(新着順、最大100件・時刻はミリ秒)")
                        Spacer()
                        Button("全ログをコピー") {
                            UIPasteboard.general.string = ble.allLogsText
                        }
                        .font(.caption)
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("ScanProbe") {
                        ScanProbeView()
                    }
                    .font(.caption)
                }
            }
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
        case .connected, .pending, .scanning:
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
        case .control: return .purple
        case .error: return .red
        }
    }
}

#Preview {
    ContentView()
}
