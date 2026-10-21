import Foundation

/// CI で git commit を差し込む差し込みポイント(ローカル既定・CI 上書き用)。
enum BuildCommit {
    static let sha = "unknown"
}
