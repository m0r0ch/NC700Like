import UIKit

/// バックグラウンド処理時間の確保(Phase 4)。
/// 押下 → いいねの HTTP 処理がバックグラウンドで完走できるよう beginBackgroundTask で
/// 実行時間を確保し、完了時に解放する。確保数は ContentView の実行環境セクションに出す。
@MainActor
final class BackgroundTaskManager: ObservableObject {
    static let shared = BackgroundTaskManager()

    @Published private(set) var activeCount = 0
    private var identifiers: [UIBackgroundTaskIdentifier] = []

    /// 実行時間の確保。戻り値の Identifier を endTask に渡して必ず解放すること。
    @discardableResult
    func beginTask(reason: String = "NC700Like 処理") -> UIBackgroundTaskIdentifier {
        let retained = UIApplication.shared.beginBackgroundTask(withName: reason) {
            Task { @MainActor in self.endTask(retained) }
        }
        identifiers.append(retained)
        activeCount = identifiers.count
        return retained
    }

    func endTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        if let index = identifiers.firstIndex(of: id) {
            identifiers.remove(at: index)
        }
        UIApplication.shared.endBackgroundTask(id)
        activeCount = identifiers.count
    }
}
