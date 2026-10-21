import SwiftUI

/// スキャンだけを確認する最小アプリ(BLEScanMin)。
/// NC700Like 本体と bundle ID・ アプリ名を分け、アーティファクトも別 IPA。
@main
struct ScanMinApp: App {
    var body: some Scene {
        WindowGroup {
            ScanMinListView()
        }
    }
}
