import SwiftUI

@main
struct NC700LikeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Cold Start(バックグラウンド起動)でも押下を拾えるよう App 起動時に接続する。
        LikeCoordinator.shared.attach()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, _ in
            NotificationManager.shared.requestAuthorizationIfNeeded()
        }
    }
}
