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
    /// 同一曲(glue=「: 」の後の曲名)の連続通知は15秒内を1件にまとめる(二重通知防止)。
    func postLikeResult(_ message: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let trackKey = trackKey(of: message)
        if trackKey == lastTrackKey, Date().timeIntervalSince(lastPostedAt) < 15 {
            return
        }
        lastTrackKey = trackKey
        lastPostedAt = Date()
        let content = UNMutableNotificationContent()
        content.title = "NC700Like"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// 「いいね追加: 曲名」「既にいいね済みのため追加しません: 曲名」の曲名部分だけを比較キーにする。
    private func trackKey(of message: String) -> String {
        guard let separator = message.range(of: ": "), separator.upperBound <= message.endIndex else {
            return message
        }
        return String(message[separator.upperBound...])
    }

    private var lastTrackKey: String?
    private var lastPostedAt = Date.distantPast
}

extension NotificationManager: UNUserNotificationCenterDelegate {}
