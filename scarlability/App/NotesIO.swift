import Foundation

/// The one queue that reads and writes the notes folder. Library actions and note saves share it,
/// so they always happen in the order they were asked for (a rename never races a save).
enum NotesIO {
    nonisolated static let queue = DispatchQueue(label: "scarlability.notes-io")

    /// Runs file work on the queue and waits for it.
    nonisolated static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
