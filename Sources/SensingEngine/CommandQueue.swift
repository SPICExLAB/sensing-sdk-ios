import Foundation

/// Runs public commands one at a time, in the order they were called. A `@MainActor` method re-enters at every `await`, so
/// without this a double tap on Start, or a Stop during Start, would interleave.
@MainActor
public final class CommandQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in _ = await task.result }
        return try await task.value
    }
}
