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
                    Button("手動で再接続 / スキャン") {
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
            .navigationTitle("NC700Like")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch ble.phase {
        case .subscribed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .connected, .connecting, .scanning:
            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func kindColor(_ kind: BLELogEntry.Kind) -> Color {
        switch kind {
        case .connection: return .blue
        case .notification: return .secondary
        case .press: return .green
        case .error: return .red
        }
    }
}

#Preview {
    ContentView()
}
