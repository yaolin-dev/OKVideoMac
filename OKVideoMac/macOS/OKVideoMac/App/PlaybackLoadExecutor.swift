import Foundation

/// Revalidates ownership at each asynchronous loading boundary. Resource cleanup
/// stays with the caller that captured the lease, even after ownership expires.
@MainActor struct PlaybackLoadExecutor {
    let isCurrent: () -> Bool

    func checkOwnership() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }

    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        try checkOwnership()
        let result = try await operation()
        try checkOwnership()
        return result
    }
}
