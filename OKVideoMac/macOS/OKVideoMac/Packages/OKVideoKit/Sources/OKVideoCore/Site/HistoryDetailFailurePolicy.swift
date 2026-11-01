import Foundation

public enum HistoryDetailFailurePolicy {
    public static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(url.code)
        }
        if permitsTitleRecovery(error) { return false }
        if case AppError.network = error { return true }
        let message = error.localizedDescription.lowercased()
        return ["socket is closed", "connection reset", "connection closed", "timed out", "timeout", "连接被重置", "网络连接已中断"].contains { message.contains($0) }
    }

    public static func permitsTitleRecovery(_ error: Error) -> Bool {
        if case AppError.contentUnavailable = error { return true }
        // Only an explicit missing/gone response establishes an invalid ID.
        if case AppError.network(let message) = error {
            return message.range(of: #"\bHTTP\s*[:：]?\s*(404|410)\b"#, options: .regularExpression) != nil
        }
        return false
    }
}
