import SwiftUI

struct ContentView: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("NC700Like")
                .font(.largeTitle)
                .bold()
            Text("Phase 0")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Version \(versionText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Phase 1 以降で BLE 接続と Spotify 連携を追加します。\nIPA の署名とインストール確認用の空アプリです。")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
