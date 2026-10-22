import UIKit
import UserNotifications

/// 押下結果の通知(Phase 4)。
/// - 許可は初回起動(scenePhase 変化時)に1回だけリクエストする。
/// - 投稿はアプリが非アクティブのときのみ(BuildView に結果が出るフォアグランドでは鳴らさない)。
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var authorizationText = "未確認"

    private let center = UNUserNotificationCenter.current()

    override private init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                authorizationText = granted ? "許可済み ✓" : "拒否"
            case .denied:
                authorizationText = "拒否(設定 → NC700Like → 通知)"
            case .authorized, .provisional, .ephemeral:
                authorizationText = "許可済み ✓"
            default:
                authorizationText = "未確認"
            }
        }
    }

    /// 押下結果の通知。フォアグランド(iOS 画面を開いて見ているとき)では投稿しない。
    func postLikeResult(_ message: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "NC700Like"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {}
